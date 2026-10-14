-- options (saved in InspectILvlDB); a missing key means "on", except those listed here
local DEFAULT_OFF = { charSlots = true }
local function opt(key)
    local v = InspectILvlDB and InspectILvlDB[key]
    if v == nil then return not DEFAULT_OFF[key] end
    return v
end

local SLOTS = {
    "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist",
    "Legs", "Feet", "Finger0", "Finger1", "Trinket0", "Trinket1", "MainHand", "SecondaryHand",
}
local ILVL_PATTERN = ITEM_LEVEL and ITEM_LEVEL:gsub("%%d", "(%%d+)") or "Item Level (%d+)"

local scanTip = CreateFrame("GameTooltip", "InspectILvlScanTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

-- returns level (nil if unknown), equipped?, link
local function slotLevel(unit, id)
    local link = GetInventoryItemLink(unit, id)
    if not link then return nil, false end
    scanTip:ClearLines()
    if scanTip:SetInventoryItem(unit, id) then
        for i = 2, math.min(scanTip:NumLines(), 6) do
            local fs = _G["InspectILvlScanTipTextLeft" .. i]
            local t = fs and fs:GetText()
            local lvl = t and t:match(ILVL_PATTERN)
            if lvl then return tonumber(lvl), true, link end
        end
    end
    local ilvl = select(4, GetItemInfo(link))
    if ilvl and ilvl > 0 then return ilvl, true, link end
    return nil, true, link
end

-- the game shows whole numbers (our 471.94 vs its 472): round half up
local function Round(x) return math.floor(x + 0.5) end
-- wands (INVTYPE_RANGEDRIGHT) are one-handed for the average, verified against the game
local TWOHAND = { INVTYPE_2HWEAPON = true, INVTYPE_RANGED = true }
local labels, avg = {}, nil
local retry = 0
local Update

local updater = CreateFrame("Frame")
updater:Hide()
updater:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    if self.t >= 0.5 then
        self.t = 0
        self:Hide()
        if InspectFrame and InspectFrame:IsShown() then Update() end
    end
end)

local function getLabel(name)
    local btn = _G["Inspect" .. name .. "Slot"]
    if not btn then return end
    local fs = labels[name]
    if not fs then
        fs = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        fs:SetPoint("BOTTOM", btn, "BOTTOM", 0, 2)
        labels[name] = fs
    end
    return fs, btn
end

local function ensureAvg()
    if avg then return avg end
    if not InspectFrame then return end
    avg = InspectFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    local anchor = InspectLevelText or InspectNameText
    avg:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
    return avg
end

local lastAverage
-- average item level of `unit`'s equipped gear (16 slots, shirt/tabard excluded);
-- a two-hander/ranged weapon with an empty off-hand counts twice.
-- returns nil while any equipped item is still uncached.
local function Compute(unit)
    local total, n = 0, 0
    for _, name in ipairs(SLOTS) do
        local lvl, equipped, link = slotLevel(unit, (GetInventorySlotInfo(name .. "Slot")))
        if equipped and not lvl then return nil end
        if lvl then
            n = n + 1
            total = total + lvl
            if name == "MainHand" then
                local equipLoc = select(9, GetItemInfo(link))
                if not equipLoc then return nil end
                if TWOHAND[equipLoc] and not GetInventoryItemLink(unit, 17) then total = total + lvl end
            end
        end
    end
    return n > 0 and total / 16 or nil, n
end
InspectILvl_Compute = Compute

Update = function()
    lastAverage = nil
    local unit = InspectFrame and InspectFrame.unit
    if not unit or not UnitExists(unit) then return end
    local showSlots, showAvg = opt("slots"), opt("inspectAvg")
    local count, missing = 0, false
    for _, name in ipairs(SLOTS) do
        local fs, btn = getLabel(name)
        if fs then
            local lvl, equipped, link
            if showSlots or showAvg then lvl, equipped, link = slotLevel(unit, btn:GetID()) end
            if lvl then
                local _, _, q = GetItemInfo(link)
                if q then fs:SetTextColor(GetItemQualityColor(q)) else fs:SetTextColor(1, 1, 1) end
                fs:SetText(showSlots and lvl or "")
                count = count + 1
            else
                fs:SetText("")
                if equipped then missing = true end
            end
        end
    end
    local a = ensureAvg()
    if a then
        lastAverage = (showAvg and not missing) and Compute(unit) or nil
        if not showAvg or count == 0 then
            a:SetText("")
        elseif not lastAverage then
            a:SetText("Item Level: ...")
        else
            a:SetText(string.format("Item Level: |cffffffff%d|r", Round(lastAverage)))
        end
    end
    if missing and retry < 10 then
        retry = retry + 1
        updater:Show()
    end
end

local function Refresh() retry = 0; Update() end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("INSPECT_READY")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "Blizzard_InspectUI" then
        InspectFrame:HookScript("OnShow", Refresh)
        InspectPaperDollFrame:HookScript("OnShow", Refresh)
    elseif event == "INSPECT_READY" and InspectFrame and InspectFrame:IsShown() then
        Refresh()
    end
end)
if IsAddOnLoaded("Blizzard_InspectUI") then f:GetScript("OnEvent")(f, "ADDON_LOADED", "Blizzard_InspectUI") end

-- debug: /iilvl -> our formula vs the game's own value for the player
SLASH_INSPECTILVL1 = "/iilvl"
SlashCmdList["INSPECTILVL"] = function()
    local mine = Compute("player")
    local _, equipped = GetAverageItemLevel()
    print(string.format("InspectILvl self-check: ours %s (raw %s) | game equipped %.1f",
        mine and Round(mine) or "n/a (uncached)", mine and string.format("%.2f", mine) or "-", equipped or 0))
end

----------------------------------------------------------------------
-- Unit tooltip: "Item Level: N" for players (self = game value, others = inspect)
----------------------------------------------------------------------
local cache = {}      -- guid -> { v = rounded ilvl, t = time }
local cacheCount = 0
local pending         -- { unit, guid, tries, start, last }
local lastNotify = 0
local CACHE_SECS = 120
local CACHE_MAX = 200
local MIN_SLOTS = 8       -- fewer equipped slots than this = data not loaded yet
local PENDING_SECS = 6    -- give up on an inspect whose INSPECT_READY never came
local ownNotify, foreignNotify = false, 0

-- note inspects started by anyone else, so we never clear their data
hooksecurefunc("NotifyInspect", function()
    if not ownNotify then foreignNotify = GetTime() end
end)

local function cacheStore(guid, v)
    if not cache[guid] then
        cacheCount = cacheCount + 1
        if cacheCount > CACHE_MAX then    -- drop expired entries
            local now = GetTime()
            for g, c in pairs(cache) do
                if now - c.t >= CACHE_SECS then cache[g] = nil; cacheCount = cacheCount - 1 end
            end
        end
    end
    cache[guid] = { v = v, t = GetTime() }
end

local function addLine(tt, v)
    tt:AddLine("Item Level: |cffffd100" .. v .. "|r")
    tt:Show()
end

local function refreshTooltip(guid)
    if not GameTooltip:IsShown() then return end
    local _, u = GameTooltip:GetUnit()
    if u and UnitGUID(u) == guid then GameTooltip:SetUnit(u) end
end

local retryFrame = CreateFrame("Frame")
retryFrame:Hide()
local finish
retryFrame:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    if self.t >= 0.4 then self.t = 0; self:Hide(); finish() end
end)

finish = function()
    if not pending then return end
    local unit, guid = pending.unit, pending.guid
    if not UnitExists(unit) or UnitGUID(unit) ~= guid then pending = nil; return end
    local started = pending.start
    local avgv, n = Compute(unit)
    -- gear data can arrive in pieces and unloaded slots look empty, so only
    -- trust a read that has enough slots and is identical to the previous one
    local ready = avgv and n >= MIN_SLOTS and pending.last == avgv
    if avgv then pending.last = avgv end
    if ready then
        cacheStore(guid, Round(avgv))
        pending = nil
        if not (InspectFrame and InspectFrame:IsShown()) and foreignNotify < started then
            ClearInspectPlayer()
        end
        refreshTooltip(guid)
    elseif pending.tries < 8 then
        pending.tries = pending.tries + 1
        retryFrame:Show()
    else
        pending = nil
    end
end

-- returns true if the caller should try again shortly (busy or rate-limited)
local function request(unit, guid)
    if pending and GetTime() - pending.start > PENDING_SECS then pending = nil end
    if InspectFrame and InspectFrame:IsShown() then return end
    if not CanInspect(unit) or not CheckInteractDistance(unit, 1) then return end
    if pending or GetTime() - lastNotify < 1.5 then return true end
    lastNotify = GetTime()
    pending = { unit = unit, guid = guid, tries = 0, start = GetTime() }
    ownNotify = true
    NotifyInspect(unit)
    ownNotify = false
end

-- only inspect once the mouse has rested on a player, not while sweeping past
local HOVER_DELAY = 0.3
local HOVER_TRIES = 8     -- re-checks while a request is busy or rate-limited
local hoverGuid, hoverTries
local hoverFrame = CreateFrame("Frame")
hoverFrame:Hide()
hoverFrame:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    if self.t < HOVER_DELAY then return end
    self:Hide()
    local guid = hoverGuid
    hoverGuid = nil
    if not guid or not GameTooltip:IsShown() then return end
    local _, unit = GameTooltip:GetUnit()
    if unit and UnitGUID(unit) == guid and request(unit, guid) and hoverTries < HOVER_TRIES then
        hoverTries = hoverTries + 1
        hoverGuid, self.t = guid, 0
        self:Show()
    end
end)

GameTooltip:HookScript("OnTooltipSetUnit", function(tt)
    if not opt("tooltip") then return end
    local _, unit = tt:GetUnit()
    if not unit or not UnitIsPlayer(unit) then return end
    if UnitIsUnit(unit, "player") then
        local _, equipped = GetAverageItemLevel()
        if equipped and equipped > 0 then addLine(tt, Round(equipped)) end
        return
    end
    local guid = UnitGUID(unit)
    local c = guid and cache[guid]
    if c and GetTime() - c.t < CACHE_SECS then
        addLine(tt, c.v)
    elseif guid then
        hoverGuid, hoverTries = guid, 0
        hoverFrame.t = 0
        hoverFrame:Show()
    end
end)

local tipEvents = CreateFrame("Frame")
tipEvents:RegisterEvent("INSPECT_READY")
tipEvents:SetScript("OnEvent", function(_, _, guid)
    if pending and (not guid or guid == pending.guid) then finish() end
end)

----------------------------------------------------------------------
-- Character window: average item level and per-slot item levels
----------------------------------------------------------------------
local charLabels, charAvg = {}, nil

local function RefreshChar()
    if not (PaperDollFrame and PaperDollFrame:IsShown()) then return end
    local showSlots, showAvg = opt("charSlots"), opt("charAvg")
    for _, name in ipairs(SLOTS) do
        local btn = _G["Character" .. name .. "Slot"]
        if btn then
            local fs = charLabels[name]
            if not fs then
                fs = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
                fs:SetPoint("BOTTOM", btn, "BOTTOM", 0, 2)
                charLabels[name] = fs
            end
            local lvl, equipped, link
            if showSlots then lvl, equipped, link = slotLevel("player", btn:GetID()) end
            if lvl then
                local q = select(3, GetItemInfo(link))
                if q then fs:SetTextColor(GetItemQualityColor(q)) else fs:SetTextColor(1, 1, 1) end
                fs:SetText(lvl)
            else
                fs:SetText("")
            end
        end
    end
    if not charAvg then
        charAvg = PaperDollFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        charAvg:SetPoint("TOP", CharacterLevelText or CharacterFrameTitleText, "BOTTOM", 0, -2)
    end
    local _, equippedAvg = GetAverageItemLevel()
    if showAvg and equippedAvg and equippedAvg > 0 then
        charAvg:SetText(string.format("Item Level: |cffffffff%d|r", Round(equippedAvg)))
    else
        charAvg:SetText("")
    end
end

-- gear/average values update a moment after the equipment event
local charUpdater = CreateFrame("Frame")
charUpdater:Hide()
charUpdater:SetScript("OnUpdate", function(self, elapsed)
    self.t = (self.t or 0) + elapsed
    if self.t >= 0.2 then self.t = 0; self:Hide(); RefreshChar() end
end)

if PaperDollFrame then PaperDollFrame:HookScript("OnShow", RefreshChar) end
local charEvents = CreateFrame("Frame")
charEvents:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
charEvents:RegisterEvent("UNIT_INVENTORY_CHANGED")
charEvents:SetScript("OnEvent", function(_, event, unit)
    if event == "UNIT_INVENTORY_CHANGED" and unit ~= "player" then return end
    if PaperDollFrame and PaperDollFrame:IsShown() then charUpdater:Show() end
end)

----------------------------------------------------------------------
-- Interface > AddOns options page
----------------------------------------------------------------------
local panel = CreateFrame("Frame", "InspectILvlOptions", UIParent)
panel.name = "InspectILvl"

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("InspectILvl")
local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
sub:SetText("Choose where item levels are shown.")

local OPTIONS = {
    { key = "slots",      text = "Item level on each slot in the inspect window" },
    { key = "inspectAvg", text = "Average item level in the inspect window" },
    { key = "tooltip",    text = "Average item level in player tooltips" },
    { key = "charAvg",    text = "Average item level in your Character window" },
    { key = "charSlots",  text = "Item level on each slot in your Character window" },
}
local boxes = {}
local function applyChange()
    if InspectFrame and InspectFrame:IsShown() then Refresh() end
    RefreshChar()
end
for i, o in ipairs(OPTIONS) do
    local cb = CreateFrame("CheckButton", "InspectILvlOpt" .. o.key, panel, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -12 - (i - 1) * 28)
    _G[cb:GetName() .. "Text"]:SetText(o.text)
    cb:SetScript("OnClick", function(self)
        InspectILvlDB = InspectILvlDB or {}
        InspectILvlDB[o.key] = self:GetChecked() and true or false
        PlaySound(self:GetChecked() and "igMainMenuOptionCheckBoxOn" or "igMainMenuOptionCheckBoxOff")
        applyChange()
    end)
    boxes[o.key] = cb
end

local function refreshBoxes()
    for _, o in ipairs(OPTIONS) do boxes[o.key]:SetChecked(opt(o.key)) end
end
panel.refresh = refreshBoxes
panel:SetScript("OnShow", refreshBoxes)
panel.default = function()      -- "Defaults" button: everything on
    InspectILvlDB = {}
    refreshBoxes()
    applyChange()
end
InterfaceOptions_AddCategory(panel)
