ManastormRecruiter = ManastormRecruiter or {}
local MSR = ManastormRecruiter

MSR.VERSION = "1.5.0-beta.3"
MSR.UPSTREAM_VERSION = "0.6.8"
MSR.PARSER_VERSION = 5
MSR.PREFIX = "|cff65d5ff[MSR]|r "
MSR.ROLE_ORDER = { "TANK", "HEAL", "DPS" }
MSR.ROLE_LABELS = { TANK = "Tank", HEAL = "Heal", DPS = "DPS", UNKNOWN = "Unknown" }
MSR.STATUS_COLORS = {
    New = "|cffffd65a",
    Invited = "|cff66ccff",
    NoResponse = "|cffff9966",
    Joined = "|cff55ff88",
    Reserve = "|cffcc99ff",
    Rejected = "|cff888888",
    Declined = "|cffff7777",
    Left = "|cffff9966",
}

local MESSAGE_DEFAULTS = {
    recruitment = "LFM MS - {tank}/{tankMax} Tanks - {heal}/{healMax} Healer - {dps}/{dpsMax} DPS - Aura {aura}/{auraMax} - {total}/{totalMax} Total - Need: {needed}{reservation}",
    reservationSuffix = ". Aura required for remaining {roles} slots.",
    invalidApplicationReply = "Please whisper your role as Tank/Heal/DPS. I will ask separately for any missing Aura or level.",
    missingAuraReply = "Do you have a Manastorm Aura? Please reply yes or no.",
    missingLevelReply = "What level are you? Please reply with a number from 1 to 60.",
    acceptedApplicationReply = "Registered as {role} - Aura: {aura}. Waiting for invite.",
    inviteReminder = "Your group invite is still pending. Please accept within {seconds} seconds or the slot will be released.",
    inManastormReply = "We are already inside Manastorm and are not recruiting right now.",
    raidFullReply = "The raid is currently full. We are not accepting additional players right now.",
    roleFullReply = "We are already full on {rolePlural}. Please apply with another role if available.",
    auraRequiredReply = "We currently only need players with Aura for {roles}. The remaining selected role slots are reserved for our missing Auras.",
    rosterSummary = "MS roster: Tank {tank}/{tankMax}, Heal {heal}/{healMax}, DPS {dps}/{dpsMax}, Aura {aura}/{auraMax}.{status}",
    rosterComplete = " Roster is complete.",
    rosterNeeded = " Still need: {needed}.",
    rebuildAnnouncement = "Rebuilding the raid now. Reinvites will follow shortly.",
    level60Warning = "WARNING: {player} has reached level 60. The raid must be rebuilt.",
    level59Warning = "WARNING: {player} has reached level 59 and is close to the Manastorm cap.",
    level60StatusPost = "Thanks, everyone! I have reached level 60. Raid lead will pass automatically when I leave. The current roster is: Tank {tank}/{tankMax}, Heal {heal}/{healMax}, Aura {aura}/{auraMax}. Aura players: {auraPlayers}.",
    level59StatusPost = "Thanks, everyone! I am level 59 and close to level 60, so I am leaving the raid. Raid lead will pass automatically when I leave. The current roster is: Tank {tank}/{tankMax}, Heal {heal}/{healMax}, Aura {aura}/{auraMax}. Aura players: {auraPlayers}.",
    belowLevel59StatusPost = "Thanks, everyone! I am leaving the raid at level {level}. Raid lead will pass automatically when I leave. The current roster is: Tank {tank}/{tankMax}, Heal {heal}/{healMax}, Aura {aura}/{auraMax}. Aura players: {auraPlayers}.",
}
MSR.MESSAGE_DEFAULTS = MESSAGE_DEFAULTS

local MESSAGE_ROUTE_DEFAULTS = {
    rosterSummary = "RAID",
    rebuildAnnouncement = "RAID_WARNING",
    level60Warning = "RAID_WARNING",
    level59Warning = "RAID_WARNING",
    level60StatusPost = "RAID",
    level59StatusPost = "RAID",
    belowLevel59StatusPost = "RAID",
}
MSR.MESSAGE_ROUTE_DEFAULTS = MESSAGE_ROUTE_DEFAULTS

local DEFAULTS = {
    version = 1,
    settings = {
        channel = "8",
        autoPost = false,
        autoPostInterval = 90,
        autoReply = true,
        inviteReminderDelay = 5,
        inviteTimeout = 10,
        compactMode = false,
        minimapAngle = 225,
        slots = { tank = 2, heal = 3, dps = 10, aura = 3 },
        auraReservation = {
            enabled = true,
            roles = { tank = false, heal = false, dps = true },
        },
        recruitmentFormatVersion = 2,
        messages = MESSAGE_DEFAULTS,
        messageRoutes = MESSAGE_ROUTE_DEFAULTS,
    },
}

local CHAR_DEFAULTS = {
    version = 1,
    parserVersion = 0,
    selfRole = "DPS",
    selfAura = false,
    session = {
        listening = false,
        applicants = {},
        order = {},
        lastPostAt = 0,
        level59Alerted = {},
        level60Alerted = {},
        lastRebuildRoster = {},
        needsRebuild = false,
        whisperHistory = {},
        chatScanEntries = {},
        chatScanOrder = {},
        rebuildRecovery = { active = false },
    },
}

local function CopyDefaults(source, target)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            CopyDefaults(value, target[key])
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local function Trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function JoinWithOr(values)
    if #values == 0 then return "selected roles" end
    if #values == 1 then return values[1] end
    if #values == 2 then return values[1] .. " or " .. values[2] end
    return table.concat(values, ", ", 1, #values - 1) .. ", or " .. values[#values]
end

local function MissingLabel(count, singular, plural)
    count = tonumber(count) or 0
    if count == 1 then return "1 " .. singular end
    return tostring(count) .. " " .. (plural or (singular .. "s"))
end

local function WipeTable(target)
    for key in pairs(target) do target[key] = nil end
end

local function Clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return math.floor(value + 0.5)
end

local function SafeCall(func, ...)
    if type(func) ~= "function" then return false, "Function unavailable" end
    return pcall(func, ...)
end

function MSR:Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(self.PREFIX .. tostring(message))
    end
end

function MSR:LocalWarning(message)
    self:Print("|cffff6666" .. tostring(message) .. "|r")
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, tostring(message), ChatTypeInfo.RAID_WARNING)
    elseif UIErrorsFrame then
        UIErrorsFrame:AddMessage(tostring(message), 1, 0.25, 0.25, 1, 5)
    end
    if PlaySound then pcall(PlaySound, "RaidWarning") end
end

-- Explicitly local-only feedback. Unlike SendRaidWarning, this function never
-- writes to party, raid or raid-warning chat.
function MSR:PrivateWarning(message)
    self:Print("|cffff6666" .. tostring(message) .. "|r")
    if UIErrorsFrame then
        UIErrorsFrame:AddMessage(tostring(message), 1, 0.25, 0.25, 1, 5)
    end
    if PlaySound then pcall(PlaySound, "RaidWarning") end
end

function MSR:InitializeDatabase()
    if type(ManastormRecruiterDB) ~= "table" then ManastormRecruiterDB = {} end
    if type(ManastormRecruiterCharDB) ~= "table" then ManastormRecruiterCharDB = {} end
    local previousParserVersion = tonumber(ManastormRecruiterCharDB.parserVersion) or 0
    local previousRecruitmentFormatVersion = tonumber(
        ManastormRecruiterDB.settings and ManastormRecruiterDB.settings.recruitmentFormatVersion
    ) or 0
    CopyDefaults(DEFAULTS, ManastormRecruiterDB)
    CopyDefaults(CHAR_DEFAULTS, ManastormRecruiterCharDB)
    self.db = ManastormRecruiterDB
    self.char = ManastormRecruiterCharDB
    if previousRecruitmentFormatVersion < 2 then
        self.db.settings.messages.recruitment = MESSAGE_DEFAULTS.recruitment
        self.db.settings.recruitmentFormatVersion = 2
    else
        self:MigrateRecruitmentTemplate()
    end
    self:MigrateLevel60StatusTemplate()
    self:MigrateLeaveStatusTemplates()
    self:MigrateApplicantQuestionTemplates()
    self.runtime = self.runtime or {}
    self.runtime.roster = {}
    self.runtime.rosterByKey = {}
    self.runtime.lastRosterScan = 0
    self.runtime.lastValidationSignature = ""
    self.runtime.rebuild = nil
    self.runtime.groupOptimization = nil
    self.runtime.readyCheck = nil
    self.runtime.pendingLeave = nil
    self.runtime.rebuildRecoveryPrompted = false
    self.runtime.wasInManastorm = false
    self.runtime.groupChat = {}
    self:HydrateApplicantLevelsFromCache()
    if previousParserVersion < self.PARSER_VERSION then
        self:ReparseStoredApplicants()
        self.char.parserVersion = self.PARSER_VERSION
    end
end

function MSR:GetMessageTemplate(key)
    local messages = self.db and self.db.settings and self.db.settings.messages
    local value = messages and messages[key]
    if value == nil then value = MESSAGE_DEFAULTS[key] end
    return tostring(value or "")
end

function MSR:MigrateRecruitmentTemplate()
    local messages = self.db and self.db.settings and self.db.settings.messages
    if type(messages) ~= "table" or type(messages.recruitment) ~= "string" then return false end
    local oldCounts = "Tank%s+{tank}/{tankMax}%s+Heal%s+{heal}/{healMax}%s+DPS%s+{dps}/{dpsMax}%s+Aura%s+{aura}/{auraMax}"
    local migrated, replacements = messages.recruitment:gsub(oldCounts, "{needed}", 1)
    if replacements > 0 then
        messages.recruitment = migrated
        return true
    end
    return false
end

function MSR:MigrateLevel60StatusTemplate()
    local messages = self.db and self.db.settings and self.db.settings.messages
    if type(messages) ~= "table" then return false end
    local oldDefault = "I am level 60. Tank {tank}/{tankMax}, Heal {heal}/{healMax}, Aura {aura}/{auraMax}. Aura players: {auraPlayers}."
    if messages.level60StatusPost == oldDefault then
        messages.level60StatusPost = MESSAGE_DEFAULTS.level60StatusPost
        return true
    end
    return false
end

function MSR:GetMessageRoute(key)
    local default = MESSAGE_ROUTE_DEFAULTS[key]
    if not default then return nil end
    local routes = self.db and self.db.settings and self.db.settings.messageRoutes
    local route = routes and routes[key]
    if route == "RAID" or route == "RAID_WARNING" or route == "LOCAL" or route == "OFF" then
        return route
    end
    return default
end

function MSR:SetMessageRoute(key, route)
    if not MESSAGE_ROUTE_DEFAULTS[key] then return false end
    route = tostring(route or "OFF")
    if route ~= "RAID" and route ~= "RAID_WARNING" and route ~= "LOCAL" and route ~= "OFF" then
        return false
    end
    self.db.settings.messageRoutes = self.db.settings.messageRoutes or {}
    self.db.settings.messageRoutes[key] = route
    return true
end

function MSR:SendConfiguredMessage(key, message)
    local route = self:GetMessageRoute(key)
    if not route then return false, nil end
    if route == "OFF" then return true, route end
    message = self.PrepareChatMessage and self:PrepareChatMessage(message) or tostring(message or "")
    if message == "" then return false, route end
    if route == "LOCAL" then
        self:Print(message)
        return true, route
    end
    if route == "RAID_WARNING" then return self:SendRaidWarning(message), route end
    return self:SendGroupChat(message), route
end

function MSR:MigrateLeaveStatusTemplates()
    local messages = self.db and self.db.settings and self.db.settings.messages
    if type(messages) ~= "table" then return false end
    local changed = false
    for _, key in ipairs({ "level60StatusPost", "level59StatusPost", "belowLevel59StatusPost" }) do
        if type(messages[key]) == "string" then
            local migrated, replacements = messages[key]:gsub(
                "Raid lead will be passed on automatically%.",
                "Raid lead will pass automatically when I leave."
            )
            if replacements > 0 then
                messages[key] = migrated
                changed = true
            end
        end
    end
    return changed
end

function MSR:MigrateApplicantQuestionTemplates()
    local messages = self.db and self.db.settings and self.db.settings.messages
    if type(messages) ~= "table" then return false end
    local oldDefault = "Please whisper your role and aura as: Tank/Heal/DPS + Aura yes/no. Level is optional."
    if messages.invalidApplicationReply == oldDefault then
        messages.invalidApplicationReply = MESSAGE_DEFAULTS.invalidApplicationReply
        return true
    end
    return false
end

function MSR:ApplyTemplate(template, values)
    values = values or {}
    return tostring(template or ""):gsub("{([%w_]+)}", function(key)
        local value = values[key]
        if value == nil then return "{" .. key .. "}" end
        return tostring(value)
    end)
end

function MSR:BuildMessageValues(counts, extra)
    counts = counts or self:GetCommittedCounts()
    local slots = self.db.settings.slots
    local tankNeeded = math.max(0, (tonumber(slots.tank) or 0) - (tonumber(counts.tank) or 0))
    local healNeeded = math.max(0, (tonumber(slots.heal) or 0) - (tonumber(counts.heal) or 0))
    local dpsNeeded = math.max(0, (tonumber(slots.dps) or 0) - (tonumber(counts.dps) or 0))
    local auraNeeded = math.max(0, (tonumber(slots.aura) or 0) - (tonumber(counts.aura) or 0))
    local needed = {}
    if tankNeeded > 0 then table.insert(needed, MissingLabel(tankNeeded, "Tank")) end
    if healNeeded > 0 then table.insert(needed, MissingLabel(healNeeded, "Healer")) end
    if dpsNeeded > 0 then table.insert(needed, MissingLabel(dpsNeeded, "DPS", "DPS")) end
    if auraNeeded > 0 then table.insert(needed, MissingLabel(auraNeeded, "Aura")) end

    local values = {
        tank = counts.tank or 0,
        tankMax = slots.tank or 0,
        heal = counts.heal or 0,
        healMax = slots.heal or 0,
        dps = counts.dps or 0,
        dpsMax = slots.dps or 0,
        aura = math.min(counts.aura or 0, slots.aura or 0),
        auraMax = slots.aura or 0,
        total = counts.total or 0,
        totalMax = self:GetTargetTotal(),
        tankNeeded = tankNeeded,
        healNeeded = healNeeded,
        dpsNeeded = dpsNeeded,
        auraNeeded = auraNeeded,
        needed = #needed > 0 and table.concat(needed, " - ") or "Roster complete",
    }
    for key, value in pairs(extra or {}) do values[key] = value end
    return values
end

function MSR:BuildConfiguredMessage(key, values)
    return self:ApplyTemplate(self:GetMessageTemplate(key), values)
end

function MSR:PrepareChatMessage(message)
    message = tostring(message or ""):gsub("[\r\n]+", " "):gsub("%s%s+", " ")
    message = Trim(message)
    if string.len(message) > 255 then message = string.sub(message, 1, 255) end
    return message
end

function MSR:ResetMessageTemplates()
    self.db.settings.messages = {}
    CopyDefaults(MESSAGE_DEFAULTS, self.db.settings.messages)
end

function MSR:NormalizeName(name)
    name = tostring(name or "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    local short = name:match("^([^%-]+)") or name
    return string.lower(short), short
end

function MSR:GetApplicant(name)
    local key = self:NormalizeName(name)
    return self.char.session.applicants[key], key
end

function MSR:EnsureApplicant(name)
    local key, shortName = self:NormalizeName(name)
    local applicant = self.char.session.applicants[key]
    if not applicant then
        applicant = {
            key = key,
            name = shortName,
            role = "UNKNOWN",
            aura = nil,
            status = "New",
            message = "",
            messageHistory = {},
            needsReview = true,
            createdAt = time(),
            updatedAt = time(),
        }
        self.char.session.applicants[key] = applicant
        table.insert(self.char.session.order, key)
    end
    return applicant
end

function MSR:SetApplicantLevel(applicant, level)
    level = tonumber(level)
    if not applicant or not level or level <= 0 then return false end
    applicant.level = math.floor(level)
    return true
end

function MSR:HydrateApplicantLevelsFromCache()
    local session = self.char and self.char.session
    if not session or type(session.lastRebuildRoster) ~= "table" then return end
    for _, member in ipairs(session.lastRebuildRoster) do
        local applicant = session.applicants[member.key or self:NormalizeName(member.name)]
        if applicant then self:SetApplicantLevel(applicant, member.level) end
    end
end


function MSR:HandleRosterChanged()
    local roster = self:BuildRoster()
    self:InvalidateReadyCheckIfRosterChanged(roster)
    local numRaid = GetNumRaidMembers and GetNumRaidMembers() or 0
    local numParty = GetNumPartyMembers and GetNumPartyMembers() or 0
    if numRaid == 0 and numParty > 0 and self:GetTargetTotal() > 5 and self:IsGroupLeader() and ConvertToRaid then
        pcall(ConvertToRaid)
    end
    self:ValidateInsideManastorm()
    self:ScanForLevel60()
    self:RefreshUI()
end

function MSR:HandleManastormUpdate()
    local inManastorm = self:IsInManastorm()
    if inManastorm and not self.runtime.wasInManastorm then
        WipeTable(self.char.session.level59Alerted)
        WipeTable(self.char.session.level60Alerted)
        self.char.session.needsRebuild = false
        self.runtime.lastValidationSignature = ""
        self:StopRecruitmentForManastorm()
        self:Print("Manastorm detected. Roster monitoring enabled.")
    elseif not inManastorm and self.runtime.wasInManastorm then
        self.runtime.lastValidationSignature = ""
        self:Print("Manastorm ended. Recruitment controls enabled.")
    end
    self.runtime.wasInManastorm = inManastorm
    self:HandleRosterChanged()
end

function MSR:RefreshUI()
    if self.UI and self.UI.Refresh then self.UI:Refresh() end
end

function MSR:OnUpdate(elapsed)
    self.runtime.updateAccumulator = (self.runtime.updateAccumulator or 0) + elapsed
    if self.runtime.updateAccumulator < 0.25 then return end
    self.runtime.updateAccumulator = 0

    self:UpdateRebuild()
    self:UpdatePendingInvites()
    self:UpdatePendingLeave()
    local now = GetTime()
    if now - (self.runtime.lastRosterScan or 0) >= 1 then
        self.runtime.lastRosterScan = now
        self:BuildRoster()
        if self:IsInManastorm() then
            self:ValidateInsideManastorm()
            self:ScanForLevel60()
        elseif self.db.settings.autoPost and self.char.session.listening then
            local lastPost = tonumber(self.char.session.lastPostAt) or 0
            local lastAttempt = tonumber(self.runtime.lastAutoPostAttempt) or 0
            if time() - lastPost >= self.db.settings.autoPostInterval and now - lastAttempt >= 30 then
                self.runtime.lastAutoPostAttempt = now
                self:PostRecruitment(true)
            end
        end
        self:RefreshUI()
    end
end

function MSR:HandleSlashCommand(input)
    input = tostring(input or "")
    local command, rest = input:match("^(%S*)%s*(.-)$")
    command = string.lower(command or "")
    if command == "" or command == "show" then
        self.UI:Toggle()
    elseif command == "post" then
        self:PostRecruitment(false)
    elseif command == "listen" then
        self.char.session.listening = not self.char.session.listening
        self:Print("Whisper listening: " .. (self.char.session.listening and "ON" or "OFF"))
        self:RefreshUI()
    elseif command == "testwhisper" then
        if rest == "" then rest = "dps aura yes" end
        self.char.session.listening = true
        self:HandleWhisper(rest, "Testplayer")
    elseif command == "test60" then
        local name = rest ~= "" and rest or "Testplayer"
        local message = self:BuildConfiguredMessage("level60Warning", { player = name, level = 60 })
        self.char.session.needsRebuild = true
        self:LocalWarning(message)
    elseif command == "test59" then
        local name = rest ~= "" and rest or "Testplayer"
        self:PrivateWarning(self:BuildConfiguredMessage("level59Warning", { player = name, level = 59 }))
    elseif command == "optimize" then
        self:OptimizeGroups()
    elseif command == "reset" then
        if self.UI and self.UI.ShowResetConfirmation then self.UI:ShowResetConfirmation() end
    else
        self:Print("Commands: /msr, /msr post, /msr listen, /msr optimize, /msr testwhisper <text>, /msr test59 <name>, /msr test60 <name>, /msr reset")
    end
end

local eventFrame = CreateFrame("Frame", "ManastormRecruiterEventFrame")
MSR.eventFrame = eventFrame
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= "FrostSeek_AuraTracker" then return end
        MSR:InitializeDatabase()
        self:RegisterEvent("PLAYER_LOGIN")
        self:RegisterEvent("PLAYER_ENTERING_WORLD")
        self:RegisterEvent("CHAT_MSG_WHISPER")
        self:RegisterEvent("CHAT_MSG_CHANNEL")
        self:RegisterEvent("CHAT_MSG_SYSTEM")
        self:RegisterEvent("CHAT_MSG_PARTY")
        self:RegisterEvent("CHAT_MSG_PARTY_LEADER")
        self:RegisterEvent("CHAT_MSG_RAID")
        self:RegisterEvent("CHAT_MSG_RAID_LEADER")
        self:RegisterEvent("CHAT_MSG_RAID_WARNING")
        self:RegisterEvent("PARTY_MEMBERS_CHANGED")
        self:RegisterEvent("RAID_ROSTER_UPDATE")
        self:RegisterEvent("UNIT_LEVEL")
        self:RegisterEvent("PLAYER_LEVEL_UP")
        self:RegisterEvent("ACTIVE_MANASTORM_UPDATED")
        self:RegisterEvent("READY_CHECK")
        self:RegisterEvent("READY_CHECK_CONFIRM")
        self:RegisterEvent("READY_CHECK_FINISHED")
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        self:SetScript("OnUpdate", function(_, elapsed) MSR:OnUpdate(elapsed) end)
        SLASH_MANASTORMRECRUITER1 = "/msr"
        SLASH_MANASTORMRECRUITER2 = "/manastormrecruiter"
        SlashCmdList.MANASTORMRECRUITER = function(message) MSR:HandleSlashCommand(message) end
        MSR:Print("Loaded. Type /msr to open.")
    elseif event == "PLAYER_LOGIN" then
        if not MSR.UI or not MSR.UI.frame then
            MSR:CreateUI()
            MSR:CheckRebuildRecovery()
        end
        MSR:HandleManastormUpdate()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "ACTIVE_MANASTORM_UPDATED" then
        MSR:HandleManastormUpdate()
    elseif event == "CHAT_MSG_WHISPER" then
        local message, sender = ...
        MSR:HandleWhisper(message, sender)
    elseif event == "CHAT_MSG_CHANNEL" then
        local message, sender, _, channelName, _, _, _, channelNumber, channelBaseName = ...
        if type(MSR.HandlePublicChannelMessage) == "function" then
            MSR:HandlePublicChannelMessage(message, sender, channelName, channelNumber, channelBaseName)
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        local message = tostring((...))
        local declinedName = message:match("^(.+) declines your group invitation")
        if declinedName then
            local applicant = MSR:GetApplicant(declinedName)
            if applicant then MSR:SetApplicantStatus(applicant, "Declined") end
        end
    elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER"
        or event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER"
        or event == "CHAT_MSG_RAID_WARNING" then
        local message, sender = ...
        MSR:RecordGroupChat(event, message, sender)
    elseif event == "READY_CHECK" or event == "READY_CHECK_CONFIRM" or event == "READY_CHECK_FINISHED" then
        MSR:HandleReadyCheckEvent(event, ...)
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" or event == "UNIT_LEVEL" or event == "PLAYER_LEVEL_UP" or event == "PLAYER_REGEN_ENABLED" then
        MSR:HandleRosterChanged()
    end
end)
