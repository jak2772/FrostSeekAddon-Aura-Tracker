-- ============================================================================
-- FrostSeek Aura Tracker v1.4.0
-- Companion module for FrostSeek 2.2.5 / WoW Ascension (3.3.5 client).
--
-- This addon DOES NOT modify or redistribute FrostSeek source.
-- It uses FrostSeek's public-at-runtime module/tab API to appear inside its UI.
--
-- Manastorm model:
--   15 player raid
--   3 subgroups of 5
--   exactly one designated Aura of Experience player per subgroup
-- ============================================================================

local ADDON = "FrostSeek_AuraTracker"
local FSA = CreateFrame("Frame", "FrostSeekAuraTrackerEventFrame")
_G.FrostSeekAuraTracker = FSA

local PFX = "|cff88ccff[FrostSeek Aura]|r "
local VERSION = "1.4.0"
local REQUIRED_FROSTSEEK_VERSION = "2.2.5"
local dependencyWarningShown = false

local MESSAGE_DEFAULTS = {
    missingRole = "What role are you joining as? Reply Tank, Heal, or DPS.",
    missingAura = "Do you provide Aura of Experience? Reply aura yes or aura no.",
    missingLevel = "What level are you? Reply with a number from 1 to 60.",
    accepted = "Registered: {role}, Aura: {aura}, Level: {level}. Waiting for raid lead.",
    insideManastorm = "We are already inside Manastorm and are not recruiting right now.",
}

local defaults = {
    marked = {},                 -- [lowercaseName] = displayName
    knownAuraPlayers = {},       -- [lowercaseName] = displayName, confirmed PROVIDERS only (manual or unitCaster)
    ignoredProviders = {},       -- explicit UI opt-out for automatically learned providers
    providerCacheMigration = 0,
    inferProviderOnCoverageTransition = true,
    recruitChannel = 1,         -- IMPORTANT: Ascension is channel slot 1 by default
    recruitInterval = 60,
    recruiting = false,
    recruitMessage = "",       -- blank uses the generated coverage-aware advert
    autoInviteAuraWhispers = false, -- exact trimmed/case-insensitive "aura" only
    autoApplicantReplies = true,
    candidateLifetime = 600,    -- seconds
    manualProviders = {},       -- explicit user assignments, separate from confirmed providers

    announceToGroup = true,
    leaderOnlyAlerts = false,
    soundAlerts = false,
    announceLevel59 = true,
    announceJoin = true,
    announceLeave = true,
    announceDistribution = true,
    announceRestored = true,

    autoMarkDetected = true,

    -- Event scans are primary; this is only a fallback for Ascension quirks.
    periodicScan = true,
    periodicScanInterval = 5,

    combatRoleTracking = true,
    messages = MESSAGE_DEFAULTS,

    overlay = {
        shown = true,
        locked = false,
        point = "RIGHT",
        relativePoint = "RIGHT",
        x = -35,
        y = 30,
        scale = 1.0,
    },
}

local state = {
    roster = {},
    initializedRoster = false,
    coverage = { [1] = {}, [2] = {}, [3] = {} }, -- assigned coverage
    verifiedCoverage = { [1] = {}, [2] = {}, [3] = {} },
    auraDetectedGroups = { [1] = false, [2] = false, [3] = false },
    distributionSignature = nil,
    candidates = {},            -- EXACT "aura" replies only
    nonAuraCandidates = {},       -- other whispers received during recruitment response window
    recruitReplyUntil = 0,
    recruitElapsed = 0,
    pendingScan = nil,
    periodicElapsed = 0,
    partyAuraSensor = { [1] = nil, [2] = nil, [3] = nil },
    pendingProviderCandidates = {},
    departedProviders = {},
    lastAnnouncedText = nil,
    lastAnnouncedAt = 0,
    lastPartyHealthSignature = nil,
    pendingDistributionAlert = nil,
    lastManastormState = false,
    manastormAuditDue = nil,
    manastormEntryGraceUntil = nil,
    candidatePruneElapsed = 0,
    roleEvidence = {},
    roleUpdateElapsed = 0,
    groupChat = {},
    level59Announced = {},
}

local Module = {}
FSA.Module = Module

-- ============================================================================
-- Helpers
-- ============================================================================

local function MergeDefaults(src, dst)
    if type(dst) ~= "table" then dst = {} end
    for k, v in pairs(src) do
        if type(v) == "table" then
            dst[k] = MergeDefaults(v, dst[k])
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
    return dst
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PFX .. tostring(msg))
end

local function VersionAtLeast(actual, required)
    local actualParts, requiredParts = {}, {}
    for value in string.gmatch(tostring(actual or ""), "%d+") do
        table.insert(actualParts, tonumber(value) or 0)
    end
    for value in string.gmatch(tostring(required or ""), "%d+") do
        table.insert(requiredParts, tonumber(value) or 0)
    end
    for index = 1, math.max(#actualParts, #requiredParts) do
        local actualValue = actualParts[index] or 0
        local requiredValue = requiredParts[index] or 0
        if actualValue ~= requiredValue then
            return actualValue > requiredValue
        end
    end
    return true
end

local function FrostSeekDependencyReady()
    local frostSeek = _G.FrostSeek
    local actualVersion = frostSeek and frostSeek.VERSION
    if frostSeek and VersionAtLeast(actualVersion, REQUIRED_FROSTSEEK_VERSION) then
        return true
    end
    if not dependencyWarningShown then
        dependencyWarningShown = true
        Print("|cffff5555Requires FrostSeek " .. REQUIRED_FROSTSEEK_VERSION ..
            " or newer. Install/update FrostSeek, then reload the UI.|r")
    end
    return false
end

local function ShortName(name)
    if not name then return nil end
    local dash = string.find(name, "-", 1, true)
    if dash then return string.sub(name, 1, dash - 1) end
    return name
end

local function Key(name)
    return string.lower(ShortName(name or ""))
end

-- Combat-log roles are evidence, not permanent assignments. Values decay so
-- an old pull cannot label someone for the rest of the session.
local ROLE_EVIDENCE_HALF_LIFE = 120

local function DecayRoleEvidence(record, now)
    if not record then return end
    now = now or GetTime()
    local elapsed = now - (record.updatedAt or now)
    if elapsed > 0 then
        local factor = math.pow(0.5, elapsed / ROLE_EVIDENCE_HALF_LIFE)
        record.damageTaken = (record.damageTaken or 0) * factor
        record.effectiveHealing = (record.effectiveHealing or 0) * factor
        record.damageEvents = (record.damageEvents or 0) * factor
        record.healEvents = (record.healEvents or 0) * factor
        record.updatedAt = now
    end
end

local function RoleEvidenceFor(name)
    local key = Key(name)
    if key == "" then return nil end
    local record = state.roleEvidence[key]
    if not record then
        record = {
            key = key,
            name = ShortName(name),
            damageTaken = 0,
            effectiveHealing = 0,
            damageEvents = 0,
            healEvents = 0,
            updatedAt = GetTime(),
        }
        state.roleEvidence[key] = record
    end
    DecayRoleEvidence(record)
    return record
end

local function RecordCombatRoleEvidence(subevent, sourceName, destName, ...)
    if not FrostSeekAuraDB or not FrostSeekAuraDB.combatRoleTracking then return end
    local sourceKey = Key(sourceName)
    local destKey = Key(destName)
    local sourceInRaid = sourceKey ~= "" and state.roster[sourceKey] ~= nil
    local destInRaid = destKey ~= "" and state.roster[destKey] ~= nil

    if (subevent == "SPELL_HEAL" or subevent == "SPELL_PERIODIC_HEAL") and sourceInRaid and destInRaid then
        local _, _, _, amount, overhealing = ...
        amount = tonumber(amount) or 0
        overhealing = tonumber(overhealing) or 0
        local effective = math.max(0, amount - overhealing)
        if effective > 0 then
            local record = RoleEvidenceFor(sourceName)
            record.effectiveHealing = record.effectiveHealing + effective
            record.healEvents = record.healEvents + 1
        end
        return
    end

    if destInRaid and not sourceInRaid then
        local amount
        if subevent == "SWING_DAMAGE" then
            amount = select(1, ...)
        elseif subevent == "ENVIRONMENTAL_DAMAGE" then
            amount = select(2, ...)
        elseif subevent == "RANGE_DAMAGE" or subevent == "SPELL_DAMAGE" or
               subevent == "SPELL_PERIODIC_DAMAGE" or subevent == "DAMAGE_SHIELD" or
               subevent == "DAMAGE_SPLIT" then
            amount = select(4, ...)
        end
        amount = tonumber(amount) or 0
        if amount > 0 then
            local record = RoleEvidenceFor(destName)
            record.damageTaken = record.damageTaken + amount
            record.damageEvents = record.damageEvents + 1
        end
    end
end

local function UpdateInferredRoles()
    local now = GetTime()
    local records = {}
    local totalHealing, totalDamage = 0, 0
    for key, info in pairs(state.roster or {}) do
        local record = state.roleEvidence[key]
        if record then
            record.name = info.name or record.name
            DecayRoleEvidence(record, now)
            record.inferredRole = nil
            record.confidence = nil
            totalHealing = totalHealing + (record.effectiveHealing or 0)
            totalDamage = totalDamage + (record.damageTaken or 0)
            table.insert(records, record)
        end
    end

    table.sort(records, function(a, b)
        return (a.effectiveHealing or 0) > (b.effectiveHealing or 0)
    end)
    local healerCount = 0
    local topHealing = records[1] and records[1].effectiveHealing or 0
    for _, record in ipairs(records) do
        local healing = record.effectiveHealing or 0
        local share = totalHealing > 0 and healing / totalHealing or 0
        if healerCount < 3 and healing >= 1000 and (record.healEvents or 0) >= 3 and
           share >= 0.05 and (topHealing <= 0 or healing >= topHealing * 0.12) then
            record.inferredRole = "HEALER"
            record.confidence = (share >= 0.25 or (record.healEvents or 0) >= 15) and "high" or "medium"
            healerCount = healerCount + 1
        end
    end

    table.sort(records, function(a, b)
        return (a.damageTaken or 0) > (b.damageTaken or 0)
    end)
    local tankCount = 0
    local topDamage = records[1] and records[1].damageTaken or 0
    for _, record in ipairs(records) do
        local damage = record.damageTaken or 0
        local share = totalDamage > 0 and damage / totalDamage or 0
        if not record.inferredRole and tankCount < 2 and damage >= 1000 and
           (record.damageEvents or 0) >= 5 and share >= 0.12 and
           (topDamage <= 0 or damage >= topDamage * 0.25) then
            record.inferredRole = "TANK"
            record.confidence = (share >= 0.30 or (record.damageEvents or 0) >= 20) and "high" or "medium"
            tankCount = tankCount + 1
        end
    end
end

local function InferredRoleNames(role)
    local names = {}
    for key, info in pairs(state.roster or {}) do
        local record = state.roleEvidence[key]
        if record and record.inferredRole == role then
            table.insert(names, (info.name or record.name) .. " (" .. tostring(record.confidence or "low") .. ")")
        end
    end
    table.sort(names)
    return names
end

local function CombatRoleSummary()
    local tanks, healers = {}, {}
    for key, info in pairs(state.roster or {}) do
        local record = state.roleEvidence[key]
        if record and record.inferredRole == "TANK" then
            table.insert(tanks, info.name or record.name)
        elseif record and record.inferredRole == "HEALER" then
            table.insert(healers, info.name or record.name)
        end
    end
    table.sort(tanks)
    table.sort(healers)
    local tankText = #tanks > 0 and table.concat(tanks, "/") or "learning"
    local healerText = #healers > 0 and table.concat(healers, "/") or "learning"
    return "T: " .. tankText .. "  H: " .. healerText
end

local function Trim(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
end

local function ApplyMessageTemplate(template, values)
    return tostring(template or ""):gsub("{([%w_]+)}", function(key)
        local value = values and values[key]
        return value == nil and ("{" .. key .. "}") or tostring(value)
    end)
end

local function MessageTemplate(key)
    local messages = FrostSeekAuraDB and FrostSeekAuraDB.messages or nil
    return tostring((messages and messages[key]) or MESSAGE_DEFAULTS[key] or "")
end

local function HasWord(clean, word)
    return string.find(clean, " " .. word .. " ", 1, true) ~= nil
end

local function ParseRecruitmentReply(message, previous)
    local raw = string.lower(tostring(message or ""))
    local clean = " " .. string.gsub(raw, "[^%w]+", " ") .. " "
    clean = string.gsub(clean, "%s+", " ")
    local result = {
        role = previous and previous.role or nil,
        aura = previous and previous.aura or nil,
        level = previous and previous.level or nil,
    }

    local tank = HasWord(clean, "tank") or HasWord(clean, "mt") or HasWord(clean, "ot")
    local heal = HasWord(clean, "heal") or HasWord(clean, "healer") or HasWord(clean, "heals")
    local dps = HasWord(clean, "dps") or HasWord(clean, "dd") or HasWord(clean, "damage") or
                HasWord(clean, "rdps") or HasWord(clean, "mdps") or HasWord(clean, "melee") or
                HasWord(clean, "ranged")
    local roleCount = (tank and 1 or 0) + (heal and 1 or 0) + (dps and 1 or 0)
    if roleCount == 1 then
        result.role = tank and "TANK" or heal and "HEAL" or "DPS"
    elseif roleCount > 1 then
        result.role = nil
    end

    local auraMention = HasWord(clean, "aura") or HasWord(clean, "auraa") or HasWord(clean, "auro")
    local auraNo = string.find(clean, " no aura ", 1, true) or
                   string.find(clean, " aura no ", 1, true) or HasWord(clean, "noaura") or
                   string.find(clean, " without aura ", 1, true)
    local auraYes = string.find(clean, " aura yes ", 1, true) or
                    string.find(clean, " yes aura ", 1, true) or
                    string.find(clean, " with aura ", 1, true) or
                    string.find(clean, " have aura ", 1, true)
    if auraNo then
        result.aura = false
    elseif auraYes or (auraMention and not string.find(clean, " raf aura ", 1, true)) then
        result.aura = true
    elseif previous and previous.role and previous.aura == nil then
        if HasWord(clean, "yes") or HasWord(clean, "y") then result.aura = true end
        if HasWord(clean, "no") or HasWord(clean, "n") then result.aura = false end
    end

    local level = tonumber(string.match(clean, " level (%d+) ") or
                           string.match(clean, " lvl (%d+) ") or
                           string.match(clean, " (%d+) %s*$"))
    if level and level >= 1 and level <= 60 then result.level = level end

    result.complete = result.role ~= nil and result.aura ~= nil and result.level ~= nil
    result.exactAura = string.lower(Trim(message)) == "aura"
    return result
end

local function CandidateReply(entry)
    if not FrostSeekAuraDB.autoApplicantReplies then return nil, nil end
    if not entry.role then return MessageTemplate("missingRole"), "missing:role" end
    if entry.aura == nil then return MessageTemplate("missingAura"), "missing:aura" end
    if not entry.level then return MessageTemplate("missingLevel"), "missing:level" end
    local reply = ApplyMessageTemplate(MessageTemplate("accepted"), {
        role = entry.role == "HEAL" and "Heal" or entry.role == "TANK" and "Tank" or "DPS",
        aura = entry.aura and "Yes" or "No",
        level = entry.level,
        player = entry.name,
    })
    return reply, "accepted:" .. entry.role .. ":" .. tostring(entry.aura) .. ":" .. tostring(entry.level)
end

local function SendCandidateReply(entry)
    local reply, signature = CandidateReply(entry)
    if not reply or reply == "" or entry.lastReplySignature == signature then return end
    SendChatMessage(reply, "WHISPER", nil, entry.name)
    entry.lastReplySignature = signature
end

local function RecordGroupChat(event, message, sender)
    local channel = (event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER") and "RAID" or
                    event == "CHAT_MSG_RAID_WARNING" and "WARNING" or "PARTY"
    table.insert(state.groupChat, {
        channel = channel,
        message = tostring(message or ""),
        sender = ShortName(sender) or "?",
        time = GetTime(),
    })
    while #state.groupChat > 50 do table.remove(state.groupChat, 1) end
end

local function IsExactAuraReply(message)
    return string.lower(Trim(message)) == "aura"
end

local function RecruitmentReplyWindowOpen()
    if FrostSeekAuraDB and FrostSeekAuraDB.recruiting then return true end
    return GetTime() <= (state.recruitReplyUntil or 0)
end

local function IsInManastorm()
    local parts = {}
    if GetInstanceInfo then
        local name = GetInstanceInfo()
        if name then table.insert(parts, name) end
    end
    if GetRealZoneText then
        local z = GetRealZoneText()
        if z then table.insert(parts, z) end
    end
    if GetSubZoneText then
        local z = GetSubZoneText()
        if z then table.insert(parts, z) end
    end
    for _, text in ipairs(parts) do
        if string.find(string.lower(tostring(text)), "manastorm", 1, true) then
            return true
        end
    end
    return false
end

local function PlayerCanBroadcastRaidAlert()
    if not FrostSeekAuraDB.leaderOnlyAlerts then return true end
    if RaidCount() <= 0 then
        if GetPartyLeaderIndex then
            local idx = GetPartyLeaderIndex()
            return idx == 0
        end
        return true
    end
    local me = Key(UnitName("player"))
    for i = 1, RaidCount() do
        local name, rank = GetRaidRosterInfo(i)
        if name and Key(name) == me then
            return (rank or 0) >= 1
        end
    end
    return false
end

local function PlayAuraAlertSound()
    if not FrostSeekAuraDB.soundAlerts then return end
    if PlaySound then
        pcall(PlaySound, "RaidWarning")
    end
end

local function IsDuplicateAnnouncement(msg)
    local now = GetTime()
    if state.lastAnnouncedText == msg and
       (now - (state.lastAnnouncedAt or 0)) < 5 then
        return true
    end
    state.lastAnnouncedText = msg
    state.lastAnnouncedAt = now
    return false
end

local function PruneCandidates()
    local now = GetTime()
    local ttl = tonumber(FrostSeekAuraDB.candidateLifetime) or 600
    if ttl < 60 then ttl = 60 end
    for _, tbl in ipairs({state.candidates, state.nonAuraCandidates}) do
        for k, c in pairs(tbl or {}) do
            if (now - (c.time or 0)) > ttl then
                tbl[k] = nil
            end
        end
    end
end


local function RaidCount()
    return (GetNumRaidMembers and GetNumRaidMembers()) or 0
end

local function PartyCount()
    return (GetNumPartyMembers and GetNumPartyMembers()) or 0
end

local function GroupSize()
    local r = RaidCount()
    if r > 0 then return r end
    local p = PartyCount()
    if p > 0 then return p + 1 end
    return 1
end

local function GroupChat(msg)
    if IsDuplicateAnnouncement(msg) then return end

    if FrostSeekAuraDB.announceToGroup and PlayerCanBroadcastRaidAlert() then
        if RaidCount() > 0 then
            SendChatMessage("[FrostSeek Aura] " .. msg, "RAID")
            return
        elseif PartyCount() > 0 then
            SendChatMessage("[FrostSeek Aura] " .. msg, "PARTY")
            return
        end
    end
    Print(msg)
end

local function ThemeColor(key, fallback)
    local T = _G.FrostSeekTheme
    if T and T.Get then
        local ok, c = pcall(T.Get, key)
        if ok and type(c) == "table" then return c end
    end
    return fallback
end

local function ColorTexture(tex, key, fallback)
    local c = ThemeColor(key, fallback)
    tex:SetTexture(c[1], c[2], c[3], c[4] or 1)
end

local function NewBlock(parent)
    local f = CreateFrame("Frame", nil, parent)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    ColorTexture(bg, "bgBlock", {0.08, 0.09, 0.11, 0.95})
    f.bg = bg
    return f
end

local function NewButton(parent, w, h, label)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)

    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    ColorTexture(b.bg, "bgRowHover", {0.14, 0.16, 0.20, 1})

    b.border = b:CreateTexture(nil, "BORDER")
    b.border:SetPoint("TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", 1, -1)
    ColorTexture(b.border, "border", {0.25, 0.30, 0.36, 1})

    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER")
    b.text:SetText(label)

    b:SetScript("OnEnter", function(self)
        ColorTexture(self.bg, "bgTabActive", {0.18, 0.25, 0.32, 1})
    end)
    b:SetScript("OnLeave", function(self)
        ColorTexture(self.bg, "bgRowHover", {0.14, 0.16, 0.20, 1})
    end)

    function b:SetLabel(s) self.text:SetText(s) end
    return b
end

local function NewCheckbox(parent, label, checked, callback)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetChecked(checked and true or false)

    local txt = cb:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    txt:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    txt:SetText(label)
    txt:SetTextColor(0.85, 0.88, 0.93)
    cb.label = txt

    cb:SetScript("OnClick", function(self)
        callback(self:GetChecked() and true or false)
    end)
    return cb
end

local function NewEdit(parent, w, h, text, numeric)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(w, h)
    e:SetAutoFocus(false)
    e:SetText(tostring(text or ""))
    if numeric then e:SetNumeric(true) end
    return e
end

-- ============================================================================
-- Aura / roster
-- ============================================================================

local AURA_NAMES = {
    ["aura of experience"] = true,
    ["experience aura"] = true,
}

-- Live Ascension testing:
-- 818059 = the active Aura of Experience buff shown by UnitBuff on the provider.
-- 818066 = related/trigger Aura of Experience spell from the Ascension DB.
-- Keep both as matches, but 818059 is the important active aura.
local AURA_SPELL_IDS = {
    [818059] = true,
    [818066] = true,
}

local function IsExperienceAura(name, spellId)
    if spellId and AURA_SPELL_IDS[tonumber(spellId)] then
        return true
    end

    local lowerName = string.lower(tostring(name or ""))
    if AURA_NAMES[lowerName] then
        return true
    end

    -- Conservative fallback for alternate Ascension ranks/variants.
    -- Require both words so ordinary XP buffs/potions are not picked up.
    if string.find(lowerName, "aura", 1, true) and
       string.find(lowerName, "experience", 1, true) then
        return true
    end

    return false
end

local function UnitAuraInfo(unit)
    if not unit or not UnitExists(unit) then return false end
    for i = 1, 40 do
        local name, rank, icon, count, debuffType, duration, expirationTime,
              unitCaster, isStealable, shouldConsolidate, spellId = UnitBuff(unit, i)
        if not name then break end
        if IsExperienceAura(name, spellId) then
            return true, name, unitCaster, spellId
        end
    end
    return false
end

local function ResolveUnitName(unit)
    if not unit or unit == "" then return nil end
    if not UnitExists(unit) then return nil end
    return ShortName(UnitName(unit))
end


local function UnitIsLocallyVisible(unit)
    if not unit or not UnitExists(unit) then return false end

    if UnitIsVisible then
        local ok, visible = pcall(UnitIsVisible, unit)
        if ok then
            return visible and true or false
        end
    end

    -- If this client does not expose UnitIsVisible, don't trust a negative
    -- C_Aura result as authoritative.
    return false
end

local function DetectExperienceCapability(unit, display)
    local k = Key(display)

    -- Provider cache contains ONLY confirmed providers:
    -- manual assignments or names resolved from an actual 818059 aura caster.
    local cachedProvider =
        FrostSeekAuraDB.knownAuraPlayers and FrostSeekAuraDB.knownAuraPlayers[k]
    local knownProvider = cachedProvider and true or false

    local visible = UnitIsLocallyVisible(unit)

    -- C_Aura answers whether THIS UNIT IS AFFECTED by Aura of Experience.
    -- It does NOT identify the provider. Never promote this result into the
    -- provider cache.
    local receivesAura = nil
    if type(_G.C_Aura) == "table" and type(_G.C_Aura.UnitHasAura) == "function" then
        local ok, result = pcall(_G.C_Aura.UnitHasAura, unit, 818059)
        if ok then
            if result then
                receivesAura = true
            elseif visible then
                receivesAura = false
            end
        end
    end

    return knownProvider, receivesAura, visible
end


local function GetPartyRecipientSensor(roster)
    local sensor = { [1] = nil, [2] = nil, [3] = nil }
    local sampled = { [1] = false, [2] = false, [3] = false }

    for _, info in pairs(roster or {}) do
        local g = info.subgroup
        if g and g >= 1 and g <= 3 and info.locallyVisible then
            sampled[g] = true
            if info.recipientHasAura or info.liveRecipientState == true then
                sensor[g] = true
            elseif sensor[g] ~= true then
                sensor[g] = false
            end
        end
    end

    for g = 1, 3 do
        if not sampled[g] then sensor[g] = nil end
    end
    return sensor
end

local function NoteRosterProviderCandidates(oldRoster, newRoster)
    local arrivals = { [1] = {}, [2] = {}, [3] = {} }
    local now = GetTime()

    for k, new in pairs(newRoster or {}) do
        local old = oldRoster and oldRoster[k] or nil
        if (not old or old.subgroup ~= new.subgroup) and
           new.subgroup and new.subgroup >= 1 and new.subgroup <= 3 then
            table.insert(arrivals[new.subgroup], {
                name = new.name,
                key = k,
                since = now,
            })
        end
    end

    for g = 1, 3 do
        if #arrivals[g] == 1 then
            state.pendingProviderCandidates[g] = arrivals[g][1]
        elseif #arrivals[g] > 1 then
            state.pendingProviderCandidates[g] = nil
        end
    end
end

local function ApplyCoverageTransitionInference(oldSensor, newSensor, roster)
    if not FrostSeekAuraDB.inferProviderOnCoverageTransition then return end
    local now = GetTime()

    for g = 1, 3 do
        local candidate = state.pendingProviderCandidates[g]
        if candidate then
            if (now - (candidate.since or 0)) > 8 then
                state.pendingProviderCandidates[g] = nil
            elseif oldSensor and oldSensor[g] == false and newSensor[g] == true then
                local info = roster and roster[candidate.key] or nil
                if info and info.subgroup == g then
                    FrostSeekAuraDB.knownAuraPlayers[candidate.key] = candidate.name
                    FrostSeekAuraDB.marked[candidate.key] = candidate.name
                    info.detected = true
                    info.marked = true
                    local fromAuraCandidate = state.candidates and state.candidates[candidate.key] ~= nil
                    info.detectionSource = fromAuraCandidate and "aura-candidate-transition" or "coverage-transition"
                    if fromAuraCandidate then
                        state.candidates[candidate.key].status = "Aura confirmed"
                    end
                    Print("Confirmed Aura provider by Party " .. g ..
                          " coverage transition: " .. candidate.name ..
                          (fromAuraCandidate and " (exact aura candidate)." or "."))
                    state.pendingProviderCandidates[g] = nil
                end
            end
        end
    end
end

local function PartySensorText(v)
    if v == true then return "ACTIVE" end
    if v == false then return "NO AURA" end
    return "UNKNOWN"
end

local function BuildRoster()
    local out = {}
    local n = RaidCount()

    local function addUnit(unit, display, subgroup, online, level, raidIndex, classFile)
        local k = Key(display)

        local hasVisibleAura, auraName, casterUnit, spellId = UnitAuraInfo(unit)
        local knownProvider, receivesAura, visible =
            DetectExperienceCapability(unit, display)

        local providerName = ResolveUnitName(casterUnit)
        local providerKey = providerName and Key(providerName) or nil

        -- This is the authoritative automatic provider-learning path:
        -- an actual Aura of Experience record whose caster can be resolved.
        if hasVisibleAura and spellId == 818059 and providerName then
            FrostSeekAuraDB.knownAuraPlayers[providerKey] = providerName

            -- If that provider is already represented in the roster, it will
            -- become detected when its own record is processed or below.
            if providerKey == k then
                knownProvider = true
            end
        end

        -- Re-check cache in case another recipient row identified this player
        -- as the caster earlier in this same roster scan.
        if FrostSeekAuraDB.knownAuraPlayers[k] and not FrostSeekAuraDB.ignoredProviders[k] then
            knownProvider = true
        end

        out[k] = {
            name = display,
            subgroup = subgroup or 0,
            level = tonumber(level) or tonumber(UnitLevel and UnitLevel(unit)) or 0,
            online = online ~= false,
            unit = unit,
            raidIndex = raidIndex or 99,
            classFile = classFile,

            recipientHasAura = (receivesAura == true) or (hasVisibleAura and true or false),
            liveRecipientState = receivesAura, -- true / false / nil unknown
            locallyVisible = visible and true or false,

            auraCasterUnit = casterUnit,
            auraProvider = providerName,
            auraSpellId = spellId,

            -- detected now means confirmed PROVIDER, never merely recipient.
            detected = knownProvider and not FrostSeekAuraDB.ignoredProviders[k] and true or false,
            detectionSource = knownProvider and "provider-cache" or nil,

            marked = FrostSeekAuraDB.marked[k] and true or false,
            manual = FrostSeekAuraDB.manualProviders and FrostSeekAuraDB.manualProviders[k] and true or false,
        }
    end

    if n > 0 then
        for i = 1, n do
            local name, rank, subgroup, level, class, fileName, zone, online =
                GetRaidRosterInfo(i)
            if name then
                addUnit("raid" .. i, ShortName(name), subgroup or 0, online, level, i, fileName)
            end
        end
    else
        local player = UnitName("player")
        if player then
            local _, classFile = UnitClass and UnitClass("player")
            addUnit("player", ShortName(player), 1, true, UnitLevel and UnitLevel("player") or 0, 1, classFile)
        end

        for i = 1, PartyCount() do
            local unit = "party" .. i
            local name = UnitName(unit)
            if name then
                local _, classFile = UnitClass and UnitClass(unit)
                addUnit(unit, ShortName(name), 1, UnitIsConnected(unit) ~= false, UnitLevel and UnitLevel(unit) or 0, i + 1, classFile)
            end
        end
    end

    -- Second pass: recipient rows can identify a provider that appeared later
    -- in the roster iteration, so refresh detected flags from the cache.
    for k, info in pairs(out) do
        if FrostSeekAuraDB.knownAuraPlayers[k] and not FrostSeekAuraDB.ignoredProviders[k] then
            info.detected = true
            info.detectionSource = "provider-cache"
        end
    end

    return out
end

local function AssignedCoverageFromRoster(roster)
    local c = { [1] = {}, [2] = {}, [3] = {} }
    for _, info in pairs(roster) do
        if info.marked and info.subgroup >= 1 and info.subgroup <= 3 then
            table.insert(c[info.subgroup], info)
        end
    end
    for g = 1, 3 do
        table.sort(c[g], function(a,b) return a.name < b.name end)
    end
    return c
end

local function VerifiedCoverageFromRoster(roster)
    local c = { [1] = {}, [2] = {}, [3] = {} }
    for _, info in pairs(roster) do
        if info.detected and info.subgroup >= 1 and info.subgroup <= 3 then
            table.insert(c[info.subgroup], info)
        end
    end
    for g = 1, 3 do
        table.sort(c[g], function(a,b) return a.name < b.name end)
    end
    return c
end

local function AutoMarkDetected(roster)
    if not FrostSeekAuraDB.autoMarkDetected then return end

    for k, info in pairs(roster) do
        if info.detected then
            FrostSeekAuraDB.marked[k] = info.name
            info.marked = true
        end
    end
end

local function BuildCoverage(roster)
    -- Automatic positives are promoted to assignments. Manual marks still work
    -- as an override/fallback for players we have not yet observed locally.
    return AssignedCoverageFromRoster(roster)
end

local function CoveredParties(c)
    local n = 0
    for g = 1, 3 do if #c[g] > 0 then n = n + 1 end end
    return n
end

local function MissingGroups(c)
    local t = {}
    for g = 1, 3 do
        if #c[g] == 0 then table.insert(t, g) end
    end
    return t
end

local function MissingText(c)
    local m = MissingGroups(c)
    if #m == 0 then return "none" end
    local t = {}
    for _, g in ipairs(m) do table.insert(t, "P" .. g) end
    return table.concat(t, ", ")
end

local function DistSig(c)
    local t = {}
    for g = 1, 3 do
        if #c[g] ~= 1 then
            table.insert(t, tostring(g) .. ":" .. tostring(#c[g]))
        end
    end
    return table.concat(t, "|")
end

local function ProviderDisplayName(info)
    if not info then return "unknown" end
    local name = info.name or "unknown"
    if tonumber(info.level) == 59 then
        return name .. " |cffff5555[59 - REPLACE SOON]|r"
    end
    return name
end

local function PartyHealth(group, coverage, sensor, verified)
    local assigned = coverage[group] or {}
    local live = sensor[group]
    local confirmed = verified[group] or {}

    if #assigned > 1 then
        return "DUPLICATE", #assigned .. " providers assigned"
    end

    if live == true then
        if #confirmed > 0 then
            return "CONFIRMED", ProviderDisplayName(confirmed[1])
        elseif #assigned == 1 then
            local a = assigned[1]
            if a.manual and not a.detected then
                return "MANUAL_ACTIVE", ProviderDisplayName(a)
            end
            return "ACTIVE_ASSIGNED", ProviderDisplayName(a)
        else
            return "ACTIVE_UNKNOWN", "Aura active, provider unknown"
        end
    end

    if live == false then
        if #assigned == 1 then
            return "INACTIVE_ASSIGNED", ProviderDisplayName(assigned[1])
        end
        return "NO_AURA", "No aura"
    end

    -- nil sensor: no trustworthy local sample.
    if #assigned == 1 then
        local a = assigned[1]
        if a.manual and not a.detected then
            return "MANUAL_UNKNOWN", ProviderDisplayName(a)
        end
        return "OUT_OF_RANGE", ProviderDisplayName(a)
    end
    return "UNKNOWN", "Unknown / out of range"
end


local function PartyHealthSignature(coverage, sensor, verified)
    local t = {}
    for g = 1, 3 do
        local code = PartyHealth(g, coverage, sensor, verified)
        table.insert(t, "P" .. g .. ":" .. tostring(code) .. ":" .. tostring(#(coverage[g] or {})))
    end
    return table.concat(t, "|")
end

local function RecruitmentMissingGroups(coverage, sensor)
    local missing = {}
    local inMS = IsInManastorm()
    for g = 1, 3 do
        local assigned = coverage[g] or {}
        local live = sensor[g]

        local needs = false
        if live == true then
            needs = false
        elseif live == false then
            needs = true
        else
            -- Outside/local-unknown: fall back to assignment knowledge.
            -- Inside Manastorm unknown remains unresolved and should not stop recruiting.
            if inMS then
                needs = (#assigned == 0)
            else
                needs = (#assigned == 0)
            end
        end

        if #assigned > 1 then
            -- Duplicates are a distribution problem, but not an additional
            -- recruitment requirement if an Aura is already present.
            needs = false
        end
        if needs then table.insert(missing, g) end
    end
    return missing
end

local function RaidAuraReady(coverage, sensor)
    return #RecruitmentMissingGroups(coverage, sensor) == 0 and DistSig(coverage) == ""
end

local function MoveSuggestion(c)
    local missing = {}
    local donors = {}
    for g = 1, 3 do
        if #c[g] == 0 then
            table.insert(missing, g)
        elseif #c[g] > 1 then
            table.insert(donors, g)
        end
    end
    if #missing == 0 or #donors == 0 then return nil end

    local from = donors[1]
    local to = missing[1]
    local mover = c[from][#c[from]]
    if not mover then return nil end
    return "Suggestion: move " .. mover.name .. " from P" .. from .. " -> P" .. to .. "."
end

local function ReasonAwareWarning(c, sensor, verified)
    local reasons = {}

    for g = 1, 3 do
        local code, detail = PartyHealth(g, c, sensor, verified)
        if code == "DUPLICATE" then
            table.insert(reasons, "P" .. g .. " duplicate providers (" .. tostring(#c[g]) .. ")")
        elseif code == "NO_AURA" then
            table.insert(reasons, "P" .. g .. " missing provider")
        elseif code == "INACTIVE_ASSIGNED" then
            table.insert(reasons, "P" .. g .. " Aura inactive despite assigned " .. detail)
        elseif code == "OUT_OF_RANGE" or code == "MANUAL_UNKNOWN" or code == "UNKNOWN" then
            table.insert(reasons, "P" .. g .. " provider unverified / out of range")
        end
    end

    if #reasons == 0 then
        return "Aura distribution healthy."
    end

    local msg = table.concat(reasons, "; ") .. "."
    local suggestion = MoveSuggestion(c)
    if suggestion then msg = msg .. " " .. suggestion end
    if not IsInManastorm() then
        msg = msg .. " Automatic verification is local-range data."
    end
    return msg
end

local function CompactHealthWarning(c, sensor, verified)
    local missing, inactive, duplicate, unknown = {}, {}, {}, {}
    for g = 1, 3 do
        local code = PartyHealth(g, c, sensor, verified)
        local label = "P" .. g
        if code == "NO_AURA" then
            table.insert(missing, label)
        elseif code == "INACTIVE_ASSIGNED" then
            table.insert(inactive, label)
        elseif code == "DUPLICATE" then
            table.insert(duplicate, label)
        elseif code == "OUT_OF_RANGE" or code == "MANUAL_UNKNOWN" or code == "UNKNOWN" then
            table.insert(unknown, label)
        end
    end

    local bits = {}
    if #missing > 0 then table.insert(bits, table.concat(missing, "/") .. " missing Aura") end
    if #inactive > 0 then table.insert(bits, table.concat(inactive, "/") .. " Aura inactive") end
    if #duplicate > 0 then table.insert(bits, table.concat(duplicate, "/") .. " duplicate") end
    if #unknown > 0 then table.insert(bits, table.concat(unknown, "/") .. " provider unverified") end
    return #bits > 0 and (table.concat(bits, "; ") .. ".") or "Aura state healthy."
end

local function AllGroupsReportingAuraMessage(c, sensor, verified)
    for g = 1, 3 do
        if sensor[g] ~= true then return nil end
    end

    local unknown = {}
    for g = 1, 3 do
        local code = PartyHealth(g, c, sensor, verified)
        if code == "ACTIVE_UNKNOWN" then
            table.insert(unknown, "P" .. g)
        end
    end

    local message = "All 3 groups are reporting an Aura."
    if #unknown == 1 then
        message = message .. " Aura provider unknown in " .. unknown[1] .. "."
    elseif #unknown > 1 then
        message = message .. " Aura providers unknown in " .. table.concat(unknown, ", ") .. "."
    end
    return message
end

local function DistMessage(c)
    return "Aura warning: " .. ReasonAwareWarning(
        c,
        state.partyAuraSensor or { [1]=nil,[2]=nil,[3]=nil },
        state.verifiedCoverage or { [1]={},[2]={},[3]={} }
    )
end
local function FindRosterPlayer(name)
    return state.roster[Key(name)]
end

local function Mark(name)
    if not name or name == "" then return end
    local info = FindRosterPlayer(name)
    local display = info and info.name or ShortName(name)
    local k = Key(display)
    FrostSeekAuraDB.marked[k] = display
    FrostSeekAuraDB.manualProviders = FrostSeekAuraDB.manualProviders or {}
    FrostSeekAuraDB.manualProviders[k] = display
    FrostSeekAuraDB.ignoredProviders = FrostSeekAuraDB.ignoredProviders or {}
    FrostSeekAuraDB.ignoredProviders[k] = nil
    if info then
        info.marked = true
        info.manual = true
    end
    Print(display .. " manually assigned as an Aura provider.")
    state.pendingScan = 0.05
end

local function ToggleAuraProvider(name)
    local info = FindRosterPlayer(name)
    if not info then return end
    local k = Key(info.name)
    FrostSeekAuraDB.ignoredProviders = FrostSeekAuraDB.ignoredProviders or {}

    if info.marked or info.detected then
        FrostSeekAuraDB.marked[k] = nil
        if FrostSeekAuraDB.manualProviders then FrostSeekAuraDB.manualProviders[k] = nil end
        FrostSeekAuraDB.ignoredProviders[k] = true
        info.marked = false
        info.manual = false
        info.detected = false
        Print(info.name .. " disabled as an Aura provider.")
    else
        FrostSeekAuraDB.ignoredProviders[k] = nil
        Mark(info.name)
        return
    end

    state.pendingScan = 0.05
end


local function ClearKnownAuraCache(name)
    FrostSeekAuraDB.knownAuraPlayers = FrostSeekAuraDB.knownAuraPlayers or {}

    if name and name ~= "" then
        local k = Key(name)
        local old = FrostSeekAuraDB.knownAuraPlayers[k]
        FrostSeekAuraDB.knownAuraPlayers[k] = nil

        if old then
            Print("Forgot learned Aura status for " .. tostring(old) .. ".")
        else
            Print("No learned Aura status stored for " .. tostring(ShortName(name)) .. ".")
        end
    else
        FrostSeekAuraDB.knownAuraPlayers = {}
        Print("Cleared learned Aura-player cache.")
    end

    state.pendingScan = 0.05
end

local function Unmark(name)
    if not name or name == "" then return end
    local k = Key(name)
    local old = FrostSeekAuraDB.marked[k]
    FrostSeekAuraDB.marked[k] = nil
    if FrostSeekAuraDB.manualProviders then FrostSeekAuraDB.manualProviders[k] = nil end
    if state.roster[k] then
        state.roster[k].marked = false
        state.roster[k].manual = false
    end
    if old then Print(old .. " removed from Aura tracking.") end
    state.pendingScan = 0.05
end

-- ============================================================================
-- Aura diagnostics
-- ============================================================================

local function FindUnitByName(wantedName)
    local wanted = Key(wantedName)
    if wanted == "" then return nil end

    if Key(UnitName("player")) == wanted then
        return "player"
    end

    if RaidCount() > 0 then
        for i = 1, RaidCount() do
            local unit = "raid" .. i
            if UnitExists(unit) and Key(UnitName(unit)) == wanted then
                return unit
            end
        end
    else
        for i = 1, PartyCount() do
            local unit = "party" .. i
            if UnitExists(unit) and Key(UnitName(unit)) == wanted then
                return unit
            end
        end
    end

    return nil
end

local function DumpUnitBuffs(playerName)
    if not playerName or playerName == "" then
        Print("Usage: /fsaura buffs <player>")
        return
    end

    local unit = FindUnitByName(playerName)
    if not unit then
        Print("Could not resolve group unit for " .. tostring(playerName) .. ".")
        return
    end

    Print("Visible buffs for " .. tostring(ShortName(UnitName(unit))) .. " (" .. unit .. "):")

    local found = false
    for i = 1, 40 do
        local name, rank, icon, count, debuffType, duration, expirationTime,
              unitCaster, isStealable, shouldConsolidate, spellId = UnitBuff(unit, i)

        if not name then break end
        found = true

        local provider = ResolveUnitName(unitCaster) or "UNKNOWN"
        local markerText = IsExperienceAura(name, spellId) and "  << EXPERIENCE AURA MATCH" or ""

        Print(" #" .. i ..
              " name=" .. tostring(name) ..
              " spellId=" .. tostring(spellId or "nil") ..
              " casterUnit=" .. tostring(unitCaster or "nil") ..
              " provider=" .. tostring(provider) ..
              markerText)
    end

    if not found then
        Print(" - UnitBuff returned no visible buffs for this unit.")
    end
end


local function ProbeAuraUnit(playerName)
    if not playerName or playerName == "" then
        Print("Usage: /fsaura probe <player>")
        return
    end

    local unit = FindUnitByName(playerName)
    if not unit then
        Print("Could not resolve group unit for " .. tostring(playerName) .. ".")
        return
    end

    local display = ShortName(UnitName(unit)) or tostring(playerName)
    Print("Aura probe for " .. display .. " (" .. unit .. "):")

    local exists = UnitExists(unit) and "yes" or "no"
    local connected = UnitIsConnected(unit) and "yes" or "no"
    local visible = UnitIsVisible and (UnitIsVisible(unit) and "yes" or "no") or "n/a"
    local phase = UnitInPhase and (UnitInPhase(unit) and "yes" or "no") or "n/a"

    Print(" exists=" .. exists ..
          " connected=" .. connected ..
          " visible=" .. visible ..
          " inPhase=" .. phase)

    if GetSpellInfo then
        local n1 = GetSpellInfo(818059)
        local n2 = GetSpellInfo(818066)
        Print(" GetSpellInfo(818059)=" .. tostring(n1 or "nil"))
        Print(" GetSpellInfo(818066)=" .. tostring(n2 or "nil"))
    end

    local matched = 0
    for i = 1, 40 do
        local name, rank, icon, count, debuffType, duration, expirationTime,
              unitCaster, isStealable, shouldConsolidate, spellId = UnitBuff(unit, i)
        if not name then break end

        if IsExperienceAura(name, spellId) then
            matched = matched + 1
            Print(" MATCH #" .. i ..
                  " name=" .. tostring(name) ..
                  " spellId=" .. tostring(spellId or "nil") ..
                  " count=" .. tostring(count or "nil") ..
                  " duration=" .. tostring(duration or "nil") ..
                  " expires=" .. tostring(expirationTime or "nil") ..
                  " casterUnit=" .. tostring(unitCaster or "nil") ..
                  " provider=" .. tostring(ResolveUnitName(unitCaster) or "UNKNOWN"))
        end
    end

    if matched == 0 then
        Print(" No Aura of Experience match in UnitBuff().")
    end

    if UnitAura then
        local auraMatches = 0
        for i = 1, 40 do
            local name, rank, icon, count, debuffType, duration, expirationTime,
                  unitCaster, isStealable, shouldConsolidate, spellId = UnitAura(unit, i)
            if not name then break end
            if IsExperienceAura(name, spellId) then
                auraMatches = auraMatches + 1
                Print(" UnitAura MATCH #" .. i ..
                      " name=" .. tostring(name) ..
                      " spellId=" .. tostring(spellId or "nil") ..
                      " casterUnit=" .. tostring(unitCaster or "nil") ..
                      " provider=" .. tostring(ResolveUnitName(unitCaster) or "UNKNOWN"))
            end
        end
        if auraMatches == 0 then
            Print(" No Aura of Experience match in UnitAura().")
        end
    else
        Print(" UnitAura function not exposed by this client.")
    end
end

-- ============================================================================
-- Automated Ascension aura research
-- ============================================================================

local RESEARCH_HOOKS = {
    "UnitPackedAura",
    "PlayerAuraHidden",
    "ClientsideAura",
    "ClientsideAuraTarget",
    "ClientsideAuraCreature",
    "RefreshAuras",
}

local function EnsureResearchState()
    if type(state.research) ~= "table" then
        state.research = {}
    end

    if state.research.active == nil then state.research.active = false end
    if state.research.targetName == nil then state.research.targetName = nil end
    if state.research.targetUnit == nil then state.research.targetUnit = nil end
    if state.research.started == nil then state.research.started = 0 end
    if state.research.duration == nil then state.research.duration = 20 end
    if state.research.unitAuraEvents == nil then state.research.unitAuraEvents = 0 end
    if type(state.research.hookedCalls) ~= "table" then state.research.hookedCalls = {} end
    if state.research.hooksInstalled == nil then state.research.hooksInstalled = false end
end

local function ResearchPrint(msg)
    Print("|cffb388ff[Research]|r " .. tostring(msg))
end

local function SafeFunctionInfo(name)
    local fn = _G[name]
    if type(fn) ~= "function" then
        return "missing"
    end

    if debug and debug.getinfo then
        local ok, info = pcall(debug.getinfo, fn, "Snu")
        if ok and info then
            return "function source=" .. tostring(info.short_src or info.source or "?") ..
                   " linedefined=" .. tostring(info.linedefined or "?") ..
                   " nups=" .. tostring(info.nups or "?")
        end
    end

    return "function (debug metadata unavailable)"
end

local function InstallResearchHooks()
    EnsureResearchState()
    if state.research.hooksInstalled then return end

    if not hooksecurefunc then
        ResearchPrint("hooksecurefunc is unavailable; passive custom-function tracing disabled.")
        return
    end

    for _, name in ipairs(RESEARCH_HOOKS) do
        if type(_G[name]) == "function" then
            local hookName = name
            local ok, err = pcall(function()
                hooksecurefunc(hookName, function(...)
                    if not state.research.active then return end

                    state.research.hookedCalls[hookName] =
                        (state.research.hookedCalls[hookName] or 0) + 1

                    -- Only print the first few calls per function to avoid spam.
                    if state.research.hookedCalls[hookName] <= 5 then
                        local args = {}
                        local n = select("#", ...)
                        for i = 1, math.min(n, 6) do
                            local v = select(i, ...)
                            table.insert(args, tostring(v))
                        end
                        ResearchPrint(hookName .. " called(" .. table.concat(args, ", ") .. ")")
                    end
                end)
            end)

            if ok then
                ResearchPrint("Passive hook installed: " .. hookName)
            else
                ResearchPrint("Could not hook " .. hookName .. ": " .. tostring(err))
            end
        end
    end

    state.research.hooksInstalled = true
end

local function PrintAuraMatchesForUnit(unit, display)
    local normalCount = 0
    local matchCount = 0

    for i = 1, 40 do
        local name, rank, icon, count, debuffType, duration, expirationTime,
              unitCaster, isStealable, shouldConsolidate, spellId = UnitBuff(unit, i)

        if not name then break end
        normalCount = normalCount + 1

        if IsExperienceAura(name, spellId) then
            matchCount = matchCount + 1
            ResearchPrint(display ..
                " UnitBuff MATCH #" .. i ..
                " name=" .. tostring(name) ..
                " spellId=" .. tostring(spellId or "nil") ..
                " stacks=" .. tostring(count or "nil") ..
                " caster=" .. tostring(unitCaster or "nil") ..
                " provider=" .. tostring(ResolveUnitName(unitCaster) or "UNKNOWN"))
        end
    end

    ResearchPrint(display .. ": UnitBuff visible=" .. normalCount ..
                  ", experience matches=" .. matchCount)

    if UnitAura then
        local auraCount = 0
        local auraMatches = 0

        for i = 1, 40 do
            local name, rank, icon, count, debuffType, duration, expirationTime,
                  unitCaster, isStealable, shouldConsolidate, spellId = UnitAura(unit, i)

            if not name then break end
            auraCount = auraCount + 1

            if IsExperienceAura(name, spellId) then
                auraMatches = auraMatches + 1
                ResearchPrint(display ..
                    " UnitAura MATCH #" .. i ..
                    " name=" .. tostring(name) ..
                    " spellId=" .. tostring(spellId or "nil") ..
                    " caster=" .. tostring(unitCaster or "nil") ..
                    " provider=" .. tostring(ResolveUnitName(unitCaster) or "UNKNOWN"))
            end
        end

        ResearchPrint(display .. ": UnitAura visible=" .. auraCount ..
                      ", experience matches=" .. auraMatches)
    else
        ResearchPrint("UnitAura API unavailable.")
    end
end


local function FormatReturns(ok, ...)
    if not ok then
        return "ERROR: " .. tostring((...))
    end

    local n = select("#", ...)
    if n == 0 then return "<no returns>" end

    local out = {}
    for i = 1, math.min(n, 8) do
        local v = select(i, ...)
        local tv = type(v)

        if tv == "string" or tv == "number" or tv == "boolean" or tv == "nil" then
            table.insert(out, tv .. "=" .. tostring(v))
        elseif tv == "table" then
            local count = 0
            local sample = {}
            for k, value in pairs(v) do
                count = count + 1
                if #sample < 4 then
                    table.insert(sample, tostring(k) .. "=" .. tostring(value))
                end
            end
            table.insert(out, "table(" .. count .. "){" .. table.concat(sample, ",") .. "}")
        else
            table.insert(out, tv .. "=" .. tostring(v))
        end
    end

    return table.concat(out, " | ")
end

local function CallAndReport(label, fn, ...)
    if type(fn) ~= "function" then
        ResearchPrint(label .. " -> unavailable")
        return
    end

    local results = { pcall(fn, ...) }
    local ok = table.remove(results, 1)
    ResearchPrint(label .. " -> " .. FormatReturns(ok, unpack(results)))
end

local function ProbeGetterCandidates(unit, display)
    ResearchPrint("----- getter signature probes: " .. display .. " / " .. unit .. " -----")

    -- PlayerAuraHidden sounds getter-like, so try common query signatures.
    -- Every call is protected by pcall.
    if type(_G.PlayerAuraHidden) == "function" then
        CallAndReport("PlayerAuraHidden(818059)", _G.PlayerAuraHidden, 818059)
        CallAndReport("PlayerAuraHidden(818066)", _G.PlayerAuraHidden, 818066)
        CallAndReport("PlayerAuraHidden(unit,818059)", _G.PlayerAuraHidden, unit, 818059)
        CallAndReport("PlayerAuraHidden(unit,818066)", _G.PlayerAuraHidden, unit, 818066)
        CallAndReport("PlayerAuraHidden(name,818059)", _G.PlayerAuraHidden, display, 818059)
    end

    -- UnitPackedAura also sounds accessor-like. Test likely unit/index and
    -- unit/spell-id signatures, bounded to avoid excessive calls.
    if type(_G.UnitPackedAura) == "function" then
        CallAndReport("UnitPackedAura(unit,1)", _G.UnitPackedAura, unit, 1)
        CallAndReport("UnitPackedAura(unit,818059)", _G.UnitPackedAura, unit, 818059)
        CallAndReport("UnitPackedAura(unit,818066)", _G.UnitPackedAura, unit, 818066)

        -- Probe a few packed indices in case it mirrors UnitAura indexing.
        for i = 1, 12 do
            local results = { pcall(_G.UnitPackedAura, unit, i) }
            local ok = table.remove(results, 1)

            if ok then
                local interesting = false
                for _, v in ipairs(results) do
                    if tonumber(v) == 818059 or tonumber(v) == 818066 then
                        interesting = true
                    elseif type(v) == "string" then
                        local lv = string.lower(v)
                        if string.find(lv, "experience", 1, true) or
                           string.find(lv, "aura", 1, true) then
                            interesting = true
                        end
                    end
                end

                if interesting then
                    ResearchPrint("UnitPackedAura(" .. unit .. "," .. i .. ") INTERESTING -> " ..
                                  FormatReturns(true, unpack(results)))
                end
            end
        end
    end
end

local function CompareSelfAndTargetGetterProbes(targetUnit, targetDisplay)
    ProbeGetterCandidates("player", ShortName(UnitName("player")) or "player")
    if targetUnit and targetUnit ~= "player" then
        ProbeGetterCandidates(targetUnit, targetDisplay)
    end
end


local function NameLooksAuraRelevant(name)
    local n = string.lower(tostring(name or ""))
    return
        string.find(n, "aura", 1, true) or
        string.find(n, "buff", 1, true) or
        string.find(n, "hidden", 1, true) or
        string.find(n, "packed", 1, true) or
        string.find(n, "experience", 1, true)
end

local function NameLooksPromisingRemoteGetter(name)
    local n = string.lower(tostring(name or ""))

    local auraish =
        string.find(n, "aura", 1, true) or
        string.find(n, "buff", 1, true) or
        string.find(n, "hidden", 1, true)

    local unitish =
        string.find(n, "unit", 1, true) or
        string.find(n, "player", 1, true) or
        string.find(n, "target", 1, true) or
        string.find(n, "raid", 1, true) or
        string.find(n, "party", 1, true)

    return auraish and unitish
end


local function CallTableFunctionAndReport(label, tbl, key, ...)
    if type(tbl) ~= "table" or type(tbl[key]) ~= "function" then
        ResearchPrint(label .. " -> unavailable")
        return
    end

    local results = { pcall(tbl[key], ...) }
    local ok = table.remove(results, 1)
    ResearchPrint(label .. " -> " .. FormatReturns(ok, unpack(results)))
end


local function CAuraHasExperience(unit)
    if type(_G.C_Aura) ~= "table" or type(_G.C_Aura.UnitHasAura) ~= "function" then
        return nil, "C_Aura.UnitHasAura unavailable"
    end

    local ok, result = pcall(_G.C_Aura.UnitHasAura, unit, 818059)
    if not ok then
        return nil, tostring(result)
    end

    return result and true or false, nil
end

local function ScanRaidWithCAura()
    ResearchPrint("===== C_AURA RAID RECIPIENT SCAN =====")

    if type(_G.C_Aura) ~= "table" or type(_G.C_Aura.UnitHasAura) ~= "function" then
        ResearchPrint("C_Aura.UnitHasAura unavailable.")
        return
    end

    local found = 0
    local checked = 0
    local byParty = { {}, {}, {} }

    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, GetNumRaidMembers() do
            local name, rank, subgroup = GetRaidRosterInfo(i)
            local unit = "raid" .. i

            if name and UnitExists(unit) then
                checked = checked + 1
                local hasAura, err = CAuraHasExperience(unit)

                if hasAura then
                    found = found + 1
                end

                if subgroup and subgroup >= 1 and subgroup <= 3 then
                    table.insert(byParty[subgroup], {
                        name = ShortName(name) or name,
                        unit = unit,
                        aura = hasAura,
                        err = err,
                    })
                end
            end
        end
    else
        -- Party fallback, including player.
        local units = { "player", "party1", "party2", "party3", "party4" }
        for _, unit in ipairs(units) do
            if UnitExists(unit) then
                checked = checked + 1
                local name = ShortName(UnitName(unit)) or unit
                local hasAura, err = CAuraHasExperience(unit)

                if hasAura then found = found + 1 end

                table.insert(byParty[1], {
                    name = name,
                    unit = unit,
                    aura = hasAura,
                    err = err,
                })
            end
        end
    end

    for party = 1, 3 do
        if #byParty[party] > 0 then
            ResearchPrint("Party " .. party .. ":")
            for _, row in ipairs(byParty[party]) do
                local flag
                if row.err then
                    flag = "ERROR " .. row.err
                elseif row.aura then
                    flag = "RECEIVING=TRUE  <<"
                else
                    flag = "receiving=false"
                end

                ResearchPrint("  " .. row.unit .. " " .. row.name .. " -> " .. flag)
            end
        end
    end

    ResearchPrint("C_Aura scan complete: " .. found .. " positive / " .. checked .. " checked.")
    ResearchPrint("TRUE means the unit is RECEIVING Aura of Experience; it does not identify the provider.")
end

local function ProbeHiddenAuraAPIs(playerName)
    local unit = FindUnitByName(playerName)
    if not unit then
        ResearchPrint("Could not resolve " .. tostring(playerName) .. " for hidden-aura probes.")
        return
    end

    local display = ShortName(UnitName(unit)) or tostring(playerName)
    ResearchPrint("===== FOCUSED HIDDEN AURA PROBE: " .. display .. " / " .. unit .. " =====")

    -- 1) UnitAuraAllowHidden
    if type(_G.UnitAuraAllowHidden) == "function" then
        ResearchPrint("-- UnitAuraAllowHidden --")

        -- Likely UnitAura-style signatures
        for i = 1, 12 do
            CallAndReport("UnitAuraAllowHidden(" .. unit .. "," .. i .. ")",
                          _G.UnitAuraAllowHidden, unit, i)
        end

        -- Spell/name forms, in case this is a hidden-spell resolver/helper
        CallAndReport("UnitAuraAllowHidden(" .. unit .. ",818059)",
                      _G.UnitAuraAllowHidden, unit, 818059)
        CallAndReport("UnitAuraAllowHidden(" .. unit .. ",\"Aura of Experience\")",
                      _G.UnitAuraAllowHidden, unit, "Aura of Experience")
        CallAndReport("UnitAuraAllowHidden(818059)",
                      _G.UnitAuraAllowHidden, 818059)
    else
        ResearchPrint("UnitAuraAllowHidden unavailable")
    end

    -- 2) C_Aura.UnitHasAura
    if type(_G.C_Aura) == "table" and type(_G.C_Aura.UnitHasAura) == "function" then
        ResearchPrint("-- C_Aura.UnitHasAura --")
        CallTableFunctionAndReport("C_Aura.UnitHasAura(unit,818059)", _G.C_Aura, "UnitHasAura", unit, 818059)
        CallTableFunctionAndReport("C_Aura.UnitHasAura(unit,818066)", _G.C_Aura, "UnitHasAura", unit, 818066)
        CallTableFunctionAndReport("C_Aura.UnitHasAura(unit,\"Aura of Experience\")", _G.C_Aura, "UnitHasAura", unit, "Aura of Experience")
        CallTableFunctionAndReport("C_Aura.UnitHasAura(818059,unit)", _G.C_Aura, "UnitHasAura", 818059, unit)
    else
        ResearchPrint("C_Aura.UnitHasAura unavailable")
    end

    -- 3) AuraUtil helpers.
    if type(_G.AuraUtil) == "table" then
        ResearchPrint("-- AuraUtil --")

        if type(_G.AuraUtil.GetAura) == "function" then
            for i = 1, 12 do
                CallTableFunctionAndReport("AuraUtil.GetAura(" .. unit .. "," .. i .. ")", _G.AuraUtil, "GetAura", unit, i)
            end
            CallTableFunctionAndReport("AuraUtil.GetAura(unit,818059)", _G.AuraUtil, "GetAura", unit, 818059)
        end

        if type(_G.AuraUtil.GetBuff) == "function" then
            for i = 1, 12 do
                CallTableFunctionAndReport("AuraUtil.GetBuff(" .. unit .. "," .. i .. ")", _G.AuraUtil, "GetBuff", unit, i)
            end
            CallTableFunctionAndReport("AuraUtil.GetBuff(unit,818059)", _G.AuraUtil, "GetBuff", unit, 818059)
        end

        if type(_G.AuraUtil.HasAura) == "function" then
            CallTableFunctionAndReport("AuraUtil.HasAura(unit,818059)", _G.AuraUtil, "HasAura", unit, 818059)
            CallTableFunctionAndReport("AuraUtil.HasAura(unit,\"Aura of Experience\")", _G.AuraUtil, "HasAura", unit, "Aura of Experience")
            CallTableFunctionAndReport("AuraUtil.HasAura(818059,unit)", _G.AuraUtil, "HasAura", 818059, unit)
        end

        if type(_G.AuraUtil.HasBuff) == "function" then
            CallTableFunctionAndReport("AuraUtil.HasBuff(unit,818059)", _G.AuraUtil, "HasBuff", unit, 818059)
            CallTableFunctionAndReport("AuraUtil.HasBuff(unit,\"Aura of Experience\")", _G.AuraUtil, "HasBuff", unit, "Aura of Experience")
        end

        if type(_G.AuraUtil.FindAura) == "function" then
            CallTableFunctionAndReport("AuraUtil.FindAura(818059,unit)", _G.AuraUtil, "FindAura", 818059, unit)
            CallTableFunctionAndReport("AuraUtil.FindAura(\"Aura of Experience\",unit)", _G.AuraUtil, "FindAura", "Aura of Experience", unit)
        end

        if type(_G.AuraUtil.FindAuraByName) == "function" then
            CallTableFunctionAndReport("AuraUtil.FindAuraByName(\"Aura of Experience\",unit)", _G.AuraUtil, "FindAuraByName", "Aura of Experience", unit)
            CallTableFunctionAndReport("AuraUtil.FindAuraByName(unit,\"Aura of Experience\")", _G.AuraUtil, "FindAuraByName", unit, "Aura of Experience")
        end
    else
        ResearchPrint("AuraUtil unavailable")
    end

    -- Compare against self immediately; this is useful because our own hidden aura
    -- is known to exist and gives us a control sample for signature discovery.
    if unit ~= "player" then
        ResearchPrint("===== CONTROL SAMPLE: player =====")
        local selfName = ShortName(UnitName("player")) or "player"

        if type(_G.C_Aura) == "table" and type(_G.C_Aura.UnitHasAura) == "function" then
            CallTableFunctionAndReport("SELF C_Aura.UnitHasAura(player,818059)", _G.C_Aura, "UnitHasAura", "player", 818059)
            CallTableFunctionAndReport("SELF C_Aura.UnitHasAura(player,\"Aura of Experience\")", _G.C_Aura, "UnitHasAura", "player", "Aura of Experience")
        end

        if type(_G.UnitAuraAllowHidden) == "function" then
            for i = 1, 12 do
                CallAndReport("SELF UnitAuraAllowHidden(player," .. i .. ")", _G.UnitAuraAllowHidden, "player", i)
            end
        end

        if type(_G.AuraUtil) == "table" and type(_G.AuraUtil.FindAuraByName) == "function" then
            CallTableFunctionAndReport("SELF AuraUtil.FindAuraByName(\"Aura of Experience\",player)",
                                       _G.AuraUtil, "FindAuraByName", "Aura of Experience", "player")
        end
    end

    ResearchPrint("===== END FOCUSED HIDDEN AURA PROBE =====")
end

local function DiscoverAuraGlobals()
    ResearchPrint("----- automated aura global discovery -----")

    local funcs = {}
    local tables = {}
    local others = {}

    for name, value in pairs(_G) do
        if type(name) == "string" and NameLooksAuraRelevant(name) then
            local t = type(value)

            if t == "function" then
                table.insert(funcs, name)
            elseif t == "table" then
                table.insert(tables, name)
            else
                table.insert(others, name .. "=" .. tostring(value))
            end
        end
    end

    table.sort(funcs)
    table.sort(tables)
    table.sort(others)

    ResearchPrint("Relevant functions found: " .. tostring(#funcs))
    for _, name in ipairs(funcs) do
        local prefix = NameLooksPromisingRemoteGetter(name) and "  >> " or "     "
        ResearchPrint(prefix .. name)
    end

    ResearchPrint("Relevant tables found: " .. tostring(#tables))
    for _, name in ipairs(tables) do
        ResearchPrint("     " .. name)
    end

    -- Search one level inside relevant global tables for function names that
    -- themselves look aura/hidden/unit related. This catches namespace-style
    -- APIs such as C_Something.GetUnitAuraHidden.
    local nested = {}

    for _, tableName in ipairs(tables) do
        local tbl = _G[tableName]
        if type(tbl) == "table" then
            local inspected = 0

            for key, value in pairs(tbl) do
                inspected = inspected + 1
                if inspected > 250 then break end

                if type(key) == "string" and type(value) == "function" and
                   NameLooksAuraRelevant(key) then
                    table.insert(nested, tableName .. "." .. key)
                end
            end
        end
    end

    table.sort(nested)

    ResearchPrint("Nested aura-related functions: " .. tostring(#nested))
    for _, name in ipairs(nested) do
        ResearchPrint("  >> " .. name)
    end

    ResearchPrint("Discovery complete. Functions marked >> are strongest remote-aura candidates.")
end

local function SafeAutoProbeNamedFunction(name, unit, display)
    local fn = _G[name]
    if type(fn) ~= "function" then return end

    -- Only auto-call names that strongly resemble query/getter functions.
    local lower = string.lower(name)

    local getterish =
        string.find(lower, "get", 1, true) or
        string.find(lower, "has", 1, true) or
        string.find(lower, "is", 1, true) or
        string.find(lower, "find", 1, true) or
        string.find(lower, "hidden", 1, true) or
        string.find(lower, "packed", 1, true)

    local dangerousish =
        string.find(lower, "set", 1, true) or
        string.find(lower, "add", 1, true) or
        string.find(lower, "remove", 1, true) or
        string.find(lower, "apply", 1, true) or
        string.find(lower, "create", 1, true) or
        string.find(lower, "refresh", 1, true) or
        string.find(lower, "client", 1, true)

    if not getterish or dangerousish then return end

    ResearchPrint("Safe candidate probe: " .. name)

    CallAndReport(name .. "(unit,818059)", fn, unit, 818059)
    CallAndReport(name .. "(unit,818066)", fn, unit, 818066)
    CallAndReport(name .. "(name,818059)", fn, display, 818059)
    CallAndReport(name .. "(818059)", fn, 818059)
end

local function AutoProbeDiscoveredGetters(playerName)
    local unit = FindUnitByName(playerName)
    if not unit then
        ResearchPrint("Could not resolve " .. tostring(playerName) .. " for discovery probes.")
        return
    end

    local display = ShortName(UnitName(unit)) or tostring(playerName)

    ResearchPrint("----- safe discovered-getter probes for " .. display .. " -----")

    local names = {}
    for name, value in pairs(_G) do
        if type(name) == "string" and type(value) == "function" and
           NameLooksPromisingRemoteGetter(name) then
            table.insert(names, name)
        end
    end

    table.sort(names)

    local probed = 0
    for _, name in ipairs(names) do
        if name ~= "PlayerAuraHidden" and name ~= "UnitPackedAura" then
            local before = probed
            local lower = string.lower(name)
            local getterish =
                string.find(lower, "get", 1, true) or
                string.find(lower, "has", 1, true) or
                string.find(lower, "is", 1, true) or
                string.find(lower, "find", 1, true) or
                string.find(lower, "hidden", 1, true) or
                string.find(lower, "packed", 1, true)

            local dangerousish =
                string.find(lower, "set", 1, true) or
                string.find(lower, "add", 1, true) or
                string.find(lower, "remove", 1, true) or
                string.find(lower, "apply", 1, true) or
                string.find(lower, "create", 1, true) or
                string.find(lower, "refresh", 1, true) or
                string.find(lower, "client", 1, true)

            if getterish and not dangerousish then
                probed = probed + 1
                SafeAutoProbeNamedFunction(name, unit, display)
            end

            if probed >= 20 then break end
        end
    end

    if probed == 0 then
        ResearchPrint("No additional safe getter-like global functions found.")
    else
        ResearchPrint("Safe additional getters probed: " .. tostring(probed))
    end
end


local function ResearchSnapshot(playerName)
    EnsureResearchState()
    local unit = FindUnitByName(playerName)
    if not unit then
        ResearchPrint("Could not resolve " .. tostring(playerName) .. " to a party/raid unit.")
        return false
    end

    local display = ShortName(UnitName(unit)) or tostring(playerName)

    ResearchPrint("----- snapshot: " .. display .. " / " .. unit .. " -----")
    ResearchPrint("exists=" .. tostring(UnitExists(unit) and true or false) ..
                  " connected=" .. tostring(UnitIsConnected(unit) and true or false) ..
                  " visible=" .. tostring(UnitIsVisible and UnitIsVisible(unit) or "n/a") ..
                  " inPhase=" .. tostring(UnitInPhase and UnitInPhase(unit) or "n/a"))

    if GetSpellInfo then
        ResearchPrint("818059=" .. tostring(GetSpellInfo(818059) or "nil") ..
                      " | 818066=" .. tostring(GetSpellInfo(818066) or "nil"))
    end

    PrintAuraMatchesForUnit(unit, display)

    ResearchPrint("Ascension/custom globals:")
    for _, name in ipairs(RESEARCH_HOOKS) do
        ResearchPrint("  " .. name .. " -> " .. SafeFunctionInfo(name))
    end

    return true
end

local function StartAuraResearch(playerName)
    EnsureResearchState()
    if not playerName or playerName == "" then
        local target = UnitName("target")
        if target then
            playerName = target
        else
            ResearchPrint("Target a player or provide a name.")
            return
        end
    end

    local unit = FindUnitByName(playerName)
    if not unit then
        ResearchPrint("Player " .. tostring(playerName) .. " is not currently resolvable in your group.")
        return
    end

    state.research.active = true
    state.research.targetName = ShortName(UnitName(unit)) or ShortName(playerName)
    state.research.targetUnit = unit
    state.research.started = GetTime()
    state.research.unitAuraEvents = 0
    state.research.hookedCalls = {}

    ResearchPrint("Starting 20-second automated aura research for " ..
                  state.research.targetName .. " (" .. unit .. ").")
    ResearchPrint("Move them between groups / retarget them / wait normally; no devconsole required.")

    InstallResearchHooks()
    ResearchSnapshot(state.research.targetName)
    CompareSelfAndTargetGetterProbes(state.research.targetUnit, state.research.targetName)
end

local function FinishAuraResearch()
    EnsureResearchState()
    if not state.research.active then return end

    ResearchPrint("----- research summary for " ..
                  tostring(state.research.targetName or "?") .. " -----")
    ResearchPrint("UNIT_AURA events seen for target unit/name: " ..
                  tostring(state.research.unitAuraEvents or 0))

    local any = false
    for _, name in ipairs(RESEARCH_HOOKS) do
        local count = state.research.hookedCalls[name] or 0
        if count > 0 then
            any = true
            ResearchPrint(name .. " natural calls captured: " .. count)
        end
    end
    if not any then
        ResearchPrint("No candidate custom aura functions were naturally called during the test.")
    end

    ResearchSnapshot(state.research.targetName)
    ResearchPrint("Research complete. Screenshot/copy the [Research] lines if we still cannot identify the aura.")

    state.research.active = false
end

-- ============================================================================
-- Recruitment
-- ============================================================================

local function GeneratedRecruitmentMessage()
    local c = state.coverage
    local sensor = state.partyAuraSensor or { [1]=nil,[2]=nil,[3]=nil }
    local missing = RecruitmentMissingGroups(c, sensor)
    local need = #missing

    if need == 0 then return nil end

    local groupBits = {}
    for _, g in ipairs(missing) do table.insert(groupBits, "P" .. g) end
    local where = table.concat(groupBits, " + ")

    if need == 1 then
        return "LFM Manastorm Leveling " .. GroupSize() ..
               "/15 - need 1 Aura of Experience player for " .. where ..
               ". Whisper \"aura\" for invite."
    end

    return "LFM Manastorm Leveling " .. GroupSize() ..
           "/15 - need Aura for " .. where ..
           " (" .. need .. " players). Whisper \"aura\" for invite."
end

local function RecruitmentMessage()
    local generated = GeneratedRecruitmentMessage()
    if not generated then return nil end
    local custom = Trim(FrostSeekAuraDB and FrostSeekAuraDB.recruitMessage or "")
    return custom ~= "" and custom or generated
end
local function ChannelDisplay(slot)
    slot = tonumber(slot) or 1
    local id, name = GetChannelName(slot)
    -- On 3.3.5 GetChannelName(slot) can vary by client implementation.
    -- We deliberately SEND to numeric slot; this label is cosmetic.
    if name and name ~= "" then
        return tostring(slot) .. ". " .. tostring(name)
    end
    return "Channel " .. tostring(slot)
end

local function SendRecruitment()
    local msg = RecruitmentMessage()
    if not msg then
        Print("All three parties have Aura coverage. No Aura advert sent.")
        return false
    end

    local slot = tonumber(FrostSeekAuraDB.recruitChannel) or 1
    if slot < 1 then slot = 1 end
    if slot > 10 then slot = 10 end

    -- Send directly to numbered channel slot. Default is 1 = Ascension on user's setup.
    state.recruitReplyUntil = GetTime() + 180
    SendChatMessage(msg, "CHANNEL", nil, slot)
    Print("Recruitment sent to " .. ChannelDisplay(slot) .. ".")
    return true
end

local function PostRoster()
    local groups = {}
    for g = 1, 3 do
        local players = {}
        for _, info in pairs(state.roster or {}) do
            if info.subgroup == g then
                table.insert(players, info.name .. ((info.marked or info.detected) and "[A]" or ""))
            end
        end
        table.sort(players)
        table.insert(groups, "P" .. g .. ": " .. (#players > 0 and table.concat(players, "/") or "empty"))
    end
    GroupChat(table.concat(groups, " | "))
end

local function SendManualGroupMessage(message)
    message = Trim(message)
    if message == "" then return false end
    if RaidCount() > 0 then
        SendChatMessage(message, "RAID")
        return true
    elseif PartyCount() > 0 then
        SendChatMessage(message, "PARTY")
        return true
    end
    Print("Join a party or raid before sending group chat.")
    return false
end

local function StartReadyCheck()
    if DoReadyCheck then
        local ok = pcall(DoReadyCheck)
        Print(ok and "Ready check started." or "Ready check requires raid leadership.")
    else
        Print("Ready check is unavailable on this client or requires raid leadership.")
    end
end

local function SuggestGroupOptimization()
    local suggestion = MoveSuggestion(state.coverage or { [1]={}, [2]={}, [3]={} })
    if suggestion then
        Print(suggestion)
    else
        Print(CompactHealthWarning(
            state.coverage or { [1]={}, [2]={}, [3]={} },
            state.partyAuraSensor or { [1]=nil, [2]=nil, [3]=nil },
            state.verifiedCoverage or { [1]={}, [2]={}, [3]={} }))
    end
end

-- ============================================================================
-- Roster delta alerts
-- ============================================================================

-- Compatibility helper used by roster alerts / verification.
-- Existing callers pass the roster info TABLE, not a player name.
local function IsAssignedAuraPlayer(info)
    if not info then return false end

    -- Current auto/manual assignment state on the roster record.
    if info.marked or info.detected then
        return true
    end

    -- Positive C_Aura detections are cached by character name so an
    -- out-of-range Aura player remains known.
    local k = Key(info.name)
    if FrostSeekAuraDB.knownAuraPlayers and FrostSeekAuraDB.knownAuraPlayers[k] then
        return true
    end

    if FrostSeekAuraDB.marked and FrostSeekAuraDB.marked[k] then
        return true
    end

    return false
end

local function IsTrackedAuraProvider(info)
    return IsAssignedAuraPlayer(info)
end

local function CheckLevel59Warnings(oldRoster, newRoster)
    if not FrostSeekAuraDB.announceLevel59 then return end
    state.level59Announced = state.level59Announced or {}

    for k, info in pairs(newRoster or {}) do
        if IsTrackedAuraProvider(info) and tonumber(info.level) == 59 then
            local old = oldRoster and oldRoster[k] or nil
            local justReached59 = (not old) or tonumber(old.level) ~= 59

            if justReached59 and not state.level59Announced[k] then
                state.level59Announced[k] = true
                local partyText = ""
                if info.subgroup and info.subgroup >= 1 and info.subgroup <= 3 then
                    partyText = " in P" .. tostring(info.subgroup)
                end
                GroupChat("Aura player " .. info.name .. partyText ..
                          " has reached level 59 and is about to hit max level. " ..
                          "Prepare a replacement Aura player.")
                PlayAuraAlertSound()
            end
        end
    end
end

local function ProcessRosterDelta(oldRoster, newRoster, newCoverage)
    if not state.initializedRoster then return end

    for k, old in pairs(oldRoster or {}) do
        if IsAssignedAuraPlayer(old) and not newRoster[k] then
            state.departedProviders[k] = {
                name = old.name,
                subgroup = old.subgroup,
                time = GetTime(),
            }

            if FrostSeekAuraDB.announceLeave then
                local g = old.subgroup
                local stillAssigned = g and newCoverage[g] and #newCoverage[g] > 0
                if g and g >= 1 and g <= 3 and not stillAssigned then
                    GroupChat("Aura player " .. old.name ..
                              " left. P" .. g .. " now needs an Aura player.")
                    PlayAuraAlertSound()
                else
                    GroupChat("Aura player " .. old.name ..
                              " left the raid (last assigned P" .. tostring(g or "?") .. ").")
                    PlayAuraAlertSound()
                end
            end
        end
    end

    for k, new in pairs(newRoster or {}) do
        if not oldRoster[k] then
            -- Candidate lifecycle: the player is now represented in the roster,
            -- so remove their recruitment row rather than duplicating them.
            if state.candidates[k] then
                state.candidates[k].status = new.detected and "Aura confirmed" or "Joined"
                state.candidates[k] = nil
            end
            if state.nonAuraCandidates[k] then
                state.nonAuraCandidates[k].status = "Joined"
                state.nonAuraCandidates[k] = nil
            end

            if IsAssignedAuraPlayer(new) and FrostSeekAuraDB.announceJoin then
                GroupChat("Aura player " .. new.name ..
                          " joined the raid in P" .. tostring(new.subgroup) .. ".")
            end
        end
    end
end
-- Forward declarations for UI update
local RefreshUI
local RefreshCandidates
local RefreshOverlay

local function Scan(silent, suppressAnnouncements)
    local oldRoster = state.roster or {}
    local oldSensor = state.partyAuraSensor or { [1] = nil, [2] = nil, [3] = nil }

    local newRoster = BuildRoster()
    AutoMarkDetected(newRoster)

    NoteRosterProviderCandidates(oldRoster, newRoster)
    local newSensor = GetPartyRecipientSensor(newRoster)
    ApplyCoverageTransitionInference(oldSensor, newSensor, newRoster)
    AutoMarkDetected(newRoster)

    local newCoverage = BuildCoverage(newRoster)
    local newVerifiedCoverage = VerifiedCoverageFromRoster(newRoster)
    local newSig = DistSig(newCoverage)
    local newHealthSig = PartyHealthSignature(newCoverage, newSensor, newVerifiedCoverage)

    local inEntryGrace = state.manastormEntryGraceUntil and
                         GetTime() < state.manastormEntryGraceUntil
    local suppress = suppressAnnouncements or inEntryGrace

    if not suppress then
        ProcessRosterDelta(oldRoster, newRoster, newCoverage)
        CheckLevel59Warnings(oldRoster, newRoster)
    end

    -- Debounce distribution/restored messages. Repeated 5-second scans do not
    -- announce anything unless the actual health signature changes.
    if not suppress and state.initializedRoster and
       state.lastPartyHealthSignature ~= nil and
       newHealthSig ~= state.lastPartyHealthSignature then
        state.pendingDistributionAlert = {
            signature = newHealthSig,
            due = GetTime() + 1.5,
            restored = RaidAuraReady(newCoverage, newSensor),
        }
    end

    state.roster = newRoster
    state.partyAuraSensor = newSensor
    state.coverage = newCoverage
    state.verifiedCoverage = newVerifiedCoverage
    state.distributionSignature = newSig
    state.lastPartyHealthSignature = newHealthSig
    state.initializedRoster = true

    if RefreshUI then RefreshUI() end
    if RefreshCandidates then RefreshCandidates() end
    if RefreshOverlay then RefreshOverlay() end

    if not silent then
        local learned = 0
        for _ in pairs(FrostSeekAuraDB.knownAuraPlayers or {}) do learned = learned + 1 end
        local ready = RaidAuraReady(newCoverage, newSensor) and "READY" or "NOT READY"
        Print("Scan: " .. ready .. "; " .. CoveredParties(newCoverage) ..
              "/3 assigned; " .. learned .. " confirmed provider(s). " ..
              "P1=" .. PartySensorText(newSensor[1]) ..
              " P2=" .. PartySensorText(newSensor[2]) ..
              " P3=" .. PartySensorText(newSensor[3]) .. ".")
    end

    if RaidAuraReady(newCoverage, newSensor) and FrostSeekAuraDB.recruiting then
        FrostSeekAuraDB.recruiting = false
        state.recruitElapsed = 0
        Print("Aura recruitment stopped automatically: raid Aura state is ready.")
        if RefreshUI then RefreshUI() end
    end
end
-- ============================================================================
-- Small draggable FrostSeek-styled overlay
-- ============================================================================

local overlay = {}

local function CreateOverlay()
    if overlay.frame then return end

    -- Unscaled anchor/mover. The visible overlay is a child of this frame.
    -- Keeping position and scale on separate frames avoids SetScale changing
    -- the coordinate system used by movement/anchoring.
    local f = CreateFrame("Frame", "FrostSeekAuraOverlay", UIParent)
    f:SetWidth(1)
    f:SetHeight(1)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true)
    f:EnableMouse(false)

    f:ClearAllPoints()
    f:SetPoint(
        FrostSeekAuraDB.overlay.point or "RIGHT",
        UIParent,
        FrostSeekAuraDB.overlay.relativePoint or "RIGHT",
        FrostSeekAuraDB.overlay.x or -35,
        FrostSeekAuraDB.overlay.y or 30
    )

    local content = CreateFrame("Frame", nil, f)
    content:SetWidth(235)
    content:SetHeight(154)
    content:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    content:SetFrameStrata("MEDIUM")
    content:EnableMouse(true)
    content:RegisterForDrag("LeftButton")

    local savedScale = tonumber(FrostSeekAuraDB.overlay.scale) or 1.0
    if savedScale < 0.55 then savedScale = 0.55 end
    if savedScale > 2.0 then savedScale = 2.0 end
    FrostSeekAuraDB.overlay.scale = savedScale
    content:SetScale(savedScale)

    local bg = content:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    ColorTexture(bg, "bgBlock", {0.05, 0.06, 0.08, 0.93})

    local header = content:CreateTexture(nil, "ARTWORK")
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(24)
    ColorTexture(header, "bgTabActive", {0.12, 0.18, 0.24, 1})

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 8, -6)
    title:SetText("|cff88ccffManastorm Auras|r")

    local summary = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    summary:SetPoint("TOPRIGHT", -43, -6)
    overlay.summary = summary

    local hide = NewButton(content, 34, 18, "Hide")
    hide:SetPoint("TOPRIGHT", -4, -3)
    hide:SetScript("OnClick", function()
        FrostSeekAuraDB.overlay.shown = false
        f:Hide()
        if RefreshUI then RefreshUI() end
    end)

    overlay.rows = {}
    for g = 1, 3 do
        local row = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row:SetPoint("TOPLEFT", 9, -34 - ((g - 1) * 23))
        row:SetWidth(216)
        row:SetJustifyH("LEFT")
        overlay.rows[g] = row
    end

    local roles = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    roles:SetPoint("TOPLEFT", 9, -103)
    roles:SetWidth(216)
    roles:SetJustifyH("LEFT")
    roles:SetTextColor(0.70, 0.78, 0.88)
    overlay.roles = roles

    local status = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("BOTTOMLEFT", 9, 7)
    status:SetWidth(216)
    status:SetJustifyH("LEFT")
    overlay.status = status

    -- Dragging moves only the unscaled anchor. Scale can never affect the
    -- stored position or cause a movement offset.
    content:SetScript("OnDragStart", function()
        if not FrostSeekAuraDB.overlay.locked then
            f:StartMoving()
        end
    end)

    content:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        local point, _, relativePoint, x, y = f:GetPoint(1)
        FrostSeekAuraDB.overlay.point = point or "RIGHT"
        FrostSeekAuraDB.overlay.relativePoint = relativePoint or point or "RIGHT"
        FrostSeekAuraDB.overlay.x = x or -35
        FrostSeekAuraDB.overlay.y = y or 30
    end)

    -- Bottom-right scale grip.
    local grip = CreateFrame("Button", nil, content)
    grip:SetWidth(18)
    grip:SetHeight(18)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:EnableMouse(true)

    local gripTex = grip:CreateTexture(nil, "OVERLAY")
    gripTex:SetAllPoints()
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetNormalTexture(gripTex)

    local gripHi = grip:CreateTexture(nil, "HIGHLIGHT")
    gripHi:SetAllPoints()
    gripHi:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")

    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Scale Aura Tracker")
        GameTooltip:AddLine("Drag the corner. The grip stays under your mouse.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Range: 55% to 200%", 0.65, 0.75, 0.9, true)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)

    grip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        if FrostSeekAuraDB.overlay.locked then return end

        local cursorX, cursorY = GetCursorPosition()
        self.startCursorX = cursorX
        self.startCursorY = cursorY
        self.startScale = content:GetScale() or 1.0
        self.baseWidth = content:GetWidth() or 235
        self.baseHeight = content:GetHeight() or 132
        self.scaling = true

        -- Normalize the mover to an absolute TOPLEFT UIParent anchor before
        -- scaling so we can reposition it precisely in cursor coordinates.
        local uiScale = UIParent:GetEffectiveScale()
        if not uiScale or uiScale == 0 then uiScale = 1 end

        local cLeft = content:GetLeft()
        local cTop = content:GetTop()
        local cScale = content:GetEffectiveScale()
        if not cScale or cScale == 0 then cScale = uiScale * self.startScale end

        if cLeft and cTop then
            -- GetLeft/GetTop are in the content's coordinate space. Convert
            -- through its effective scale back to UIParent logical coords.
            local leftUI = (cLeft * cScale) / uiScale
            local topUI = (cTop * cScale) / uiScale

            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", leftUI, topUI)

            FrostSeekAuraDB.overlay.point = "TOPLEFT"
            FrostSeekAuraDB.overlay.relativePoint = "BOTTOMLEFT"
            FrostSeekAuraDB.overlay.x = leftUI
            FrostSeekAuraDB.overlay.y = topUI
        end
    end)

    grip:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        if not self.scaling then return end

        self.scaling = false
        FrostSeekAuraDB.overlay.scale = content:GetScale() or 1.0

        local point, _, relativePoint, x, y = f:GetPoint(1)
        FrostSeekAuraDB.overlay.point = point or "TOPLEFT"
        FrostSeekAuraDB.overlay.relativePoint = relativePoint or "BOTTOMLEFT"
        FrostSeekAuraDB.overlay.x = x or FrostSeekAuraDB.overlay.x
        FrostSeekAuraDB.overlay.y = y or FrostSeekAuraDB.overlay.y

        if RefreshOverlay then RefreshOverlay() end
    end)

    grip:SetScript("OnUpdate", function(self)
        if not self.scaling then return end

        local uiScale = UIParent:GetEffectiveScale()
        if not uiScale or uiScale == 0 then uiScale = 1 end

        local cursorX, cursorY = GetCursorPosition()
        local dx = (cursorX - (self.startCursorX or cursorX)) / uiScale
        local dy = ((self.startCursorY or cursorY) - cursorY) / uiScale

        local bw = self.baseWidth or 235
        local bh = self.baseHeight or 132

        -- Uniform scale from the mouse's movement projected onto the overlay
        -- diagonal. This gives a stable scale rate regardless of screen/UI scale.
        local denom = (bw * bw) + (bh * bh)
        local deltaScale = 0
        if denom > 0 then
            deltaScale = ((dx * bw) + (dy * bh)) / denom
        end

        local newScale = (self.startScale or 1.0) + deltaScale
        if newScale < 0.55 then newScale = 0.55 end
        if newScale > 2.00 then newScale = 2.00 end

        content:SetScale(newScale)
        FrostSeekAuraDB.overlay.scale = newScale

        -- Hard-lock the visible bottom-right corner to the cursor. Any mouse
        -- path is valid; instead of allowing the grip to drift off a uniform
        -- scaling diagonal, translate the unscaled mover by the tiny amount
        -- necessary to keep the grabbed corner exactly under the pointer.
        local cursorUIX = cursorX / uiScale
        local cursorUIY = cursorY / uiScale
        local leftUI = cursorUIX - (bw * newScale) + (2 * newScale)
        local topUI = cursorUIY + (bh * newScale) - (2 * newScale)

        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", leftUI, topUI)

        FrostSeekAuraDB.overlay.point = "TOPLEFT"
        FrostSeekAuraDB.overlay.relativePoint = "BOTTOMLEFT"
        FrostSeekAuraDB.overlay.x = leftUI
        FrostSeekAuraDB.overlay.y = topUI
    end)

    overlay.grip = grip
    overlay.content = content
    overlay.scaleFrame = content
    overlay.frame = f

    if FrostSeekAuraDB.overlay.shown then f:Show() else f:Hide() end
end

RefreshOverlay = function()
    if not overlay.frame then return end
    local c = state.coverage
    local sensor = state.partyAuraSensor or { [1]=nil,[2]=nil,[3]=nil }
    local verified = state.verifiedCoverage or { [1]={},[2]={},[3]={} }

    local ready = RaidAuraReady(c, sensor)
    if ready then
        overlay.summary:SetText("|cff66ff66Auras 3/3 READY|r")
    else
        local active = 0
        local unknown = 0
        for g = 1, 3 do
            if sensor[g] == true then active = active + 1
            elseif sensor[g] == nil then unknown = unknown + 1 end
        end
        if unknown > 0 then
            overlay.summary:SetText("|cffffaa00Auras " .. active .. "/3 UNKNOWN|r")
        else
            overlay.summary:SetText("|cffff5555Auras " .. active .. "/3 NOT READY|r")
        end
    end

    for g = 1, 3 do
        local code, detail = PartyHealth(g, c, sensor, verified)
        if code == "CONFIRMED" then
            overlay.rows[g]:SetText("P" .. g .. "  |cff66ff66" .. detail .. "|r  |cff888888confirmed|r")
        elseif code == "MANUAL_ACTIVE" then
            overlay.rows[g]:SetText("P" .. g .. "  |cff66ff66" .. detail .. "|r  |cffffff66manual|r")
        elseif code == "ACTIVE_ASSIGNED" then
            overlay.rows[g]:SetText("P" .. g .. "  |cff66ff66" .. detail .. "|r  |cff888888active|r")
        elseif code == "ACTIVE_UNKNOWN" then
            overlay.rows[g]:SetText("P" .. g .. "  |cff66ff66Aura active|r  |cffffff66provider unknown|r")
        elseif code == "MANUAL_UNKNOWN" or code == "OUT_OF_RANGE" then
            overlay.rows[g]:SetText("P" .. g .. "  |cffffff66" .. detail .. "|r  |cff888888out of range|r")
        elseif code == "INACTIVE_ASSIGNED" then
            overlay.rows[g]:SetText("P" .. g .. "  |cffff5555" .. detail .. " INACTIVE|r")
        elseif code == "DUPLICATE" then
            overlay.rows[g]:SetText("P" .. g .. "  |cffffaa00DUPLICATE PROVIDERS|r")
        elseif code == "NO_AURA" then
            overlay.rows[g]:SetText("P" .. g .. "  |cffff5555NO AURA|r")
        else
            overlay.rows[g]:SetText("P" .. g .. "  |cffffff66UNKNOWN|r")
        end
    end

    if overlay.roles then
        overlay.roles:SetText(CombatRoleSummary())
    end

    local level59Name = nil
    for _, info in pairs(state.roster or {}) do
        if IsTrackedAuraProvider(info) and tonumber(info.level) == 59 then
            level59Name = info.name
            break
        end
    end

    local scalePct = math.floor(((FrostSeekAuraDB.overlay.scale or 1) * 100) + 0.5)
    if level59Name then
        overlay.status:SetText("|cffff5555" .. level59Name .. " is 59 - replace soon|r")
    elseif ready then
        overlay.status:SetText("|cff66ff66Raid ready|r  |cff888888" .. scalePct .. "%|r")
    else
        local suggestion = MoveSuggestion(c)
        if suggestion then
            overlay.status:SetText("|cffffaa00" .. suggestion .. "|r")
        else
            overlay.status:SetText("|cffffaa00" .. MissingText(c) .. "|r  |cff888888" .. scalePct .. "%|r")
        end
    end
end
-- ============================================================================
-- Integrated FrostSeek UI
-- ============================================================================

local ui = {}

local function OpenRosterMenuForGroup(group, anchor)
    local menu = {}
    local found = false

    for _, info in pairs(state.roster) do
        if info.subgroup == group then
            found = true
            local already = FrostSeekAuraDB.marked[Key(info.name)] ~= nil
            table.insert(menu, {
                text = (already and "|cff66ff66OK |r" or "") .. info.name,
                notCheckable = true,
                func = function()
                    Mark(info.name)
                end,
            })
        end
    end

    table.sort(menu, function(a,b) return a.text < b.text end)

    if not found then
        table.insert(menu, {
            text = "No players currently in Party " .. group,
            disabled = true,
            notCheckable = true,
        })
    end

    if EasyMenu then
        EasyMenu(menu, CreateFrame("Frame", "FrostSeekAuraRosterMenu" .. group, UIParent, "UIDropDownMenuTemplate"),
                 anchor, 0, 0, "MENU")
    else
        Print("Roster menu unavailable on this client. Use /fsaura mark <name>.")
    end
end

local function FirstMissingGroup()
    for g = 1, 3 do
        if #state.coverage[g] == 0 then return g end
    end
    return 1
end

local function CreateUI(parent)
    local frame = CreateFrame("Frame", "FrostSeekAuraIntegratedFrame", parent)
    frame:SetAllPoints(parent)
    frame:Hide()
    ui.frame = frame

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -15)
    title:SetText("|cff88ccffManastorm Aura Manager|r")

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)
    subtitle:SetText("15-player raid • 3 parties • 1 Aura of Experience player per party")
    subtitle:SetTextColor(0.65, 0.70, 0.78)

    local localNote = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    localNote:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -3)
    localNote:SetWidth(650)
    localNote:SetJustifyH("LEFT")
    localNote:SetText("|cffffcc66Automatic Aura detection is local-range data; inside Manastorm it is treated as authoritative.|r")
    ui.localNote = localNote

    local overlayBtn = NewButton(frame, 105, 24, "Show Overlay")
    overlayBtn:SetPoint("TOPRIGHT", -18, -14)
    overlayBtn:SetScript("OnClick", function()
        FrostSeekAuraDB.overlay.shown = true
        if overlay.frame then overlay.frame:Show() end
        if RefreshOverlay then RefreshOverlay() end
        if RefreshUI then RefreshUI() end
    end)
    ui.overlayBtn = overlayBtn

    local resetScaleBtn = NewButton(frame, 90, 24, "Reset Scale")
    resetScaleBtn:SetPoint("RIGHT", overlayBtn, "LEFT", -6, 0)
    resetScaleBtn:SetScript("OnClick", function()
        FrostSeekAuraDB.overlay.scale = 1.0
        if overlay.scaleFrame then
            overlay.scaleFrame:SetScale(1.0)
        elseif overlay.frame then
            overlay.frame:SetScale(1.0)
        end
        if RefreshOverlay then RefreshOverlay() end
    end)
    ui.resetScaleBtn = resetScaleBtn

    local lockOverlay = NewCheckbox(frame, "Lock overlay",
        FrostSeekAuraDB.overlay.locked,
        function(v) FrostSeekAuraDB.overlay.locked = v end)
    lockOverlay:SetPoint("TOPLEFT", resetScaleBtn, "BOTTOMLEFT", 0, -5)
    ui.lockOverlay = lockOverlay


    -- STATUS / PARTY BLOCK -----------------------------------------------------
    local statusBlock = NewBlock(frame)
    statusBlock:SetPoint("TOPLEFT", 15, -82)
    statusBlock:SetSize(565, 238)
    ui.statusBlock = statusBlock

    local st = statusBlock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    st:SetPoint("TOPLEFT", 12, -10)
    st:SetText("Raid groups")

    local summary = statusBlock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    summary:SetPoint("TOPRIGHT", -12, -10)
    ui.summary = summary

    ui.groups = {}
    for g = 1, 3 do
        local panel = NewBlock(statusBlock)
        panel:SetPoint("TOPLEFT", 10 + ((g - 1) * 181), -34)
        panel:SetSize(175, 150)

        local groupName = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        groupName:SetPoint("TOPLEFT", 7, -6)
        groupName:SetText("Group " .. g)

        local groupState = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        groupState:SetPoint("TOPRIGHT", -7, -7)
        groupState:SetWidth(92)
        groupState:SetJustifyH("RIGHT")

        local rows = {}
        for slot = 1, 5 do
            local playerRow = CreateFrame("Frame", nil, panel)
            playerRow:SetPoint("TOPLEFT", 6, -27 - ((slot - 1) * 23))
            playerRow:SetSize(163, 21)

            local aura = CreateFrame("Button", nil, playerRow)
            aura:SetPoint("LEFT", 0, 0)
            aura:SetSize(18, 18)
            local auraTexture = aura:CreateTexture(nil, "ARTWORK")
            auraTexture:SetAllPoints()
            auraTexture:SetTexture((GetSpellTexture and GetSpellTexture(818059)) or
                                   "Interface\\Icons\\Spell_Holy_GreaterBlessingofKings")
            aura.texture = auraTexture

            local name = playerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            name:SetPoint("LEFT", aura, "RIGHT", 4, 0)
            name:SetWidth(91)
            name:SetJustifyH("LEFT")

            local role = playerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            role:SetPoint("RIGHT", -27, 0)
            role:SetWidth(18)
            role:SetJustifyH("CENTER")

            local level = playerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            level:SetPoint("RIGHT", -1, 0)
            level:SetWidth(25)
            level:SetJustifyH("RIGHT")

            rows[slot] = {frame=playerRow, aura=aura, name=name, role=role, level=level}
        end

        ui.groups[g] = {frame=panel, state=groupState, rows=rows}
    end

    local warning = statusBlock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warning:SetPoint("TOPLEFT", 12, -190)
    warning:SetWidth(535)
    warning:SetHeight(20)
    warning:SetJustifyH("LEFT")
    ui.warning = warning

    local warningNote = statusBlock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warningNote:SetPoint("TOPLEFT", 12, -211)
    warningNote:SetWidth(535)
    warningNote:SetHeight(18)
    warningNote:SetJustifyH("LEFT")
    warningNote:SetText("|cff8f96a3Bright Aura icons are assigned providers; click any player's icon to toggle.|r")
    ui.warningNote = warningNote

    -- RECRUIT BLOCK -----------------------------------------------------------
    local recruitBlock = NewBlock(frame)
    recruitBlock:SetPoint("TOPLEFT", statusBlock, "BOTTOMLEFT", 0, -10)
    recruitBlock:SetSize(565, 205)

    local rt = recruitBlock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rt:SetPoint("TOPLEFT", 12, -10)
    rt:SetText("Aura recruitment")

    rt:SetText("Recruitment message (editable)")

    local preview = NewEdit(recruitBlock, 430, 24, "", false)
    preview:SetPoint("TOPLEFT", 12, -34)
    preview:SetMaxLetters(255)
    preview:SetScript("OnEnterPressed", function(self)
        FrostSeekAuraDB.recruitMessage = Trim(self:GetText())
        self:ClearFocus()
        RefreshUI()
    end)
    preview:SetScript("OnEditFocusLost", function(self)
        FrostSeekAuraDB.recruitMessage = Trim(self:GetText())
        RefreshUI()
    end)
    ui.preview = preview

    local resetMessage = NewButton(recruitBlock, 92, 22, "Use Auto")
    resetMessage:SetPoint("LEFT", preview, "RIGHT", 8, 0)
    resetMessage:SetScript("OnClick", function()
        FrostSeekAuraDB.recruitMessage = ""
        RefreshUI()
    end)

    local chLabel = recruitBlock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chLabel:SetPoint("TOPLEFT", 12, -80)
    chLabel:SetText("Channel slot:")

    local chEdit = NewEdit(recruitBlock, 38, 20, FrostSeekAuraDB.recruitChannel or 1, true)
    chEdit:SetPoint("LEFT", chLabel, "RIGHT", 8, 0)
    chEdit:SetMaxLetters(2)
    chEdit:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText()) or 1
        if v < 1 then v = 1 elseif v > 10 then v = 10 end
        FrostSeekAuraDB.recruitChannel = v
        self:SetText(tostring(v))
        self:ClearFocus()
        RefreshUI()
    end)
    chEdit:SetScript("OnEditFocusLost", function(self)
        local v = tonumber(self:GetText()) or 1
        if v < 1 then v = 1 elseif v > 10 then v = 10 end
        FrostSeekAuraDB.recruitChannel = v
        self:SetText(tostring(v))
        RefreshUI()
    end)
    ui.channelEdit = chEdit

    local chName = recruitBlock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chName:SetPoint("LEFT", chEdit, "RIGHT", 8, 0)
    chName:SetWidth(135)
    chName:SetJustifyH("LEFT")
    ui.channelName = chName

    local intLabel = recruitBlock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    intLabel:SetPoint("LEFT", chName, "RIGHT", 10, 0)
    intLabel:SetText("Repeat:")

    local intEdit = NewEdit(recruitBlock, 45, 20, FrostSeekAuraDB.recruitInterval or 60, true)
    intEdit:SetPoint("LEFT", intLabel, "RIGHT", 7, 0)
    intEdit:SetMaxLetters(4)
    intEdit:SetScript("OnEnterPressed", function(self)
        local v = tonumber(self:GetText()) or 60
        if v < 30 then v = 30 end
        FrostSeekAuraDB.recruitInterval = v
        self:SetText(tostring(v))
        self:ClearFocus()
    end)
    intEdit:SetScript("OnEditFocusLost", function(self)
        local v = tonumber(self:GetText()) or 60
        if v < 30 then v = 30 end
        FrostSeekAuraDB.recruitInterval = v
        self:SetText(tostring(v))
    end)
    ui.intervalEdit = intEdit

    local sec = recruitBlock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec:SetPoint("LEFT", intEdit, "RIGHT", 3, 0)
    sec:SetText("sec")

    local scanCheck = NewCheckbox(recruitBlock, "Safety scan every 5 sec",
        FrostSeekAuraDB.periodicScan,
        function(v) FrostSeekAuraDB.periodicScan = v end)
    scanCheck:SetPoint("TOPLEFT", 10, -108)
    ui.scanCheck = scanCheck

    local nowBtn = NewButton(recruitBlock, 82, 25, "Advertise")
    nowBtn:SetPoint("BOTTOMLEFT", 12, 13)
    nowBtn:SetScript("OnClick", SendRecruitment)

    local startBtn = NewButton(recruitBlock, 82, 25, "Repeat")
    startBtn:SetPoint("LEFT", nowBtn, "RIGHT", 6, 0)
    startBtn:SetScript("OnClick", function()
        if RaidAuraReady(state.coverage, state.partyAuraSensor or {}) then
            Print("Aura state is already raid-ready.")
            return
        end
        FrostSeekAuraDB.recruiting = true
        state.recruitReplyUntil = GetTime() + 180
        state.recruitElapsed = FrostSeekAuraDB.recruitInterval or 60
        RefreshUI()
        Print("Repeated Aura recruitment started.")
    end)
    ui.startBtn = startBtn

    local stopBtn = NewButton(recruitBlock, 82, 25, "Stop")
    stopBtn:SetPoint("LEFT", startBtn, "RIGHT", 6, 0)
    stopBtn:SetScript("OnClick", function()
        FrostSeekAuraDB.recruiting = false
        state.recruitElapsed = 0
        RefreshUI()
        Print("Aura recruitment stopped.")
    end)

    local rosterBtn = NewButton(recruitBlock, 82, 25, "Post Roster")
    rosterBtn:SetPoint("LEFT", stopBtn, "RIGHT", 6, 0)
    rosterBtn:SetScript("OnClick", PostRoster)

    local readyBtn = NewButton(recruitBlock, 82, 25, "Ready Check")
    readyBtn:SetPoint("LEFT", rosterBtn, "RIGHT", 6, 0)
    readyBtn:SetScript("OnClick", StartReadyCheck)

    local optimizeBtn = NewButton(recruitBlock, 82, 25, "Optimize")
    optimizeBtn:SetPoint("LEFT", readyBtn, "RIGHT", 6, 0)
    optimizeBtn:SetScript("OnClick", SuggestGroupOptimization)

    -- RIGHT COLUMN: recruitment replies ---------------------------------------
    local candBlock = NewBlock(frame)
    candBlock:SetPoint("TOPLEFT", statusBlock, "TOPRIGHT", 10, 0)
    candBlock:SetSize(320, 272)

    local ct = candBlock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    ct:SetPoint("TOPLEFT", 12, -10)
    ct:SetText("Recruitment replies")

    local cd = candBlock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cd:SetPoint("TOPLEFT", 12, -30)
    cd:SetWidth(295)
    cd:SetJustifyH("LEFT")
    cd:SetText("Parses role, Aura, and level. Exact 'aura' remains the only auto-invite trigger.")
    cd:SetTextColor(0.60, 0.65, 0.72)

    local function CreateCandidateScroller(parent, titleText, topY)
        local titleTextObj = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        titleTextObj:SetPoint("TOPLEFT", 12, topY)
        titleTextObj:SetText(titleText)

        local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 10, topY - 18)
        scroll:SetSize(278, 68)

        local child = CreateFrame("Frame", nil, scroll)
        child:SetWidth(270)
        child:SetHeight(68)
        scroll:SetScrollChild(child)

        return {
            title = titleTextObj,
            scroll = scroll,
            child = child,
            rows = {},
        }
    end

    ui.auraCandidateList = CreateCandidateScroller(candBlock, "|cff66ff66Aura candidates|r", -54)
    ui.nonAuraCandidateList = CreateCandidateScroller(candBlock, "|cffffcc66Non-aura candidates|r", -145)

    local autoInv = NewCheckbox(candBlock, "Auto-invite",
        FrostSeekAuraDB.autoInviteAuraWhispers,
        function(v) FrostSeekAuraDB.autoInviteAuraWhispers = v end)
    autoInv:SetPoint("BOTTOMLEFT", 10, 8)
    ui.autoInvite = autoInv

    local autoReply = NewCheckbox(candBlock, "Auto follow-up",
        FrostSeekAuraDB.autoApplicantReplies,
        function(v) FrostSeekAuraDB.autoApplicantReplies = v end)
    autoReply:SetPoint("BOTTOMLEFT", 145, 8)
    ui.autoReply = autoReply

    -- RIGHT COLUMN: alerts ----------------------------------------------------
    local alertBlock = NewBlock(frame)
    alertBlock:SetPoint("TOPLEFT", candBlock, "BOTTOMLEFT", 0, -10)
    alertBlock:SetSize(320, 210)

    local at = alertBlock:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    at:SetPoint("TOPLEFT", 12, -10)
    at:SetText("Alerts")

    local c1 = NewCheckbox(alertBlock, "Send alerts to raid / party chat",
        FrostSeekAuraDB.announceToGroup,
        function(v) FrostSeekAuraDB.announceToGroup = v end)
    c1:SetPoint("TOPLEFT", 10, -32)

    local leaderOnly = NewCheckbox(alertBlock, "Leader / assistant broadcasts only",
        FrostSeekAuraDB.leaderOnlyAlerts,
        function(v) FrostSeekAuraDB.leaderOnlyAlerts = v end)
    leaderOnly:SetPoint("TOPLEFT", 10, -55)

    local soundAlert = NewCheckbox(alertBlock, "Sound on provider loss",
        FrostSeekAuraDB.soundAlerts,
        function(v) FrostSeekAuraDB.soundAlerts = v end)
    soundAlert:SetPoint("TOPLEFT", 10, -78)

    local c2 = NewCheckbox(alertBlock, "Aura player leaves",
        FrostSeekAuraDB.announceLeave,
        function(v) FrostSeekAuraDB.announceLeave = v end)
    c2:SetPoint("TOPLEFT", 10, -106)

    local c3 = NewCheckbox(alertBlock, "Aura player joins",
        FrostSeekAuraDB.announceJoin,
        function(v) FrostSeekAuraDB.announceJoin = v end)
    c3:SetPoint("TOPLEFT", 165, -106)

    local c4 = NewCheckbox(alertBlock, "Incorrect distribution",
        FrostSeekAuraDB.announceDistribution,
        function(v) FrostSeekAuraDB.announceDistribution = v end)
    c4:SetPoint("TOPLEFT", 10, -132)

    local c5 = NewCheckbox(alertBlock, "3/3 restored",
        FrostSeekAuraDB.announceRestored,
        function(v) FrostSeekAuraDB.announceRestored = v end)
    c5:SetPoint("TOPLEFT", 165, -132)

    local level59Alert = NewCheckbox(alertBlock, "Level 59 replacement warning",
        FrostSeekAuraDB.announceLevel59,
        function(v) FrostSeekAuraDB.announceLevel59 = v end)
    level59Alert:SetPoint("TOPLEFT", 10, -158)

    local chatLabel = alertBlock:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chatLabel:SetPoint("BOTTOMLEFT", 10, 12)
    chatLabel:SetText("Chat:")

    local chatEdit = NewEdit(alertBlock, 185, 20, "", false)
    chatEdit:SetPoint("BOTTOMLEFT", 48, 7)
    chatEdit:SetMaxLetters(220)
    ui.chatEdit = chatEdit

    local sendChat = NewButton(alertBlock, 62, 20, "Send")
    sendChat:SetPoint("BOTTOMRIGHT", -8, 7)
    local function SendChatEdit()
        if SendManualGroupMessage(chatEdit:GetText()) then chatEdit:SetText("") end
        chatEdit:ClearFocus()
    end
    sendChat:SetScript("OnClick", SendChatEdit)
    chatEdit:SetScript("OnEnterPressed", SendChatEdit)

    ui.alertChecks = {c1,leaderOnly,soundAlert,c2,c3,c4,c5,level59Alert}

    -- Keep the complete right column inside FrostSeek.
    -- Candidate overflow is handled by the scroll frames above.
    alertBlock:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 14)

    return frame
end

RefreshCandidates = function()
    if not ui.auraCandidateList or not ui.nonAuraCandidateList then return end
    PruneCandidates()

    local function SortedCandidates(tbl)
        local list = {}
        for _, c in pairs(tbl or {}) do table.insert(list, c) end
        table.sort(list, function(a,b)
            if (a.time or 0) == (b.time or 0) then return tostring(a.name) < tostring(b.name) end
            return (a.time or 0) > (b.time or 0)
        end)
        return list
    end

    local function StatusText(c)
        local st = c.status or "New"
        if st == "Aura confirmed" then return "|cff66ff66Aura confirmed|r" end
        if st == "Invited" then return "|cff88ccffInvited|r" end
        if st == "Declined" then return "|cffffaa00Declined|r" end
        if st == "Already grouped" then return "|cffffaa00Already grouped|r" end
        if st == "Offline" then return "|cff999999Offline|r" end
        return "|cff999999New|r"
    end

    local function CandidateSummary(c)
        local role = c.role == "HEAL" and "Heal" or c.role == "TANK" and "Tank" or c.role or "?"
        local aura = c.aura == true and "Yes" or c.aura == false and "No" or "?"
        local level = c.level and tostring(c.level) or "?"
        return role .. " | Aura " .. aura .. " | L" .. level
    end

    local function RenderList(widget, source, auraList)
        local list = SortedCandidates(source)
        local rowHeight = 56
        local width = 266

        for i, c in ipairs(list) do
            local row = widget.rows[i]
            if not row then
                local frame = NewBlock(widget.child)
                frame:SetPoint("TOPLEFT", 0, -((i-1)*rowHeight))
                frame:SetSize(width, 52)

                local name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                name:SetPoint("TOPLEFT", 7, -5)
                name:SetWidth(92)
                name:SetJustifyH("LEFT")

                local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                status:SetPoint("TOPLEFT", 100, -5)
                status:SetWidth(100)
                status:SetJustifyH("LEFT")

                local message = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                message:SetPoint("TOPLEFT", 7, -24)
                message:SetWidth(150)
                message:SetHeight(22)
                message:SetJustifyH("LEFT")
                message:SetJustifyV("TOP")
                message:SetTextColor(0.72, 0.75, 0.80)

                local invite = NewButton(frame, 48, 18, "Invite")
                invite:SetPoint("TOPRIGHT", -5, -4)

                local mark = NewButton(frame, 62, 18, "Mark")
                mark:SetPoint("BOTTOMRIGHT", -5, 4)

                row = {frame=frame, name=name, status=status, message=message, invite=invite, mark=mark}
                widget.rows[i] = row
            end

            row.frame:Show()
            row.name:SetText(c.name)
            row.status:SetText(StatusText(c))
            row.message:SetText(CandidateSummary(c) .. "\n" .. (c.message or ""))
            row.invite:SetScript("OnClick", function()
                InviteUnit(c.name)
                c.status = "Invited"
                c.time = GetTime()
                Print("Invited candidate " .. c.name .. ".")
                RefreshCandidates()
            end)
            row.mark:SetScript("OnClick", function()
                Mark(c.name)
            end)

            row.frame:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(c.name)
                GameTooltip:AddLine(CandidateSummary(c), 0.75, 0.9, 1.0, true)
                GameTooltip:AddLine(c.message or "", 0.8, 0.8, 0.8, true)
                GameTooltip:AddLine(c.status or "New", 0.65, 0.75, 0.9, true)
                if auraList then
                    GameTooltip:AddLine("Applicant declares Aura", 0.4, 1.0, 0.4, true)
                else
                    GameTooltip:AddLine("Non-aura recruitment reply", 1.0, 0.8, 0.3, true)
                end
                if c.history and #c.history > 1 then
                    GameTooltip:AddLine(tostring(#c.history) .. " replies captured", 0.6, 0.65, 0.72, true)
                end
                GameTooltip:Show()
            end)
            row.frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end

        for i = #list + 1, #widget.rows do
            widget.rows[i].frame:Hide()
        end

        widget.child:SetHeight(math.max(68, #list * rowHeight))
        widget.scroll:UpdateScrollChildRect()
    end

    RenderList(ui.auraCandidateList, state.candidates, true)
    RenderList(ui.nonAuraCandidateList, state.nonAuraCandidates, false)
end
RefreshUI = function()
    if not ui.frame then return end
    local c = state.coverage
    local sensor = state.partyAuraSensor or { [1]=nil,[2]=nil,[3]=nil }
    local verified = state.verifiedCoverage or { [1]={},[2]={},[3]={} }
    local ready = RaidAuraReady(c, sensor)

    if ready then
        ui.summary:SetText("|cff66ff66Auras: 3/3 READY|r   Raid " .. GroupSize() .. "/15")
    else
        local active, unknown = 0, 0
        for g=1,3 do
            if sensor[g] == true then active=active+1
            elseif sensor[g] == nil then unknown=unknown+1 end
        end
        local suffix = unknown > 0 and "UNKNOWN" or "NOT READY"
        ui.summary:SetText("|cffffaa00Auras: " .. active .. "/3 " .. suffix ..
                           "|r   Assigned " .. CoveredParties(c) .. "/3   Raid " .. GroupSize() .. "/15")
    end

    for g = 1, 3 do
        local code = PartyHealth(g, c, sensor, verified)
        local header
        if code == "CONFIRMED" or code == "MANUAL_ACTIVE" or code == "ACTIVE_ASSIGNED" then
            header = "|cff66ff66AURA OK|r"
        elseif code == "ACTIVE_UNKNOWN" then
            header = "|cffffff66AURA / ?|r"
        elseif code == "DUPLICATE" then
            header = "|cffffaa00DUPLICATE|r"
        elseif code == "NO_AURA" or code == "INACTIVE_ASSIGNED" then
            header = "|cffff5555NO AURA|r"
        else
            header = "|cff888888UNKNOWN|r"
        end
        ui.groups[g].state:SetText(header)

        local players = {}
        for _, info in pairs(state.roster or {}) do
            if info.subgroup == g then table.insert(players, info) end
        end
        table.sort(players, function(a, b)
            if (a.raidIndex or 99) == (b.raidIndex or 99) then return a.name < b.name end
            return (a.raidIndex or 99) < (b.raidIndex or 99)
        end)

        for slot = 1, 5 do
            local row = ui.groups[g].rows[slot]
            local info = players[slot]
            if info then
                local k = Key(info.name)
                local active = info.marked or info.detected
                local roleEvidence = state.roleEvidence[k]
                local role = roleEvidence and roleEvidence.inferredRole or nil
                row.name:SetText(info.online and info.name or ("|cff777777" .. info.name .. "|r"))
                row.level:SetText((tonumber(info.level) or 0) > 0 and tostring(info.level) or "?")
                row.role:SetText(role == "TANK" and "|cff88ccffT|r" or
                                 role == "HEALER" and "|cff66ff66H|r" or "|cff777777-|r")
                row.aura.texture:SetAlpha(active and 1 or 0.18)
                if row.aura.texture.SetDesaturated then
                    row.aura.texture:SetDesaturated(not active)
                end
                row.aura:SetScript("OnClick", function() ToggleAuraProvider(info.name) end)
                row.aura:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(info.name)
                    GameTooltip:AddLine(active and "Aura provider enabled" or "Aura provider disabled", active and 0.4 or 0.65, active and 1 or 0.65, active and 0.4 or 0.65)
                    GameTooltip:AddLine("Click to toggle this player's Aura assignment.", 0.8, 0.8, 0.8, true)
                    if info.detected then GameTooltip:AddLine("Provider automatically confirmed.", 0.5, 0.8, 1, true) end
                    GameTooltip:Show()
                end)
                row.aura:SetScript("OnLeave", function() GameTooltip:Hide() end)
                row.aura:Enable()
            else
                row.name:SetText("|cff555555Empty|r")
                row.level:SetText("")
                row.role:SetText("")
                row.aura.texture:SetAlpha(0.05)
                if row.aura.texture.SetDesaturated then row.aura.texture:SetDesaturated(true) end
                row.aura:SetScript("OnClick", nil)
                row.aura:SetScript("OnEnter", nil)
                row.aura:SetScript("OnLeave", nil)
                row.aura:Disable()
            end
        end
    end

    local healthWarning = CompactHealthWarning(c, sensor, verified)
    local level59Warnings = {}
    for _, info in pairs(state.roster or {}) do
        if IsTrackedAuraProvider(info) and tonumber(info.level) == 59 then
            table.insert(level59Warnings, info.name)
        end
    end

    if #level59Warnings > 0 then
        ui.warning:SetText("|cffff5555REPLACE SOON: " ..
                           table.concat(level59Warnings, ", ") ..
                           " reached level 59.|r")
    elseif ready then
        ui.warning:SetText("|cff66ff66Raid Aura state READY.|r")
    else
        ui.warning:SetText("|cffffaa00WARNING: " .. healthWarning .. "|r")
    end

    if ui.localNote then
        if IsInManastorm() then
            ui.localNote:SetText("|cff66ff66Inside Manastorm: local Aura verification is authoritative after the entry audit.|r")
            ui.warningNote:SetText("|cff8f96a3Bright icon = provider. Click an Aura icon to toggle; subgroup sensing remains authoritative.|r")
        else
            ui.localNote:SetText("|cffffcc66Outside Manastorm: Aura verification is local-range only.|r")
            ui.warningNote:SetText("|cff8f96a3Grey icon = unassigned. Click to toggle; outside-instance sensing is range-limited.|r")
        end
    end

    local generatedMessage = GeneratedRecruitmentMessage()
    local previewText = Trim(FrostSeekAuraDB.recruitMessage or "")
    if previewText == "" then previewText = generatedMessage or "Aura recruitment not required." end
    if ui.preview and not ui.preview:HasFocus() and ui.preview:GetText() ~= previewText then
        ui.preview:SetText(previewText)
    end

    local slot = tonumber(FrostSeekAuraDB.recruitChannel) or 1
    ui.channelName:SetText("|cff88ccff" .. ChannelDisplay(slot) .. "|r")

    if FrostSeekAuraDB.recruiting then
        ui.startBtn:SetLabel("Running...")
        ui.startBtn.text:SetTextColor(0.4,1,0.4)
    else
        ui.startBtn:SetLabel("Repeat")
        ui.startBtn.text:SetTextColor(1,1,1)
    end

    if ui.overlayBtn then
        ui.overlayBtn:SetLabel(FrostSeekAuraDB.overlay.shown and "Overlay Shown" or "Show Overlay")
    end

    RefreshCandidates()
end
function Module:Initialize(parentFrame)
    if self.frame then return end
    self.frame = CreateUI(parentFrame)
    RefreshUI()
end

function Module:Show()
    if self.frame then
        self.frame:Show()
        Scan(true)
    end
end

function Module:Hide()
    if self.frame then self.frame:Hide() end
end

function Module:ApplyTheme()
    -- Current test build reads theme colors on frame creation.
    -- Full live theme refresh can be added after compatibility testing.
end

-- ============================================================================
-- FrostSeek integration
-- ============================================================================

local function IntegrateWithFrostSeek()
    local FS = _G.FrostSeek
    if not FS or not FS.MainFrame or not FS.MainFrame.ContentFrame then
        return false
    end
    if not FS.CreateModernTab or not FS.RegisterModule then
        return false
    end

    if FS.Tabs and FS.Tabs["auras"] then
        return true
    end

    local tab = FS:CreateModernTab("auras", "Auras")

    -- Insert between LFM and Community when those stock v2.2.5 tabs exist.
    local lfm = _G["FrostSeekTab_lfm"]
    local community = _G["FrostSeekTab_community"]
    local options = _G["FrostSeekTab_options"]

    if lfm then
        tab:ClearAllPoints()
        tab:SetPoint("LEFT", lfm, "RIGHT", 2, 0)

        if community then
            community:ClearAllPoints()
            community:SetPoint("LEFT", tab, "RIGHT", 2, 0)
        end
        if options and community then
            options:ClearAllPoints()
            options:SetPoint("LEFT", community, "RIGHT", 2, 0)
        end
    else
        tab:SetPoint("RIGHT", FS.MainFrame.TabFrame, "RIGHT", 0, 0)
    end

    tab:SetScript("OnEnter", function(self)
        if FS.ActiveTab ~= "auras" then
            if self.highlight then self.highlight:Show() end
            if self.text then self.text:SetTextColor(0.65,0.85,1) end
        end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Manastorm Auras")
        GameTooltip:AddLine("Recruit and track one Aura of Experience player in each of the three Manastorm parties.", 0.8,0.8,0.8,true)
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if FS.ActiveTab ~= "auras" then
            if self.highlight then self.highlight:Hide() end
            local c = ThemeColor("textMuted", {0.6,0.6,0.6,1})
            if self.text then self.text:SetTextColor(c[1],c[2],c[3]) end
        end
    end)

    FS:RegisterModule("auras", Module)
    Module:Initialize(FS.MainFrame.ContentFrame)

    if _G.FrostSeekTheme and _G.FrostSeekTheme.RegisterModule then
        pcall(_G.FrostSeekTheme.RegisterModule, "auras")
    end

    Print("Integrated into FrostSeek as the |cff88ccffAuras|r tab.")
    return true
end

local RegisterFrostSeekAuraSlashCommands

-- ============================================================================
-- Events / whispers / timer
-- ============================================================================

FSA:RegisterEvent("ADDON_LOADED")
FSA:RegisterEvent("PLAYER_LOGIN")
FSA:RegisterEvent("PLAYER_ENTERING_WORLD")
FSA:RegisterEvent("RAID_ROSTER_UPDATE")
FSA:RegisterEvent("PARTY_MEMBERS_CHANGED")
FSA:RegisterEvent("UNIT_AURA")
FSA:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
FSA:RegisterEvent("CHAT_MSG_WHISPER")
FSA:RegisterEvent("CHAT_MSG_SYSTEM")
FSA:RegisterEvent("CHAT_MSG_PARTY")
FSA:RegisterEvent("CHAT_MSG_PARTY_LEADER")
FSA:RegisterEvent("CHAT_MSG_RAID")
FSA:RegisterEvent("CHAT_MSG_RAID_LEADER")
FSA:RegisterEvent("CHAT_MSG_RAID_WARNING")
FSA:RegisterEvent("ZONE_CHANGED_NEW_AREA")

local integrationElapsed = 0
local integrated = false

FSA:SetScript("OnEvent", function(self, event, ...)
    local arg1, arg2 = ...
    if event == "ADDON_LOADED" and arg1 == ADDON then
        FrostSeekAuraDB = MergeDefaults(defaults, FrostSeekAuraDB or {})
        FrostSeekAuraDB.knownAuraPlayers = FrostSeekAuraDB.knownAuraPlayers or {}
        FrostSeekAuraDB.manualProviders = FrostSeekAuraDB.manualProviders or {}

        -- v0.6.9-v0.6.12 incorrectly learned recipients from C_Aura as
        -- providers. Clear that contaminated cache once on migration.
        if (FrostSeekAuraDB.providerCacheMigration or 0) < 1 then
            FrostSeekAuraDB.knownAuraPlayers = {}
            FrostSeekAuraDB.providerCacheMigration = 1
            Print("Cleared legacy Aura-provider cache; recipients are no longer learned as providers.")
        end

        EnsureResearchState()
        -- Migration from v0.1 which used channel name "world"
        if type(FrostSeekAuraDB.channel) == "string" then
            FrostSeekAuraDB.channel = nil
            FrostSeekAuraDB.recruitChannel = 1
        end
        if not FrostSeekAuraDB.recruitChannel then FrostSeekAuraDB.recruitChannel = 1 end
        CreateOverlay()
        RefreshOverlay()
        Print("Loaded Aura Tracker v" .. VERSION)
        state.pendingScan = 0.5

    elseif event == "PLAYER_LOGIN" then
        integrated = FrostSeekDependencyReady() and IntegrateWithFrostSeek()
        CreateOverlay()
        RegisterFrostSeekAuraSlashCommands(true)
        state.pendingScan = 0.5

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        local nowMS = IsInManastorm()
        if nowMS and not state.lastManastormState then
            state.manastormEntryGraceUntil = GetTime() + 5
            state.manastormAuditDue = state.manastormEntryGraceUntil
            state.pendingDistributionAlert = nil
        elseif not nowMS then
            state.manastormEntryGraceUntil = nil
            state.manastormAuditDue = nil
        end
        state.lastManastormState = nowMS
        state.pendingScan = nowMS and 5 or 0.35

    elseif event == "RAID_ROSTER_UPDATE" or
           event == "PARTY_MEMBERS_CHANGED" then
        state.pendingScan = 0.35

    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local timestamp, subevent, sourceGUID, sourceName, sourceFlags,
              destGUID, destName, destFlags, a1, a2, a3, a4, a5 = ...
        RecordCombatRoleEvidence(subevent, sourceName, destName, a1, a2, a3, a4, a5)

    elseif event == "UNIT_AURA" then
        if arg1 == "player" or
           (arg1 and string.find(arg1, "raid", 1, true) == 1) or
           (arg1 and string.find(arg1, "party", 1, true) == 1) then
            state.pendingScan = 0.25
        end

        EnsureResearchState()
        if false and state.research.active and arg1 then
            local eventName = UnitExists(arg1) and ShortName(UnitName(arg1)) or nil
            if arg1 == state.research.targetUnit or
               (eventName and Key(eventName) == Key(state.research.targetName)) then
                state.research.unitAuraEvents = state.research.unitAuraEvents + 1
                if state.research.unitAuraEvents <= 5 then
                    ResearchPrint("UNIT_AURA -> " .. tostring(arg1) ..
                                  " (" .. tostring(eventName or "?") .. ")")
                end
            end
        end

    elseif event == "CHAT_MSG_SYSTEM" then
        local message = tostring(arg1 or "")
        local who = string.match(message, "^(.+) declines your group invitation")
        local status = "Declined"

        if not who then
            who = string.match(message, "^(.+) is already in a group")
            status = "Already grouped"
        end
        if not who then
            who = string.match(message, "No player named ['\"]?([^'\"]+)['\"]? is currently playing")
            status = "Offline"
        end

        if who then
            local k = Key(who)
            local c = state.candidates[k] or state.nonAuraCandidates[k]
            if c then
                c.status = status
                c.time = GetTime()
                if RefreshCandidates then RefreshCandidates() end
            end
        end

    elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER" or
           event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" or
           event == "CHAT_MSG_RAID_WARNING" then
        RecordGroupChat(event, arg1, arg2)

    elseif event == "CHAT_MSG_WHISPER" then
        local message = arg1 or ""
        local sender = ShortName(arg2)

        if sender and IsInManastorm() then
            if FrostSeekAuraDB.autoApplicantReplies then
                SendChatMessage(MessageTemplate("insideManastorm"), "WHISPER", nil, sender)
            end
        elseif sender and RecruitmentReplyWindowOpen() then
            local k = Key(sender)
            local previous = state.candidates[k] or state.nonAuraCandidates[k]
            local duplicateReply = previous and previous.message == message and
                                   (GetTime() - (previous.time or 0)) < 3
            local parsed = ParseRecruitmentReply(message, previous)
            local entry = previous or { name = sender, status = "New", history = {} }
            entry.name = sender
            entry.message = message
            entry.time = GetTime()
            entry.role = parsed.role
            entry.aura = parsed.aura
            entry.level = parsed.level
            entry.complete = parsed.complete
            entry.history = entry.history or {}
            table.insert(entry.history, { message = message, time = entry.time })
            while #entry.history > 10 do table.remove(entry.history, 1) end

            if parsed.exactAura or parsed.aura == true then
                state.candidates[k] = entry
                state.nonAuraCandidates[k] = nil
                if not duplicateReply then
                    Print("Aura candidate: " .. sender .. " - role " .. tostring(entry.role or "unknown") ..
                          ", level " .. tostring(entry.level or "?") .. ".")
                end

                -- Preserve the existing safety boundary: automatic invites
                -- still require the exact single-word Aura response.
                if parsed.exactAura and FrostSeekAuraDB.autoInviteAuraWhispers and entry.status ~= "Invited" then
                    InviteUnit(sender)
                    entry.status = "Invited"
                    Print("Auto-invited Aura candidate " .. sender .. ".")
                end
            else
                state.nonAuraCandidates[k] = entry
                state.candidates[k] = nil
                if not duplicateReply then
                    Print("Recruitment reply: " .. sender .. " - role " .. tostring(entry.role or "unknown") ..
                          ", Aura " .. (entry.aura == nil and "unknown" or entry.aura and "yes" or "no") ..
                          ", level " .. tostring(entry.level or "?") .. ".")
                end
            end

            SendCandidateReply(entry)
            if RefreshCandidates then RefreshCandidates() end
        end
    end
end)

FSA:SetScript("OnUpdate", function(self, elapsed)
    if not integrated then
        integrationElapsed = integrationElapsed + elapsed
        if integrationElapsed >= 1 then
            integrationElapsed = 0
            integrated = FrostSeekDependencyReady() and IntegrateWithFrostSeek()
        end
    end

    if state.pendingScan then
        state.pendingScan = state.pendingScan - elapsed
        if state.pendingScan <= 0 then
            state.pendingScan = nil
            Scan(true)
        end
    end

    if state.manastormAuditDue and GetTime() >= state.manastormAuditDue then
        state.manastormAuditDue = nil
        -- Establish the fully loaded roster/Aura state as the new baseline.
        -- This scan must not also schedule the normal distribution message,
        -- otherwise the entry audit can be followed by a duplicate alert.
        Scan(true, true)
        state.pendingDistributionAlert = nil
        state.manastormEntryGraceUntil = nil
        local parts = {}
        for g=1,3 do
            local code = PartyHealth(g, state.coverage, state.partyAuraSensor, state.verifiedCoverage)
            local ok = (code == "CONFIRMED" or code == "MANUAL_ACTIVE" or
                        code == "ACTIVE_ASSIGNED" or code == "ACTIVE_UNKNOWN")
            table.insert(parts, "P" .. g .. (ok and " OK" or " MISSING"))
        end
        local missing = RecruitmentMissingGroups(state.coverage, state.partyAuraSensor)
        local suffix = #missing == 0 and "raid ready." or
                       ("need Aura for " .. table.concat((function()
                            local t={} for _,g in ipairs(missing) do table.insert(t,"P"..g) end
                            return t
                        end)(), " + ") .. ".")
        GroupChat("Manastorm check: " .. table.concat(parts, "  ") .. " - " .. suffix)
    end

    if state.pendingDistributionAlert and GetTime() >= (state.pendingDistributionAlert.due or 0) then
        local pending = state.pendingDistributionAlert
        state.pendingDistributionAlert = nil
        local currentSig = PartyHealthSignature(state.coverage, state.partyAuraSensor, state.verifiedCoverage)

        if currentSig == pending.signature then
            local healthyMessage = AllGroupsReportingAuraMessage(
                state.coverage, state.partyAuraSensor, state.verifiedCoverage)
            if healthyMessage then
                if FrostSeekAuraDB.announceRestored or FrostSeekAuraDB.announceDistribution then
                    GroupChat(healthyMessage)
                end
            elseif pending.restored then
                if FrostSeekAuraDB.announceRestored then
                    GroupChat("Aura coverage restored: P1 OK P2 OK P3 OK.")
                end
            elseif FrostSeekAuraDB.announceDistribution then
                GroupChat("Incorrect Aura distribution: " ..
                          ReasonAwareWarning(state.coverage, state.partyAuraSensor, state.verifiedCoverage))
                PlayAuraAlertSound()
            end
        end
    end

    state.candidatePruneElapsed = state.candidatePruneElapsed + elapsed
    if state.candidatePruneElapsed >= 5 then
        state.candidatePruneElapsed = 0
        PruneCandidates()
        if RefreshCandidates then RefreshCandidates() end
    end

    state.roleUpdateElapsed = state.roleUpdateElapsed + elapsed
    if state.roleUpdateElapsed >= 2 then
        state.roleUpdateElapsed = 0
        UpdateInferredRoles()
        if overlay.frame and overlay.frame:IsShown() then RefreshOverlay() end
    end

    if FrostSeekAuraDB and FrostSeekAuraDB.periodicScan then
        state.periodicElapsed = state.periodicElapsed + elapsed
        local every = tonumber(FrostSeekAuraDB.periodicScanInterval) or 5
        if every < 2 then every = 2 end
        if state.periodicElapsed >= every then
            state.periodicElapsed = 0
            Scan(true)
        end
    end

    if FrostSeekAuraDB and FrostSeekAuraDB.recruiting then
        state.recruitElapsed = state.recruitElapsed + elapsed
        local interval = tonumber(FrostSeekAuraDB.recruitInterval) or 60
        if interval < 30 then interval = 30 end
        if state.recruitElapsed >= interval then
            state.recruitElapsed = 0
            if RaidAuraReady(state.coverage, state.partyAuraSensor or {}) then
                FrostSeekAuraDB.recruiting = false
                Print("Aura recruitment stopped automatically: raid Aura state is ready.")
                if RefreshUI then RefreshUI() end
            else
                SendRecruitment()
            end
        end
    end
end)

-- ============================================================================
-- Diagnostic / fallback slash commands
-- Normal operation should be through the FrostSeek Auras tab.
-- ============================================================================

local function FrostSeekAuraSlashHandler(msg)
    local cmd, rest = string.match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")

    if cmd == "" or cmd == "show" then
        local FS = _G.FrostSeek
        if FS and FS.MainFrame and FS.SwitchTab then
            FS.MainFrame:Show()
            FS:SwitchTab("auras")
        else
            Print("FrostSeek UI not available.")
        end

    elseif cmd == "overlay" then
        FrostSeekAuraDB.overlay.shown = true
        CreateOverlay()
        overlay.frame:Show()
        RefreshOverlay()

    elseif cmd == "scan" then
        Print("Manual scan requested.")
        Scan(false)

    elseif cmd == "mark" then
        Mark(rest)

    elseif cmd == "unmark" then
        Unmark(rest)

    elseif cmd == "forget" then
        ClearKnownAuraCache(rest)

    elseif cmd == "recruit" then
        SendRecruitment()

    elseif cmd == "chat" then
        local first = math.max(1, #state.groupChat - 7)
        if #state.groupChat == 0 then
            Print("No recent party or raid messages captured.")
        else
            Print("Recent group chat:")
            for i = first, #state.groupChat do
                local item = state.groupChat[i]
                Print("[" .. item.channel .. "] " .. item.sender .. ": " .. item.message)
            end
        end

    elseif cmd == "say" then
        if rest == "" then
            Print("Usage: /fsaura say <message>")
        elseif RaidCount() > 0 then
            SendChatMessage(rest, "RAID")
        elseif PartyCount() > 0 then
            SendChatMessage(rest, "PARTY")
        else
            Print("Join a party or raid before sending a group message.")
        end

    elseif cmd == "messages" then
        Print("Recruitment message templates:")
        for _, key in ipairs({"missingRole", "missingAura", "missingLevel", "accepted", "insideManastorm"}) do
            Print(key .. ": " .. MessageTemplate(key))
        end

    elseif cmd == "message" then
        local key, value = string.match(rest or "", "^(%S+)%s*(.-)%s*$")
        if string.lower(key or "") == "reset" then
            FrostSeekAuraDB.messages = {}
            for defaultKey, defaultValue in pairs(MESSAGE_DEFAULTS) do
                FrostSeekAuraDB.messages[defaultKey] = defaultValue
            end
            Print("Recruitment message templates reset.")
        elseif not key or MESSAGE_DEFAULTS[key] == nil or value == "" then
            Print("Usage: /fsaura message <missingRole|missingAura|missingLevel|accepted|insideManastorm> <text>")
        else
            FrostSeekAuraDB.messages[key] = value
            Print("Updated message template " .. key .. ".")
        end

    elseif cmd == "sensors" then
        Scan(true)
        local ps = state.partyAuraSensor or {}
        Print("Party sensors: P1=" .. PartySensorText(ps[1]) ..
              " P2=" .. PartySensorText(ps[2]) ..
              " P3=" .. PartySensorText(ps[3]) .. ".")

    elseif cmd == "roles" then
        UpdateInferredRoles()
        local tanks = InferredRoleNames("TANK")
        local healers = InferredRoleNames("HEALER")
        Print("Combat roles - Tanks: " .. (#tanks > 0 and table.concat(tanks, ", ") or "learning") ..
              "; Healers: " .. (#healers > 0 and table.concat(healers, ", ") or "learning") .. ".")

    elseif cmd == "rolesreset" then
        state.roleEvidence = {}
        UpdateInferredRoles()
        RefreshOverlay()
        Print("Combat role evidence reset.")

    elseif cmd == "debug" then
        Print("Debug state: " .. tostring(CoveredParties(state.coverage)) ..
              "/3 assigned, " .. tostring(CoveredParties(state.verifiedCoverage)) ..
              "/3 verified.")

    else
        Print("/fsaura show | overlay | scan | sensors | roles | rolesreset | mark <name> | unmark <name> | forget [name] | recruit | chat | say <text> | messages | message <key> <text> | debug")
    end
end

RegisterFrostSeekAuraSlashCommands = function(verbose)
    _G["SLASH_FROSTSEEKAURA1"] = "/fsaura"
    _G["SLASH_FROSTSEEKAURA2"] = "/fsa"
    SlashCmdList["FROSTSEEKAURA"] = FrostSeekAuraSlashHandler

    -- Some 3.3.5/Ascension UI builds build a hash of slash commands.
    -- Re-import our registration when those internals are available.
    if type(_G.ChatFrame_ImportListToHash) == "function" and
       type(_G.hash_SlashCmdList) == "table" then
        pcall(_G.ChatFrame_ImportListToHash, SlashCmdList, _G.hash_SlashCmdList)
    elseif type(_G.ChatFrame_ImportAllListsToHash) == "function" then
        pcall(_G.ChatFrame_ImportAllListsToHash)
    end

    if verbose then
        Print("Commands ready: /fsaura and /fsa")
    end
end

-- Register immediately, then again after the rest of the UI/addons initialize.
RegisterFrostSeekAuraSlashCommands(false)
