-- ============================================================================
-- FrostSeek Aura Tracker v1.3.0
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
local VERSION = "1.3.0"
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
    providerCacheMigration = 0,
    inferProviderOnCoverageTransition = true,
    recruitChannel = 1,         -- IMPORTANT: Ascension is channel slot 1 by default
    recruitInterval = 60,
    recruiting = false,
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

local fß®÷îÚ$z{-®éÜj×7F÷&ÔVçG'”w&6UVçF–ÂÒæ–À¢7FFRæÖæ7F÷&ÔVF—DGVRÒæ–À¢Væ@¢7FFRæÆ7DÖæ7F÷&Õ7FFRÒæ÷tÕ0¢7FFRçVæF–æu66âÒæ÷tÕ2æBR÷"ã3P ¢VÇ6V–bWfVçBÓÒ%$”Eõ$õ5DU%õUDDR"÷ ¢WfVçBÓÒ%%E•ôÔTÔ$U%5ô4„ätTB"F†Và¢7FFRçVæF–æu66âÒã3P ¢VÇ6V–bWfVçBÓÒ$4ôÔ$EôÄôuôUdTåEõTäd”ÅDU$TB"F†Và¢Æö6ÂF–ÖW7F×Â7V&WfVçBÂ6÷W&6TuT”BÂ6÷W&6TæÖRÂ6÷W&6TfÆw2À¢FW7DuT”BÂFW7DæÖRÂFW7DfÆw2ÂÂ"Â2ÂBÂRÒââà¢&V6÷&D6öÖ&E&öÆTWf–FVæ6R‡7V&WfVçBÂ6÷W&6TæÖRÂFW7DæÖRÂÂ"Â2ÂBÂR ¢VÇ6V–bWfVçBÓÒ%Tä•EôU$"F†Và¢–b&sÓÒ'Æ–W""÷ ¢†&sæB7G&–æræf–æB†&sÂ'&–B"ÂÂG'VR’ÓÒ’÷ ¢†&sæB7G&–æræf–æB†&sÂ''G’"ÂÂG'VR’ÓÒ’F†Và¢7FFRçVæF–æu66âÒã#P¢Væ@ ¢Vç7W&U&W6V&6…7FFR‚¢–bfÇ6RæB7FFRç&W6V&6‚æ7F—fRæB&sF†Và¢Æö6ÂWfVçDæÖRÒVæ—DW†—7G2†&s’æB6†÷'DæÖR…Væ—DæÖR†&s’’÷"æ–À¢–b&sÓÒ7FFRç&W6V&6‚çF&vWEVæ—B÷ ¢†WfVçDæÖRæB¶W’†WfVçDæÖR’ÓÒ¶W’‡7FFRç&W6V&6‚çF&vWDæÖR’’F†Và¢7FFRç&W6V&6‚çVæ—DW&WfVçG2Ò7FFRç&W6V&6‚çVæ—DW&WfVçG2²¢–b7FFRç&W6V&6‚çVæ—DW&WfVçG2ÃÒRF†Và¢&W6V&6…&–çB‚%Tä•EôU$Óâ"ââF÷7G&–ær†&s’âà¢"‚"ââF÷7G&–ær†WfVçDæÖR÷"#ò"’ââ"’"¢Væ@¢Væ@¢Væ@ ¢VÇ6V–bWfVçBÓÒ$4„EôÕ4uõ5•5DTÒ"F†Và¢Æö6ÂÖW76vRÒF÷7G&–ær†&s÷"""¢Æö6Âv†òÒ7G&–æræÖF6‚†ÖW76vRÂ%â‚â²’FV6Æ–æW2–÷W"w&÷W–çf—FF–öâ"¢Æö6Â7FGW2Ò$FV6Æ–æVB  ¢–bæ÷Bv†òF†Và¢v†òÒ7G&–æræÖF6‚†ÖW76vRÂ%â‚â²’—2Ç&VG’–âw&÷W"¢7FGW2Ò$Ç&VG’w&÷WVB ¢Væ@¢–bæ÷Bv†òF†Và¢v†òÒ7G&–æræÖF6‚†ÖW76vRÂ$æòÆ–W"æÖVB²uÂ%Óò…µâuÂ%Ò²•²uÂ%Óò—27W'&VçFÇ’Æ––ær"¢7FGW2Ò$öffÆ–æR ¢Væ@ ¢–bv†òF†Và¢Æö6Â²Ò¶W’‡v†ò¢Æö6Â2Ò7FFRæ6æF–FFW5¶µÒ÷"7FFRææöäW&6æF–FFW5¶µÐ¢–b2F†Và¢2ç7FGW2Ò7FGW0¢2çF–ÖRÒvWEF–ÖR‚¢–b&Vg&W6„6æF–FFW2F†Vâ&Vg&W6„6æF–FFW2‚’Væ@¢Væ@¢Væ@ ¢VÇ6V–bWfVçBÓÒ$4„EôÕ4uõ%E’"÷"WfVçBÓÒ$4„EôÕ4uõ%E•ôÄTDU""÷ ¢WfVçBÓÒ$4„EôÕ4uõ$”B"÷"WfVçBÓÒ$4„EôÕ4uõ$”EôÄTDU""÷ ¢WfVçBÓÒ$4„EôÕ4uõ$”Eõt$ä”är"F†Và¢&V6÷&Dw&÷W6†B†WfVçBÂ&sÂ&s" ¢VÇ6V–bWfVçBÓÒ$4„EôÕ4uõt„•5U""F†Và¢Æö6ÂÖW76vRÒ&s÷"" ¢Æö6Â6VæFW"Ò6†÷'DæÖR†&s" ¢–b6VæFW"æB—4–äÖæ7F÷&Ò‚’F†Và¢–bg&÷7E6VV´W&D"æWFôÆ–6çE&WÆ–W2F†Và¢6VæD6†DÖW76vR„ÖW76vUFV×ÆFR‚&–ç6–FTÖæ7F÷&Ò"’Â%t„•5U""Âæ–ÂÂ6VæFW"¢Væ@¢VÇ6V–b6VæFW"æB&V7'V—FÖVçE&WÇ•v–æF÷t÷Vâ‚’F†Và¢Æö6Â²Ò¶W’‡6VæFW"¢Æö6Â&Wf–÷W2Ò7FFRæ6æF–FFW5¶µÒ÷"7FFRææöäW&6æF–FFW5¶µÐ¢Æö6ÂGWÆ–6FU&WÇ’Ò&Wf–÷W2æB&Wf–÷W2æÖW76vRÓÒÖW76vRæ@¢„vWEF–ÖR‚’Ò‡&Wf–÷W2çF–ÖR÷"’’Â0¢Æö6Â'6VBÒ'6U&V7'V—FÖVçE&WÇ’†ÖW76vRÂ&Wf–÷W2¢Æö6ÂVçG'’Ò&Wf–÷W2÷"²æÖRÒ6VæFW"Â7FGW2Ò$æWr"Â†—7F÷'’Ò·ÒÐ¢VçG'’ææÖRÒ6VæFW ¢VçG'’æÖW76vRÒÖW76vP¢VçG'’çF–ÖRÒvWEF–ÖR‚¢VçG'’ç&öÆRÒ'6VBç&öÆP¢VçG'’æW&Ò'6VBæW&¢VçG'’æÆWfVÂÒ'6VBæÆWfVÀ¢VçG'’æ6ö×ÆWFRÒ'6VBæ6ö×ÆWFP¢VçG'’æ†—7F÷'’ÒVçG'’æ†—7F÷'’÷"·Ð¢F&ÆRæ–ç6W'B†VçG'’æ†—7F÷'’Â²ÖW76vRÒÖW76vRÂF–ÖRÒVçG'’çF–ÖRÒ¢v†–ÆR6VçG'’æ†—7F÷'’âFòF&ÆRç&VÖ÷fR†VçG'’æ†—7F÷'’Â’Væ@ ¢–b'6VBæW†7DW&÷"'6VBæW&ÓÒG'VRF†Và¢7FFRæ6æF–FFW5¶µÒÒVçG'¢7FFRææöäW&6æF–FFW5¶µÒÒæ–À¢–bæ÷BGWÆ–6FU&WÇ’F†Và¢&–çB‚$W&6æF–FFS¢"ââ6VæFW"ââ"Ò&öÆR"ââF÷7G&–ær†VçG'’ç&öÆR÷"'Væ¶æ÷vâ"’âà¢"ÂÆWfVÂ"ââF÷7G&–ær†VçG'’æÆWfVÂ÷"#ò"’ââ"â"¢Væ@ ¢ÒÒ&W6W'fRF†RW†—7F–ær6fWG’&÷VæF'“¢WFöÖF–2–çf—FW0¢ÒÒ7F–ÆÂ&WV—&RF†RW†7B6–ævÆR×v÷&BW&&W7öç6Rà¢–b'6VBæW†7DW&æBg&÷7E6VV´W&D"æWFô–çf—FTW&v†—7W'2æBVçG'’ç7FGW2ãÒ$–çf—FVB"F†Và¢–çf—FUVæ—B‡6VæFW"¢VçG'’ç7FGW2Ò$–çf—FVB ¢&–çB‚$WFòÖ–çf—FVBW&6æF–FFR"ââ6VæFW"ââ"â"¢Væ@¢VÇ6P¢7FFRææöäW&6æF–FFW5¶µÒÒVçG'¢7FFRæ6æF–FFW5¶µÒÒæ–À¢–bæ÷BGWÆ–6FU&WÇ’F†Và¢&–çB‚%&V7'V—FÖVçB&WÇ“¢"ââ6VæFW"ââ"Ò&öÆR"ââF÷7G&–ær†VçG'’ç&öÆR÷"'Væ¶æ÷vâ"’âà¢"ÂW&"ââ†VçG'’æW&ÓÒæ–ÂæB'Væ¶æ÷vâ"÷"VçG'’æW&æB'–W2"÷"&æò"’âà¢"ÂÆWfVÂ"ââF÷7G&–ær†VçG'’æÆWfVÂ÷"#ò"’ââ"â"¢Væ@¢Væ@ ¢6VæD6æF–FFU&WÇ’†VçG'’¢–b&Vg&W6„6æF–FFW2F†Vâ&Vg&W6„6æF–FFW2‚’Væ@¢Væ@¢Væ@¦VæB ¤e4¥6WE67&—B‚$öåWFFR"ÂgVæ7F–öâ‡6VÆbÂVÆ6VB¢–bæ÷B–çFVw&FVBF†Và¢–çFVw&F–öäVÆ6VBÒ–çFVw&F–öäVÆ6VB²VÆ6V@¢–b–çFVw&F–öäVÆ6VBãÒF†Và¢–çFVw&F–öäVÆ6VBÒ ¢–çFVw&FVBÒg&÷7E6VV´FWVæFVæ7•&VG’‚’æB–çFVw&FUv—F„g&÷7E6VV²‚¢Væ@¢Væ@ ¢–b7FFRçVæF–æu66âF†Và¢7FFRçVæF–æu66âÒ7FFRçVæF–æu66âÒVÆ6V@¢–b7FFRçVæF–æu66âÃÒF†Và¢7FFRçVæF–æu66âÒæ–À¢66â‡G'VR¢Væ@¢Væ@ ¢–b7FFRæÖæ7F÷&ÔVF—DGVRæBvWEF–ÖR‚’ãÒ7FFRæÖæ7F÷&ÔVF—DGVRF†Và¢7FFRæÖæ7F÷&ÔVF—DGVRÒæ–À¢ÒÒW7F&Æ—6‚F†RgVÆÇ’ÆöFVB&÷7FW"ôW&7FFR2F†RæWr&6VÆ–æRà¢ÒÒF†—266â×W7Bæ÷BÇ6ò66†VGVÆRF†Ræ÷&ÖÂF—7G&–'WF–öâÖW76vRÀ¢ÒÒ÷F†W'v—6RF†RVçG'’VF—B6â&RföÆÆ÷vVB'’GWÆ–6FRÆW'Bà¢66â‡G'VRÂG'VR¢7FFRçVæF–ætF—7G&–'WF–öäÆW'BÒæ–À¢7FFRæÖæ7F÷&ÔVçG'”w&6UVçF–ÂÒæ–À¢Æö6Â'G2Ò·Ð¢f÷"sÓÃ2Fð¢Æö6Â6öFRÒ'G”†VÇF‚†rÂ7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"Â7FFRçfW&–f–VD6÷fW&vR¢Æö6Âö²Ò†6öFRÓÒ$4ôäd•$ÔTB"÷"6öFRÓÒ$ÔåTÅô5D•dR"÷ ¢6öFRÓÒ$5D•dUô54”täTB"÷"6öFRÓÒ$5D•dUõTä´äõtâ"¢F&ÆRæ–ç6W'B‡'G2Â%"âârââ†ö²æB"ô²"÷""Ô•54”är"’¢Væ@¢Æö6ÂÖ—76–ærÒ&V7'V—FÖVçDÖ—76–ætw&÷W2‡7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"¢Æö6Â7Vff—‚Ò6Ö—76–ærÓÒæB'&–B&VG’â"÷ ¢‚&æVVBW&f÷""ââF&ÆRæ6öæ6B‚†gVæ7F–öâ‚¢Æö6ÂC×·Òf÷"òÆr–â——'2†Ö—76–ær’FòF&ÆRæ–ç6W'B‡BÂ%"âær’Væ@¢&WGW&â@¢VæB’‚’Â"²"’ââ"â"¢w&÷W6†B‚$Öæ7F÷&Ò6†V6³¢"ââF&ÆRæ6öæ6B‡'G2Â""’ââ"Ò"ââ7Vff—‚¢Væ@ ¢–b7FFRçVæF–ætF—7G&–'WF–öäÆW'BæBvWEF–ÖR‚’ãÒ‡7FFRçVæF–ætF—7G&–'WF–öäÆW'BæGVR÷"’F†Và¢Æö6ÂVæF–ærÒ7FFRçVæF–ætF—7G&–'WF–öäÆW'@¢7FFRçVæF–ætF—7G&–'WF–öäÆW'BÒæ–À¢Æö6Â7W'&VçE6–rÒ'G”†VÇF…6–væGW&R‡7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"Â7FFRçfW&–f–VD6÷fW&vR ¢–b7W'&VçE6–rÓÒVæF–ærç6–væGW&RF†Và¢Æö6Â†VÇF‡”ÖW76vRÒÆÄw&÷W5&W÷'F–ætW&ÖW76vR€¢7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"Â7FFRçfW&–f–VD6÷fW&vR¢–b†VÇF‡”ÖW76vRF†Và¢–bg&÷7E6VV´W&D"æææ÷Væ6U&W7F÷&VB÷"g&÷7E6VV´W&D"æææ÷Væ6TF—7G&–'WF–öâF†Và¢w&÷W6†B††VÇF‡”ÖW76vR¢Væ@¢VÇ6V–bVæF–ærç&W7F÷&VBF†Và¢–bg&÷7E6VV´W&D"æææ÷Væ6U&W7F÷&VBF†Và¢w&÷W6†B‚$W&6÷fW&vR&W7F÷&VC¢ô²"ô²2ô²â"¢Væ@¢VÇ6V–bg&÷7E6VV´W&D"æææ÷Væ6TF—7G&–'WF–öâF†Và¢w&÷W6†B‚$–æ6÷'&V7BW&F—7G&–'WF–öã¢"âà¢&V6öäv&Uv&æ–ær‡7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"Â7FFRçfW&–f–VD6÷fW&vR’¢Æ”W&ÆW'E6÷VæB‚¢Væ@¢Væ@¢Væ@ ¢7FFRæ6æF–FFU'VæTVÆ6VBÒ7FFRæ6æF–FFU'VæTVÆ6VB²VÆ6V@¢–b7FFRæ6æF–FFU'VæTVÆ6VBãÒRF†Và¢7FFRæ6æF–FFU'VæTVÆ6VBÒ ¢'VæT6æF–FFW2‚¢–b&Vg&W6„6æF–FFW2F†Vâ&Vg&W6„6æF–FFW2‚’Væ@¢Væ@ ¢7FFRç&öÆUWFFTVÆ6VBÒ7FFRç&öÆUWFFTVÆ6VB²VÆ6V@¢–b7FFRç&öÆUWFFTVÆ6VBãÒ"F†Và¢7FFRç&öÆUWFFTVÆ6VBÒ ¢WFFT–æfW'&VE&öÆW2‚¢–b÷fW&Æ’æg&ÖRæB÷fW&Æ’æg&ÖS¤—56†÷vâ‚’F†Vâ&Vg&W6„÷fW&Æ’‚’Væ@¢Væ@ ¢–bg&÷7E6VV´W&D"æBg&÷7E6VV´W&D"çW&–öF–566âF†Và¢7FFRçW&–öF–4VÆ6VBÒ7FFRçW&–öF–4VÆ6VB²VÆ6V@¢Æö6ÂWfW'’ÒFöçVÖ&W"„g&÷7E6VV´W&D"çW&–öF–566ä–çFW'fÂ’÷"P¢–bWfW'’Â"F†VâWfW'’Ò"Væ@¢–b7FFRçW&–öF–4VÆ6VBãÒWfW'’F†Và¢7FFRçW&–öF–4VÆ6VBÒ ¢66â‡G'VR¢Væ@¢Væ@ ¢–bg&÷7E6VV´W&D"æBg&÷7E6VV´W&D"ç&V7'V—F–ærF†Và¢7FFRç&V7'V—DVÆ6VBÒ7FFRç&V7'V—DVÆ6VB²VÆ6V@¢Æö6Â–çFW'fÂÒFöçVÖ&W"„g&÷7E6VV´W&D"ç&V7'V—D–çFW'fÂ’÷"c ¢–b–çFW'fÂÂ3F†Vâ–çFW'fÂÒ3Væ@¢–b7FFRç&V7'V—DVÆ6VBãÒ–çFW'fÂF†Và¢7FFRç&V7'V—DVÆ6VBÒ ¢–b&–DW&&VG’‡7FFRæ6÷fW&vRÂ7FFRç'G”W&6Vç6÷"÷"·Ò’F†Và¢g&÷7E6VV´W&D"ç&V7'V—F–ærÒfÇ6P¢&–çB‚$W&&V7'V—FÖVçB7F÷VBWFöÖF–6ÆÇ“¢&–BW&7FFR—2&VG’â"¢–b&Vg&W6…T’F†Vâ&Vg&W6…T’‚’Væ@¢VÇ6P¢6VæE&V7'V—FÖVçB‚¢Væ@¢Væ@¢Væ@¦VæB ¢ÒÒÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ¢ÒÒF–væ÷7F–2òfÆÆ&6²6Æ6‚6öÖÖæG0¢ÒÒæ÷&ÖÂ÷W&F–öâ6†÷VÆB&RF‡&÷Vv‚F†Rg&÷7E6VV²W&2F"à¢ÒÒÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÓÐ ¦Æö6ÂgVæ7F–öâg&÷7E6VV´W&6Æ6„†æFÆW"†×6r¢Æö6Â6ÖBÂ&W7BÒ7G&–æræÖF6‚†×6r÷"""Â%âW2¢‚U2¢’W2¢‚âÒ’W2¢B"¢6ÖBÒ7G&–æræÆ÷vW"†6ÖB÷""" ¢–b6ÖBÓÒ""÷"6ÖBÓÒ'6†÷r"F†Và¢Æö6Âe2Òôräg&÷7E6VV°¢–be2æBe2äÖ–äg&ÖRæBe2å7v—F6…F"F†Và¢e2äÖ–äg&ÖS¥6†÷r‚¢e3¥7v—F6…F"‚&W&2"¢VÇ6P¢&–çB‚$g&÷7E6VV²T’æ÷Bf–Æ&ÆRâ"¢Væ@ ¢VÇ6V–b6ÖBÓÒ&÷fW&Æ’"F†Và¢g&÷7E6VV´W&D"æ÷fW&Æ’ç6†÷vâÒG'VP¢7&VFT÷fW&Æ’‚¢÷fW&Æ’æg&ÖS¥6†÷r‚¢&Vg&W6„÷fW&Æ’‚ ¢VÇ6V–b6ÖBÓÒ'66â"F†Và¢&–çB‚$ÖçVÂ66â&WVW7FVBâ"¢66â†fÇ6R ¢VÇ6V–b6ÖBÓÒ&Ö&²"F†Và¢Ö&²‡&W7B ¢VÇ6V–b6ÖBÓÒ'VæÖ&²"F†Và¢VæÖ&²‡&W7B ¢VÇ6V–b6ÖBÓÒ&f÷&vWB"F†Và¢6ÆV$¶æ÷väW&66†R‡&W7B ¢VÇ6V–b6ÖBÓÒ'&V7'V—B"F†Và¢6VæE&V7'V—FÖVçB‚ ¢VÇ6V–b6ÖBÓÒ&6†B"F†Và¢Æö6Âf—'7BÒÖF‚æÖ‚ƒÂ77FFRæw&÷W6†BÒr¢–b77FFRæw&÷W6†BÓÒF†Và¢&–çB‚$æò&V6VçB'G’÷"&–BÖW76vW26GW&VBâ"¢VÇ6P¢&–çB‚%&V6VçBw&÷W6†C¢"¢f÷"’Òf—'7BÂ77FFRæw&÷W6†BFð¢Æö6Â—FVÒÒ7FFRæw&÷W6†E¶•Ð¢&–çB‚%²"ââ—FVÒæ6†ææVÂââ%Ò"ââ—FVÒç6VæFW"ââ#¢"ââ—FVÒæÖW76vR¢Væ@¢Væ@ ¢VÇ6V–b6ÖBÓÒ'6’"F†Và¢–b&W7BÓÒ""F†Và¢&–çB‚%W6vS¢ög6W&6’ÆÖW76vSâ"¢VÇ6V–b&–D6÷VçB‚’âF†Và¢6VæD6†DÖW76vR‡&W7BÂ%$”B"¢VÇ6V–b'G”6÷VçB‚’âF†Và¢6VæD6†DÖW76vR‡&W7BÂ%%E’"¢VÇ6P¢&–çB‚$¦ö–â'G’÷"&–B&Vf÷&R6VæF–ærw&÷WÖW76vRâ"¢Væ@ ¢VÇ6V–b6ÖBÓÒ&ÖW76vW2"F†Và¢&–çB‚%&V7'V—FÖVçBÖW76vRFV×ÆFW3¢"¢f÷"òÂ¶W’–â——'2‡²&Ö—76–æu&öÆR"Â&Ö—76–ætW&"Â&Ö—76–ætÆWfVÂ"Â&66WFVB"Â&–ç6–FTÖæ7F÷&Ò'Ò’Fð¢&–çB†¶W’ââ#¢"ââÖW76vUFV×ÆFR†¶W’’¢Væ@ ¢VÇ6V–b6ÖBÓÒ&ÖW76vR"F†Và¢Æö6Â¶W’ÂfÇVRÒ7G&–æræÖF6‚‡&W7B÷"""Â%â‚U2²’W2¢‚âÒ’W2¢B"¢–b7G&–æræÆ÷vW"†¶W’÷"""’ÓÒ'&W6WB"F†Và¢g&÷7E6VV´W&D"æÖW76vW2Ò·Ð¢f÷"FVfVÇD¶W’ÂFVfVÇEfÇVR–â—'2„ÔU54tUôDTdTÅE2’Fð¢g&÷7E6VV´W&D"æÖW76vW5¶FVfVÇD¶W•ÒÒFVfVÇEfÇVP¢Væ@¢&–çB‚%&V7'V—FÖVçBÖW76vRFV×ÆFW2&W6WBâ"¢VÇ6V–bæ÷B¶W’÷"ÔU54tUôDTdTÅE5¶¶W•ÒÓÒæ–Â÷"fÇVRÓÒ""F†Và¢&–çB‚%W6vS¢ög6W&ÖW76vRÆÖ—76–æu&öÆWÆÖ—76–ætW&ÆÖ—76–ætÆWfVÇÆ66WFVGÆ–ç6–FTÖæ7F÷&ÓâÇFW‡Câ"¢VÇ6P¢g&÷7E6VV´W&D"æÖW76vW5¶¶W•ÒÒfÇVP¢&–çB‚%WFFVBÖW76vRFV×ÆFR"ââ¶W’ââ"â"¢Væ@ ¢VÇ6V–b6ÖBÓÒ'6Vç6÷'2"F†Và¢66â‡G'VR¢Æö6Â2Ò7FFRç'G”W&6Vç6÷"÷"·Ð¢&–çB‚%'G’6Vç6÷'3¢Ò"ââ'G•6Vç6÷%FW‡B‡5³Ò’âà¢"#Ò"ââ'G•6Vç6÷%FW‡B‡5³%Ò’âà¢"3Ò"ââ'G•6Vç6÷%FW‡B‡5³5Ò’ââ"â" ¢VÇ6V–b6ÖBÓÒ'&öÆW2"F†Và¢WFFT–æfW'&VE&öÆW2‚¢Æö6ÂFæ·2Ò–æfW'&VE&öÆTæÖW2‚%Dä²"¢Æö6Â†VÆW'2Ò–æfW'&VE&öÆTæÖW2‚$„TÄU""¢&–çB‚$6öÖ&B&öÆW2ÒFæ·3¢"ââ‚7Fæ·2âæBF&ÆRæ6öæ6B‡Fæ·2Â"Â"’÷"&ÆV&æ–ær"’âà¢#²†VÆW'3¢"ââ‚6†VÆW'2âæBF&ÆRæ6öæ6B††VÆW'2Â"Â"’÷"&ÆV&æ–ær"’ââ"â" ¢VÇ6V–b6ÖBÓÒ'&öÆW7&W6WB"F†Và¢7FFRç&öÆTWf–FVæ6RÒ·Ð¢WFFT–æfW'&VE&öÆW2‚¢&Vg&W6„÷fW&Æ’‚¢&–çB‚$6öÖ&B&öÆRWf–FVæ6R&W6WBâ" ¢VÇ6V–b6ÖBÓÒ&FV'Vr"F†Và¢&–çB‚$FV'Vr7FFS¢"ââF÷7G&–ær„6÷fW&VE'F–W2‡7FFRæ6÷fW&vR’’âà¢"ó276–væVBÂ"ââF÷7G&–ær„6÷fW&VE'F–W2‡7FFRçfW&–f–VD6÷fW&vR’’âà¢"ó2fW&–f–VBâ" ¢VÇ6P¢&–çB‚"ög6W&6†÷rÂ÷fW&Æ’Â66âÂ6Vç6÷'2Â&öÆW2Â&öÆW7&W6WBÂÖ&²ÆæÖSâÂVæÖ&²ÆæÖSâÂf÷&vWB¶æÖUÒÂ&V7'V—BÂ6†BÂ6’ÇFW‡CâÂÖW76vW2ÂÖW76vRÆ¶W“âÇFW‡CâÂFV'Vr"¢Væ@¦Væ@ ¥&Vv—7FW$g&÷7E6VV´W&6Æ6„6öÖÖæG2ÒgVæ7F–öâ‡fW&&÷6R¢ôu²%4Ä4…ôe$õ5E4TT´U$%ÒÒ"ög6W& ¢ôu²%4Ä4…ôe$õ5E4TT´U$"%ÒÒ"ög6 ¢6Æ6„6ÖDÆ—7E²$e$õ5E4TT´U$%ÒÒg&÷7E6VV´W&6Æ6„†æFÆW  ¢ÒÒ6öÖR2ã2ãRô66Vç6–öâT’'V–ÆG2'V–ÆB†6‚öb6Æ6‚6öÖÖæG2à¢ÒÒ&RÖ–×÷'B÷W"&Vv—7G&F–öâv†VâF†÷6R–çFW&æÇ2&Rf–Æ&ÆRà¢–bG—R…ôrä6†Dg&ÖUô–×÷'DÆ—7EFô†6‚’ÓÒ&gVæ7F–öâ"æ@¢G—R…ôræ†6…õ6Æ6„6ÖDÆ—7B’ÓÒ'F&ÆR"F†Và¢6ÆÂ…ôrä6†Dg&ÖUô–×÷'DÆ—7EFô†6‚Â6Æ6„6ÖDÆ—7BÂôræ†6…õ6Æ6„6ÖDÆ—7B¢VÇ6V–bG—R…ôrä6†Dg&ÖUô–×÷'DÆÄÆ—7G5Fô†6‚’ÓÒ&gVæ7F–öâ"F†Và¢6ÆÂ…ôrä6†Dg&ÖUô–×÷'DÆÄÆ—7G5Fô†6‚¢Væ@ ¢–bfW&&÷6RF†Và¢&–çB‚$6öÖÖæG2&VG“¢ög6W&æBög6"¢Væ@¦Væ@ ¢ÒÒ&Vv—7FW"–ÖÖVF–FVÇ’ÂF†Vâv–âgFW"F†R&W7BöbF†RT’öFFöç2–æ—F–Æ—¦Rà¥&Vv—7FW$g&÷7E6VV´W&6Æ6„6öÖÖæG2†fÇ6R