-- FrostSeek Aura Tracker v1.5 recruiter workspace
-- Independently implemented workflow inspired by common raid-recruiter UX.

local FSA = _G.FrostSeekAuraTracker
if not FSA or not FSA.Module or not FSA.Runtime then return end

local R = FSA.Runtime
local UI = { phase = "SETUP", rows = {}, groups = {} }
local ROLE_ORDER = { "DPS", "TANK", "HEAL" }
local PHASES = { "SETUP", "WAITING", "RAID", "RUN", "REBUILD" }

local function DB()
    FrostSeekAuraDB.recruiter = FrostSeekAuraDB.recruiter or {}
    local db = FrostSeekAuraDB.recruiter
    db.slots = db.slots or { tank=2, heal=3, dps=10, aura=3, total=15 }
    db.applicants = db.applicants or {}
    db.reservations = db.reservations or {}
    db.messages = db.messages or {
        recruit = "LFM Manastorm {total}/{totalMax} - Need {needed}",
        roster = "Manastorm roster: {total}/{totalMax}; Auras {aura}/{auraMax}",
        level59 = "{player} is level 59 - replacement needed soon.",
        level60 = "{player} reached 60 and will be replaced.",
        leave = "Run complete. Thanks everyone.",
    }
    db.rebuild = db.rebuild or { active=false, stage="idle", roster={} }
    db.phase = db.phase or "SETUP"
    return db
end

local function Key(name) return R.key(name or "") end
local function Short(name) return string.match(name or "", "^[^-]+") or name or "?" end
local function Theme(key, fallback)
    local theme=_G.FrostSeekTheme
    if theme and theme.Get then
        local ok,value=pcall(theme.Get,key)
        if ok and type(value)=="table" then return value end
    end
    return fallback
end
local function Paint(texture,key,fallback)
    local c=Theme(key,fallback); texture:SetTexture(c[1],c[2],c[3],c[4] or 1)
end
local function Block(parent)
    local f = CreateFrame("Frame", nil, parent)
    local bg=f:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); Paint(bg,"bgBlock",{0.08,0.09,0.11,0.96}); f.bg=bg
    return f
end

local function Label(parent, text, size)
    local f = parent:CreateFontString(nil,"OVERLAY", size or "GameFontNormalSmall")
    f:SetText(text or "")
    return f
end

local function Button(parent, w, h, text, fn)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w,h)
    local edge=b:CreateTexture(nil,"BORDER"); edge:SetPoint("TOPLEFT",-1,1); edge:SetPoint("BOTTOMRIGHT",1,-1); Paint(edge,"border",{0.25,0.30,0.36,1})
    local bg=b:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); Paint(bg,"bgRowHover",{0.14,0.16,0.20,1})
    local label=b:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); label:SetPoint("CENTER"); label:SetText(text)
    b.bg,b.text=bg,label
    function b:SetText(value) self.text:SetText(value) end
    function b:SetEnabled(enabled) if enabled then self:Enable(); self.text:SetTextColor(1,0.82,0) else self:Disable(); self.text:SetTextColor(0.5,0.5,0.5) end end
    b:SetScript("OnClick", fn)
    b:SetScript("OnEnter",function(self) Paint(self.bg,"bgTabActive",{0.18,0.25,0.32,1}) end)
    b:SetScript("OnLeave",function(self) Paint(self.bg,"bgRowHover",{0.14,0.16,0.20,1}) end)
    return b
end

local function Edit(parent,w,h,text,numeric)
    local e=CreateFrame("EditBox",nil,parent)
    e:SetSize(w,h); e:SetAutoFocus(false); e:SetFontObject("GameFontHighlightSmall"); e:SetTextInsets(7,7,2,2)
    local edge=e:CreateTexture(nil,"BACKGROUND"); edge:SetPoint("TOPLEFT",-1,1); edge:SetPoint("BOTTOMRIGHT",1,-1); Paint(edge,"border",{0.25,0.30,0.36,1})
    local bg=e:CreateTexture(nil,"BACKGROUND"); bg:SetAllPoints(); Paint(bg,"bgInput",{0.025,0.03,0.04,0.98})
    e:SetText(tostring(text or "")); e:SetNumeric(numeric and true or false)
    return e
end

local function AuraTexture(texture)
    texture:SetTexture("Interface\\AddOns\\FrostSeek_AuraTracker\\Textures\\AuraOfExperience")
end

local function CurrentApplicants()
    local db=DB()
    for _, source in ipairs({R.state.candidates or {}, R.state.nonAuraCandidates or {}}) do
        for key, item in pairs(source) do
            local a=db.applicants[key] or {}
            a.name=item.name or a.name; a.role=item.role or a.role; a.aura=item.aura
            a.level=item.level or a.level; a.message=item.message or a.message
            a.time=item.time or a.time or GetTime(); a.status=a.status or "Waiting"
            db.applicants[key]=a
        end
    end
    local list={}
    for _,a in pairs(db.applicants) do
        if a.status~="Rejected" and a.status~="Joined" then table.insert(list,a) end
    end
    table.sort(list,function(a,b)
        local ar=a.status=="Reserved" and 0 or 1; local br=b.status=="Reserved" and 0 or 1
        if ar~=br then return ar<br end
        return (a.time or 0)>(b.time or 0)
    end)
    return list
end

local function RoleFor(name)
    local ev=R.state.roleEvidence and R.state.roleEvidence[Key(name)]
    if ev and ev.inferredRole=="TANK" then return "TANK" end
    if ev and ev.inferredRole=="HEALER" then return "HEAL" end
    local a=DB().applicants[Key(name)]
    return a and a.role or "DPS"
end

local function Counts()
    local c={tank=0,heal=0,dps=0,aura=0,total=0}
    for _,info in pairs(R.state.roster or {}) do
        c.total=c.total+1
        local role=RoleFor(info.name)
        if role=="TANK" then c.tank=c.tank+1 elseif role=="HEAL" then c.heal=c.heal+1 else c.dps=c.dps+1 end
        if info.marked or info.detected then c.aura=c.aura+1 end
    end
    return c
end

local function NeededText()
    local c,s=Counts(),DB().slots; local out={}
    if c.tank<s.tank then table.insert(out,(s.tank-c.tank).." Tank") end
    if c.heal<s.heal then table.insert(out,(s.heal-c.heal).." Healer") end
    if c.dps<s.dps then table.insert(out,(s.dps-c.dps).." DPS") end
    if c.aura<s.aura then table.insert(out,(s.aura-c.aura).." Aura") end
    return #out>0 and table.concat(out,", ") or "raid ready"
end

local function Expand(template, player)
    local c,s=Counts(),DB().slots
    local values={total=c.total,totalMax=s.total,aura=c.aura,auraMax=s.aura,tank=c.tank,heal=c.heal,dps=c.dps,needed=NeededText(),player=player or "player"}
    return (string.gsub(template or "","{([%w]+)}",function(k) return tostring(values[k] or "{"..k.."}") end))
end

local function SetPhase(phase)
    UI.phase=phase; DB().phase=phase
    for name,panel in pairs(UI.panels or {}) do if name==phase then panel:Show() else panel:Hide() end end
    for name,b in pairs(UI.tabs or {}) do b:SetEnabled(name~=phase) end
    if UI.refresh then UI.refresh() end
end

local function CycleRole(a)
    local n=1
    for i,v in ipairs(ROLE_ORDER) do if a.role==v then n=(i%#ROLE_ORDER)+1 end end
    a.role=ROLE_ORDER[n]
end

local function Invite(a)
    InviteUnit(a.name); a.status="Invited"; DB().reservations[Key(a.name)]=true
    R.print("Invited "..a.name.." and reserved a roster slot.")
end

local function Reserve(a)
    a.status="Reserved"; DB().reservations[Key(a.name)]=true
end

local function Release(a)
    a.status="Waiting"; DB().reservations[Key(a.name)]=nil
end

local function Reject(a)
    a.status="Rejected"; DB().reservations[Key(a.name)]=nil
end

local function OptimizeOneStep()
    if not IsRaidLeader() and not IsRaidOfficer() then R.print("Raid leader or assistant required."); return end
    local groups={{TANK=1,HEAL=1,DPS=3},{TANK=1,HEAL=1,DPS=3},{TANK=0,HEAL=1,DPS=4}}
    local used={}; local desired={}
    for g=1,3 do
        local auraPick=nil
        for key,info in pairs(R.state.roster or {}) do
            if not used[key] and (info.marked or info.detected) then auraPick=key; break end
        end
        if auraPick then desired[auraPick]=g; used[auraPick]=true; local role=RoleFor(R.state.roster[auraPick].name); groups[g][role]=math.max(0,(groups[g][role] or 0)-1) end
        for _,role in ipairs({"TANK","HEAL","DPS"}) do
            while (groups[g][role] or 0)>0 do
                local pick=nil
                for key,info in pairs(R.state.roster or {}) do if not used[key] and RoleFor(info.name)==role then pick=key; break end end
                if not pick then break end
                desired[pick]=g; used[pick]=true; groups[g][role]=groups[g][role]-1
            end
        end
    end
    for key,info in pairs(R.state.roster or {}) do
        local target=desired[key]
        if target and info.subgroup~=target then
            if type(SetRaidSubgroup)=="function" then SetRaidSubgroup(info.raidIndex,target); R.print("Moving "..info.name.." to Group "..target..". Click Verify / Next after the roster updates."); return end
        end
    end
    R.print("Group optimization complete or no safe move remains.")
end

local function StartManastorm()
    local c,s=Counts(),DB().slots
    if c.total<s.total or c.aura<s.aura then R.print("Cannot start: "..NeededText().."."); return end
    if not C_Manastorm or type(C_Manastorm.Enter)~="function" then R.print("Ascension Manastorm API is unavailable."); return end
    local ok,result=pcall(C_Manastorm.Enter,1)
    if ok and result~=false then FrostSeekAuraDB.recruiting=false; SetPhase("RUN"); R.print("Manastorm Level 1 entry requested.") else R.print("Manastorm entry request was rejected.") end
end

local function BeginRebuild()
    local rb=DB().rebuild; rb.active=true; rb.stage="remove60"; rb.roster={}
    for key,info in pairs(R.state.roster or {}) do rb.roster[key]={name=info.name,level=info.level} end
    SetPhase("REBUILD")
end

local function RebuildAction()
    local rb=DB().rebuild
    if not rb.active then BeginRebuild(); return end
    if rb.stage=="remove60" then
        for _,info in pairs(R.state.roster or {}) do
            if tonumber(info.level)==60 then
                if type(UninviteUnit)=="function" then UninviteUnit(info.name); R.print("Removing level-60 player "..info.name..". Click again after the roster updates."); return end
            end
        end
        rb.stage="leave"
    end
    if rb.stage=="leave" then
        if R.isInManastorm() and C_Manastorm and type(C_Manastorm.Leave)=="function" then pcall(C_Manastorm.Leave); R.print("Manastorm exit requested. Click again after exit."); return end
        rb.stage="reinvite"
    end
    if rb.stage=="reinvite" then
        for key,item in pairs(rb.roster) do
            if tonumber(item.level or 0)<60 and not R.state.roster[key] then InviteUnit(item.name); rb.roster[key]=nil; R.print("Reinvited "..item.name..". Continue until complete."); return end
        end
        rb.active=false; rb.stage="complete"; SetPhase("WAITING"); R.print("Rebuild pass complete. Recruit replacements and optimize groups.")
    end
end

local function PostAndLeave()
    local now=GetTime()
    if not UI.leaveArmed or now>UI.leaveArmed then UI.leaveArmed=now+5; R.print("Click Post & Leave again within 5 seconds to confirm."); return end
    R.sendGroupMessage(Expand(DB().messages.leave))
    if R.isInManastorm() and C_Manastorm and type(C_Manastorm.Leave)=="function" then pcall(C_Manastorm.Leave) end
    if type(LeaveParty)=="function" then LeaveParty() end
    UI.leaveArmed=nil
end

local function ShowMessageEditor()
    if not UI.messageFrame then
        local f=Block(UI.root); f:SetSize(650,410); f:SetPoint("CENTER"); f:SetFrameLevel(UI.root:GetFrameLevel()+20)
        local t=Label(f,"Editable messages","GameFontNormalLarge"); t:SetPoint("TOPLEFT",16,-14)
        UI.messageEdits={}; local keys={"recruit","roster","level59","level60","leave"}
        for i,key in ipairs(keys) do
            local l=Label(f,key); l:SetPoint("TOPLEFT",18,-52-((i-1)*58))
            local e=Edit(f,595,24,DB().messages[key]); e:SetPoint("TOPLEFT",18,-70-((i-1)*58)); e:SetMaxLetters(240); UI.messageEdits[key]=e
        end
        local save=Button(f,90,24,"Save",function() for k,e in pairs(UI.messageEdits) do DB().messages[k]=e:GetText() end f:Hide() end); save:SetPoint("BOTTOMRIGHT",-112,14)
        local close=Button(f,90,24,"Cancel",function() f:Hide() end); close:SetPoint("BOTTOMRIGHT",-16,14)
        UI.messageFrame=f
    end
    for k,e in pairs(UI.messageEdits) do e:SetText(DB().messages[k] or "") end
    UI.messageFrame:Show()
end

local function CreateWorkspace(parent)
    local root=Block(parent); root:SetAllPoints(); root:SetFrameLevel(parent:GetFrameLevel()+10); root:Hide(); UI.root=root
    root.elapsed=0
    root:SetScript("OnUpdate",function(self,elapsed)
        self.elapsed=(self.elapsed or 0)+elapsed
        if self.elapsed>=1 then self.elapsed=0; UI.refresh() end
    end)
    local title=Label(root,"|cff88ccffFrostSeek Manastorm Recruiter|r  |cffaaaaaav1.5 verification|r","GameFontNormalLarge"); title:SetPoint("TOPLEFT",16,-13)
    local close=Button(root,72,22,"Close",function() root:Hide() end); close:SetPoint("TOPRIGHT",-14,-10)
    local messages=Button(root,104,22,"Edit Messages",ShowMessageEditor); messages:SetPoint("RIGHT",close,"LEFT",-6,0)

    UI.tabs={}; UI.panels={}
    local last=nil
    for _,phase in ipairs(PHASES) do
        local b=Button(root,86,22,phase,function() SetPhase(phase) end)
        if last then b:SetPoint("LEFT",last,"RIGHT",4,0) else b:SetPoint("TOPLEFT",16,-42) end
        UI.tabs[phase]=b; last=b
        local p=CreateFrame("Frame",nil,root); p:SetPoint("TOPLEFT",12,-70); p:SetPoint("BOTTOMRIGHT",-12,48); UI.panels[phase]=p
    end

    local setup=UI.panels.SETUP
    local h=Label(setup,"Roster targets","GameFontNormal"); h:SetPoint("TOPLEFT",8,-8)
    UI.slotEdits={}; local x=8
    for _,def in ipairs({{"Tank","tank"},{"Heal","heal"},{"DPS","dps"},{"Aura","aura"},{"Total","total"}}) do
        local l=Label(setup,def[1]); l:SetPoint("TOPLEFT",x,-40)
        local e=Edit(setup,42,22,DB().slots[def[2]],true); e:SetPoint("TOPLEFT",x,-58); UI.slotEdits[def[2]]=e; x=x+82
    end
    local save=Button(setup,96,24,"Save Targets",function() for k,e in pairs(UI.slotEdits) do DB().slots[k]=tonumber(e:GetText()) or DB().slots[k] end if UI.refresh then UI.refresh() end end); save:SetPoint("TOPLEFT",8,-94)
    local desc=Label(setup,"Recruiting accepts role, Aura and level replies. Exact 'aura' remains the optional auto-invite trigger.\nUse Waiting to correct applicants and reserve slots; use Raid to distribute groups.","GameFontHighlightSmall"); desc:SetPoint("TOPLEFT",8,-140); desc:SetWidth(770); desc:SetJustifyH("LEFT")

    local waiting=UI.panels.WAITING
    local wh=Label(waiting,"Waiting applicants","GameFontNormal"); wh:SetPoint("TOPLEFT",8,-8)
    for i=1,7 do
        local index=i
        local row=Block(waiting); row:SetPoint("TOPLEFT",8,-32-((i-1)*43)); row:SetSize(820,39)
        local name=Label(row,""); name:SetPoint("LEFT",8,0); name:SetWidth(150); name:SetJustifyH("LEFT")
        local role=Button(row,60,20,"Role",function() local a=UI.rows[index].applicant if a then CycleRole(a); UI.refresh() end end); role:SetPoint("LEFT",165,0)
        local aura=Button(row,58,20,"Aura",function() local a=UI.rows[index].applicant if a then a.aura=not a.aura; UI.refresh() end end); aura:SetPoint("LEFT",229,0)
        local status=Label(row,""); status:SetPoint("LEFT",294,0); status:SetWidth(105); status:SetJustifyH("LEFT")
        local invite=Button(row,66,20,"Invite",function() local a=UI.rows[index].applicant if a then Invite(a); UI.refresh() end end); invite:SetPoint("LEFT",405,0)
        local reserve=Button(row,70,20,"Reserve",function() local a=UI.rows[index].applicant if a then Reserve(a); UI.refresh() end end); reserve:SetPoint("LEFT",475,0)
        local release=Button(row,66,20,"Release",function() local a=UI.rows[index].applicant if a then Release(a); UI.refresh() end end); release:SetPoint("LEFT",549,0)
        local reject=Button(row,62,20,"Reject",function() local a=UI.rows[index].applicant if a then Reject(a); UI.refresh() end end); reject:SetPoint("LEFT",619,0)
        local detail=Label(row,""); detail:SetPoint("LEFT",687,0); detail:SetWidth(125); detail:SetJustifyH("LEFT")
        UI.rows[i]={frame=row,name=name,role=role,aura=aura,status=status,detail=detail}
    end

    local raid=UI.panels.RAID
    local summary=Label(raid,""); summary:SetPoint("TOPLEFT",8,-7); UI.raidSummary=summary
    for g=1,3 do
        local card=Block(raid); card:SetPoint("TOPLEFT",8+((g-1)*276),-32); card:SetSize(266,230)
        local gh=Label(card,"Group "..g,"GameFontNormal"); gh:SetPoint("TOPLEFT",8,-8)
        local gs=Label(card,""); gs:SetPoint("TOPRIGHT",-8,-9); gs:SetWidth(110); gs:SetJustifyH("RIGHT")
        local rows={}
        for slot=1,5 do
            local aura=CreateFrame("Button",nil,card); aura:SetSize(22,22); aura:SetPoint("TOPLEFT",8,-36-((slot-1)*35)); local tex=aura:CreateTexture(nil,"ARTWORK"); tex:SetAllPoints(); AuraTexture(tex)
            local nm=Label(card,""); nm:SetPoint("LEFT",aura,"RIGHT",5,0); nm:SetWidth(150); nm:SetJustifyH("LEFT")
            local rl=Label(card,""); rl:SetPoint("RIGHT",-8,-36-((slot-1)*35)); rl:SetWidth(52); rl:SetJustifyH("RIGHT")
            rows[slot]={aura=aura,texture=tex,name=nm,role=rl}
        end
        UI.groups[g]={state=gs,rows=rows}
    end
    local optimize=Button(raid,120,24,"Optimize / Next",OptimizeOneStep); optimize:SetPoint("BOTTOMLEFT",8,8)
    local ready=Button(raid,100,24,"Ready Check",R.readyCheck); ready:SetPoint("LEFT",optimize,"RIGHT",6,0)
    local roster=Button(raid,95,24,"Post Roster",R.postRoster); roster:SetPoint("LEFT",ready,"RIGHT",6,0)

    local run=UI.panels.RUN
    local runText=Label(run,"Run monitoring keeps FrostSeek's live Aura sensors, provider-loss alerts, role inference and level-59 replacement warnings active.","GameFontHighlight"); runText:SetPoint("TOPLEFT",12,-20); runText:SetWidth(780); runText:SetJustifyH("LEFT")
    local start=Button(run,130,28,"Start MS Level 1",StartManastorm); start:SetPoint("TOPLEFT",12,-72)
    local rebuild=Button(run,120,28,"Rebuild Raid",BeginRebuild); rebuild:SetPoint("LEFT",start,"RIGHT",8,0)
    local leave=Button(run,120,28,"Post & Leave",PostAndLeave); leave:SetPoint("LEFT",rebuild,"RIGHT",8,0)

    local rebuildPanel=UI.panels.REBUILD
    local rbText=Label(rebuildPanel,""); rbText:SetPoint("TOPLEFT",12,-20); rbText:SetWidth(780); rbText:SetJustifyH("LEFT"); UI.rebuildText=rbText
    local rbAction=Button(rebuildPanel,180,28,"Begin Rebuild",RebuildAction); rbAction:SetPoint("TOPLEFT",12,-70); UI.rebuildAction=rbAction

    local footer=Label(root,""); footer:SetPoint("BOTTOMLEFT",16,18); footer:SetWidth(780); footer:SetJustifyH("LEFT"); UI.footer=footer
    return root
end

UI.refresh=function()
    if not UI.root then return end
    local applicants=CurrentApplicants()
    for i,row in ipairs(UI.rows) do
        local a=applicants[i]; row.applicant=a
        if a then row.frame:Show(); row.name:SetText(Short(a.name).."  L"..tostring(a.level or "?")); row.role:SetText(a.role or "Role?"); row.aura:SetText(a.aura==true and "Aura+" or a.aura==false and "Aura-" or "Aura?"); row.status:SetText(a.status or "Waiting"); row.detail:SetText(string.sub(a.message or "",1,18)) else row.frame:Hide() end
    end
    local c,s=Counts(),DB().slots
    if UI.raidSummary then UI.raidSummary:SetText(string.format("Raid %d/%d   T %d/%d   H %d/%d   D %d/%d   Auras %d/%d",c.total,s.total,c.tank,s.tank,c.heal,s.heal,c.dps,s.dps,c.aura,s.aura)) end
    for g=1,3 do
        local players={}; for _,info in pairs(R.state.roster or {}) do if info.subgroup==g then table.insert(players,info) end end
        table.sort(players,function(a,b) return (a.raidIndex or 99)<(b.raidIndex or 99) end)
        local auraCount=0
        for slot=1,5 do
            local row=UI.groups[g].rows[slot]; local info=players[slot]
            if info then
                local active=info.marked or info.detected; if active then auraCount=auraCount+1 end
                row.name:SetText(info.name.."  L"..tostring(info.level or "?")); row.role:SetText(RoleFor(info.name)); row.texture:SetAlpha(active and 1 or 0.18); if row.texture.SetDesaturated then row.texture:SetDesaturated(not active) end
                row.aura:SetScript("OnClick",function() R.toggleAuraProvider(info.name); UI.refresh() end); row.aura:Enable()
            else row.name:SetText("|cff555555Empty|r"); row.role:SetText(""); row.texture:SetAlpha(0); row.aura:SetScript("OnClick",nil); row.aura:Disable() end
        end
        UI.groups[g].state:SetText(auraCount==1 and "|cff66ff66AURA OK|r" or auraCount>1 and "|cffffaa00DUPLICATE|r" or "|cffff5555NO AURA|r")
    end
    local rb=DB().rebuild
    if UI.rebuildText then UI.rebuildText:SetText("Recovery stage: "..tostring(rb.stage)..". Actions are deliberately stepwise because raid removal, Manastorm exit and invitations are protected/asynchronous.") end
    if UI.rebuildAction then UI.rebuildAction:SetText(not rb.active and "Begin Rebuild" or rb.stage=="remove60" and "Remove 60s / Next" or rb.stage=="leave" and "Leave MS / Next" or "Reinvite / Next") end
    UI.footer:SetText("Need: "..NeededText().."   Waiting: "..#applicants.."   Phase: "..UI.phase)
end

local oldInitialize=FSA.Module.Initialize
FSA.Module.Initialize=function(self,parent)
    oldInitialize(self,parent)
    if not UI.root then
        CreateWorkspace(self.frame)
        local open=Button(self.frame,112,24,"Recruiter Setup",function() UI.root:Show(); SetPhase(DB().phase or "SETUP") end)
        open:SetPoint("TOPRIGHT",-218,-14)
        UI.openButton=open
    end
    UI.refresh()
end

local oldShow=FSA.Module.Show
FSA.Module.Show=function(self) oldShow(self); if UI.root and UI.root:IsShown() then UI.refresh() end end

-- Compact minimap access. Dragging is intentionally left to FrostSeek's own
-- minimap system; this button only opens the integrated recruiter workspace.
local mini=CreateFrame("Button","FrostSeekAuraRecruiterMinimapButton",Minimap)
mini:SetSize(28,28); mini:SetPoint("TOPLEFT",-2,-18); mini:SetFrameStrata("MEDIUM")
local mt=mini:CreateTexture(nil,"ARTWORK"); mt:SetAllPoints(); AuraTexture(mt)
mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
mini:SetScript("OnClick",function() if FSA.Module.frame then FSA.Module.frame:Show(); UI.root:Show(); SetPhase(DB().phase or "SETUP") end end)
mini:SetScript("OnEnter",function(self) GameTooltip:SetOwner(self,"ANCHOR_LEFT"); GameTooltip:SetText("FrostSeek Manastorm Recruiter"); GameTooltip:AddLine("Open the v1.5 raid workflow.",0.8,0.8,0.8); GameTooltip:Show() end)
mini:SetScript("OnLeave",function() GameTooltip:Hide() end)
