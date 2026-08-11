local function assertEqual(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

CreateFrame = function()
    return { RegisterEvent=function() end, SetScript=function() end }
end
GetTime = function() return 100 end
time = function() return 1000 end
date = function() return "12:34" end
SlashCmdList = {}
GetNumRaidMembers = function() return 0 end
GetNumPartyMembers = function() return 1 end
UnitExists = function(unit) return unit == "party1" end
UnitName = function(unit)
    if unit == "player" then return "Leader" end
    if unit == "party1" then return "Aurauser" end
end
UnitLevel = function(unit) return unit == "party1" and 42 or 40 end
UnitIsConnected = function() return true end

local lastAuraWrite
FrostSeekAuraTracker = {
    Runtime = {
        getAuraState = function(name)
            if name == "Aurauser" then return true, "automatic" end
        end,
        getInferredRole = function(name)
            if name == "Aurauser" then return "HEAL", 0.91 end
        end,
        setAuraState = function(name, enabled)
            lastAuraWrite = { name=name, enabled=enabled }
        end,
    },
}

dofile("Core.lua")
dofile("Parser.lua")
dofile("Roster.lua")

local MSR = ManastormRecruiter
MSR.db = {
    settings = {
        slots = { tank=2, heal=3, dps=10, aura=3 },
        auraReservation = { enabled=true, roles={ tank=false, heal=false, dps=true } },
        messages = {},
    },
}
MSR.char = {
    selfRole = "DPS",
    selfAura = false,
    session = {
        applicants = {}, order = {}, level59Alerted = {}, level60Alerted = {},
        whisperHistory = {}, chatScanEntries = {}, chatScanOrder = {},
    },
}
MSR.runtime = { roster={}, rosterByKey={}, groupChat={} }

local roster = MSR:BuildRoster()
local member
for _, entry in ipairs(roster) do
    if entry.name == "Aurauser" then member = entry break end
end
assertEqual(member ~= nil, true, "party member imported")
assertEqual(member.aura, true, "automatic Aura signal applied")
assertEqual(member.auraSource, "automatic", "automatic Aura source retained")
assertEqual(member.role, "HEAL", "combat role signal applied")
assertEqual(member.roleSource, "combat", "combat role source retained")

local applicant = MSR:GetApplicant("Aurauser")
assertEqual(applicant.aura, true, "applicant Aura synchronized")
assertEqual(applicant.role, "HEAL", "applicant role synchronized")
MSR:ToggleApplicantAura(applicant)
assertEqual(lastAuraWrite.name, "Aurauser", "manual Aura write targets applicant")
assertEqual(lastAuraWrite.enabled, false, "manual Aura disable reaches FrostSeek")

print("FrostSeekBridgeTests: all assertions passed")
