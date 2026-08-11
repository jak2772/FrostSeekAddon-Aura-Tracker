local MSR = ManastormRecruiter
local REBUILD_RETURN_TIMEOUT = 10

function MSR:SetRebuildRecoveryStage(stage)
    local recovery = self.char and self.char.session and self.char.session.rebuildRecovery
    if type(recovery) == "table" and recovery.active == true then
        recovery.stage = stage
        recovery.updatedAt = time()
    end
end

function MSR:SnapshotRosterForRebuild()
    local removalSnapshot = {}
    local reinviteSnapshot = {}
    local excluded = {}
    local playerKey = self:NormalizeName(UnitName("player") or "")
    for _, member in ipairs(self:BuildRoster()) do
        if member.key ~= playerKey then
            local stored = {
                key = member.key,
                name = member.name,
                role = member.role,
                aura = member.aura,
                subgroup = member.subgroup,
                level = member.level,
            }
            table.insert(removalSnapshot, stored)
            if (tonumber(member.level) or 0) >= 60 then
                table.insert(excluded, stored)
            else
                table.insert(reinviteSnapshot, stored)
            end
        end
    end
    return removalSnapshot, reinviteSnapshot, excluded
end

function MSR:BeginRebuild()
    if self.runtime.rebuild then self:LocalWarning("A raid rebuild is already running.") return false end
    if not (GetNumRaidMembers and GetNumRaidMembers() > 0) then self:LocalWarning("Raid rebuild requires an active raid.") return false end
    if not (IsRaidLeader and IsRaidLeader()) then self:LocalWarning("Only the raid leader can rebuild the raid.") return false end

    local removalSnapshot, reinviteSnapshot, excluded = self:SnapshotRosterForRebuild()
    if #removalSnapshot == 0 then self:LocalWarning("There are no raid members to rebuild.") return false end

    local reinviteByKey = {}
    for _, member in ipairs(reinviteSnapshot) do reinviteByKey[member.key] = true end

    self.char.session.lastRebuildRoster = reinviteSnapshot
    self.char.session.rebuildRecovery = {
        active = true,
        removalSnapshot = removalSnapshot,
        reinviteSnapshot = reinviteSnapshot,
        excluded = excluded,
        startedAt = time(),
        stage = "removing",
    }
    self:SendConfiguredMessage("rebuildAnnouncement", self:BuildConfiguredMessage("rebuildAnnouncement"))
    self.runtime.rebuild = {
        phase = "countdown",
        snapshot = removalSnapshot,
        removalSnapshot = removalSnapshot,
        reinviteSnapshot = reinviteSnapshot,
        reinviteByKey = reinviteByKey,
        excluded = excluded,
        index = 1,
        deadline = GetTime() + 5,
        nextAction = 0,
        startedAt = GetTime(),
        expectedTotal = #reinviteSnapshot + 1,
    }
    self:Print("Raid rebuild starts in 5 seconds. Use Cancel to abort before removal begins.")
    self:RefreshUI()
    return true
end

function MSR:CancelRebuild()
    local rebuild = self.runtime.rebuild
    if not rebuild then return end
    if rebuild.phase ~= "countdown" then
        self:LocalWarning("The rebuild can no longer be cancelled because removal has started.")
        return
    end
    self.runtime.rebuild = nil
    self.char.session.rebuildRecovery = { active = false }
    self:Print("Raid rebuild cancelled.")
    self:RefreshUI()
end
function MSR:HasRebuildRecovery()
    local recovery = self.char and self.char.session and self.char.session.rebuildRecovery
    return type(recovery) == "table" and recovery.active == true
        and type(recovery.removalSnapshot) == "table"
        and type(recovery.reinviteSnapshot) == "table"
end

function MSR:DiscardRebuildRecovery()
    if self.char and self.char.session then
        self.char.session.rebuildRecovery = { active = false }
    end
    self.runtime.rebuildRecoveryPrompted = true
    self:Print("Saved raid rebuild recovery discarded.")
    self:RefreshUI()
end

function MSR:ResumeRebuild()
    if self.runtime.rebuild then return false end
    if not self:HasRebuildRecovery() then
        self:PrivateWarning("No unfinished raid rebuild was found.")
        return false
    end
    local recovery = self.char.session.rebuildRecovery
    local reinviteByKey = {}
    for _, member in ipairs(recovery.reinviteSnapshot) do reinviteByKey[member.key] = true end
    self:BuildRoster()
    local storedPresent = false
    for _, member in ipairs(recovery.removalSnapshot) do
        if self.runtime.rosterByKey[member.key] then storedPresent = true break end
    end
    local removalIncomplete = (recovery.stage or "removing") == "removing" and storedPresent
    local resumePhase = removalIncomplete and "manual-remove-all"
        or (self:IsInManastorm() and "manual-leave-manastorm" or "inviting")
    self.runtime.rebuild = {
        phase = resumePhase,
        snapshot = removalIncomplete and recovery.removalSnapshot or recovery.reinviteSnapshot,
        removalSnapshot = recovery.removalSnapshot,
        reinviteSnapshot = recovery.reinviteSnapshot,
        reinviteByKey = reinviteByKey,
        excluded = recovery.excluded or {},
        index = 1,
        deadline = GetTime(),
        nextAction = GetTime(),
        startedAt = GetTime(),
        expectedTotal = #recovery.reinviteSnapshot + 1,
        recovered = true,
    }
    self.runtime.rebuildRecoveryPrompted = true
    self:PrivateWarning(removalIncomplete
        and "Raid rebuild restored. Click Remove all to continue safely."
        or "Raid rebuild restored. Reinvites will continue now.")
    self:RefreshUI()
    return true
end

function MSR:CheckRebuildRecovery()
    if self.runtime.rebuild or self.runtime.rebuildRecoveryPrompted or not self:HasRebuildRecovery() then return end
    self.runtime.rebuildRecoveryPrompted = true
    if StaticPopup_Show then StaticPopup_Show("MSR_RESUME_REBUILD") end
end

function MSR:GetRebuildStatus()
    local rebuild = self.runtime and self.runtime.rebuild
    if not rebuild then return "" end
    if rebuild.phase == "countdown" then return "Removing players in " .. math.max(0, math.ceil(rebuild.deadline - GetTime())) .. "s" end
    if rebuild.phase == "removing" then return string.format("Removing %d/%d", math.min(rebuild.index, #rebuild.snapshot), #rebuild.snapshot) end
    if rebuild.phase == "waiting-remove" then return string.format("Confirming removal %d/%d", math.min(rebuild.index, #rebuild.snapshot), #rebuild.snapshot) end
    if rebuild.phase == "manual-remove" then return "Manual removal required: " .. tostring((rebuild.snapshot[rebuild.index] or {}).name or "Unknown") end
    if rebuild.phase == "manual-remove-all" then return "One click required to remove all remaining raid members" end
    if rebuild.phase == "waiting-bulk-remove" then return "Confirming that all raid members were removed" end
    if rebuild.phase == "waiting-manastorm-exit" then return "Waiting for Manastorm exit confirmation" end
    if rebuild.phase == "manual-leave-manastorm" then return "One click required to leave the Manastorm" end
    if rebuild.phase == "waiting-empty" then return "Waiting before reinvite" end
    if rebuild.phase == "inviting" then return string.format("Reinviting %d/%d", math.min(rebuild.index, #rebuild.snapshot), #rebuild.snapshot) end
    if rebuild.phase == "manual-invite" then return "Manual invite required: " .. tostring((rebuild.snapshot[rebuild.index] or {}).name or "Unknown") end
    if rebuild.phase == "waiting-return" then return string.format("Waiting for players %d/%d", #self.runtime.roster, rebuild.expectedTotal) end
    return rebuild.phase or ""
end

function MSR:GetManualRebuildActionLabel()
    local rebuild = self.runtime and self.runtime.rebuild
    if not rebuild then return nil end
    if rebuild.phase == "manual-remove-all" then
        local remaining = self:GetRemainingRebuildMembers()
        return string.format("Remove all (%d)", #remaining)
    end
    if rebuild.phase == "manual-leave-manastorm" then return "Leave Manastorm" end
    local member = rebuild.snapshot and rebuild.snapshot[rebuild.index]
    if not member then return nil end
    local name = tostring(member.name or "Unknown")
    if string.len(name) > 16 then name = string.sub(name, 1, 14) .. ".." end
    if rebuild.phase == "manual-remove" then return "Remove " .. name end
    if rebuild.phase == "manual-invite" then return "Invite " .. name end
    return nil
end

function MSR:GetRemainingRebuildMembers()
    local rebuild = self.runtime and self.runtime.rebuild
    local remaining = {}
    if not rebuild or type(rebuild.snapshot) ~= "table" then return remaining end
    self:BuildRoster()
    for _, member in ipairs(rebuild.snapshot) do
        if self.runtime.rosterByKey[member.key] then table.insert(remaining, member) end
    end
    return remaining
end

function MSR:AttemptLeaveManastorm(isManual)
    local rebuild = self.runtime and self.runtime.rebuild
    if not rebuild then return false end
    if not self:IsInManastorm() then return true end
    if type(C_Manastorm) ~= "table" or type(C_Manastorm.Leave) ~= "function" then
        self:RequireManualRebuildAction(
            "manual-leave-manastorm",
            "Ascension's Manastorm leave API is unavailable. Click Leave Manastorm to retry."
        )
        return false
    end

    if type(C_Manastorm.CanLeave) == "function" then
        local canLeaveOk, canLeave = pcall(C_Manastorm.CanLeave)
        if not canLeaveOk or canLeave == false then
            self:RequireManualRebuildAction(
                "manual-leave-manastorm",
                "Ascension reports that the Manastorm cannot be left yet. Click Leave Manastorm to retry."
            )
            return false
        end
    end

    local ok, result = pcall(C_Manastorm.Leave)
    if not ok or result == false then
        self:RequireManualRebuildAction(
            "manual-leave-manastorm",
            "Ascension rejected the Manastorm leave request. Click Leave Manastorm to retry."
        )
        return false
    end

    rebuild.phase = "waiting-manastorm-exit"
    rebuild.exitDeadline = GetTime() + 5
    rebuild.exitMethod = "C_Manastorm.Leave"
    rebuild.exitWasManual = isManual and true or false
    self:Print("Manastorm exit requested. Waiting for confirmation.")
    return true
end

function MSR:StartRebuildReinviteDelay()
    local rebuild = self.runtime and self.runtime.rebuild
    if not rebuild then return end
    rebuild.phase = "waiting-empty"
    self:SetRebuildRecoveryStage("reinviting")
    rebuild.deadline = GetTime() + 3
    self:Print("Manastorm exit confirmed. Reinvites begin in 3 seconds.")
end

function MSR:HandleAllRebuildMembersRemoved()
    local rebuild = self.runtime and self.runtime.rebuild
    if not rebuild then return false end
    self:Print("All stored raid members are confirmed removed.")
    self:SetRebuildRecoveryStage("removed")
    if not self:IsInManastorm() then
        self:StartRebuildReinviteDelay()
        return true
    end
    self:RequireManualRebuildAction(
        "manual-leave-manastorm",
        "All raid members are removed. Click Leave Manastorm to exit before reinviting."
    )
    return false
end

function MSR:AttemptBulkRebuildRemoval()
    local rebuild = self.runtime and self.runtime.rebuild
    if not rebuild then return false end

    local remaining = self:GetRemainingRebuildMembers()
    if #remaining == 0 then
        return self:HandleAllRebuildMembersRemoved()
    end

    local failures = 0
    for _, member in ipairs(remaining) do
        local ok, result = pcall(UninviteUnit, member.name)
        if not ok or result == false then failures = failures + 1 end
    end
    rebuild.phase = "waiting-bulk-remove"
    rebuild.confirmDeadline = GetTime() + 2
    rebuild.bulkRequested = #remaining
    rebuild.bulkFailures = failures
    self:Print(string.format("Removal commands sent for %d raid member(s).", #remaining))
    return true
end

function MSR:IsRebuildMemberPresent(key)
    self:BuildRoster()
    return self.runtime.rosterByKey[key] ~= nil
end

function MSR:AdvanceRebuildRemoval()
    local rebuild = self.runtime.rebuild
    if not rebuild then return end
    rebuild.pendingKey = nil
    rebuild.pendingName = nil
    rebuild.manualAttempt = nil
    rebuild.attempts = 0
    rebuild.attemptKey = nil
    rebuild.index = rebuild.index + 1
    if rebuild.index > #rebuild.snapshot then
        self:HandleAllRebuildMembersRemoved()
    else
        rebuild.phase = "removing"
        rebuild.nextAction = GetTime() + 0.2
    end
end

function MSR:RequireManualRebuildAction(phase, message)
    local rebuild = self.runtime.rebuild
    if not rebuild then return end
    rebuild.phase = phase
    rebuild.lastError = tostring(message or "Manual action required.")
    self:PrivateWarning(rebuild.lastError)
    self:RefreshUI()
end

function MSR:AttemptRebuildRemoval(isManual)
    local rebuild = self.runtime.rebuild
    if not rebuild then return false end
    local member = rebuild.snapshot[rebuild.index]
    if not member then
        return self:HandleAllRebuildMembersRemoved()
    end

    if not self:IsRebuildMemberPresent(member.key) then
        self:AdvanceRebuildRemoval()
        return true
    end
    if rebuild.attemptKey ~= member.key then
        rebuild.attemptKey = member.key
        rebuild.attempts = 0
    end
    rebuild.attempts = rebuild.attempts + 1
    local ok, result = pcall(UninviteUnit, member.name)
    if not ok or result == false then
        self:RequireManualRebuildAction(
            "manual-remove",
            "Automatic removal failed for " .. member.name .. ". Click the local Remove button to continue."
        )
        return false
    end

    rebuild.phase = "waiting-remove"
    rebuild.pendingKey = member.key
    rebuild.pendingName = member.name
    rebuild.manualAttempt = isManual and true or false
    rebuild.confirmDeadline = GetTime() + 1.5
    return true
end

function MSR:AttemptRebuildInvite(isManual)
    local rebuild = self.runtime.rebuild
    if not rebuild then return false end
    local member = rebuild.snapshot[rebuild.index]
    if not member then
        rebuild.phase = "waiting-return"
        self:SetRebuildRecoveryStage("waiting-return")
        rebuild.deadline = GetTime() + REBUILD_RETURN_TIMEOUT
        return true
    end
    self:SetRebuildRecoveryStage("reinviting")
    self:BuildRoster()
    if self.runtime.rosterByKey[member.key] then
        rebuild.index = rebuild.index + 1
        rebuild.phase = "inviting"
        rebuild.nextAction = GetTime()
        return true
    end
    local ok, result = pcall(InviteUnit, member.name)
    if not ok or result == false then
        self:RequireManualRebuildAction(
            "manual-invite",
            "Automatic invite failed for " .. member.name .. ". Click the local Invite button to continue."
        )
        return false
    end

    local applicant = self:EnsureApplicant(member.name)
    applicant.role = member.role
    applicant.aura = member.aura
    applicant.status = "Invited"
    applicant.inviteSentAt = time()
    applicant.inviteReminderSent = false
    applicant.needsReview = member.role == "UNKNOWN" or member.aura == nil
    applicant.updatedAt = time()
    self:Print((isManual and "Manual" or "Automatic") .. " reinvite sent to " .. member.name .. ".")
    rebuild.index = rebuild.index + 1
    rebuild.phase = "inviting"
    rebuild.nextAction = GetTime() + 0.4
    return true
end

function MSR:PerformManualRebuildAction()
    local rebuild = self.runtime and self.runtime.rebuild
    if not rebuild then return false end
    local result = false
    if rebuild.phase == "manual-remove-all" then result = self:AttemptBulkRebuildRemoval()
    elseif rebuild.phase == "manual-remove" then result = self:AttemptRebuildRemoval(true)
    elseif rebuild.phase == "manual-leave-manastorm" then result = self:AttemptLeaveManastorm(true)
    elseif rebuild.phase == "manual-invite" then result = self:AttemptRebuildInvite(true) end
    self:RefreshUI()
    return result
end

function MSR:UpdateRebuild()
    local rebuild = self.runtime.rebuild
    if not rebuild then return end
    local now = GetTime()

    if rebuild.phase == "countdown" then
        if now >= rebuild.deadline then
            rebuild.phase = "manual-remove-all"
            rebuild.index = 1
            self:PrivateWarning("Click Remove all once to remove every stored raid member.")
        end
    elseif rebuild.phase == "waiting-bulk-remove" then
        local remaining = self:GetRemainingRebuildMembers()
        if #remaining == 0 then
            self:HandleAllRebuildMembersRemoved()
        elseif now >= (rebuild.confirmDeadline or 0) then
            rebuild.phase = "manual-remove-all"
            self:PrivateWarning(string.format(
                "%d raid member(s) are still present. Click Remove all again to retry only those players.",
                #remaining
            ))
        end
    elseif rebuild.phase == "waiting-manastorm-exit" then
        if not self:IsInManastorm() then
            self:StartRebuildReinviteDelay()
        elseif now >= (rebuild.exitDeadline or 0) then
            self:RequireManualRebuildAction(
                "manual-leave-manastorm",
                "The Manastorm exit was not confirmed. Click Leave Manastorm to retry."
            )
        end
    elseif rebuild.phase == "removing" and now >= rebuild.nextAction then
        self:AttemptRebuildRemoval(false)
    elseif rebuild.phase == "waiting-remove" then
        if not self:IsRebuildMemberPresent(rebuild.pendingKey) then
            self:Print(tostring(rebuild.pendingName or "Player") .. " is confirmed removed.")
            self:AdvanceRebuildRemoval()
        elseif now >= (rebuild.confirmDeadline or 0) then
            if rebuild.manualAttempt or (rebuild.attempts or 0) >= 2 then
                self:RequireManualRebuildAction(
                    "manual-remove",
                    "Removal was not confirmed for " .. tostring(rebuild.pendingName or "player") .. ". Click Remove to retry."
                )
            else
                rebuild.phase = "removing"
                rebuild.nextAction = now
            end
        end
    elseif rebuild.phase == "waiting-empty" and now >= rebuild.deadline then
        local stillPresent
        for index, member in ipairs(rebuild.snapshot) do
            if self:IsRebuildMemberPresent(member.key) then
                stillPresent = member
                rebuild.index = index
                break
            end
        end
        if stillPresent then
            self:RequireManualRebuildAction(
                "manual-remove-all",
                stillPresent.name .. " is still in the raid. Click Remove all again before reinviting."
            )
        else
            rebuild.snapshot = rebuild.reinviteSnapshot or rebuild.snapshot
            rebuild.phase = "inviting"
            rebuild.index = 1
            rebuild.nextAction = now
        end
    elseif rebuild.phase == "inviting" and now >= rebuild.nextAction then
        self:AttemptRebuildInvite(false)
    elseif rebuild.phase == "waiting-return" then
        local roster = self:BuildRoster()
        if #roster >= rebuild.expectedTotal then
            self.runtime.rebuild = nil
            self.char.session.rebuildRecovery = { active = false }
            self.char.session.needsRebuild = false
            self:Print("All players returned. Optimizing raid groups.")
            if GetNumRaidMembers and GetNumRaidMembers() > 0 then self:OptimizeGroups() end
        elseif now >= rebuild.deadline then
            local missing = rebuild.expectedTotal - #roster
            self.runtime.rebuild = nil
            self.char.session.rebuildRecovery = { active = false }
            self:LocalWarning(string.format("Raid rebuild finished with %d missing player(s).", math.max(0, missing)))
        end
    end
    self:RefreshUI()
end

