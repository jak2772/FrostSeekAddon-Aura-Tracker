local function assertEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local function assertContains(value, expected, label)
    if not string.find(tostring(value), expected, 1, true) then
        error(string.format("%s: expected %q in %q", label, expected, tostring(value)))
    end
end

CreateFrame = function()
    return {
        RegisterEvent = function() end,
        SetScript = function() end,
    }
end
local monotonicNow = 100
GetTime = function() return monotonicNow end
local epochNow = 1000
time = function() return epochNow end
date = function() return "12:34" end
UnitName = function(unit) return unit == "player" and "Leader" or nil end
local playerLevel = 60
UnitLevel = function() return playerLevel end
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = function() return 0 end
LeaveParty = function() return true end
SlashCmdList = {}

dofile("Core.lua")
dofile("Parser.lua")
dofile("Roster.lua")
dofile("Recruitment.lua")
dofile("Manastorm.lua")
dofile("Rebuild.lua")

local MSR = ManastormRecruiter
MSR.db = {
    settings = {
        channel = "8",
        autoPost = true,
        autoPostInterval = 90,
        autoReply = true,
        inviteReminderDelay = 5,
        inviteTimeout = 10,
        slots = { tank = 2, heal = 3, dps = 10, aura = 3 },
        auraReservation = {
            enabled = true,
            roles = { tank = false, heal = false, dps = true },
        },
        messages = {},
    },
}
MSR.char = { session = { applicants = {} } }
MSR.runtime = { roster = {}, rosterByKey = {}, groupChat = {} }

local counts = { tank = 0, heal = 0, dps = 8, aura = 1, unknown = 0, total = 9 }
local active, missing, free = MSR:GetAuraReservationState(counts)
assertEqual(active, true, "default DPS reservation active")
assertEqual(missing, 2, "missing Auras")
assertEqual(free, 2, "free selected slots")

local issue = MSR:GetApplicantCapacityIssue({ role = "DPS", aura = false }, counts)
assertEqual(issue, "AURA_REQUIRED", "DPS without Aura is reserved")
issue = MSR:GetApplicantCapacityIssue({ role = "TANK", aura = false }, counts)
assertEqual(issue, nil, "unselected Tank role is not reserved")

MSR.db.settings.auraReservation.roles = { tank = true, heal = false, dps = false }
counts = { tank = 1, heal = 3, dps = 10, aura = 2, unknown = 0, total = 14 }
issue = MSR:GetApplicantCapacityIssue({ role = "TANK", aura = false }, counts)
assertEqual(issue, "AURA_REQUIRED", "Tank reservation can be selected")

MSR.db.settings.auraReservation.enabled = false
issue = MSR:GetApplicantCapacityIssue({ role = "TANK", aura = false }, counts)
assertEqual(issue, nil, "reservation can be disabled")

MSR.db.settings.auraReservation.enabled = true
MSR.db.settings.auraReservation.roles = { tank = false, heal = false, dps = true }
counts = { tank = 0, heal = 0, dps = 8, aura = 1, unknown = 0, total = 9 }
MSR.GetCommittedCounts = function() return counts end
local recruitment = MSR:BuildRecruitmentMessage()
assertContains(recruitment, "LFM MS - 0/2 Tanks - 0/3 Healer - 8/10 DPS - Aura 1/3 - 9/15 Total", "full recruitment counters")
assertContains(recruitment, "Need: 2 Tanks - 3 Healers - 2 DPS - 2 Auras", "missing-slot recruitment")
assertContains(recruitment, "Aura required for remaining DPS slots", "reservation suffix")

local originalGetChannelName = GetChannelName
local originalSendChatMessage = SendChatMessage
local recruitmentPosts = 0
GetChannelName = function() return 8 end
SendChatMessage = function(_, channel)
    if channel == "CHANNEL" then recruitmentPosts = recruitmentPosts + 1 end
    return true
end
MSR.char.session.listening = false
assertEqual(MSR:ToggleRecruitment(), true, "recruitment toggle starts")
assertEqual(MSR.char.session.listening, true, "start enables applicant listening")
assertEqual(MSR.db.settings.autoPost, true, "start enables automatic recruitment posts")
assertEqual(recruitmentPosts, 0, "start does not send a recruitment post")
assertEqual(MSR.char.session.lastPostAt, epochNow, "start begins a fresh automatic-post interval")
assertEqual(MSR:ToggleRecruitment(), true, "recruitment toggle stops")
assertEqual(MSR.char.session.listening, false, "stop pauses applicant listening and auto posts")
assertEqual(MSR.db.settings.autoPost, false, "stop disables automatic recruitment posts")
assertEqual(recruitmentPosts, 0, "stop does not send a recruitment post")
GetChannelName = originalGetChannelName
SendChatMessage = originalSendChatMessage

local oneMissing = MSR:BuildMessageValues({ tank = 2, heal = 2, dps = 10, aura = 3, total = 14 })
assertEqual(oneMissing.needed, "1 Healer", "Need omits fulfilled values")

MSR.db.settings.messages.recruitment = "LFM MS Tank {tank}/{tankMax} Heal {heal}/{healMax} DPS {dps}/{dpsMax} Aura {aura}/{auraMax}. PM me"
assertEqual(MSR:MigrateRecruitmentTemplate(), true, "legacy recruitment template migration")
assertEqual(MSR.db.settings.messages.recruitment, "LFM MS {needed}. PM me", "migrated recruitment template")
MSR.db.settings.messages.recruitment = nil

MSR.db.settings.messages.level60StatusPost = "I am level 60. Tank {tank}/{tankMax}, Heal {heal}/{healMax}, Aura {aura}/{auraMax}. Aura players: {auraPlayers}."
assertEqual(MSR:MigrateLevel60StatusTemplate(), true, "legacy Level 60 status template migration")
assertContains(MSR.db.settings.messages.level60StatusPost, "Thanks, everyone!", "friendly migrated Level 60 status")
MSR.db.settings.messages.level60StatusPost = nil

MSR.db.settings.messages.acceptedApplicationReply = "Welcome {player}: {role}/{aura}"
local configured = MSR:BuildConfiguredMessage("acceptedApplicationReply", {
    player = "Alice",
    role = "Heal",
    aura = "Yes",
})
assertEqual(configured, "Welcome Alice: Heal/Yes", "custom message placeholders")

local roster = {
    { key = "leader", name = "Leader", unit = "player", raidIndex = 1, role = "TANK", aura = true },
    { key = "alice", name = "Alice", unit = "raid2", raidIndex = 2, role = "HEAL", aura = true },
    { key = "bob", name = "Bob", unit = "raid3", raidIndex = 3, role = "DPS", aura = false },
}

local partialRoster = {
    { key = "healer", name = "Healer", unit = "raid1", raidIndex = 1, subgroup = 1, role = "HEAL", aura = true },
    { key = "tank", name = "MainTank", unit = "raid2", raidIndex = 2, subgroup = 2, role = "TANK", aura = false },
    { key = "damage", name = "Damage", unit = "raid3", raidIndex = 3, subgroup = 1, role = "DPS", aura = true },
}
local partialGroups = MSR:BuildPartialDesiredGroups(partialRoster)
assertEqual(partialGroups[1][1].key, "tank", "primary Tank is first in desired Group 1")
local partialPlan = MSR:BuildGroupOptimizationPlan(partialRoster)
assertEqual(partialPlan.primaryTankKey, "tank", "group optimization stores primary Tank")
local markedUnit, markedIcon
SetRaidTarget = function(unit, icon)
    markedUnit, markedIcon = unit, icon
    return true
end
partialRoster[2].subgroup = 1
assertEqual(MSR:MarkPrimaryTank(partialRoster, "tank"), true, "primary Tank star marker")
assertEqual(markedUnit, "raid2", "primary Tank marker unit")
assertEqual(markedIcon, 1, "primary Tank receives raid star")

local mainTankAssignments = {}
SetPartyAssignment = function(assignment, unit, name, exactMatch)
    table.insert(mainTankAssignments, {
        assignment = assignment,
        unit = unit,
        name = name,
        exactMatch = exactMatch,
    })
    return true
end
local tankRoster = {
    { key = "tank1", name = "MainTank", unit = "raid1", raidIndex = 1, subgroup = 1, role = "TANK" },
    { key = "tank2", name = "OffTank", unit = "raid6", raidIndex = 6, subgroup = 2, role = "TANK" },
    { key = "damage", name = "Damage", unit = "raid2", raidIndex = 2, subgroup = 1, role = "DPS" },
}
assertEqual(MSR:AssignMainTanks(tankRoster), true, "all configured Tanks receive main-Tank assignment")
assertEqual(#mainTankAssignments, 2, "only Tank roles receive /mt")
assertEqual(mainTankAssignments[1].assignment, "MAINTANK", "first Tank uses MAINTANK assignment")
assertEqual(mainTankAssignments[1].unit, "raid1", "first Tank unit is forwarded")
assertEqual(mainTankAssignments[2].unit, "raid6", "second Tank unit is forwarded")
assertEqual(mainTankAssignments[2].exactMatch, true, "main-Tank assignment uses exact player matching")

local statuses = { player = "ready", raid2 = "notready", raid3 = "waiting" }
GetReadyCheckStatus = function(unit) return statuses[unit] end
MSR.runtime.readyCheck = MSR:CreateReadyCheckState(roster, "Leader")
MSR:RefreshReadyCheckMemberStatuses(MSR.runtime.readyCheck)
local readyText = MSR:GetReadyCheckStatusText()
assertContains(readyText, "1/3 ready", "ready count")
assertContains(readyText, "Not ready: Alice", "not-ready name")
assertContains(readyText, "Waiting: Bob", "waiting name")

MSR:HandleReadyCheckEvent("READY_CHECK_CONFIRM", "raid3", true)
assertEqual(MSR.runtime.readyCheck.ready, 2, "live ready confirmation")
assertEqual(MSR:GetReadyCheckMemberStatus(roster[2]), "notready", "per-player not-ready status")
assertEqual(MSR:GetReadyCheckMemberStatus(roster[3]), "ready", "per-player ready status")

MSR.char.session.applicants = {
    alice = { key = "alice", name = "Alice", status = "Joined", role = "HEAL", aura = true },
    waiter = { key = "waiter", name = "Waiter", status = "New", role = "DPS", aura = false },
}
MSR.char.session.order = { "alice", "waiter" }
MSR.char.session.listening = true
MSR.db.settings.autoPost = true
C_Manastorm = {
    IsInManastorm = function() return false end,
    Enter = function(level) return level == 1 end,
}
local originalBuildRoster = MSR.BuildRoster
MSR.BuildRoster = function() return roster end
assertEqual(MSR:StartManastormLevelOne(), true, "Manastorm start request")
MSR.BuildRoster = originalBuildRoster
assertEqual(MSR.char.session.listening, false, "listening stops when Manastorm starts")
assertEqual(MSR.db.settings.autoPost, false, "auto post stops when Manastorm starts")
assertEqual(MSR.char.session.applicants.waiter, nil, "waiting applicant cleared on Manastorm start")
assertEqual(MSR.char.session.applicants.alice.name, "Alice", "joined applicant retained on Manastorm start")
assertEqual(#MSR.char.session.order, 1, "only joined applicants remain ordered")

MSR.db.settings.autoPost = true
MSR:DisableAutoPostForManastorm()
assertEqual(MSR.db.settings.autoPost, false, "auto post stops for Manastorm")

local sentMessage, sentChannel
GetNumRaidMembers = function() return 3 end
SendChatMessage = function(message, channel)
    sentMessage, sentChannel = message, channel
    return true
end
local leavePartyCalls = 0
LeaveParty = function()
    leavePartyCalls = leavePartyCalls + 1
    return true
end
assertEqual(MSR:SendGroupChat("Hello raid"), true, "embedded chat send")
assertEqual(sentMessage, "Hello raid", "embedded chat message")
assertEqual(sentChannel, "RAID", "embedded chat channel")
assertEqual(MSR:GetMessageRoute("rosterSummary"), "RAID", "roster summary keeps its legacy raid-chat default")
assertEqual(MSR:GetMessageRoute("level60Warning"), "RAID_WARNING", "level warning keeps its legacy raid-warning default")
assertEqual(MSR:GetMessageRoute("recruitment"), nil, "recruitment output remains fixed to its recruitment channel")
local localConfiguredOutput
local originalPrint = MSR.Print
MSR.Print = function(_, message) localConfiguredOutput = message end
assertEqual(MSR:SetMessageRoute("rosterSummary", "LOCAL"), true, "roster route can be changed")
assertEqual(MSR:SendConfiguredMessage("rosterSummary", "Local roster"), true, "local configured message is delivered")
assertEqual(localConfiguredOutput, "Local roster", "local configured message remains private")
localConfiguredOutput = nil
assertEqual(MSR:SetMessageRoute("rosterSummary", "OFF"), true, "configured message can be disabled")
assertEqual(MSR:SendConfiguredMessage("rosterSummary", "Hidden roster"), true, "disabled message is intentionally skipped")
assertEqual(localConfiguredOutput, nil, "disabled message produces no local output")
assertEqual(MSR:SetMessageRoute("rosterSummary", "RAID"), true, "roster route can be restored")
MSR.Print = originalPrint

local reminderTarget
MSR.char.session.applicants.pending = {
    key = "pending", name = "Pending", role = "DPS", aura = true,
    status = "Invited", inviteSentAt = 1000, inviteReminderSent = false,
}
SendChatMessage = function(message, channel, _, target)
    sentMessage, sentChannel, reminderTarget = message, channel, target
    return true
end
epochNow = 1005
MSR:UpdatePendingInvites()
assertEqual(sentChannel, "WHISPER", "pending invite reminder channel")
assertEqual(reminderTarget, "Pending", "pending invite reminder target")
epochNow = 1010
MSR:UpdatePendingInvites()
assertEqual(MSR.char.session.applicants.pending.status, "NoResponse", "pending invite releases after ten seconds")
epochNow = 1000

local automaticReplies, lastAutomaticReply = 0, nil
SendChatMessage = function(message, channel)
    if channel == "WHISPER" then
        automaticReplies = automaticReplies + 1
        lastAutomaticReply = message
    end
    return true
end
MSR.char.session.listening = true
MSR.db.settings.autoReply = true
MSR:HandleWhisper("tank aura yes", "Dedupe")
MSR:HandleWhisper("tank aura yes", "Dedupe")
assertEqual(automaticReplies, 1, "unchanged application reply is deduplicated")
MSR:HandleWhisper("heal aura yes", "Dedupe")
assertEqual(automaticReplies, 2, "changed application receives a new reply")

MSR:HandleWhisper("dps", "Clarify")
assertEqual(MSR.char.session.applicants.clarify.pendingQuestion, "aura", "missing Aura starts clarification")
assertContains(lastAutomaticReply, "Aura", "missing Aura question is whispered")
MSR:HandleWhisper("yes", "Clarify")
assertEqual(MSR.char.session.applicants.clarify.aura, true, "Aura-only answer updates applicant")
assertEqual(MSR.char.session.applicants.clarify.pendingQuestion, "level", "level is requested after Aura")
assertContains(lastAutomaticReply, "level", "missing level question is whispered")
MSR:HandleWhisper("42", "Clarify")
assertEqual(MSR.char.session.applicants.clarify.level, 42, "level-only answer updates applicant")
assertEqual(MSR.char.session.applicants.clarify.pendingQuestion, nil, "clarification completes after level")
assertContains(lastAutomaticReply, "Welcome", "completed clarification receives acceptance reply")
assertEqual(automaticReplies, 5, "Aura, level, and completion each receive one reply")

MSR.char.session.chatScanEntries = {}
MSR.char.session.chatScanOrder = {}
MSR.char.session.order = MSR.char.session.order or {}
MSR.char.session.listening = true
assertEqual(MSR:IsChatScanCandidate("LF Manastorm"), true, "LF plus Manastorm is accepted")
assertEqual(MSR:IsChatScanCandidate("LFG Manastorms"), true, "LFG plus Manastorms is accepted")
assertEqual(MSR:IsChatScanCandidate("LFM MS need healer"), false, "other groups looking for members are ignored")
assertEqual(MSR:IsChatScanCandidate("LFG looms dps"), false, "loom gear terms do not identify Manastorm")
assertEqual(MSR:IsChatScanCandidate("MS need tank healer dps"), false, "roles without LF or LFG are ignored")
assertEqual(MSR:IsChatScanCandidate("LFG dungeon dps"), false, "LFG without Manastorm is ignored")
assertEqual(MSR:HandlePublicChannelMessage("LFG MS dps loom", "ScanGuy", "1. Ascension", 1, "Ascension"), true, "public Manastorm post is scanned")
assertEqual(#MSR:GetChatScanEntries(), 1, "scanner records one candidate")
assertEqual(MSR:GetChatScanEntries()[1].role, "DPS", "scanner infers public-post role")
assertEqual(MSR:HandlePublicChannelMessage("new LFG MS dps", "ScanGuy", "1. Ascension", 1, "Ascension"), true, "repeated candidate updates")
assertEqual(#MSR:GetChatScanEntries(), 1, "repeated player is deduplicated")
assertEqual(MSR:HandlePublicChannelMessage("WTS materials", "Trader", "2. Trade", 2, "Trade"), false, "unrelated public post is ignored")
local scannerInviteName
InviteUnit = function(name) scannerInviteName = name return true end
local originalIsGroupLeader = MSR.IsGroupLeader
MSR.IsGroupLeader = function() return true end
assertEqual(MSR:InviteChatScanEntry(MSR:GetChatScanEntries()[1]), true, "scanner candidate can be invited before Aura review")
assertEqual(scannerInviteName, "ScanGuy", "scanner invites the detected player")
assertEqual(MSR.char.session.applicants.scanguy.status, "Invited", "scanner invite enters applicant workflow")
MSR.IsGroupLeader = originalIsGroupLeader

local originalIsInManastorm = MSR.IsInManastorm
local lateReplyMessage, lateReplyChannel, lateReplyTarget, lateReplyCount
lateReplyCount = 0
MSR.IsInManastorm = function() return true end
MSR.char.session.listening = false
SendChatMessage = function(message, channel, _, target)
    lateReplyMessage, lateReplyChannel, lateReplyTarget = message, channel, target
    lateReplyCount = lateReplyCount + 1
    return true
end
MSR:HandleWhisper("Are you still recruiting?", "Lateplayer")
assertEqual(lateReplyChannel, "WHISPER", "Manastorm reply bypasses stopped listening")
assertEqual(lateReplyTarget, "Lateplayer", "Manastorm reply targets the late whisper sender")
assertContains(lateReplyMessage, "already inside Manastorm", "late whisper receives Manastorm status")
assertEqual(MSR.char.session.applicants.lateplayer, nil, "late Manastorm whisper is not added as applicant")
MSR:HandleWhisper("Any free slot?", "Lateplayer")
assertEqual(lateReplyTarget, "Lateplayer", "later whispers still receive the Manastorm reply")
assertEqual(lateReplyCount, 2, "every later Manastorm whisper is answered")
MSR.IsInManastorm = originalIsInManastorm
SendChatMessage = function(message, channel)
    sentMessage, sentChannel = message, channel
    return true
end

MSR.BuildRoster = function() return roster end
local level60Status = MSR:BuildLevel60StatusMessage(roster)
assertContains(level60Status, "Thanks, everyone! I have reached level 60", "friendly manual Level 60 status")
assertContains(level60Status, "Raid lead will pass automatically when I leave", "automatic lead handoff information")
assertContains(level60Status, "The current roster is", "current roster introduction")
assertContains(level60Status, "Tank 1/2, Heal 1/3, Aura 2/3", "configured Level 60 roster counts")
assertContains(level60Status, "Aura players: Leader, Alice", "Aura player names")
assertEqual(MSR:PostLevel60Status(), true, "manual Level 60 post")
assertEqual(sentMessage, level60Status, "manual Level 60 group message")
assertEqual(leavePartyCalls, 0, "Level 60 post waits before leaving the group")
monotonicNow = monotonicNow + 1
MSR:UpdatePendingLeave()
assertEqual(leavePartyCalls, 1, "Level 60 group leave starts after the post delay")

playerLevel = 59
local level59Status = MSR:BuildLevelStatusMessage(roster)
assertContains(level59Status, "I am level 59 and close to level 60", "manual Level 59 status")
assertEqual(MSR:PostLevelStatus(), true, "manual Level 59 post")
assertEqual(sentMessage, level59Status, "manual Level 59 group message")
assertEqual(leavePartyCalls, 1, "Level 59 post waits before leaving the group")
monotonicNow = monotonicNow + 1
MSR:UpdatePendingLeave()

playerLevel = 42
local below59Status = MSR:BuildLevelStatusMessage(roster)
assertContains(below59Status, "leaving the raid at level 42", "manual below-Level-59 status")
assertEqual(MSR:PostLevelStatus(), true, "manual below-Level-59 post")
assertEqual(sentMessage, below59Status, "manual below-Level-59 group message")
assertEqual(leavePartyCalls, 2, "below-Level-59 post waits before leaving the group")
monotonicNow = monotonicNow + 1
MSR:UpdatePendingLeave()
assertEqual(leavePartyCalls, 3, "Post and Leave exits the group outside Manastorm")

local insideManastorm = true
local leaveManastormCalls = 0
MSR.IsInManastorm = function() return insideManastorm end
C_Manastorm.Leave = function()
    leaveManastormCalls = leaveManastormCalls + 1
    return true
end
assertEqual(MSR:PostLevelStatus(), true, "Post and Leave starts inside Manastorm")
assertEqual(leaveManastormCalls, 0, "Manastorm exit waits for the chat post delay")
monotonicNow = monotonicNow + 1
MSR:UpdatePendingLeave()
assertEqual(leaveManastormCalls, 1, "Manastorm is left after the chat post delay")
assertEqual(leavePartyCalls, 3, "group remains until Manastorm exit confirmation")
insideManastorm = false
MSR:UpdatePendingLeave()
assertEqual(leavePartyCalls, 4, "group leaves after Manastorm exit confirmation")

insideManastorm = true
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = function() return 0 end
assertEqual(MSR:PostLevelStatus(), true, "solo Manastorm exit remains available without a group")
assertEqual(leaveManastormCalls, 2, "solo Manastorm exit uses only the Manastorm leave API")
assertEqual(leavePartyCalls, 4, "solo Manastorm exit does not call LeaveParty")
GetNumRaidMembers = function() return 3 end

local removedName
IsRaidLeader = function() return true end
InCombatLockdown = function() return false end
roster[2].level = 59
MSR.char.session.level59Alerted = {}
MSR.char.session.level60Alerted = {}
MSR.IsInManastorm = function() return true end
MSR:ScanForLevel60()
assertEqual(sentChannel, "RAID_WARNING", "Level 59 uses a real raid warning")
assertContains(sentMessage, "Alice", "Level 59 raid warning player")

UninviteUnit = function(name) removedName = name return true end
assertEqual(MSR:KickRosterMember(roster[2]), true, "single-player removal")
assertEqual(removedName, "Alice", "selected player removal target")
assertEqual(MSR:KickRosterMember(roster[1]), false, "self removal is blocked")

MSR:RecordGroupChat("CHAT_MSG_RAID", "Ready?", "Alice-Realm")
assertEqual(#MSR.runtime.groupChat, 1, "embedded chat history")
assertEqual(MSR.runtime.groupChat[1].sender, "Alice", "chat sender normalization")

MSR.runtime.rebuild = { phase = "inviting", snapshot = {}, index = 1 }
assertEqual(MSR:AttemptRebuildInvite(false), true, "finished reinvites enter return wait")
assertEqual(MSR.runtime.rebuild.phase, "waiting-return", "rebuild waits for returning players")
assertEqual(MSR.runtime.rebuild.deadline - GetTime(), 10, "rebuild return wait is limited to ten seconds")

MSR.runtime.rebuild = nil
MSR.runtime.rosterByKey = {}
MSR.char.session.rebuildRecovery = {
    active = true,
    stage = "reinviting",
    removalSnapshot = { { key = "alice", name = "Alice" } },
    reinviteSnapshot = { { key = "alice", name = "Alice", role = "HEAL", aura = true } },
    excluded = {},
}
MSR.IsInManastorm = function() return false end
assertEqual(MSR:ResumeRebuild(), true, "unfinished rebuild can be resumed")
assertEqual(MSR.runtime.rebuild.phase, "inviting", "rebuild recovery resumes at reinvites")

MSR.char.session.applicants = { private = { name = "Privateplayer" } }
MSR.char.session.order = { "private" }
MSR.char.session.whisperHistory = { { sender = "Privateplayer", message = "dps aura yes" } }
MSR:ClearSession()
assertEqual(next(MSR.char.session.applicants), nil, "session reset clears applicants")
assertEqual(next(MSR.char.session.whisperHistory), nil, "session reset clears stored whispers")
assertEqual(MSR.char.session.rebuildRecovery.active, false, "session reset clears rebuild recovery")

print("CoreTests: all assertions passed")

