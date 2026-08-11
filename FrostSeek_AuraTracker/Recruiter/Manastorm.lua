local MSR = ManastormRecruiter

local function WipeTable(target)
    for key in pairs(target) do target[key] = nil end
end

function MSR:IsInManastorm()
    if C_Manastorm and type(C_Manastorm.IsInManastorm) == "function" then
        local ok, result = pcall(C_Manastorm.IsInManastorm)
        if ok then return result and true or false end
    end
    return false
end

function MSR:GetRosterSignature(roster)
    roster = roster or self:BuildRoster()
    local keys = {}
    for _, member in ipairs(roster) do table.insert(keys, member.key or self:NormalizeName(member.name)) end
    table.sort(keys)
    return table.concat(keys, "|")
end

function MSR:CreateReadyCheckState(roster, initiatorName)
    roster = roster or self:BuildRoster()
    local readyCheck = {
        state = "running",
        startedAt = GetTime(),
        rosterSignature = self:GetRosterSignature(roster),
        responses = {},
        members = {},
        memberOrder = {},
        total = #roster,
        ready = 0,
        notReady = 0,
        waiting = #roster,
        initiatorKey = initiatorName and self:NormalizeName(initiatorName) or nil,
    }
    for _, member in ipairs(roster) do
        readyCheck.members[member.key] = {
            key = member.key,
            name = member.name,
            unit = member.unit,
            raidIndex = member.raidIndex,
            status = "waiting",
        }
        table.insert(readyCheck.memberOrder, member.key)
    end
    if readyCheck.initiatorKey and readyCheck.members[readyCheck.initiatorKey] then
        readyCheck.members[readyCheck.initiatorKey].status = "ready"
    end
    self:RefreshReadyCheckCounts(readyCheck)
    return readyCheck
end

function MSR:ResolveReadyCheckMember(readyCheck, identifier)
    if not readyCheck then return nil end
    local id = tostring(identifier or "")
    local normalized = self:NormalizeName(id)
    local numeric = tonumber(id)
    for _, key in ipairs(readyCheck.memberOrder or {}) do
        local member = readyCheck.members[key]
        if member and (id == tostring(member.unit or "")
            or normalized == member.key
            or (numeric and numeric == tonumber(member.raidIndex))) then
            return member
        end
    end
    return nil
end

function MSR:RefreshReadyCheckCounts(readyCheck)
    if not readyCheck then return end
    local ready, notReady, waiting = 0, 0, 0
    for _, key in ipairs(readyCheck.memberOrder or {}) do
        local member = readyCheck.members[key]
        if member and member.status == "ready" then ready = ready + 1
        elseif member and member.status == "notready" then notReady = notReady + 1
        else waiting = waiting + 1 end
    end
    readyCheck.ready = ready
    readyCheck.notReady = notReady
    readyCheck.waiting = waiting
    readyCheck.total = #(readyCheck.memberOrder or {})
end

function MSR:RefreshReadyCheckMemberStatuses(readyCheck)
    if not readyCheck or type(GetReadyCheckStatus) ~= "function" then
        self:RefreshReadyCheckCounts(readyCheck)
        return
    end
    for _, key in ipairs(readyCheck.memberOrder or {}) do
        local member = readyCheck.members[key]
        if member and member.unit then
            local ok, status = pcall(GetReadyCheckStatus, member.unit)
            if ok and (status == "ready" or status == "notready") then
                member.status = status
            elseif ok and status == "waiting" and member.status ~= "ready" and member.status ~= "notready" then
                member.status = "waiting"
            end
        end
    end
    self:RefreshReadyCheckCounts(readyCheck)
end

function MSR:GetReadyCheckNames(status)
    local readyCheck = self.runtime and self.runtime.readyCheck
    local names = {}
    if not readyCheck then return names end
    for _, key in ipairs(readyCheck.memberOrder or {}) do
        local member = readyCheck.members[key]
        if member and member.status == status then table.insert(names, member.name) end
    end
    return names
end

function MSR:GetReadyCheckMemberStatus(member)
    local readyCheck = self.runtime and self.runtime.readyCheck
    if not member or not readyCheck or readyCheck.state == "stale" or readyCheck.state == "starting" then
        return nil
    end
    local readyMember = readyCheck.members and readyCheck.members[member.key]
    return readyMember and readyMember.status or nil
end

function MSR:InvalidateReadyCheckIfRosterChanged(roster)
    local readyCheck = self.runtime and self.runtime.readyCheck
    if not readyCheck or readyCheck.state == "starting" then return end
    if readyCheck.rosterSignature ~= self:GetRosterSignature(roster) then
        readyCheck.state = "stale"
        readyCheck.passed = false
        self:Print("The roster changed. Run a new Ready Check before entering Manastorm.")
    end
end

function MSR:StartReadyCheck()
    if self:IsInManastorm() then
        self:PrivateWarning("A Ready Check cannot be started inside Manastorm.")
        return false
    end
    if not self:IsGroupLeader() then
        self:PrivateWarning("Only the group leader can start the Ready Check.")
        return false
    end
    local numRaid = GetNumRaidMembers and GetNumRaidMembers() or 0
    local numParty = GetNumPartyMembers and GetNumPartyMembers() or 0
    if numRaid == 0 and numParty == 0 then
        self:PrivateWarning("Create a group before starting the Ready Check.")
        return false
    end
    if type(DoReadyCheck) ~= "function" then
        self:PrivateWarning("The Ready Check API is unavailable.")
        return false
    end

    local roster = self:BuildRoster()
    self.runtime.readyCheck = self:CreateReadyCheckState(roster, UnitName("player"))
    local ok, result = pcall(DoReadyCheck)
    if not ok or result == false then
        self.runtime.readyCheck = nil
        self:PrivateWarning("The Ready Check could not be started.")
        self:RefreshUI()
        return false
    end
    self:Print("Ready Check started. Manastorm Level 1 can still be started regardless of the result.")
    self:RefreshUI()
    return true
end

function MSR:HandleReadyCheckEvent(event, ...)
    if event == "READY_CHECK" then
        local initiatorName = ...
        local roster = self:BuildRoster()
        self.runtime.readyCheck = self:CreateReadyCheckState(roster, initiatorName)
    elseif event == "READY_CHECK_CONFIRM" then
        local id, response = ...
        local readyCheck = self.runtime.readyCheck
        if readyCheck and readyCheck.state == "running" then
            readyCheck.responses[tostring(id)] = response and true or false
            local member = self:ResolveReadyCheckMember(readyCheck, id)
            if member then member.status = response and "ready" or "notready" end
            self:RefreshReadyCheckMemberStatuses(readyCheck)
        end
    elseif event == "READY_CHECK_FINISHED" then
        local readyCheck = self.runtime.readyCheck
        if not readyCheck or readyCheck.state ~= "running" then return end
        local roster = self:BuildRoster()
        if readyCheck.rosterSignature ~= self:GetRosterSignature(roster) then
            readyCheck.state = "stale"
            readyCheck.passed = false
            self:PrivateWarning("Ready Check invalidated because the roster changed.")
            self:RefreshUI()
            return
        end

        self:RefreshReadyCheckMemberStatuses(readyCheck)
        local ready = readyCheck.ready or 0
        local notReady = readyCheck.notReady or 0
        local waiting = readyCheck.waiting or 0
        readyCheck.finishedAt = GetTime()
        readyCheck.passed = #roster > 0 and ready == #roster and notReady == 0 and waiting == 0
        readyCheck.state = readyCheck.passed and "passed" or "failed"
        if readyCheck.passed then
            self:Print(string.format("Ready Check passed: %d/%d ready.", ready, #roster))
        else
            self:PrivateWarning(string.format(
                "Ready Check failed: %d ready, %d not ready, %d unanswered.",
                ready, notReady, waiting
            ))
        end
    end
    self:RefreshUI()
end

function MSR:GetReadyCheckStatusText()
    local readyCheck = self.runtime and self.runtime.readyCheck
    if not readyCheck then return "Ready Check is optional. Manastorm Level 1 can be started at any time." end
    if readyCheck.state == "starting" then return "Entering Manastorm Level 1..." end
    if readyCheck.state == "stale" then return "Roster changed after the Ready Check. Start remains available." end
    if readyCheck.state == "running" then self:RefreshReadyCheckMemberStatuses(readyCheck) end

    local parts = { string.format("Ready Check: %d/%d ready", readyCheck.ready or 0, readyCheck.total or 0) }
    local notReady = self:GetReadyCheckNames("notready")
    local waiting = self:GetReadyCheckNames("waiting")
    if #notReady > 0 then table.insert(parts, "Not ready: " .. table.concat(notReady, ", ")) end
    if #waiting > 0 then table.insert(parts, "Waiting: " .. table.concat(waiting, ", ")) end
    if readyCheck.state ~= "running" and readyCheck.state ~= "passed" then table.insert(parts, "Start remains available") end
    return table.concat(parts, " | ") .. "."
end

function MSR:CanStartManastormLevelOne()
    if self:IsInManastorm() then return false, "Already inside Manastorm." end
    if self.runtime and self.runtime.rebuild then return false, "Finish the raid rebuild first." end
    if not self:IsGroupLeader() then return false, "Only the group leader can enter Manastorm." end
    if type(C_Manastorm) ~= "table" or type(C_Manastorm.Enter) ~= "function" then
        return false, "Ascension's Manastorm enter API is unavailable."
    end
    return true
end

function MSR:DisableAutoPostForManastorm()
    if not self.db or not self.db.settings then return end
    local wasEnabled = self.db.settings.autoPost == true
    self.db.settings.autoPost = false
    self.runtime.lastAutoPostAttempt = nil
    if wasEnabled then self:Print("Auto post disabled for the Manastorm run.") end
end

function MSR:ClearWaitingApplicantsForManastorm()
    local session = self.char and self.char.session
    if not session or type(session.applicants) ~= "table" then return 0 end

    -- Refresh group membership first so every player currently in the raid is
    -- retained with their role and Aura assignment.
    self:BuildRoster()

    local removed = 0
    for key, applicant in pairs(session.applicants) do
        if type(applicant) ~= "table" or applicant.status ~= "Joined" then
            session.applicants[key] = nil
            removed = removed + 1
        end
    end

    local retainedOrder = {}
    for _, key in ipairs(session.order or {}) do
        if session.applicants[key] then table.insert(retainedOrder, key) end
    end
    session.order = session.order or {}
    WipeTable(session.order)
    for _, key in ipairs(retainedOrder) do table.insert(session.order, key) end
    self.runtime.groupOptimization = nil
    return removed
end

function MSR:StopRecruitmentForManastorm()
    local session = self.char and self.char.session
    if not session then return 0 end
    local wasListening = session.listening == true
    session.listening = false
    local removed = self:ClearWaitingApplicantsForManastorm()
    self:DisableAutoPostForManastorm()
    if wasListening or removed > 0 then
        self:Print(string.format(
            "Listening disabled and waiting list cleared (%d player%s removed).",
            removed,
            removed == 1 and "" or "s"
        ))
    end
    return removed
end

function MSR:StartManastormLevelOne()
    local allowed, reason = self:CanStartManastormLevelOne()
    if not allowed then
        self:PrivateWarning(reason or "Manastorm Level 1 cannot be started yet.")
        self:RefreshUI()
        return false
    end

    if type(C_Manastorm.CanEnter) == "function" then
        local canEnterOk, canEnter = pcall(C_Manastorm.CanEnter, 1)
        if not canEnterOk or canEnter == false then
            self:Print("Ascension currently reports CanEnter=false; sending the manual Level 1 start request anyway.")
        end
    end

    local ok, result = pcall(C_Manastorm.Enter, 1)
    if not ok or result == false then
        self:PrivateWarning("Ascension rejected the Manastorm Level 1 start request.")
        return false
    end
    self.runtime.readyCheck = self.runtime.readyCheck or {}
    self.runtime.readyCheck.state = "starting"
    self:StopRecruitmentForManastorm()
    self:Print("Manastorm Level 1 start requested. Waiting for entry confirmation.")
    self:RefreshUI()
    return true
end

function MSR:GetValidationIssues(roster)
    roster = roster or self:BuildRoster()
    local counts = self:GetCounts(roster)
    local slots = self.db.settings.slots
    local issues = {}
    if counts.total ~= self:GetTargetTotal() then table.insert(issues, string.format("Players %d/%d", counts.total, self:GetTargetTotal())) end
    if counts.tank ~= slots.tank then table.insert(issues, string.format("Tanks %d/%d", counts.tank, slots.tank)) end
    if counts.heal ~= slots.heal then table.insert(issues, string.format("Healers %d/%d", counts.heal, slots.heal)) end
    if counts.dps ~= slots.dps then table.insert(issues, string.format("DPS %d/%d", counts.dps, slots.dps)) end
    local tracker = _G.FrostSeekAuraTracker
    local frostSeekOwnsAuraValidation = tracker and tracker.Runtime and
        type(tracker.Runtime.getAuraState) == "function"
    if not frostSeekOwnsAuraValidation and counts.aura < slots.aura then
        table.insert(issues, string.format("Auras %d/%d", counts.aura, slots.aura))
    end
    if counts.unknown > 0 then table.insert(issues, string.format("Unknown roles %d", counts.unknown)) end

    if not frostSeekOwnsAuraValidation then
        local requiredAuraGroups = math.min(3, slots.aura or 0)
        for group = 1, requiredAuraGroups do
            local hasAura = false
            for _, member in ipairs(roster) do
                if member.subgroup == group and member.aura == true then hasAura = true break end
            end
            if not hasAura then table.insert(issues, "Group " .. group .. " has no Aura") end
        end
    end
    return issues
end

function MSR:ValidateInsideManastorm()
    if not self:IsInManastorm() then return end
    local issues = self:GetValidationIssues(self:BuildRoster())
    local signature = table.concat(issues, " | ")
    if signature ~= "" and signature ~= self.runtime.lastValidationSignature then
        self:LocalWarning("Manastorm roster warning: " .. signature)
    end
    self.runtime.lastValidationSignature = signature
end

function MSR:SendRaidWarning(message)
    message = self:PrepareChatMessage(message)
    if message == "" then return false end
    if GetNumRaidMembers and GetNumRaidMembers() > 0 and self:CanManageRaid() then
        local ok = pcall(SendChatMessage, message, "RAID_WARNING")
        if ok then return true end
    end
    self:LocalWarning(message)
    return false
end

function MSR:GetAuraPlayerNames(roster)
    roster = roster or self:BuildRoster()
    local names = {}
    for _, member in ipairs(roster) do
        if member.aura == true then table.insert(names, member.name) end
    end
    if #names == 0 then return "None" end
    return table.concat(names, ", ")
end

function MSR:GetPlayerLevelMessageKey(level)
    level = tonumber(level) or 0
    if level >= 60 then return "level60StatusPost" end
    if level == 59 then return "level59StatusPost" end
    return "belowLevel59StatusPost"
end

function MSR:BuildLevelStatusMessage(roster, level)
    roster = roster or self:BuildRoster()
    level = tonumber(level) or tonumber(UnitLevel("player")) or 0
    local counts = self:GetCounts(roster)
    return self:PrepareChatMessage(self:BuildConfiguredMessage(self:GetPlayerLevelMessageKey(level), self:BuildMessageValues(counts, {
        player = UnitName("player") or "Unknown",
        level = level,
        auraPlayers = self:GetAuraPlayerNames(roster),
    })))
end

function MSR:BuildLevel60StatusMessage(roster)
    return self:BuildLevelStatusMessage(roster, 60)
end
function MSR:LeaveManastormOnly()
    if not self:IsInManastorm() then
        self:PrivateWarning("You are not inside Manastorm.")
        return false
    end
    if type(C_Manastorm) ~= "table" or type(C_Manastorm.Leave) ~= "function" then
        self:PrivateWarning("Ascension's Manastorm leave API is unavailable. Leave Manastorm manually.")
        return false
    end
    local ok, result = pcall(C_Manastorm.Leave)
    if not ok or result == false then
        self:PrivateWarning("Ascension rejected the Manastorm exit. Try again manually.")
        return false
    end
    self:Print("Manastorm exit requested.")
    self:RefreshUI()
    return true
end

function MSR:PostLevelStatus()
    local inRaid = GetNumRaidMembers and GetNumRaidMembers() > 0
    local inParty = GetNumPartyMembers and GetNumPartyMembers() > 0
    if self:IsInManastorm() and not inRaid and not inParty then
        return self:LeaveManastormOnly()
    end
    local level = tonumber(UnitLevel("player")) or 0
    local messageKey = self:GetPlayerLevelMessageKey(level)
    local message = self:BuildLevelStatusMessage(nil, level)
    if self:GetMessageRoute(messageKey) ~= "OFF" and message == "" then
        self:PrivateWarning("The level status message is empty. Open Edit messages and configure it first.")
        return false
    end
    if not self:SendConfiguredMessage(messageKey, message) then return false end
    local nextPhase = self:IsInManastorm() and "leaving-manastorm" or "leaving-group"
    self.runtime.pendingLeave = {
        phase = "waiting-after-post",
        nextPhase = nextPhase,
        startedAt = GetTime(),
        continueAt = GetTime() + 1,
        deadline = GetTime() + 13,
    }
    return self:UpdatePendingLeave(true)
end

function MSR:LeaveCurrentGroupAfterStatus()
    if type(LeaveParty) ~= "function" then
        self.runtime.pendingLeave = nil
        self:PrivateWarning("The leave-group API is unavailable. Leave the group manually.")
        return false
    end
    local ok, result = pcall(LeaveParty)
    if not ok or result == false then
        self.runtime.pendingLeave = nil
        self:PrivateWarning("The group could not be left automatically. Leave it manually.")
        return false
    end
    self.runtime.pendingLeave = nil
    self:Print("Leave-group request sent. Raid lead will pass automatically.")
    self:RefreshUI()
    return true
end

function MSR:UpdatePendingLeave(fromClick)
    local pending = self.runtime and self.runtime.pendingLeave
    if not pending then return false end
    if pending.phase == "waiting-after-post" then
        if GetTime() < (pending.continueAt or 0) then return true end
        pending.phase = pending.nextPhase or "leaving-group"
        pending.nextPhase = nil
    end
    if pending.phase == "leaving-group" then
        return self:LeaveCurrentGroupAfterStatus()
    end
    if pending.phase ~= "leaving-manastorm" then return false end

    if not self:IsInManastorm() then
        pending.phase = "leaving-group"
        return self:LeaveCurrentGroupAfterStatus()
    end
    if not pending.requested then
        if type(C_Manastorm) ~= "table" or type(C_Manastorm.Leave) ~= "function" then
            self.runtime.pendingLeave = nil
            self:PrivateWarning("Leave Manastorm manually, then leave the group. Ascension's leave API is unavailable.")
            return false
        end
        local ok, result = pcall(C_Manastorm.Leave)
        if not ok or result == false then
            self.runtime.pendingLeave = nil
            self:PrivateWarning("Ascension rejected the Manastorm exit. Try Post & Leave again.")
            return false
        end
        pending.requested = true
        self:Print("Manastorm exit requested. The group will be left after exit confirmation.")
        self:RefreshUI()
        return true
    end
    if GetTime() >= (pending.deadline or 0) then
        self.runtime.pendingLeave = nil
        self:PrivateWarning("Manastorm exit was not confirmed. The group was not left; try again manually.")
        self:RefreshUI()
        return false
    end
    return true
end


-- Kept as a compatibility alias for older buttons and macros.
function MSR:PostLevel60Status()
    return self:PostLevelStatus()
end

function MSR:ScanForLevel60()
    if not self:IsInManastorm() then return end
    local roster = self:BuildRoster()
    for _, member in ipairs(roster) do
        local level = tonumber(member.level) or 0
        if level == 59 and not self.char.session.level59Alerted[member.key] then
            self.char.session.level59Alerted[member.key] = true
            local message = self:BuildConfiguredMessage("level59Warning", {
                player = member.name,
                level = level,
            })
            self:SendConfiguredMessage("level59Warning", message)
        end
        if level >= 60 and not self.char.session.level60Alerted[member.key] then
            self.char.session.level60Alerted[member.key] = true
            self.char.session.needsRebuild = true
            local message = self:BuildConfiguredMessage("level60Warning", {
                player = member.name,
                level = level,
            })
            self:SendConfiguredMessage("level60Warning", message)
        end
    end
end
