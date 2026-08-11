-- ============================================================================
-- FrostSeek Aura Tracker v1.1.4
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
local VERSION = "1.1.4"
local REQUIRED_FROSTSEEK_VERSION = "2.2.5"
local dependencyWarningShown = false

local defaults = {
    marked = {},                 -- [lowercaseName] = displayName
    knownAuraPlayers = {},       -- [lowercaseName] = displayName, confirmed PROVIDERS only (manual or unitCaster)
    providerCacheMigration = 0,
    inferProviderOnCoverageTransition = true,
    recruitChannel = 1,         -- IMPORTANT: Ascension is channel slot 1 by default
    recruitInterval = 60,
    recruiting = false,
    autoInviteAuraWhispers = false, -- exact trimmed/case-insensitive "aura" only
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
    candidatePruneElapsed = 0,
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

local function Trim(text)
    text = tostring(text or "")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    return text
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
ßN4æÚ$z{-®éÜj×r‚¢66â‡G'VR¢Væ@¦Væ@ ¦gVæ7F–öâÖöGVÆS¤†–FR‚¢–b6VÆbæg&ÖRF†Vâ6VÆbæg&ÖS¤†–FR‚’Væ@¦Væ@ ¦gVæ7F–öâÖöGVÆS¤Ç•F†VÖR‚¢ÒÒ7W'&VçBFW7B'V–ÆB&VG2F†VÖR6öÆ÷'2öâg&ÖR7&VF–öâà¢ÒÒgVÆÂÆ—fRF†VÖR&Vg&W6‚6â&RFFVBgFW"6ö×F–&–Æ—G’FW7F–ærà¦Væ@ ¢ÒÒÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ¢ÒÒg&÷7E6VV²–çFVw&F–öà¢ÒÒÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ ¦Æö6ÂgVæ7F–öâ–çFVw&FUv—F„g&÷7E6VV²‚¢Æö6Âe2Òôräg&÷7E6VV°¢–bæ÷Be2÷"æ÷Be2äÖ–äg&ÖR÷"æ÷Be2äÖ–äg&ÖRä6öçFVçDg&ÖRF†Và¢&WGW&âfÇ6P¢Væ@¢–bæ÷Be2ä7&VFTÖöFW&åF"÷"æ÷Be2å&Vv—7FW$ÖöGVÆRF†Và¢&WGW&âfÇ6P¢Væ@ ¢–be2åF'2æBe2åF'5²&W&2%ÒF†Và¢&WGW&âG'VP¢Væ@ ¢Æö6ÂF"Òe3¤7&VFTÖöFW&åF"‚&W&2"Â$W&2" ¢ÒÒ–ç6W'B&WGvVVâÄdÒæB6öÖ×Væ—G’v†VâF†÷6R7Fö6²c"ã"ãRF'2W†—7Bà¢Æö6ÂÆfÒÒôu²$g&÷7E6VVµF%öÆfÒ%Ð¢Æö6Â6öÖ×Væ—G’Òôu²$g&÷7E6VVµF%ö6öÖ×Væ—G’%Ð¢Æö6Â÷F–öç2Òôu²$g&÷7E6VVµF%ö÷F–öç2%Ð ¢–bÆfÒF†Và¢F#¤6ÆV$ÆÅö–çG2‚¢F#¥6WEö–çB‚$ÄTeB"ÂÆfÒÂ%$”t…B"Â"Â ¢–b6öÖ×Væ—G’F†Và¢6öÖ×Væ—G“¤6ÆV$ÆÅö–çG2‚¢6öÖ×Væ—G“¥6WEö–çB‚$ÄTeB"ÂF"Â%$”t…B"Â"Â¢Væ@¢–b÷F–öç2æB6öÖ×Væ—G’F†Và¢÷F–öç3¤6ÆV$ÆÅö–çG2‚¢÷F–öç3¥6WEö–çB‚$ÄTeB"Â6öÖ×Væ—G’Â%$”t…B"Â"Â¢Væ@¢VÇ6P¢F#¥6WEö–çB‚%$”t…B"Âe2äÖ–äg&ÖRåF$g&ÖRÂ%$”t…B"ÂÂ¢Væ@ ¢F#¥6WE67&—B‚$öäVçFW""ÂgVæ7F–öâ‡6VÆb¢–be2ä7F—fUF"ãÒ&W&2"F†Và¢–b6VÆbæ†–v†Æ–v‡BF†Vâ6VÆbæ†–v†Æ–v‡C¥6†÷r‚’Væ@¢–b6VÆbçFW‡BF†Vâ6VÆbçFW‡C¥6WEFW‡D6öÆ÷"ƒãcRÃãƒRÃ’Væ@¢Væ@¢vÖUFööÇF—¥6WD÷væW"‡6VÆbÂ$ä4„õ%õDõ"¢vÖUFööÇF—¥6WEFW‡B‚$Öæ7F÷&ÒW&2"¢vÖUFööÇF—¤FDÆ–æR‚%&V7'V—BæBG&6²öæRW&öbW‡W&–Væ6RÆ–W"–âV6‚öbF†RF‡&VRÖæ7F÷&Ò'F–W2â"Âã‚Ãã‚Ãã‚ÇG'VR¢vÖUFööÇF—¥6†÷r‚¢VæB¢F#¥6WE67&—B‚$öäÆVfR"ÂgVæ7F–öâ‡6VÆb¢vÖUFööÇF—¤†–FR‚¢–be2ä7F—fUF"ãÒ&W&2"F†Và¢–b6VÆbæ†–v†Æ–v‡BF†Vâ6VÆbæ†–v†Æ–v‡C¤†–FR‚’Væ@¢Æö6Â2ÒF†VÖT6öÆ÷"‚'FW‡D×WFVB"Â³ãbÃãbÃãbÃÒ¢–b6VÆbçFW‡BF†Vâ6VÆbçFW‡C¥6WEFW‡D6öÆ÷"†5³ÒÆ5³%ÒÆ5³5Ò’Væ@¢Væ@¢VæB ¢e3¥&Vv—7FW$ÖöGVÆR‚&W&2"ÂÖöGVÆR¢ÖöGVÆS¤–æ—F–Æ—¦R„e2äÖ–äg&ÖRä6öçFVçDg&ÖR ¢–bôräg&÷7E6VVµF†VÖRæBôräg&÷7E6VVµF†VÖRå&Vv—7FW$ÖöGVÆRF†Và¢6ÆÂ…ôräg&÷7E6VVµF†VÖRå&Vv—7FW$ÖöGVÆRÂ&W&2"¢Væ@ ¢&–çB‚$–çFVw&FVB–çFòg&÷7E6VV²2F†RÆ6fcƒ†66fdW&7Ç"F"â"¢&WGW&âG'VP¦Væ@ ¦Æö6Â&Vv—7FW$g&÷7E6VV´W&6Æ6„6öÖÖæG0 ¢ÒÒÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ¢ÒÒWfVçG2òv†—7W'2òF–ÖW ¢ÒÒÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ ¤e4¥&Vv—7FW$WfVçB‚$DDôåôÄôDTB"¤e4¥&Vv—7FW$WfVçB‚%Ä”U%ôÄôt”â"¤e4¥&Vv—7FW$WfVçB‚%Ä”U%ôTåDU$”äuõtõ$ÄB"¤e4¥&Vv—7FW$WfVçB‚%$”Eõ$õ5DU%õUDDR"¤e4¥&Vv—7FW$WfVçB‚%%E•ôÔTÔ$U%5ô4„ätTB"¤e4¥&Vv—7FW$WfVçB‚%Tä•EôU$"¤e4¥&Vv—7FW$WfVçB‚$4„EôÕ4uõt„•5U""¤e4¥&Vv—7FW$WfVçB‚$4„EôÕ4uõ5•5DTÒ"¤e4¥&Vv—7FW$WfVçB‚%¤ôäUô4„ätTEôäUuô$T" ¦Æö6Â–çFVw&F–öäVÆ6VBÒ ¦Æö6Â–çFVw&FVBÒfÇ6P ¤e4¥6WE67&—B‚$öäWfVçB"ÂgVæ7F–öâ‡6VÆbÂWfVçBÂ&sÂ&s"¢–bWfVçBÓÒ$DDôåôÄôDTB"æB&sÓÒDDôâF†Và¢g&÷7E6VV´W&D"ÒÖW&vTFVfVÇG2†FVfVÇG2Âg&÷7E6VV´W&D"÷"·Ò¢g&÷7E6VV´W&D"æ¶æ÷väW&Æ–W'2Òg&÷7E6VV´W&D"æ¶æ÷väW&Æ–W'2÷"·Ð¢g&÷7E6VV´W&D"æÖçVÅ&÷f–FW'2Òg&÷7E6VV´W&D"æÖçVÅ&÷f–FW'2÷"·Ð ¢ÒÒcãbã’×cãbã"–æ6÷'&V7FÇ’ÆV&æVB&V6—–VçG2g&öÒ5ôW&0¢ÒÒ&÷f–FW'2â6ÆV"F†B6öçFÖ–æFVB66†Röæ6RöâÖ–w&F–öâà¢–b„g&÷7E6VV´W&D"ç&÷f–FW$66†TÖ–w&F–öâ÷"’ÂF†Và¢g&÷7E6VV´W&D"æ¶æ÷väW&Æ–W'2Ò·Ð¢g&÷7E6VV´W&D"ç&÷f–FW$66†TÖ–w&F–öâÒ¢&–çB‚$6ÆV&VBÆVv7’W&×&÷f–FW"66†S²&V6—–VçG2&RæòÆöævW"ÆV&æVB2&÷f–FW'2â"¢Væ@ ¢Vç7W&U&W6V&6…7FFR‚¢ÒÒÖ–w&F–öâg&öÒcãv†–6‚W6VB6†ææVÂæÖR'v÷&ÆB ¢–bG—R„g&÷7E6VV´W&D"æ6†ææVÂ’ÓÒ'7G&–ær"F†Và¢g&÷7E6VV´W&D"æ6†ææVÂÒæ–À¢g&÷7E6VV´W&D"ç&V7'V—D6†ææVÂÒ¢Væ@¢–bæ÷Bg&÷7E6VV´W&D"ç&V7'V—D6†ææVÂF†Vâg&÷7E6VV´W&D"ç&V7'V—D6†ææVÂÒVæ@¢7&VFT÷fW&Æ’‚¢&Vg&W6„÷fW&Æ’‚¢&–çB‚$ÆöFVBW&G&6¶W"b"ââdU%4”ôâ¢7FFRçVæF–æu66âÒãP ¢VÇ6V–bWfVçBÓÒ%Ä”U%ôÄôt”â"F†Và¢–çFVw&FVBÒg&÷7E6VV´FWVæFVæ7•&VG’‚’æB–çFVw&FUv—F„g&÷7E6VV²‚¢7&VFT÷fW&Æ’‚¢&Vv—7FW$g&÷7E6VV´W&6Æ6„6öÖÖæG2‡G'VR¢7FFRçVæF–æu66âÒãP ¢VÇ6V–bWfVçBÓÒ%Ä”U%ôTåDU$”äuõtõ$ÄB"÷"WfVçBÓÒ%¤ôäUô4„ätTEôäUuô$T"F†Và¢Æö6Âæ÷tÕ2Ò—4–äÖæ7F÷&Ò‚¢–bæ÷tÕ2æBæ÷B7FFRæÆ7DÖæ7F÷&Õ7FFRF†Và¢7FFRæÖæ7F÷&ÔVF—DGVRÒvWEF–ÖR‚’²"ãP¢Væ@¢7FFRæÆ7DÖæ7F÷&Õ7FFRÒæ÷tÕ0¢7FFRçVæF–æu66âÒæ÷tÕ2æB"ãR÷"ã3P ¢VÇ6V–bWfVçBÓÒ%$”Eõ$õ5DU%õUDDR"÷ ¢WfVçBÓÒ%%E•ôÔTÔ$U%5ô4„ätTB"F†Và¢7FFRçVæF–æu66âÒã3P ¢VÇ6V–bWfVçBÓÒ%Tä•EôU$"F†Và¢–b&sÓÒ'Æ–W""÷ ¢†&sæB7G&–æræf–æB†&sÂ'&–B"ÂÂG'VR’ÓÒ’÷ ¢†&sæB7G&–æræf–æB†&sÂ''G’"ÂÂG'VR’ÓÒ’F†Và¢7FFRçVæF–æu66âÒã#P¢Væ@ ¢Vç7W&U&W6V&6…7FFR‚¢–bfÇ6RæB7FFRç&W6V&6‚æ7F—fRæB&sF†Và¢Æö6ÂWfVçDæÖRÒVæ—DW†—7G2†&s’æB6†÷'DæÖR…Væ—DæÖR†&s’’÷"æ–À¢–b&sÓÒ7FFRç&W6V&6‚çF&vWEVæ—B÷ ¢†WfVçDæÖRæB¶W’†WfVçDæÖR’ÓÒ¶W’‡7FFRç&W6V&6‚çF&vWDæÖR’’F†Và¢7FFRç&W6V&6‚çVæ—DW&WfVçG2Ò7FFRç&W6V&6‚çVæ—DW&WfVçG2²¢–b7FFRç&W6V&6‚çVæ—DW&WfVçG2ÃÒRF†Và¢&W6V&6…&–çB‚%Tä•EôU$Óâ"ââF÷7G&–ær†&s’âà¢"‚"ââF÷7G&–ær†WfVçDæÖR÷"#ò"’ââ"’"¢Væ@¢Væ@¢Væ@ ¢VÇ6V–bWfVçBÓÒ$4„EôÕ4uõ5•5DTÒ"F†Và¢Æö6ÂÖW76vRÒF÷7G&–ær†&s÷"""¢Æö6Âv†òÒ7G&–æræÖF6‚†ÖW76vRÂ%â‚â²’FV6Æ–æW2–÷W"w&÷W–çf—FF–öâ"¢Æö6Â7FGW2Ò$FV6Æ–æVB  ¢–bæ÷Bv†òF†Và¢v†òÒ7G&–æræÖF6‚†ÖW76vRÂ%â‚â²’—2Ç&VG’–âw&÷W"¢7FGW2Ò$Ç&VG’w&÷WVB ¢Væ@¢–bæ÷Bv†òF†Và¢v†òÒ7G&–æræÖF6‚†ÖW76vRÂ$æòÆ–W"æÖVB²uÂ%Óò…µâuÂ%Ò²•²uÂ%Óò—27W'&VçFÇ’Æ––ær"¢7FGW2Ò$öffÆ–æR ¢Væ@ ¢–bv†òF†Và¢Æö6Â²Ò¶W’‡v†ò¢Æö6Â2Ò7FFRæ6æF–FFW5¶µÒ÷"7FFRææöäW&6æF–FFW5¶µÐ¢–b2F†Và¢2ç7FGW2Ò7FGW0¢2çF–ÖRÒvWEF–ÖR‚¢–b&Vg&W6„6æF–FFW2F†Vâ&Vg&W6„6æF–FFW2‚’Væ@¢Væ@¢Væ@ ¢VÇ6V–bWfVçBÓÒ$4„EôÕ4uõt„•5U""F†Và¢Æö6ÂÖW76vRÒ&s÷"" ¢Æö6Â6VæFW"Ò6†÷'DæÖR†&s" ¢–b6VæFW"æB&V7'V—FÖVçE&WÇ•v–æF÷t÷Vâ‚’F†Và¢Æö6Â²Ò¶W’‡6VæFW"¢Æö6ÂVçG'’Ò°¢æÖRÒ6VæFW"À¢ÖW76vRÒÖW76vRÀ¢F–ÖRÒvWEF–ÖR‚’À¢Ð ¢Æö6Â&Wf–÷W2Ò7FFRæ6æF–FFW5¶µÒ÷"7FFRææöäW&6æF–FFW5¶µÐ¢Æö6ÂGWÆ–6FU&WÇ’Ò&Wf–÷W2æB&Wf–÷W2æÖW76vRÓÒÖW76vRæ@¢„vWEF–ÖR‚’Ò‡&Wf–÷W2çF–ÖR÷"’’Â0 ¢–b—4W†7DW&&WÇ’†ÖW76vR’F†Và¢VçG'’ç7FGW2Ò&Wf–÷W2æB&Wf–÷W2ç7FGW2÷"$æWr ¢7FFRæ6æF–FFW5¶µÒÒVçG'¢7FFRææöäW&6æF–FFW5¶µÒÒæ–À¢–bæ÷BGWÆ–6FU&WÇ’F†Và¢&–çB‚$W&6æF–FFS¢"ââ6VæFW"ââ"v†—7W&VBW†7B¶W—v÷&BÂ&W&Â"â"¢Væ@ ¢–bg&÷7E6VV´W&D"æWFô–çf—FTW&v†—7W'2æBVçG'’ç7FGW2ãÒ$–çf—FVB"F†Và¢–çf—FUVæ—B‡6VæFW"¢VçG'’ç7FGW2Ò$–çf—FVB ¢&–çB‚$WFòÖ–çf—FVBW&6æF–FFR"ââ6VæFW"ââ"â"¢Væ@¢VÇ6P¢VçG'’ç7FGW2Ò&Wf–÷W2æB&Wf–÷W2ç7FGW2÷"$æWr ¢7FFRææöäW&6æF–FFW5¶µÒÒVçG'¢7FFRæ6æF–FFW5¶µÒÒæ–À¢–bæ÷BGWÆ–6FU&WÇ’F†Và¢&–çB‚$æöâÖW&6æF–FFS¢"ââ6VæFW"ââ"v†—7W&VBÂ""ââÖW76vRââ%Â"â"¢Væ@¢Væ@ ¢–b&Vg&W6„6æF–FFW2F†Vâ&Vg&W6„6æF–FFW2‚’Væ@¢Væ@¢Væ@¦VæB ¤e4¥6WE67&—B‚$öåWFFR"ÂgVæ7F–öâ‡6VÆbÂVÆ6VB¢–bæ÷B–çFVw&FVBF†Và¢–çFVw&F–öäVÆ6VBÒ–çFVw&F–öäVÆ6VB²VÆ6V@¢–b–çFVw&F–öäVÆ6VBãÒF†Và¢–çFVw&F–öäVÆ6VBÒ ¢–çFVw&FVBÒg&÷7E6VV´FWVæFVæ7•&VG’‚’æB–çFVw&FUv—F„g&÷7E6VV²‚¢Væ@¢Væ@ ¢–b7FFRçVæF–æu66âF†Và¢7FFRçVæF–æu66âÒ7FFRçVæF–æu66âÒVÆ6V@¢–b7FFRçVæF–æu66âÃÒF†Và¢7FFRçVæF–æu66âÒæ–À¢66â‡G'VR¢Væ@¢Væ@ ¢–b7FFRæÖæ7F÷&ÔVF—DGVRæBvWEF–ÖR‚’ãÒ7FFRæÖæ7F÷&ÔVF—DGVRF†Và¢7FFRæÖæ7F÷&ÔVF—DGVRÒæ–À¢66â‡G'VR¢Æö6Â'G2Ò·Ð¢f÷"sÓÃ2Fð¢Æö6Â6öFRÒ'G”†VÇF‚†rÂ7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"Â7FFRçfW&–f–VD6÷fW&vR¢Æö6Âö²Ò†6öFRÓÒ$4ôäd•$ÔTB"÷"6öFRÓÒ$ÔåTÅô5D•dR"÷ ¢6öFRÓÒ$5D•dUô54”täTB"÷"6öFRÓÒ$5D•dUõTä´äõtâ"¢F&ÆRæ–ç6W'B‡'G2Â%"âârââ†ö²æB"ô²"÷""Ô•54”är"’¢Væ@¢Æö6ÂÖ—76–ærÒ&V7'V—FÖVçDÖ—76–ætw&÷W2‡7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"¢Æö6Â7Vff—‚Ò6Ö—76–ærÓÒæB'&–B&VG’â"÷ ¢‚&æVVBW&f÷""ââF&ÆRæ6öæ6B‚†gVæ7F–öâ‚¢Æö6ÂC×·Òf÷"òÆr–â——'2†Ö—76–ær’FòF&ÆRæ–ç6W'B‡BÂ%"âær’Væ@¢&WGW&â@¢VæB’‚’Â"²"’ââ"â"¢w&÷W6†B‚$Öæ7F÷&Ò6†V6³¢"ââF&ÆRæ6öæ6B‡'G2Â""’ââ"(	B"ââ7Vff—‚¢Væ@ ¢–b7FFRçVæF–ætF—7G&–'WF–öäÆW'BæBvWEF–ÖR‚’ãÒ‡7FFRçVæF–ætF—7G&–'WF–öäÆW'BæGVR÷"’F†Và¢Æö6ÂVæF–ærÒ7FFRçVæF–ætF—7G&–'WF–öäÆW'@¢7FFRçVæF–ætF—7G&–'WF–öäÆW'BÒæ–À¢Æö6Â7W'&VçE6–rÒ'G”†VÇF…6–væGW&R‡7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"Â7FFRçfW&–f–VD6÷fW&vR ¢–b7W'&VçE6–rÓÒVæF–ærç6–væGW&RF†Và¢–bVæF–ærç&W7F÷&VBF†Và¢–bg&÷7E6VV´W&D"æææ÷Væ6U&W7F÷&VBF†Và¢w&÷W6†B‚$W&6÷fW&vR&W7F÷&VC¢ô²"ô²2ô²â"¢Væ@¢VÇ6V–bg&÷7E6VV´W&D"æææ÷Væ6TF—7G&–'WF–öâF†Và¢w&÷W6†B‚$–æ6÷'&V7BW&F—7G&–'WF–öã¢"âà¢&V6öäv&Uv&æ–ær‡7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"Â7FFRçfW&–f–VD6÷fW&vR’¢Æ”W&ÆW'E6÷VæB‚¢Væ@¢Væ@¢Væ@ ¢7FFRæ6æF–FFU'VæTVÆ6VBÒ7FFRæ6æF–FFU'VæTVÆ6VB²VÆ6V@¢–b7FFRæ6æF–FFU'VæTVÆ6VBãÒRF†Và¢7FFRæ6æF–FFU'VæTVÆ6VBÒ ¢'VæT6æF–FFW2‚¢–b&Vg&W6„6æF–FFW2F†Vâ&Vg&W6„6æF–FFW2‚’Væ@¢Væ@ ¢–bg&÷7E6VV´W&D"æBg&÷7E6VV´W&D"çW&–öF–566âF†Và¢7FFRçW&–öF–4VÆ6VBÒ7FFRçW&–öF–4VÆ6VB²VÆ6V@¢Æö6ÂWfW'’ÒFöçVÖ&W"„g&÷7E6VV´W&D"çW&–öF–566ä–çFW'fÂ’÷"P¢–bWfW'’Â"F†VâWfW'’Ò"Væ@¢–b7FFRçW&–öF–4VÆ6VBãÒWfW'’F†Và¢7FFRçW&–öF–4VÆ6VBÒ ¢66â‡G'VR¢Væ@¢Væ@ ¢–bg&÷7E6VV´W&D"æBg&÷7E6VV´W&D"ç&V7'V—F–ærF†Và¢7FFRç&V7'V—DVÆ6VBÒ7FFRç&V7'V—DVÆ6VB²VÆ6V@¢Æö6Â–çFW'fÂÒFöçVÖ&W"„g&÷7E6VV´W&D"ç&V7'V—D–çFW'fÂ’÷"c ¢–b–çFW'fÂÂ3F†Vâ–çFW'fÂÒ3Væ@¢–b7FFRç&V7'V—DVÆ6VBãÒ–çFW'fÂF†Và¢7FFRç&V7'V—DVÆ6VBÒ ¢–b&–DW&&VG’‡7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"÷"·Ò’F†Và¢g&÷7E6VV´W&D"ç&V7'V—F–ærÒfÇ6P¢&–çB‚$W&&V7'V—FÖVçB7F÷VBWFöÖF–6ÆÇ“¢&–BW&7FFR—2&VG’â"¢–b&Vg&W6…T’F†Vâ&Vg&W6…T’‚’Væ@¢VÇ6P¢6VæE&V7'V—FÖVçB‚¢Væ@¢Væ@¢Væ@¦VæB ¢ÒÒÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ¢ÒÒF–væ÷7F–2òfÆÆ&6²6Æ6‚6öÖÖæG0¢ÒÒæ÷&ÖÂ÷W&F–öâ6†÷VÆB&RF‡&÷Vv‚F†Rg&÷7E6VV²W&2F"à¢ÒÒÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ ¦Æö6ÂgVæ7F–öâg&÷7E6VV´W&6Æ6„†æFÆW"†×6r¢Æö6Â6ÖBÂ&W7BÒ7G&–æræÖF6‚†×6r÷"""Â%âW2¢‚U2¢’W2¢‚âÒ’W2¢B"¢6ÖBÒ7G&–æræÆ÷vW"†6ÖB÷""" ¢–b6ÖBÓÒ""÷"6ÖBÓÒ'6†÷r"F†Và¢Æö6Âe2Òôräg&÷7E6VV°¢–be2æBe2äÖ–äg&ÖRæBe2å7v—F6…F"F†Và¢e2äÖ–äg&ÖS¥6†÷r‚¢e3¥7v—F6…F"‚&W&2"¢VÇ6P¢&–çB‚$g&÷7E6VV²T’æ÷Bf–Æ&ÆRâ"¢Væ@ ¢VÇ6V–b6ÖBÓÒ&÷fW&Æ’"F†Và¢g&÷7E6VV´W&D"æ÷fW&Æ’ç6†÷vâÒG'VP¢7&VFT÷fW&Æ’‚¢÷fW&Æ’æg&ÖS¥6†÷r‚¢&Vg&W6„÷fW&Æ’‚ ¢VÇ6V–b6ÖBÓÒ'66â"F†Và¢&–çB‚$ÖçVÂ66â&WVW7FVBâ"¢66â†fÇ6R ¢VÇ6V–b6ÖBÓÒ&Ö&²"F†Và¢Ö&²‡&W7B ¢VÇ6V–b6ÖBÓÒ'VæÖ&²"F†Và¢VæÖ&²‡&W7B ¢VÇ6V–b6ÖBÓÒ&f÷&vWB"F†Và¢6ÆV$¶æ÷väW&66†R‡&W7B ¢VÇ6V–b6ÖBÓÒ'&V7'V—B"F†Và¢6VæE&V7'V—FÖVçB‚ ¢VÇ6V–b6ÖBÓÒ'6Vç6÷'2"F†Và¢66â‡G'VR¢Æö6Â2Ò7FFRç'G”W&6Vç6÷"÷"·Ð¢&–çB‚%'G’6Vç6÷'3¢Ò"ââ'G•6Vç6÷%FW‡B‡5³Ò’âà¢"#Ò"ââ'G•6Vç6÷%FW‡B‡5³%Ò’âà¢"3Ò"ââ'G•6Vç6÷%FW‡B‡5³5Ò’ââ"â" ¢VÇ6V–b6ÖBÓÒ&FV'Vr"F†Và¢&–çB‚$FV'Vr7FFS¢"ââF÷7G&–ær„6÷fW&VE'F–W2‡7FFRæ6÷fW&vR’’âà¢"ó276–væVBÂ"ââF÷7G&–ær„6÷fW&VE'F–W2‡7FFRçfW&–f–VD6÷fW&vR’’âà¢"ó2fW&–f–VBâ" ¢VÇ6P¢&–çB‚"ög6W&6†÷rÂ÷fW&Æ’Â66âÂ6Vç6÷'2ÂÖ&²ÆæÖSâÂVæÖ&²ÆæÖSâÂf÷&vWB¶æÖUÒÂ&V7'V—BÂFV'Vr"¢Væ@¦Væ@ ¥&Vv—7FW$g&÷7E6VV´W&6Æ6„6öÖÖæG2ÒgVæ7F–öâ‡fW&&÷6R¢ôu²%4Ä4…ôe$õ5E4TT´U$%ÒÒ"ög6W& ¢ôu²%4Ä4…ôe$õ5E4TT´U$"%ÒÒ"ög6 ¢6Æ6„6ÖDÆ—7E²$e$õ5E4TT´U$%ÒÒg&÷7E6VV´W&6Æ6„†æFÆW  ¢ÒÒ6öÖR2ã2ãRô66Vç6–öâT’'V–ÆG2'V–ÆB†6‚öb6Æ6‚6öÖÖæG2à¢ÒÒ&RÖ–×÷'B÷W"&Vv—7G&F–öâv†VâF†÷6R–çFW&æÇ2&Rf–Æ&ÆRà¢–bG—R…ôrä6†Dg&ÖUô–×÷'DÆ—7EFô†6‚’ÓÒ&gVæ7F–öâ"æ@¢G—R…ôræ†6…õ6Æ6„6ÖDÆ—7B’ÓÒ'F&ÆR"F†Và¢6ÆÂ…ôrä6†Dg&ÖUô–×÷'DÆ—7EFô†6‚Â6Æ6„6ÖDÆ—7BÂôræ†6…õ6Æ6„6ÖDÆ—7B¢VÇ6V–bG—R…ôrä6†Dg&ÖUô–×÷'DÆÄÆ—7G5Fô†6‚’ÓÒ&gVæ7F–öâ"F†Và¢6ÆÂ…ôrä6†Dg&ÖUô–×÷'DÆÄÆ—7G5Fô†6‚¢Væ@ ¢–bfW&&÷6RF†Và¢&–çB‚$6öÖÖæG2&VG“¢ög6W&æBög6"¢Væ@¦Væ@ ¢ÒÒ&Vv—7FW"–ÖÖVF–FVÇ’ÂF†Vâv–âgFW"F†R&W7BöbF†RT’öFFöç2–æ—F–Æ—¦Rà¥&Vv—7FW$g&÷7E6VV´W&6Æ6„6öÖÖæG2†fÇ6R