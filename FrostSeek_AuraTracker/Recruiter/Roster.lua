local MSR = ManastormRecruiter

local function ApplyFrostSeekSignals(member, applicant)
    local tracker = _G.FrostSeekAuraTracker
    local bridge = tracker and tracker.Runtime
    if not bridge or not member then return end

    if type(bridge.getAuraState) == "function" then
        local aura, source = bridge.getAuraState(member.name)
        if aura ~= nil then
            member.aura = aura
            member.auraSource = source
            if applicant then
                applicant.aura = aura
                applicant.auraSource = source
            end
        end
    end

    if type(bridge.getInferredRole) == "function" then
        local role, confidence = bridge.getInferredRole(member.name)
        if role and (member.role == nil or member.role == "UNKNOWN" or role == "TANK" or role == "HEAL") then
            member.role = role
            member.roleSource = "combat"
            member.roleConfidence = confidence
            if applicant then
                applicant.role = role
                applicant.roleSource = "combat"
                applicant.roleConfidence = confidence
            end
        end
    end
end

local function JoinWithOr(values)
    if #values == 0 then return "selected roles" end
    if #values == 1 then return values[1] end
    if #values == 2 then return values[1] .. " or " .. values[2] end
    return table.concat(values, ", ", 1, #values - 1) .. ", or " .. values[#values]
end

local function Clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return math.floor(value + 0.5)
end

function MSR:IsGroupLeader()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        return IsRaidLeader and IsRaidLeader()
    end
    if GetNumPartyMembers and GetNumPartyMembers() > 0 then
        if IsRealPartyLeader then return IsRealPartyLeader() end
        return IsPartyLeader and IsPartyLeader("player")
    end
    return true
end

function MSR:CanManageRaid()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        return (IsRaidLeader and IsRaidLeader()) or (IsRaidOfficer and IsRaidOfficer())
    end
    return self:IsGroupLeader()
end

function MSR:CanKickRosterMember(member)
    if not member or not member.name then return false, "No raid member was selected." end
    local playerKey = self:NormalizeName(UnitName("player") or "")
    if member.key == playerKey then return false, "You cannot remove yourself with this button." end
    if self.runtime and self.runtime.rebuild then
        return false, "Finish or cancel the active raid rebuild first."
    end
    if InCombatLockdown and InCombatLockdown() then
        return false, "Players cannot be removed during combat."
    end
    if not self:CanManageRaid() then
        return false, "You must be group leader or raid assistant to remove players."
    end
    if type(UninviteUnit) ~= "function" then return false, "The remove-player API is unavailable." end
    return true
end

function MSR:KickRosterMember(member)
    local allowed, reason = self:CanKickRosterMember(member)
    if not allowed then
        self:PrivateWarning(reason)
        return false
    end
    local ok, result = pcall(UninviteUnit, member.name)
    if not ok or result == false then
        self:PrivateWarning("The removal request for " .. tostring(member.name) .. " failed.")
        return false
    end
    self:Print("Removal requested for " .. tostring(member.name) .. ".")
    return true
end

function MSR:GetTargetTotal()
    local slots = self.db.settings.slots
    return (slots.tank or 0) + (slots.heal or 0) + (slots.dps or 0)
end

function MSR:ValidateSettings()
    local slots = self.db.settings.slots
    slots.tank = Clamp(slots.tank, 0, 15)
    slots.heal = Clamp(slots.heal, 0, 15)
    slots.dps = Clamp(slots.dps, 0, 15)
    slots.aura = Clamp(slots.aura, 0, 15)
    self.db.settings.autoPostInterval = Clamp(self.db.settings.autoPostInterval, 30, 600)
    self.db.settings.inviteTimeout = Clamp(self.db.settings.inviteTimeout, 5, 30)
    self.db.settings.inviteReminderDelay = Clamp(self.db.settings.inviteReminderDelay, 1, self.db.settings.inviteTimeout - 1)
    local reservation = self.db.settings.auraReservation
    if type(reservation) ~= "table" then
        reservation = { enabled = true, roles = { tank = false, heal = false, dps = true } }
        self.db.settings.auraReservation = reservation
    end
    if type(reservation.roles) ~= "table" then reservation.roles = {} end
    reservation.enabled = reservation.enabled == true
    reservation.roles.tank = reservation.roles.tank == true
    reservation.roles.heal = reservation.roles.heal == true
    reservation.roles.dps = reservation.roles.dps == true
    if type(self.db.settings.messages) ~= "table" then self:ResetMessageTemplates() end
    if self:GetTargetTotal() > 15 then return false, "Role slots cannot exceed 15 players." end
    if self:GetTargetTotal() < 1 then return false, "At least one role slot is required." end
    if slots.aura > self:GetTargetTotal() then return false, "Aura slots cannot exceed total players." end
    return true
end

function MSR:GetRoleForName(name)
    local key = self:NormalizeName(name)
    local playerKey = self:NormalizeName(UnitName("player") or "")
    if key == playerKey then return self.char.selfRole, self.char.selfAura end
    local applicant = self.char.session.applicants[key]
    if applicant then return applicant.role or "UNKNOWN", applicant.aura end
    return "UNKNOWN", nil
end

function MSR:BuildRoster()
    local roster = {}
    local present = {}
    local numRaid = GetNumRaidMembers and GetNumRaidMembers() or 0

    if numRaid > 0 then
        for index = 1, numRaid do
            local name, rank, subgroup, level, class, classFileName, zone, online = GetRaidRosterInfo(index)
            if name then
                local key, shortName = self:NormalizeName(name)
                local role, aura = self:GetRoleForName(name)
                local member = {
                    key = key,
                    name = shortName,
                    unit = "raid" .. index,
                    raidIndex = index,
                    subgroup = subgroup or 1,
                    level = tonumber(level) or UnitLevel("raid" .. index) or 0,
                    online = online ~= false,
                    role = role,
                    aura = aura,
                    rank = rank or 0,
                }
                table.insert(roster, member)
                present[key] = member
            end
        end
    else
        local playerName = UnitName("player")
        if playerName then
            local key, shortName = self:NormalizeName(playerName)
            local member = {
                key = key,
                name = shortName,
                unit = "player",
                raidIndex = nil,
                subgroup = 1,
                level = UnitLevel("player") or 0,
                online = true,
                role = self.char.selfRole,
                aura = self.char.selfAura,
                rank = 2,
            }
            table.insert(roster, member)
            present[key] = member
        end

        local numParty = GetNumPartyMembers and GetNumPartyMembers() or 0
        for index = 1, numParty do
            local unit = "party" .. index
            if UnitExists(unit) then
                local name = UnitName(unit)
                local key, shortName = self:NormalizeName(name)
                local role, aura = self:GetRoleForName(name)
                local connected = true
                if UnitIsConnected then connected = UnitIsConnected(unit) and true or false end
                local member = {
                    key = key,
                    name = shortName,
                    unit = unit,
                    raidIndex = nil,
                    subgroup = 1,
                    level = UnitLevel(unit) or 0,
                    online = connected,
                    role = role,
                    aura = aura,
                    rank = 0,
                }
                table.insert(roster, member)
                present[key] = member
            end
        end
    end

    -- A player can also be invited manually, without ever whispering the addon.
    -- Add those group members to the same editable list so role and Aura can be
    -- assigned after they join.
    local playerKey = self:NormalizeName(UnitName("player") or "")
    for _, member in ipairs(roster) do
        if member.key ~= playerKey then
            local applicant = self.char.session.applicants[member.key]
            if not applicant then
                applicant = self:EnsureApplicant(member.name)
                applicant.message = "Added automatically from the current group roster."
                applicant.needsReview = true
            end
            if applicant.status ~= "Joined" then
                applicant.status = "Joined"
                applicant.updatedAt = time()
            end
            applicant.inviteSentAt = nil
            applicant.inviteReminderSent = nil
            self:SetApplicantLevel(applicant, member.level)
            member.role = applicant.role or "UNKNOWN"
            member.aura = applicant.aura
        end
    end

    -- FrostSeek owns live Aura detection and combat-role evidence. Apply those
    -- signals after the upstream editable roster is hydrated so automatic
    -- detection augments, rather than bypasses, the complete recruiter flow.
    for _, member in ipairs(roster) do
        ApplyFrostSeekSignals(member, self.char.session.applicants[member.key])
    end

    for key, applicant in pairs(self.char.session.applicants) do
        if present[key] then
            applicant.status = "Joined"
        elseif applicant.status == "Joined" then
            local rebuild = self.runtime.rebuild
            local willBeReinvited = rebuild
                and rebuild.reinviteByKey
                and rebuild.reinviteByKey[applicant.key]
            applicant.status = willBeReinvited and "Invited" or "Left"
        end
    end

    self.runtime.roster = roster
    self.runtime.rosterByKey = present
    return roster
end

function MSR:GetCounts(roster)
    roster = roster or self.runtime.roster or self:BuildRoster()
    local counts = { tank = 0, heal = 0, dps = 0, aura = 0, unknown = 0, total = #roster }
    for _, member in ipairs(roster) do
        if member.role == "TANK" then counts.tank = counts.tank + 1
        elseif member.role == "HEAL" then counts.heal = counts.heal + 1
        elseif member.role == "DPS" then counts.dps = counts.dps + 1
        else counts.unknown = counts.unknown + 1 end
        if member.aura == true then counts.aura = counts.aura + 1 end
    end
    return counts
end

function MSR:GetCommittedCounts(roster)
    roster = roster or self:BuildRoster()
    local counts = self:GetCounts(roster)
    local present = {}
    for _, member in ipairs(roster) do present[member.key] = true end

    -- Pending invites already consume a planned slot even though the player is
    -- not visible in the group roster yet. Counting them prevents overbooking.
    for key, applicant in pairs(self.char.session.applicants) do
        if applicant.status == "Invited" and not present[key] then
            counts.total = counts.total + 1
            if applicant.role == "TANK" then counts.tank = counts.tank + 1
            elseif applicant.role == "HEAL" then counts.heal = counts.heal + 1
            elseif applicant.role == "DPS" then counts.dps = counts.dps + 1
            else counts.unknown = counts.unknown + 1 end
            if applicant.aura == true then counts.aura = counts.aura + 1 end
        end
    end
    return counts
end

function MSR:GetAuraReservationRoles()
    local reservation = self.db.settings.auraReservation or {}
    local configured = reservation.roles or {}
    local roles = {}
    for _, role in ipairs(self.ROLE_ORDER) do
        if configured[string.lower(role)] == true then table.insert(roles, role) end
    end
    return roles
end

function MSR:GetAuraReservationRoleLabel(onlyOpen, counts)
    counts = counts or self:GetCommittedCounts()
    local slots = self.db.settings.slots
    local labels = {}
    for _, role in ipairs(self:GetAuraReservationRoles()) do
        local key = string.lower(role)
        if not onlyOpen or (tonumber(slots[key]) or 0) > (tonumber(counts[key]) or 0) then
            table.insert(labels, self.ROLE_LABELS[role] or role)
        end
    end
    return JoinWithOr(labels)
end

function MSR:GetAuraReservationState(counts)
    counts = counts or self:GetCounts(self:BuildRoster())
    local reservation = self.db.settings.auraReservation or {}
    if reservation.enabled ~= true then return false, 0, 0 end
    local slots = self.db.settings.slots
    local missingAuras = math.max(0, (tonumber(slots.aura) or 0) - (tonumber(counts.aura) or 0))
    local freeSelectedSlots = 0
    for _, role in ipairs(self:GetAuraReservationRoles()) do
        local key = string.lower(role)
        freeSelectedSlots = freeSelectedSlots + math.max(
            0,
            (tonumber(slots[key]) or 0) - (tonumber(counts[key]) or 0)
        )
    end
    local active = missingAuras > 0 and freeSelectedSlots > 0 and freeSelectedSlots <= missingAuras
    return active, missingAuras, freeSelectedSlots
end

function MSR:ShouldRequireAuraForDPS()
    local roles = self.db.settings.auraReservation and self.db.settings.auraReservation.roles or {}
    return roles.dps == true and self:GetAuraReservationState()
end

function MSR:GetApplicantCapacityIssue(applicant, counts)
    counts = counts or self:GetCommittedCounts()
    local slots = self.db.settings.slots
    if (tonumber(counts.total) or 0) >= self:GetTargetTotal() then
        return "RAID_FULL", self:BuildConfiguredMessage("raidFullReply")
    end

    local role = applicant and applicant.role or "UNKNOWN"
    local roleCount, roleLimit, roleName
    if role == "TANK" then
        roleCount, roleLimit, roleName = counts.tank, slots.tank, "Tanks"
    elseif role == "HEAL" then
        roleCount, roleLimit, roleName = counts.heal, slots.heal, "Healers"
    elseif role == "DPS" then
        roleCount, roleLimit, roleName = counts.dps, slots.dps, "DPS"
    end
    if roleName and (tonumber(roleCount) or 0) >= (tonumber(roleLimit) or 0) then
        return "ROLE_FULL", self:BuildConfiguredMessage("roleFullReply", {
            role = self.ROLE_LABELS[role] or role,
            rolePlural = roleName,
        })
    end

    local reservationRoles = self.db.settings.auraReservation and self.db.settings.auraReservation.roles or {}
    if applicant and applicant.aura == false and reservationRoles[string.lower(role)] == true
        and self:GetAuraReservationState(counts) then
        local _, missingAuras = self:GetAuraReservationState(counts)
        return "AURA_REQUIRED", self:BuildConfiguredMessage("auraRequiredReply", {
            roles = self:GetAuraReservationRoleLabel(true, counts),
            missingAura = missingAuras,
        })
    end
    return nil
end

function MSR:GetApplicationCapacityReply(applicant, counts)
    if self:IsInManastorm() then
        return self:BuildConfiguredMessage("inManastormReply")
    end
    local _, reply = self:GetApplicantCapacityIssue(applicant, counts)
    return reply
end

function MSR:IsRosterFull()
    local counts = self:GetCommittedCounts()
    local slots = self.db.settings.slots
    return counts.total == self:GetTargetTotal()
        and counts.tank == slots.tank
        and counts.heal == slots.heal
        and counts.dps == slots.dps
        and counts.aura >= slots.aura
        and counts.unknown == 0
end


function MSR:GetRoleCapacities()
    local slots = self.db.settings.slots
    local capacities = {
        [1] = { TANK = 0, HEAL = 0, DPS = 0, total = 0 },
        [2] = { TANK = 0, HEAL = 0, DPS = 0, total = 0 },
        [3] = { TANK = 0, HEAL = 0, DPS = 0, total = 0 },
    }
    local counts = { TANK = slots.tank, HEAL = slots.heal, DPS = slots.dps }
    for _, role in ipairs(self.ROLE_ORDER) do
        local group = 1
        for _ = 1, counts[role] do
            local attempts = 0
            while capacities[group].total >= 5 and attempts < 3 do
                group = group % 3 + 1
                attempts = attempts + 1
            end
            if capacities[group].total < 5 then
                capacities[group][role] = capacities[group][role] + 1
                capacities[group].total = capacities[group].total + 1
            end
            group = group % 3 + 1
        end
    end
    return capacities
end

function MSR:BuildDesiredGroups(roster)
    local capacities = self:GetRoleCapacities()
    local assignments = { [1] = {}, [2] = {}, [3] = {} }
    local used = {}
    local auraGroups = math.min(3, self.db.settings.slots.aura or 0)

    local function AssignAura(group)
        if group > auraGroups then return true end
        for index, member in ipairs(roster) do
            if not used[index] and member.aura == true and capacities[group][member.role] and capacities[group][member.role] > 0 then
                used[index] = true
                capacities[group][member.role] = capacities[group][member.role] - 1
                table.insert(assignments[group], member)
                if AssignAura(group + 1) then return true end
                table.remove(assignments[group])
                capacities[group][member.role] = capacities[group][member.role] + 1
                used[index] = nil
            end
        end
        return false
    end

    if not AssignAura(1) then return nil, "No valid arrangement can place an Aura player in every required group." end

    for _, role in ipairs(self.ROLE_ORDER) do
        for index, member in ipairs(roster) do
            if not used[index] and member.role == role then
                local placed = false
                for group = 1, 3 do
                    if capacities[group][role] > 0 then
                        capacities[group][role] = capacities[group][role] - 1
                        table.insert(assignments[group], member)
                        used[index] = true
                        placed = true
                        break
                    end
                end
                if not placed then return nil, "Role distribution does not match the configured slots." end
            end
        end
    end

    for index = 1, #roster do
        if not used[index] then return nil, roster[index].name .. " has no valid group slot." end
    end
    return assignments
end

function MSR:BuildPartialDesiredGroups(roster)
    local playerCount = #(roster or {})
    if playerCount == 0 then return nil, "There are no raid members to optimize." end
    if playerCount > 15 then return nil, "Manastorm groups support at most 15 players." end

    local activeGroups = math.min(3, math.max(1, math.ceil(playerCount / 5)))
    local assignments = { [1] = {}, [2] = {}, [3] = {} }
    local roleCounts = {
        [1] = { TANK = 0, HEAL = 0, DPS = 0, UNKNOWN = 0 },
        [2] = { TANK = 0, HEAL = 0, DPS = 0, UNKNOWN = 0 },
        [3] = { TANK = 0, HEAL = 0, DPS = 0, UNKNOWN = 0 },
    }
    local configured = self:GetRoleCapacities()
    local used = {}

    local function AddMember(group, index)
        local member = roster[index]
        local role = member.role or "UNKNOWN"
        table.insert(assignments[group], member)
        roleCounts[group][role] = (roleCounts[group][role] or 0) + 1
        used[index] = true
    end

    local auraPlayers = 0
    for _, member in ipairs(roster) do
        if member.aura == true then auraPlayers = auraPlayers + 1 end
    end
    local auraGroups = math.min(
        activeGroups,
        tonumber(self.db.settings.slots.aura) or 0,
        auraPlayers
    )

    -- The primary Tank is anchored in the first slot of Group 1 before Aura
    -- distribution. This keeps partial raids deterministic as well.
    for index, member in ipairs(roster) do
        if member.role == "TANK" then
            AddMember(1, index)
            break
        end
    end

    -- Seed as many active groups as possible with one Aura player. Prefer an
    -- Aura role that also fits the configured final composition for that group.
    for group = 1, auraGroups do
        local alreadyHasAura = false
        for _, assigned in ipairs(assignments[group]) do
            if assigned.aura == true then alreadyHasAura = true break end
        end
        if not alreadyHasAura then
            local selected
            for index, member in ipairs(roster) do
                if not used[index] and member.aura == true then
                    local role = member.role or "UNKNOWN"
                    if configured[group][role] and configured[group][role] > 0 then
                        selected = index
                        break
                    end
                    selected = selected or index
                end
            end
            if selected then AddMember(group, selected) end
        end
    end

    local function FindBestGroup(role)
        local bestGroup
        local bestConfigured = -1
        local bestRoleCount
        local bestTotal
        for group = 1, activeGroups do
            local total = #assignments[group]
            if total < 5 then
                local configuredNeed = 0
                if configured[group][role] then
                    configuredNeed = math.max(0, configured[group][role] - (roleCounts[group][role] or 0))
                end
                local roleCount = roleCounts[group][role] or 0
                if not bestGroup
                    or configuredNeed > bestConfigured
                    or (configuredNeed == bestConfigured and roleCount < bestRoleCount)
                    or (configuredNeed == bestConfigured and roleCount == bestRoleCount and total < bestTotal) then
                    bestGroup = group
                    bestConfigured = configuredNeed
                    bestRoleCount = roleCount
                    bestTotal = total
                end
            end
        end
        return bestGroup
    end

    local roles = { "TANK", "HEAL", "DPS", "UNKNOWN" }
    for _, role in ipairs(roles) do
        for index, member in ipairs(roster) do
            if not used[index] and (member.role or "UNKNOWN") == role then
                local group = FindBestGroup(role)
                if not group then return nil, member.name .. " has no available subgroup slot." end
                AddMember(group, index)
            end
        end
    end

    return assignments
end

function MSR:BuildAuraSwapPlan(roster)
    local requiredGroups = math.min(3, tonumber(self.db.settings.slots.aura) or 0)
    local auraCounts = {}
    local membersByGroup = {}
    local usedDonors = {}
    for group = 1, 8 do
        auraCounts[group] = 0
        membersByGroup[group] = {}
    end

    for _, member in ipairs(roster or {}) do
        local group = tonumber(member.subgroup) or 1
        if group >= 1 and group <= 8 then
            table.insert(membersByGroup[group], member)
            if member.aura == true then auraCounts[group] = auraCounts[group] + 1 end
        end
    end

    local swaps = {}
    for targetGroup = 1, requiredGroups do
        if auraCounts[targetGroup] == 0 then
            local donor
            for _, member in ipairs(roster or {}) do
                local sourceGroup = tonumber(member.subgroup) or 1
                if member.aura == true
                    and sourceGroup ~= targetGroup
                    and not usedDonors[member.key]
                    and (sourceGroup > requiredGroups or auraCounts[sourceGroup] > 1) then
                    donor = member
                    break
                end
            end
            if not donor then
                return nil, "Not enough movable Aura players to cover every required group."
            end

            local sameRole
            local fallback
            for _, candidate in ipairs(membersByGroup[targetGroup]) do
                if candidate.aura ~= true then
                    fallback = fallback or candidate
                    if candidate.role == donor.role then sameRole = candidate break end
                end
            end
            local recipient = sameRole or fallback
            if not recipient then
                return nil, "Group " .. targetGroup .. " has no player available for an Aura swap."
            end

            local sourceGroup = tonumber(donor.subgroup) or 1
            table.insert(swaps, {
                donor = donor,
                recipient = recipient,
                sourceGroup = sourceGroup,
                targetGroup = targetGroup,
            })
            usedDonors[donor.key] = true
            auraCounts[sourceGroup] = auraCounts[sourceGroup] - 1
            auraCounts[targetGroup] = auraCounts[targetGroup] + 1
        end
    end
    return swaps
end

function MSR:OptimizeAuraGroups()
    if InCombatLockdown and InCombatLockdown() then self:PrivateWarning("Aura groups cannot be optimized during combat.") return false end
    if not (GetNumRaidMembers and GetNumRaidMembers() > 0) then self:PrivateWarning("Convert the party to a raid first.") return false end
    if not (IsRaidLeader and IsRaidLeader()) then self:PrivateWarning("Only the raid leader can optimize Aura groups.") return false end
    if type(SwapRaidSubgroup) ~= "function" then self:PrivateWarning("SwapRaidSubgroup is unavailable in this client.") return false end

    local roster = self:BuildRoster()
    local swaps, reason = self:BuildAuraSwapPlan(roster)
    if not swaps then self:PrivateWarning(reason) return false end
    if #swaps == 0 then
        self:Print("Aura distribution is already correct.")
        return true
    end

    for _, swap in ipairs(swaps) do
        if not swap.donor.raidIndex or not swap.recipient.raidIndex then
            self:PrivateWarning("Unable to resolve raid indexes for the Aura swap.")
            return false
        end
        local ok, result = pcall(SwapRaidSubgroup, swap.donor.raidIndex, swap.recipient.raidIndex)
        if not ok or result == false then
            self:PrivateWarning("Ascension rejected an Aura subgroup swap.")
            return false
        end
    end

    self:Print(string.format("Aura distribution optimized with %d subgroup swap(s).", #swaps))
    self:BuildRoster()
    self:RefreshUI()
    return true
end

function MSR:GetGroupOptimizationSignature(roster)
    local values = {}
    for _, member in ipairs(roster or {}) do
        table.insert(values, table.concat({
            tostring(member.key or ""),
            tostring(member.role or "UNKNOWN"),
            member.aura == nil and "?" or (member.aura and "1" or "0"),
        }, ":"))
    end
    table.sort(values)
    return table.concat(values, "|")
end

function MSR:BuildGroupOptimizationPlan(roster)
    local counts = self:GetCounts(roster)
    local slots = self.db.settings.slots
    local isComplete = counts.total == self:GetTargetTotal()
        and counts.tank == slots.tank
        and counts.heal == slots.heal
        and counts.dps == slots.dps
        and counts.aura >= slots.aura
        and counts.unknown == 0

    local assignments, reason
    if isComplete then
        assignments, reason = self:BuildDesiredGroups(roster)
    else
        assignments, reason = self:BuildPartialDesiredGroups(roster)
    end
    if not assignments then return nil, reason end

    local primaryTankKey
    for index, member in ipairs(assignments[1]) do
        if member.role == "TANK" then
            primaryTankKey = member.key
            if index ~= 1 then
                table.remove(assignments[1], index)
                table.insert(assignments[1], 1, member)
            end
            break
        end
    end

    local desired = {}
    for group = 1, 3 do
        for _, member in ipairs(assignments[group]) do desired[member.key] = group end
    end
    return {
        desired = desired,
        signature = self:GetGroupOptimizationSignature(roster),
        isComplete = isComplete,
        playerCount = #roster,
        primaryTankKey = primaryTankKey,
        pending = nil,
    }
end

function MSR:MarkPrimaryTank(roster, primaryTankKey)
    if not primaryTankKey then return true end
    local tank
    for _, member in ipairs(roster or {}) do
        if member.key == primaryTankKey then tank = member break end
    end
    if not tank or tank.role ~= "TANK" or tonumber(tank.subgroup) ~= 1 then
        self:PrivateWarning("The primary Tank is not confirmed in Group 1 yet.")
        return false
    end
    if type(SetRaidTarget) ~= "function" then
        self:PrivateWarning("SetRaidTarget is unavailable in this client; the Tank could not be marked with a star.")
        return false
    end
    local unit = tank.unit or (tank.raidIndex and ("raid" .. tostring(tank.raidIndex)))
    if not unit then
        self:PrivateWarning("Unable to resolve the primary Tank for the star marker.")
        return false
    end
    local ok, result = pcall(SetRaidTarget, unit, 1)
    if not ok or result == false then
        self:PrivateWarning("Ascension rejected the star marker for " .. tostring(tank.name) .. ".")
        return false
    end
    self:Print(tostring(tank.name) .. " is first in Group 1 and marked with the raid star.")
    return true
end
function MSR:AssignMainTanks(roster)
    if type(SetPartyAssignment) ~= "function" then
        self:PrivateWarning("SetPartyAssignment is unavailable in this client; Tanks could not be promoted with /mt.")
        return false
    end
    local assigned = 0
    local failed = {}
    for _, member in ipairs(roster or {}) do
        if member.role == "TANK" then
            local unit = member.unit or (member.raidIndex and ("raid" .. tostring(member.raidIndex)))
            if not unit then
                table.insert(failed, tostring(member.name or "Unknown"))
            else
                local ok, result = pcall(SetPartyAssignment, "MAINTANK", unit, member.name, true)
                if ok and result ~= false then
                    assigned = assigned + 1
                else
                    table.insert(failed, tostring(member.name or unit))
                end
            end
        end
    end
    if #failed > 0 then
        self:PrivateWarning("Ascension rejected /mt for: " .. table.concat(failed, ", ") .. ". Click Optimize groups again to retry.")
        return false
    end
    if assigned > 0 then
        self:Print(string.format("%d Tank%s promoted with /mt.", assigned, assigned == 1 and "" or "s"))
    end
    return true
end

function MSR:GetGroupOptimizationRemaining(roster, optimization)
    local remaining = 0
    if not optimization then return remaining end
    for _, member in ipairs(roster or {}) do
        if optimization.desired[member.key] ~= member.subgroup then remaining = remaining + 1 end
    end
    return remaining
end

function MSR:FindNextGroupOptimizationAction(roster, desired)
    local groupCounts = {}
    for group = 1, 8 do groupCounts[group] = 0 end
    for _, member in ipairs(roster or {}) do
        local group = tonumber(member.subgroup) or 1
        if group >= 1 and group <= 8 then groupCounts[group] = groupCounts[group] + 1 end
    end

    -- First consume any free destination. Players already parked in a
    -- temporary group receive priority so the buffer never fills needlessly.
    for pass = 1, 2 do
        for _, member in ipairs(roster or {}) do
            local target = desired[member.key]
            local current = tonumber(member.subgroup) or 1
            local isBuffered = current >= 4
            if target and current ~= target and groupCounts[target] < 5
                and ((pass == 1 and isBuffered) or (pass == 2 and not isBuffered)) then
                return { member = member, target = target, kind = "direct" }
            end
        end
    end

    local mover
    for _, member in ipairs(roster or {}) do
        if desired[member.key] and desired[member.key] ~= member.subgroup then
            mover = member
            break
        end
    end
    if not mover then return nil end

    local target = desired[mover.key]
    local displaced
    for _, candidate in ipairs(roster or {}) do
        if candidate.subgroup == target and desired[candidate.key] ~= target then
            displaced = candidate
            break
        end
    end
    if not displaced then return nil, "No displaced player was found in full Group " .. tostring(target) .. "." end

    local bufferGroup
    for group = 4, 8 do
        if groupCounts[group] < 5 then bufferGroup = group break end
    end
    if not bufferGroup then return nil, "No temporary raid group is available as a move buffer." end

    return { member = displaced, target = bufferGroup, kind = "buffer" }
end

function MSR:ApplyGroupOptimizationAction(action, attempt)
    if not action or not action.member or not action.member.raidIndex then
        self:PrivateWarning("Unable to resolve the next raid member for group optimization.")
        return false
    end
    if type(SetRaidSubgroup) ~= "function" then
        self:PrivateWarning("SetRaidSubgroup is unavailable in this client.")
        return false
    end

    local from = tonumber(action.member.subgroup) or 1
    local ok, result = pcall(SetRaidSubgroup, action.member.raidIndex, action.target)
    if not ok or result == false then
        self:PrivateWarning("Ascension rejected the subgroup move for " .. tostring(action.member.name) .. ".")
        return false
    end

    self.runtime.groupOptimization.pending = {
        key = action.member.key,
        name = action.member.name,
        from = from,
        target = action.target,
        kind = action.kind,
        attempts = tonumber(attempt) or 1,
    }
    self:Print(string.format(
        "Group step sent: %s, Group %d -> Group %d. Click Optimize groups again to verify and continue.",
        tostring(action.member.name),
        from,
        action.target
    ))
    self:RefreshUI()
    return true
end

function MSR:GetGroupOptimizationStatus()
    local optimization = self.runtime and self.runtime.groupOptimization
    if not optimization then return "" end
    if optimization.pending then
        return string.format(
            "Group optimization: verify %s -> Group %d, then continue.",
            tostring(optimization.pending.name),
            optimization.pending.target
        )
    end
    return "Group optimization is ready for the next verified step."
end

function MSR:GetGroupOptimizationButtonLabel()
    local optimization = self.runtime and self.runtime.groupOptimization
    if not optimization then return "Optimize groups" end
    return optimization.pending and "Verify / next" or "Next group step"
end

function MSR:OptimizeGroups()
    if InCombatLockdown and InCombatLockdown() then self:PrivateWarning("Groups cannot be optimized during combat.") return false end
    if self.runtime.rebuild then self:PrivateWarning("Finish or cancel the raid rebuild before optimizing groups.") return false end
    if not (GetNumRaidMembers and GetNumRaidMembers() > 0) then self:PrivateWarning("Convert the party to a raid first.") return false end
    if not (IsRaidLeader and IsRaidLeader()) then self:PrivateWarning("Only the raid leader can optimize groups.") return false end

    local roster = self:BuildRoster()
    local signature = self:GetGroupOptimizationSignature(roster)
    local optimization = self.runtime.groupOptimization
    if optimization and optimization.signature ~= signature then
        self:Print("Raid members, roles or Auras changed. Rebuilding the group optimization plan.")
        optimization = nil
        self.runtime.groupOptimization = nil
    end

    if not optimization then
        local reason
        optimization, reason = self:BuildGroupOptimizationPlan(roster)
        if not optimization then self:PrivateWarning(reason) return false end
        self.runtime.groupOptimization = optimization
    end

    if optimization.pending then
        local pending = optimization.pending
        local currentMember
        for _, member in ipairs(roster) do
            if member.key == pending.key then currentMember = member break end
        end
        if currentMember and currentMember.subgroup == pending.target then
            self:Print(string.format(
                "Group step confirmed: %s is now in Group %d.",
                tostring(currentMember.name),
                pending.target
            ))
            optimization.pending = nil
        else
            if not currentMember then
                self.runtime.groupOptimization = nil
                self:PrivateWarning("The pending player left the raid. Start group optimization again.")
                self:RefreshUI()
                return false
            end
            self:PrivateWarning(string.format(
                "The previous move for %s was not confirmed. Retrying it now.",
                tostring(currentMember.name)
            ))
            return self:ApplyGroupOptimizationAction({
                member = currentMember,
                target = pending.target,
                kind = pending.kind,
            }, (pending.attempts or 1) + 1)
        end
    end

    local remaining = self:GetGroupOptimizationRemaining(roster, optimization)
    if remaining == 0 then
        if not self:AssignMainTanks(roster) then
            self:RefreshUI()
            return false
        end
        if not self:MarkPrimaryTank(roster, optimization.primaryTankKey) then
            self:RefreshUI()
            return false
        end
        self.runtime.groupOptimization = nil
        self:Print("Raid groups verified and optimized: Tanks promoted with /mt, primary Tank first in Group 1, roles and Auras distributed across Groups 1-3.")
        self:BuildRoster()
        self:RefreshUI()
        return true
    end

    local action, reason = self:FindNextGroupOptimizationAction(roster, optimization.desired)
    if not action then
        self:PrivateWarning(reason or "No valid next group move was found.")
        return false
    end
    return self:ApplyGroupOptimizationAction(action, 1)
end
