local MSR = ManastormRecruiter

local function CleanWords(message)
    local clean = string.lower(tostring(message or ""))
    clean = clean:gsub("[^%a]+", " ")
    clean = " " .. clean:gsub("%s+", " ") .. " "
    return clean
end

function MSR:ParseApplicantLevel(message)
    local clean = " " .. string.lower(tostring(message or "")):gsub("[^%w]+", " "):gsub("%s+", " ") .. " "
    local level = clean:match(" level%s+(%d+) ")
        or clean:match(" lvl%s+(%d+) ")
        or clean:match(" lv%s+(%d+) ")
    level = tonumber(level)
    if level and level >= 1 and level <= 60 then return level end

    -- Also accept the compact format advertised by the addon, for example
    -- "DPS aura yes 47". Only a final standalone number is interpreted.
    level = tonumber(clean:match(" (%d+) %s*$"))
    if level and level >= 1 and level <= 60 then return level end
    return nil
end

local function HasWord(clean, word)
    return clean:find(" " .. word .. " ", 1, true) ~= nil
end

local function HasAnyWord(clean, words)
    for _, word in ipairs(words) do
        if HasWord(clean, word) then return true end
    end
    return false
end

local function HasPhrase(clean, phrase)
    return clean:find(" " .. phrase .. " ", 1, true) ~= nil
end

function MSR:ParseApplication(message, allowAuraOnlyAnswer)
    local clean = CleanWords(message)
    local raw = string.lower(tostring(message or ""))
    local compact = raw:gsub("[^%a]+", "")
    local role = "UNKNOWN"

    local tank = HasAnyWord(clean, { "tank", "tanking", "tanky", "mt", "ot" })
    local heal = HasAnyWord(clean, { "heal", "healer", "heals", "healing", "healspec" })
    local dps = HasAnyWord(clean, {
        "dps", "dd", "damage", "damager", "ranged", "rdps", "melee", "mdps", "caster",
    })

    -- Also accept compact answers such as "dpsaura", "healaura" or "tankno".
    if not tank and not heal and not dps then
        tank = compact:find("^tank") ~= nil
        heal = compact:find("^heal") ~= nil
        dps = compact:find("^dps") ~= nil or compact:find("^rdps") ~= nil or compact:find("^mdps") ~= nil
    end

    -- Single-letter role answers remain supported, but only as whole words.
    if not tank and not heal and not dps then
        tank = HasWord(clean, "t")
        heal = HasWord(clean, "h")
        dps = HasWord(clean, "d")
    end

    local roleMatches = (tank and 1 or 0) + (heal and 1 or 0) + (dps and 1 or 0)
    if roleMatches == 1 then
        if tank then role = "TANK"
        elseif heal then role = "HEAL"
        else role = "DPS" end
    end

    local aura = nil
    local auraMention = HasAnyWord(clean, { "aura", "auraa", "auro", "aure", "aurs", "auta" })
        or compact:find("aura", 1, true) ~= nil
        or compact:find("auta", 1, true) ~= nil
    local recruitAFriendAura = HasPhrase(clean, "raf aura")
        or HasPhrase(clean, "raf aura buff")
        or HasPhrase(clean, "recruit a friend aura")
        or HasPhrase(clean, "recruit friend aura")
    local negativeAura = HasPhrase(clean, "aura no")
        or HasPhrase(clean, "no aura")
        or HasPhrase(clean, "auta no")
        or HasPhrase(clean, "no auta")
        or HasPhrase(clean, "auro no")
        or HasPhrase(clean, "no auro")
        or HasPhrase(clean, "aure no")
        or HasPhrase(clean, "no aure")
        or HasPhrase(clean, "aurs no")
        or HasPhrase(clean, "no aurs")
        or HasPhrase(clean, "without aura")
        or HasPhrase(clean, "aura n")
        or HasPhrase(clean, "aura nope")
        or HasPhrase(clean, "aura nah")
        or HasPhrase(clean, "aura false")
        or HasPhrase(clean, "not aura")
        or HasPhrase(clean, "don t have aura")
        or HasPhrase(clean, "do not have aura")
        or HasPhrase(clean, "dont have aura")
        or HasWord(clean, "noaura")
        or compact:find("noaura", 1, true) ~= nil

    local positiveAura = HasPhrase(clean, "aura yes")
        or HasPhrase(clean, "yes aura")
        or HasPhrase(clean, "with aura")
        or HasPhrase(clean, "have aura")
        or HasPhrase(clean, "has aura")
        or HasPhrase(clean, "got aura")
        or HasPhrase(clean, "aura y")
        or HasPhrase(clean, "aura yep")
        or HasPhrase(clean, "aura yeah")
        or HasPhrase(clean, "aura true")
        or HasPhrase(clean, "my aura")
        or auraMention
        or (role ~= "UNKNOWN" and raw:find("a+", 1, true) ~= nil)

    -- Recruit-a-Friend Aura is not the Manastorm Aura requested by the raid.
    -- Do not let a later coordination whisper overwrite the player's stored
    -- Aura answer. An explicit negative still remains a valid Aura: No.
    if recruitAFriendAura and not negativeAura then positiveAura = false end

    if negativeAura then
        aura = false
    elseif positiveAura then
        aura = true
    elseif (role ~= "UNKNOWN" or allowAuraOnlyAnswer) and HasAnyWord(clean, { "yes", "y", "yep", "yeah", "aye", "true" }) then
        aura = true
    elseif (role ~= "UNKNOWN" or allowAuraOnlyAnswer) and HasAnyWord(clean, { "no", "n", "nope", "nah", "none", "false" }) then
        aura = false
    end

    return role, aura, roleMatches ~= 1 or aura == nil, roleMatches
end
function MSR:GetApplicantMissingField(applicant)
    if not applicant or applicant.role == "UNKNOWN" then return "role" end
    if applicant.aura == nil then return "aura" end
    if not tonumber(applicant.level) then return "level" end
    return nil
end

function MSR:ReparseStoredApplicants()
    local session = self.char and self.char.session
    if not session or type(session.applicants) ~= "table" then return end
    for _, applicant in pairs(session.applicants) do
        local assignmentLocked = type(applicant) == "table"
            and applicant.status == "Joined"
            and applicant.role ~= "UNKNOWN"
            and applicant.aura ~= nil
        if type(applicant) == "table" and not assignmentLocked then
            local messages = {}
            if type(applicant.messageHistory) == "table" and #applicant.messageHistory > 0 then
                for _, entry in ipairs(applicant.messageHistory) do
                    if type(entry) == "table" and type(entry.message) == "string" and entry.message ~= "" then
                        table.insert(messages, entry.message)
                    end
                end
            elseif type(applicant.message) == "string" and applicant.message ~= "" then
                table.insert(messages, applicant.message)
            end

            if #messages > 0 then
                applicant.role = "UNKNOWN"
                applicant.aura = nil
                for _, storedMessage in ipairs(messages) do
                    local allowAuraOnlyAnswer = applicant.role ~= "UNKNOWN" and applicant.aura == nil
                    local parsedRole, parsedAura, _, roleMatches = self:ParseApplication(
                        storedMessage,
                        allowAuraOnlyAnswer
                    )
                    if roleMatches == 1 then
                        applicant.role = parsedRole
                    elseif roleMatches > 1 then
                        applicant.role = "UNKNOWN"
                    end
                    if parsedAura ~= nil then applicant.aura = parsedAura end
                    self:SetApplicantLevel(applicant, self:ParseApplicantLevel(storedMessage))
                end
                applicant.needsReview = applicant.role == "UNKNOWN" or applicant.aura == nil
                applicant.pendingQuestion = self:GetApplicantMissingField(applicant)
            end
        end
    end
end

function MSR:RecordWhisper(message, sender, role, aura, needsReview)
    local history = self.char.session.whisperHistory
    if type(history) ~= "table" then
        history = {}
        self.char.session.whisperHistory = history
    end
    table.insert(history, {
        sender = tostring(sender or ""),
        message = tostring(message or ""),
        role = role,
        aura = aura,
        needsReview = needsReview,
        receivedAt = time(),
    })
    while #history > 100 do table.remove(history, 1) end
end

function MSR:RecordApplicantWhisper(applicant, message, role, aura, needsReview)
    if not applicant then return end
    if type(applicant.messageHistory) ~= "table" then applicant.messageHistory = {} end
    table.insert(applicant.messageHistory, {
        message = tostring(message or ""),
        parsedRole = role,
        parsedAura = aura,
        parsedNeedsReview = needsReview,
        receivedAt = time(),
    })
    while #applicant.messageHistory > 20 do table.remove(applicant.messageHistory, 1) end
end

function MSR:HandleWhisper(message, sender)
    if self:IsInManastorm() then
        if self.db.settings.autoReply and type(SendChatMessage) == "function" then
            local reply = self:PrepareChatMessage(self:BuildConfiguredMessage("inManastormReply", {
                player = sender,
            }))
            if reply ~= "" then pcall(SendChatMessage, reply, "WHISPER", nil, sender) end
        end
        return
    end
    if not self.char.session.listening then return end

    local applicant = self:EnsureApplicant(sender)
    self:SetApplicantLevel(applicant, self:ParseApplicantLevel(message))
    local allowAuraOnlyAnswer = applicant.role ~= "UNKNOWN" and applicant.aura == nil
    local parsedRole, parsedAura, parsedNeedsReview, roleMatches = self:ParseApplication(
        message,
        allowAuraOnlyAnswer
    )
    self:RecordWhisper(message, sender, parsedRole, parsedAura, parsedNeedsReview)
    self:RecordApplicantWhisper(applicant, message, parsedRole, parsedAura, parsedNeedsReview)

    local assignmentLocked = applicant.status == "Joined"
        and applicant.role ~= "UNKNOWN"
        and applicant.aura ~= nil
    if not assignmentLocked then
        -- A whisper may contain only one half of the application. Preserve the
        -- previously parsed half and update only fields explicitly present in
        -- this message. Multiple roles are intentionally treated as ambiguous.
        if roleMatches == 1 then
            applicant.role = parsedRole
        elseif roleMatches > 1 then
            applicant.role = "UNKNOWN"
        end
        if parsedAura ~= nil then applicant.aura = parsedAura end
        applicant.needsReview = applicant.role == "UNKNOWN" or applicant.aura == nil
        applicant.pendingQuestion = self:GetApplicantMissingField(applicant)
    else
        applicant.needsReview = false
        applicant.pendingQuestion = nil
    end
    applicant.message = tostring(message or "")
    applicant.updatedAt = time()
    if applicant.status == "Rejected" or applicant.status == "Declined" or applicant.status == "Left"
        or applicant.status == "NoResponse" then
        applicant.status = "New"
    end

    local capacityReply
    if not assignmentLocked and applicant.status ~= "Invited" then
        capacityReply = self:GetApplicationCapacityReply(applicant)
    end

    if self.db.settings.autoReply and not assignmentLocked and applicant.status ~= "Invited" then
        local reply, replyKind
        if applicant.pendingQuestion == "role" then
            reply = self:BuildConfiguredMessage("invalidApplicationReply", { player = applicant.name })
            replyKind = "question:role"
        elseif applicant.pendingQuestion == "aura" then
            reply = self:BuildConfiguredMessage("missingAuraReply", {
                player = applicant.name,
                role = self.ROLE_LABELS[applicant.role],
            })
            replyKind = "question:aura:" .. tostring(applicant.role)
        elseif applicant.pendingQuestion == "level" then
            reply = self:BuildConfiguredMessage("missingLevelReply", {
                player = applicant.name,
                role = self.ROLE_LABELS[applicant.role],
                aura = applicant.aura and "Yes" or "No",
            })
            replyKind = "question:level:" .. tostring(applicant.role) .. ":" .. tostring(applicant.aura)
        elseif capacityReply then
            reply = capacityReply
            replyKind = "capacity:" .. capacityReply
        else
            reply = self:BuildConfiguredMessage("acceptedApplicationReply", {
                role = self.ROLE_LABELS[applicant.role],
                aura = applicant.aura and "Yes" or "No",
                player = applicant.name,
            })
            replyKind = "accepted:" .. tostring(applicant.role) .. ":" .. tostring(applicant.aura)
        end
        reply = self:PrepareChatMessage(reply)
        local replySignature = tostring(replyKind or "") .. ":" .. tostring(applicant.status)
        if reply ~= "" and applicant.lastAutoReplySignature ~= replySignature then
            pcall(SendChatMessage, reply, "WHISPER", nil, sender)
            applicant.lastAutoReplySignature = replySignature
        end
    end

    if assignmentLocked then
        self:Print(string.format(
            "%s whispered again. Stored the message and kept %s, Aura: %s.",
            applicant.name,
            self.ROLE_LABELS[applicant.role],
            applicant.aura and "Yes" or "No"
        ))
    else
        self:Print(string.format(
            "%s applied as %s, Aura: %s%s.",
            applicant.name,
            self.ROLE_LABELS[applicant.role],
            applicant.aura == nil and "Unknown" or (applicant.aura and "Yes" or "No"),
            applicant.needsReview and " |cffff6666(Needs Review)|r" or ""
        ))
    end
    self:RefreshUI()
end

function MSR:SetApplicantRole(applicant, role)
    if not applicant or not self.ROLE_LABELS[role] or role == "UNKNOWN" then return end
    applicant.role = role
    applicant.needsReview = applicant.aura == nil
    applicant.pendingQuestion = self:GetApplicantMissingField(applicant)
    applicant.updatedAt = time()
    self.runtime.groupOptimization = nil
    self:BuildRoster()
    self:RefreshUI()
end

function MSR:CycleApplicantRole(applicant)
    if not applicant then return end
    local nextRole = applicant.role == "TANK" and "HEAL" or applicant.role == "HEAL" and "DPS" or "TANK"
    self:SetApplicantRole(applicant, nextRole)
end

function MSR:ToggleApplicantAura(applicant)
    if not applicant then return end
    applicant.aura = not (applicant.aura == true)
    local tracker = _G.FrostSeekAuraTracker
    local bridge = tracker and tracker.Runtime
    if bridge and type(bridge.setAuraState) == "function" then
        bridge.setAuraState(applicant.name, applicant.aura)
        applicant.auraSource = "manual"
    end
    applicant.needsReview = applicant.role == "UNKNOWN"
    applicant.pendingQuestion = self:GetApplicantMissingField(applicant)
    applicant.updatedAt = time()
    self.runtime.groupOptimization = nil
    self:BuildRoster()
    self:RefreshUI()
end

function MSR:SetApplicantStatus(applicant, status)
    if not applicant then return end
    applicant.status = status
    if status ~= "Invited" then
        applicant.inviteSentAt = nil
        applicant.inviteReminderSent = nil
    end
    applicant.updatedAt = time()
    self:RefreshUI()
end
