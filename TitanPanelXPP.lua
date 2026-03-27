---@diagnostic disable: duplicate-set-field
-- **************************************************************************
-- * TitanPanelXPP.lua
-- *
-- * By: Spotnick
-- * A Titan Panel plugin that displays an XP progress bar with detailed
-- * leveling statistics, inspired by popular XP tracking WeakAuras.
-- **************************************************************************

-- ******************************** Constants *******************************
local _G = getfenv(0)
local TITAN_XPP_ID = "XPPlus"
local TITAN_XPP_BUTTON = "TitanPanel" .. TITAN_XPP_ID .. "Button"
local ADDON_MSG_PREFIX = "TitanXPPlus"

-- Bar visual settings
local BAR_HEIGHT = 14
local BAR_MIN_WIDTH = 340

-- Colors (r, g, b, a) — matching the WeakAura color scheme
local COLOR_XP_BAR        = { 0.25, 0.60, 0.90, 0.90 }  -- Blue XP fill
local COLOR_COMPLETE_BAR  = { 1.00, 0.59, 0.04, 0.85 }  -- Orange completed quest XP
local COLOR_INCOMPLETE_BAR= { 0.90, 0.80, 0.10, 0.85 }  -- Yellow incomplete quest XP
local COLOR_RESTED_BAR    = { 0.31, 0.56, 1.00, 0.40 }  -- Lighter blue rested overlay
local COLOR_BAR_BG        = { 0.12, 0.12, 0.15, 0.60 }  -- Dark background
local COLOR_BAR_BORDER    = { 0.35, 0.35, 0.35, 0.85 }  -- Subtle border

-- ******************************** Variables *******************************
local AceTimer = LibStub("AceTimer-3.0")
local XPPTimer = {}
XPPTimer.timer = nil
XPPTimer.delay = 10
XPPTimer.running = false
XPPTimer.last = 0

-- State table
local xpp = {
    frame = nil,
    lastMobXP = 0,
    XPGain = 0,
    initXP = 0,
    lastXP = 0,
    accumXP = 0,
    sessionXP = 0,
    startSessionTime = 0,
    totalTime = 0,
    levelTime = 0,
    barCreated = false,
    updatingBar = false,
    isMaxLevel = false,
    completedQuestXP = 0,
    incompleteQuestXP = 0,
    totalQuestXP = 0,
}

-- Bar frame references
local barBG, xpBar, completeQuestBar, incompleteQuestBar, restedBar, barBorder
local barTextLeft, barTextCenter, barTextRight
local barIconOverlay  -- our own icon on top of the bar

-- Chat message suppression for RequestTimePlayed
local xpp_requesting = false
local xpp_chat_hooked = false

local function HookTimePlayed()
    if xpp_chat_hooked then return end
    xpp_chat_hooked = true

    if Titan_Global and Titan_Global.switch and Titan_Global.switch.chat_class then
        if ChatFrameUtil and ChatFrameUtil.DisplayTimePlayed then
            local orig = ChatFrameUtil.DisplayTimePlayed
            ChatFrameUtil.DisplayTimePlayed = function(...)
                if xpp_requesting then
                    xpp_requesting = false
                    return
                end
                return orig(...)
            end
        end
    else
        if ChatFrame_DisplayTimePlayed then
            local orig = ChatFrame_DisplayTimePlayed
            ChatFrame_DisplayTimePlayed = function(...)
                if xpp_requesting then
                    xpp_requesting = false
                    return
                end
                return orig(...)
            end
        end
    end
end

-- ******************************** Utility *******************************

---Check if player is at max level
---@return boolean
local function IsMaxLevel()
    local level = UnitLevel("player") or 0
    if GetMaxLevelForExpansionLevel then
        local exp = GetExpansionLevel and GetExpansionLevel() or 0
        local ml = GetMaxLevelForExpansionLevel(exp)
        if ml and level >= ml then return true end
    elseif MAX_PLAYER_LEVEL and level >= MAX_PLAYER_LEVEL then
        return true
    elseif MAX_PLAYER_LEVEL_TABLE then
        local exp = GetExpansionLevel and GetExpansionLevel() or 0
        local ml = MAX_PLAYER_LEVEL_TABLE[exp] or 60
        if level >= ml then return true end
    end
    return false
end

---Format a number with comma separators
---@param amount number
---@return string
local function FormatNumber(amount)
    if not amount then return "0" end
    amount = math.floor(amount + 0.5)

    local sep = ","
    local dec = "."
    if TitanGetVar then
        local ok, usePeriod = pcall(TitanGetVar, TITAN_XPP_ID, "UseSeperatorPeriod")
        if ok and usePeriod then
            sep = "."
            dec = ","
        end
    end

    if TitanUtils_NumToString then
        return TitanUtils_NumToString(amount, sep, dec)
    end

    if amount < 1000 then return tostring(amount) end
    local s = tostring(amount)
    local result, count = "", 0
    for i = #s, 1, -1 do
        count = count + 1
        result = s:sub(i, i) .. result
        if count % 3 == 0 and i > 1 then
            result = sep .. result
        end
    end
    return result
end

---Request time played from server without spamming chat
local function RefreshPlayed()
    if xpp.frame and xpp.frame.RequestTimePlayed then
        xpp.frame:RequestTimePlayed()
    else
        xpp_requesting = true
        pcall(RequestTimePlayed)
    end
end

---Hide or show the default WoW experience bar based on user setting
local function UpdateDefaultXPBar()
    local ok, hideIt = pcall(TitanGetVar, TITAN_XPP_ID, "HideDefaultXPBar")
    if not ok then return end

    if hideIt then
        -- Retail: StatusTrackingBarManager or MainStatusTrackingBarContainer
        if StatusTrackingBarManager then
            pcall(function() StatusTrackingBarManager:Hide() end)
        end
        if MainStatusTrackingBarContainer then
            pcall(function() MainStatusTrackingBarContainer:Hide() end)
        end
        -- Classic: MainMenuExpBar
        if MainMenuExpBar then
            pcall(function() MainMenuExpBar:Hide() end)
        end
    else
        if StatusTrackingBarManager then
            pcall(function() StatusTrackingBarManager:Show() end)
        end
        if MainStatusTrackingBarContainer then
            pcall(function() MainStatusTrackingBarContainer:Show() end)
        end
        if MainMenuExpBar then
            pcall(function() MainMenuExpBar:Show() end)
        end
    end
end

-- ******************************** Quest XP *******************************

---Calculate XP from quests in the quest log (both completed and incomplete)
---Matches the WeakAura's UpdateQuestXP approach
---@return number completeXP, number incompleteXP
local function GetQuestXPBreakdown()
    local completeXP = 0
    local incompleteXP = 0

    -- Grab API references (matching WA pattern for compat)
    local _GetNumQuestLogEntries = (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) or GetNumQuestLogEntries
    local _GetQuestIDForLogIndex = (C_QuestLog and C_QuestLog.GetQuestIDForLogIndex) or function(i)
        return select(8, GetQuestLogTitle(i))
    end
    local _SelectQuestLogEntry = SelectQuestLogEntry or function() end
    local _IsQuestComplete = (C_QuestLog and C_QuestLog.IsComplete) or IsQuestComplete or function() return false end
    local _QuestReadyForTurnIn = (C_QuestLog and C_QuestLog.ReadyForTurnIn) or function() return false end
    local _GetQuestLogRewardXP = GetQuestLogRewardXP or function() return 0 end

    if not _GetNumQuestLogEntries then return 0, 0 end

    local numQ = _GetNumQuestLogEntries() or 0

    -- Save current quest log selection so we can restore it
    local savedSelection = 0
    if GetQuestLogSelection then
        savedSelection = GetQuestLogSelection()
    end

    for i = 1, numQ do
        _SelectQuestLogEntry(i)
        local questID = _GetQuestIDForLogIndex(i)

        if questID and questID > 0 then
            local rewardXP = _GetQuestLogRewardXP(questID) or 0

            if rewardXP > 0 then
                if _IsQuestComplete(questID) or _QuestReadyForTurnIn(questID) then
                    completeXP = completeXP + rewardXP
                else
                    incompleteXP = incompleteXP + rewardXP
                end
            end
        end
    end

    -- Restore original quest log selection
    if savedSelection > 0 then
        _SelectQuestLogEntry(savedSelection)
        -- Hide popups that might have appeared from SelectQuestLogEntry
        if StaticPopup_Hide then
            pcall(StaticPopup_Hide, "ABANDON_QUEST")
            pcall(StaticPopup_Hide, "ABANDON_QUEST_WITH_ITEMS")
        end
    end

    return completeXP, incompleteXP
end

---Refresh the cached quest XP values
local function RefreshQuestXP()
    local complete, incomplete = GetQuestXPBreakdown()
    xpp.completedQuestXP = complete
    xpp.incompleteQuestXP = incomplete
    xpp.totalQuestXP = complete + incomplete
end

-- ******************************** Session *******************************

---Reset session tracking variables
---@param self Button
local function ResetSession(self)
    xpp.accumXP = 0
    xpp.sessionXP = 0
    xpp.startSessionTime = time()

    local xp = UnitXP("player")
    xpp.initXP = xp or 0
    xpp.lastXP = xpp.initXP
end

---Timer callback: accumulate time and refresh button
local function TimerUpdate()
    local now = GetTime()
    local elapsed = now - XPPTimer.last
    XPPTimer.last = now
    xpp.totalTime = xpp.totalTime + elapsed
    xpp.levelTime = xpp.levelTime + elapsed

    TitanPanelButton_UpdateButton(TITAN_XPP_ID)
end

-- ******************************** Bar Creation *******************************

local function MakeStatusBar(parent, color, level)
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:GetStatusBarTexture():SetHorizTile(false)
    bar:SetStatusBarColor(color[1], color[2], color[3], color[4])
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetFrameLevel(parent:GetFrameLevel() + level)
    bar:Hide()
    return bar
end

---Create the XP bar overlay elements on the Titan button
---@param button Frame
local function CreateBar(button)
    if not button or xpp.barCreated then return end

    -- Background
    barBG = button:CreateTexture(nil, "BACKGROUND", nil, -1)
    barBG:SetColorTexture(COLOR_BAR_BG[1], COLOR_BAR_BG[2], COLOR_BAR_BG[3], COLOR_BAR_BG[4])
    barBG:Hide()

    -- Layer order (back to front): rested -> incomplete -> complete -> xp
    restedBar          = MakeStatusBar(button, COLOR_RESTED_BAR, 1)
    incompleteQuestBar = MakeStatusBar(button, COLOR_INCOMPLETE_BAR, 2)
    completeQuestBar   = MakeStatusBar(button, COLOR_COMPLETE_BAR, 3)
    xpBar              = MakeStatusBar(button, COLOR_XP_BAR, 4)

    -- Border
    local borderOk
    borderOk, barBorder = pcall(CreateFrame, "Frame", nil, button, "BackdropTemplate")
    if borderOk and barBorder and barBorder.SetBackdrop then
        barBorder:SetBackdrop({
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        barBorder:SetBackdropBorderColor(
            COLOR_BAR_BORDER[1], COLOR_BAR_BORDER[2], COLOR_BAR_BORDER[3], COLOR_BAR_BORDER[4])
        barBorder:SetFrameLevel(button:GetFrameLevel() + 5)
        barBorder:Hide()
    else
        barBorder = nil
    end

    -- Overlay frame for icon and text (sits above all bars and border)
    local overlayFrame = CreateFrame("Frame", nil, button)
    overlayFrame:SetFrameLevel(button:GetFrameLevel() + 6)
    overlayFrame:SetAllPoints(button)

    -- Our own icon rendered on the overlay frame (above all bars)
    barIconOverlay = overlayFrame:CreateTexture(nil, "OVERLAY")
    barIconOverlay:SetTexture("Interface\\Icons\\XP_Icon")
    barIconOverlay:SetSize(16, 16)
    barIconOverlay:Hide()

    -- Text overlays on the overlay frame
    local font = STANDARD_TEXT_FONT
    local fontSize = 10

    barTextLeft = overlayFrame:CreateFontString(nil, "OVERLAY")
    barTextLeft:SetFont(font, fontSize, "OUTLINE")
    barTextLeft:SetTextColor(1, 1, 1, 1)
    barTextLeft:SetJustifyH("LEFT")

    barTextCenter = overlayFrame:CreateFontString(nil, "OVERLAY")
    barTextCenter:SetFont(font, fontSize, "OUTLINE")
    barTextCenter:SetTextColor(1, 1, 1, 1)
    barTextCenter:SetJustifyH("CENTER")

    barTextRight = overlayFrame:CreateFontString(nil, "OVERLAY")
    barTextRight:SetFont(font, fontSize, "OUTLINE")
    barTextRight:SetTextColor(1, 1, 1, 1)
    barTextRight:SetJustifyH("RIGHT")

    xpp.barCreated = true
end

---Hide all bar elements safely
local function HideBar()
    if barBG then barBG:Hide() end
    if xpBar then xpBar:Hide() end
    if completeQuestBar then completeQuestBar:Hide() end
    if incompleteQuestBar then incompleteQuestBar:Hide() end
    if restedBar then restedBar:Hide() end
    if barBorder then barBorder:Hide() end
    if barIconOverlay then barIconOverlay:Hide() end
    if barTextLeft then barTextLeft:Hide() end
    if barTextCenter then barTextCenter:Hide() end
    if barTextRight then barTextRight:Hide() end
end

---Update bar position, values, and text
---@param button Frame
local function UpdateBar(button)
    if not button or not xpp.barCreated then return end
    if xpp.updatingBar then return end
    xpp.updatingBar = true

    local ok, showBar = pcall(TitanGetVar, TITAN_XPP_ID, "ShowBar")
    if not ok or xpp.isMaxLevel then
        HideBar()
        xpp.updatingBar = false
        return
    end

    local totalXP = UnitXPMax("player") or 1
    local currentXP = UnitXP("player") or 0
    local level = UnitLevel("player") or 0
    local exhaustion = GetXPExhaustion() or 0
    local remainXP = totalXP - currentXP
    local percent = (totalXP > 0) and (currentXP / totalXP * 100) or 0
    local restedPct = (totalXP > 0) and (exhaustion / totalXP * 100) or 0
    local compQXP = xpp.completedQuestXP or 0
    local incQXP = xpp.incompleteQuestXP or 0

    if not showBar then
        HideBar()
        -- Show original Titan icon back when bar is off
        local titanIcon = _G[TITAN_XPP_BUTTON .. "Icon"]
        if titanIcon then titanIcon:Show() end
        xpp.updatingBar = false
        return
    end

    -- Hide the original Titan icon (our overlay icon replaces it)
    local titanIcon = _G[TITAN_XPP_BUTTON .. "Icon"]
    if titanIcon then titanIcon:Hide() end

    local ICON_SPACE = 20  -- 16px icon + 4px gap
    local buttonWidth = math.max(button:GetWidth() or 0, BAR_MIN_WIDTH)
    local barWidth = buttonWidth - ICON_SPACE
    local yOff = 0

    -- Icon overlay: sits to the LEFT of the bar
    barIconOverlay:ClearAllPoints()
    barIconOverlay:SetPoint("LEFT", button, "LEFT", 2, yOff)
    barIconOverlay:Show()

    -- Helper to position a bar element anchored after the icon
    local function PositionBar(bar)
        bar:ClearAllPoints()
        bar:SetPoint("LEFT", button, "LEFT", ICON_SPACE, yOff)
        bar:SetSize(barWidth, BAR_HEIGHT)
    end

    -- Background
    PositionBar(barBG)
    barBG:Show()

    -- Rested bar (lighter blue): from 0 to min(current + rested, max)
    PositionBar(restedBar)
    restedBar:SetMinMaxValues(0, totalXP)
    restedBar:SetValue(math.min(currentXP + exhaustion, totalXP))
    if exhaustion > 0 then
        restedBar:Show()
    else
        restedBar:Hide()
    end

    -- Incomplete quest bar (yellow): current + complete + incomplete
    local _, showIncomplete = pcall(TitanGetVar, TITAN_XPP_ID, "ShowIncompleteQuests")
    PositionBar(incompleteQuestBar)
    incompleteQuestBar:SetMinMaxValues(0, totalXP)
    incompleteQuestBar:SetValue(math.min(currentXP + compQXP + incQXP, totalXP))
    if showIncomplete and incQXP > 0 then
        incompleteQuestBar:Show()
    else
        incompleteQuestBar:Hide()
    end

    -- Completed quest bar (orange): current + complete
    PositionBar(completeQuestBar)
    completeQuestBar:SetMinMaxValues(0, totalXP)
    completeQuestBar:SetValue(math.min(currentXP + compQXP, totalXP))
    if compQXP > 0 then
        completeQuestBar:Show()
    else
        completeQuestBar:Hide()
    end

    -- XP bar (blue): from 0 to current
    PositionBar(xpBar)
    xpBar:SetMinMaxValues(0, totalXP)
    xpBar:SetValue(currentXP)
    xpBar:Show()

    -- Border
    if barBorder then
        barBorder:ClearAllPoints()
        barBorder:SetPoint("LEFT", button, "LEFT", ICON_SPACE - 2, yOff)
        barBorder:SetSize(barWidth + 4, BAR_HEIGHT + 4)
        barBorder:Show()
    end

    -- Text anchors (relative to barBG which is the bar area)
    local pad = 6
    barTextLeft:ClearAllPoints()
    barTextLeft:SetPoint("LEFT", barBG, "LEFT", pad, 0)
    barTextCenter:ClearAllPoints()
    barTextCenter:SetPoint("CENTER", barBG, "CENTER", 0, 0)
    barTextRight:ClearAllPoints()
    barTextRight:SetPoint("RIGHT", barBG, "RIGHT", -pad, 0)

    -- Text format
    local _, fmt = pcall(TitanGetVar, TITAN_XPP_ID, "BarTextFormat")
    if not fmt then fmt = "full" end

    if fmt == "full" then
        barTextLeft:SetText("|cffffffccLevel " .. level .. "|r")
        barTextCenter:SetText(
            FormatNumber(currentXP) .. " / " .. FormatNumber(totalXP)
            .. " (" .. FormatNumber(remainXP) .. ")"
        )
        -- Right side: current% and projected% with completed quests
        local rightTxt = string.format("%.1f%%", percent)
        if compQXP > 0 then
            local projectedPct = math.min((currentXP + compQXP) / totalXP * 100, 100)
            rightTxt = rightTxt .. string.format(" (%.1f%%)", projectedPct)
        end
        barTextRight:SetText(rightTxt)

    elseif fmt == "compact" then
        barTextLeft:SetText("|cffffffccLv" .. level .. "|r")
        barTextCenter:SetText(string.format("%.1f%%", percent))
        if compQXP > 0 then
            local projectedPct = math.min((currentXP + compQXP) / totalXP * 100, 100)
            barTextRight:SetText(string.format("|cffff9700%.1f%% Q|r", projectedPct))
        elseif exhaustion > 0 then
            barTextRight:SetText(string.format("|cff4f90ff%.1f%% R|r", restedPct))
        else
            barTextRight:SetText("")
        end

    elseif fmt == "percent" then
        barTextLeft:SetText("")
        barTextCenter:SetText(string.format("%.1f%%", percent))
        barTextRight:SetText("")
    end

    barTextLeft:Show()
    barTextCenter:Show()
    barTextRight:Show()

    xpp.updatingBar = false
end

-- ******************************** Button Text *******************************

local function GetButtonText(id)
    local button = TitanUtils_GetButton(id)
    if not button then return "", "" end
    if xpp.isMaxLevel then return "", "" end
    if xpp.startSessionTime == nil or xpp.startSessionTime == 0 then
        return "XP+: ", ""
    end

    local ok, showBar = pcall(TitanGetVar, TITAN_XPP_ID, "ShowBar")
    if ok and showBar then
        local label = ""
        local _, showLabel = pcall(TitanGetVar, TITAN_XPP_ID, "ShowLabelText")
        if showLabel then
            label = "XP+: "
        end
        return label, "                                                                    "
    end

    -- Text-only fallback (bar disabled)
    local totalXP = UnitXPMax("player") or 1
    local currentXP = UnitXP("player") or 0
    local percent = (totalXP > 0) and (currentXP / totalXP * 100) or 0
    local level = UnitLevel("player") or 0

    local text = string.format("Lv%d  %s / %s  %.1f%%",
        level, FormatNumber(currentXP), FormatNumber(totalXP), percent)

    return "XP+: ", TitanUtils_GetHighlightText(text)
end

-- ******************************** Tooltip *******************************

local function GetTooltipText()
    local button = TitanUtils_GetButton(TITAN_XPP_ID)
    if not button then return "" end
    if xpp.isMaxLevel then return "" end

    local totalXP = UnitXPMax("player") or 1
    local currentXP = UnitXP("player") or 0
    local toLevelXP = totalXP - currentXP
    local level = UnitLevel("player") or 0
    local percent = (totalXP > 0) and (currentXP / totalXP * 100) or 0
    local toLevelPct = (totalXP > 0) and (toLevelXP / totalXP * 100) or 0
    local exhaustion = GetXPExhaustion() or 0
    local restedPct = (totalXP > 0) and (exhaustion / totalXP * 100) or 0
    local questXP = xpp.completedQuestXP or 0
    local questPct = (totalXP > 0) and (questXP / totalXP * 100) or 0

    local sessionTime = time() - (xpp.startSessionTime or time())
    local levelTime = xpp.levelTime or 0

    local xpPerHourSession = 0
    if xpp.sessionXP > 0 and sessionTime > 0 then
        xpPerHourSession = xpp.sessionXP / sessionTime * 3600
    end
    local xpPerHourLevel = 0
    if currentXP > 0 and levelTime > 0 then
        xpPerHourLevel = currentXP / levelTime * 3600
    end

    local ttlSession = -1
    if xpp.sessionXP > 0 then
        ttlSession = toLevelXP / xpp.sessionXP * sessionTime
    end
    local ttlLevel = -1
    if currentXP > 0 and levelTime > 0 then
        ttlLevel = toLevelXP / currentXP * levelTime
    end

    local killsToLevel = 0
    if xpp.lastMobXP > 0 then
        killsToLevel = math.ceil(toLevelXP / xpp.lastMobXP)
    end
    local gainsToLevel = 0
    if xpp.XPGain > 0 then
        gainsToLevel = math.ceil(toLevelXP / xpp.XPGain)
    end

    local r = ""

    -- Time
    r = r .. TitanUtils_GetNormalText("Total Time Played:") .. "\t"
        .. TitanUtils_GetHighlightText(TitanUtils_GetAbbrTimeText(xpp.totalTime)) .. "\n"
    r = r .. TitanUtils_GetNormalText("Time this Level:") .. "\t"
        .. TitanUtils_GetHighlightText(TitanUtils_GetAbbrTimeText(levelTime)) .. "\n"
    r = r .. TitanUtils_GetNormalText("Time this Session:") .. "\t"
        .. TitanUtils_GetHighlightText(TitanUtils_GetAbbrTimeText(sessionTime)) .. "\n"

    r = r .. " \n"

    -- XP
    r = r .. TitanUtils_GetNormalText("XP to Level:") .. "\t"
        .. TitanUtils_GetHighlightText(FormatNumber(totalXP)) .. "\n"
    r = r .. TitanUtils_GetNormalText("Current XP:") .. "\t"
        .. TitanUtils_GetHighlightText(FormatNumber(currentXP)
        .. string.format(" (%.1f%%)", percent)) .. "\n"
    r = r .. TitanUtils_GetNormalText("Remaining XP:") .. "\t"
        .. TitanUtils_GetHighlightText(FormatNumber(toLevelXP)
        .. string.format(" (%.1f%%)", toLevelPct)) .. "\n"
    r = r .. TitanUtils_GetNormalText("Rested XP:") .. "\t"
        .. TitanUtils_GetHighlightText(FormatNumber(exhaustion)
        .. (exhaustion > 0 and string.format(" (%.1f%%)", restedPct) or "")) .. "\n"

    -- Quest XP lines
    local incompleteQXP = xpp.incompleteQuestXP or 0
    if questXP > 0 or incompleteQXP > 0 then
        local totalQXP = questXP + incompleteQXP
        local totalQPct = (totalXP > 0) and (totalQXP / totalXP * 100) or 0
        r = r .. TitanUtils_GetNormalText("Quest XP (total):") .. "\t"
            .. "|cffe6cc19" .. FormatNumber(totalQXP)
            .. string.format(" (%.1f%%)", totalQPct) .. "|r" .. "\n"
        if questXP > 0 then
            r = r .. TitanUtils_GetNormalText("  Completed:") .. "\t"
                .. "|cff00ff00" .. FormatNumber(questXP)
                .. string.format(" (%.1f%%)", questPct) .. "|r" .. "\n"
        end
        if incompleteQXP > 0 then
            local incPct = (totalXP > 0) and (incompleteQXP / totalXP * 100) or 0
            r = r .. TitanUtils_GetNormalText("  Incomplete:") .. "\t"
                .. "|cffff9700" .. FormatNumber(incompleteQXP)
                .. string.format(" (%.1f%%)", incPct) .. "|r" .. "\n"
        end
    end

    r = r .. TitanUtils_GetNormalText("Session XP:") .. "\t"
        .. TitanUtils_GetHighlightText(FormatNumber(xpp.sessionXP)) .. "\n"

    -- Kills/gains
    if not (Titan_Global and Titan_Global.switch and Titan_Global.switch.has_secrets) then
        if xpp.lastMobXP > 0 then
            r = r .. TitanUtils_GetNormalText("Last Kill XP:") .. "\t"
                .. TitanUtils_GetHighlightText(FormatNumber(xpp.lastMobXP)
                .. " (" .. FormatNumber(killsToLevel) .. " kills to level)") .. "\n"
        end
    end
    if xpp.XPGain > 0 then
        r = r .. TitanUtils_GetNormalText("Last XP Gain:") .. "\t"
            .. TitanUtils_GetHighlightText(FormatNumber(xpp.XPGain)
            .. " (" .. FormatNumber(gainsToLevel) .. " gains to level)") .. "\n"
    end

    r = r .. " \n"

    -- Rates
    r = r .. TitanUtils_GetNormalText("XP/hr (this level):") .. "\t"
        .. TitanUtils_GetHighlightText(FormatNumber(math.floor(xpPerHourLevel + 0.5)) .. " XP/hr") .. "\n"
    r = r .. TitanUtils_GetNormalText("XP/hr (this session):") .. "\t"
        .. TitanUtils_GetHighlightText(FormatNumber(math.floor(xpPerHourSession + 0.5)) .. " XP/hr") .. "\n"
    r = r .. TitanUtils_GetNormalText("Leveling in (level):") .. "\t"
        .. TitanUtils_GetHighlightText(ttlLevel > 0 and TitanUtils_GetAbbrTimeText(ttlLevel) or "--") .. "\n"
    r = r .. TitanUtils_GetNormalText("Leveling in (session):") .. "\t"
        .. TitanUtils_GetHighlightText(ttlSession > 0 and TitanUtils_GetAbbrTimeText(ttlSession) or "--") .. "\n"

    r = r .. " \n"
    r = r .. TitanUtils_GetGreenText("Right-click for options.")

    return r
end

-- ******************************** Events *******************************

local function OnEvent(self, event, a1, a2, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        -- Max level check: if max level, shut everything down
        if IsMaxLevel() then
            xpp.isMaxLevel = true
            HideBar()
            -- Unregister XP-related events (guild broadcast uses its own frame)
            pcall(function() self:UnregisterEvent("TIME_PLAYED_MSG") end)
            pcall(function() self:UnregisterEvent("PLAYER_XP_UPDATE") end)
            pcall(function() self:UnregisterEvent("PLAYER_LEVEL_UP") end)
            pcall(function() self:UnregisterEvent("UPDATE_EXHAUSTION") end)
            pcall(function() self:UnregisterEvent("PLAYER_UPDATE_RESTING") end)
            pcall(function() self:UnregisterEvent("CHAT_MSG_COMBAT_XP_GAIN") end)
            pcall(function() self:UnregisterEvent("QUEST_LOG_UPDATE") end)
            pcall(function() self:UnregisterEvent("QUEST_TURNED_IN") end)
            if XPPTimer.timer then
                AceTimer:CancelTimer(XPPTimer.timer)
                XPPTimer.running = false
                XPPTimer.timer = nil
            end
            -- Hide from Titan Panel
            local btn = _G[TITAN_XPP_BUTTON]
            if btn then btn:Hide() end
            return
        end

        if a1 == true then
            ResetSession(self)
        end
        -- Initial quest XP scan
        RefreshQuestXP()

    elseif event == "TIME_PLAYED_MSG" then
        xpp.totalTime = a1 or 0
        xpp.levelTime = a2 or 0
        TitanPanelButton_UpdateButton(TITAN_XPP_ID)

    elseif event == "PLAYER_XP_UPDATE" then
        xpp.XPGain = (UnitXP("player") or 0) - (xpp.lastXP or 0)
        xpp.lastXP = UnitXP("player") or 0
        if xpp.XPGain < 0 then
            xpp.XPGain = 0
        end
        xpp.sessionXP = (UnitXP("player") or 0) - xpp.initXP + xpp.accumXP
        TitanPanelButton_UpdateButton(TITAN_XPP_ID)

    elseif event == "PLAYER_LEVEL_UP" then
        local newLevel = a1 or (UnitLevel("player") or 0)
        xpp.levelTime = 0
        xpp.accumXP = xpp.accumXP + (UnitXPMax("player") or 0) - xpp.initXP
        xpp.initXP = 0
        -- Check if we just hit max level
        if IsMaxLevel() then
            xpp.isMaxLevel = true
            HideBar()
            local btn = _G[TITAN_XPP_BUTTON]
            if btn then btn:Hide() end
        end
        TitanPanelButton_UpdateButton(TITAN_XPP_ID)

        -- Broadcast level-up to guild (uses standalone frame)
        if xpp.BroadcastLevelUp then
            pcall(xpp.BroadcastLevelUp, newLevel)
        end

    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        if a1 then
            local killXP = a1:match("(%d+) experience")
                or a1:match("(%d+) point")
                or a1:match("(%d+)")
            if killXP then
                local val = tonumber(killXP)
                if val and val > 0 then
                    xpp.lastMobXP = val
                    TitanPanelButton_UpdateButton(TITAN_XPP_ID)
                end
            end
        end

    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_TURNED_IN" then
        -- Refresh completed quest XP when quest log changes
        RefreshQuestXP()
        TitanPanelButton_UpdateButton(TITAN_XPP_ID)

    elseif event == "UPDATE_EXHAUSTION" or event == "PLAYER_UPDATE_RESTING" then
        TitanPanelButton_UpdateButton(TITAN_XPP_ID)
    end
end

-- ******************************** Right-Click Menu *******************************

local function ResetThisSession()
    ResetSession(_G[TITAN_XPP_BUTTON])
    TitanPanelButton_UpdateButton(TITAN_XPP_ID)
end

local function SetBarFormat(fmt)
    TitanSetVar(TITAN_XPP_ID, "BarTextFormat", fmt)
    TitanSetVar(TITAN_XPP_ID, "BarFmtFull", (fmt == "full"))
    TitanSetVar(TITAN_XPP_ID, "BarFmtCompact", (fmt == "compact"))
    TitanSetVar(TITAN_XPP_ID, "BarFmtPercent", (fmt == "percent"))
    TitanPanelButton_UpdateButton(TITAN_XPP_ID)
end

local function GeneratorFunction(owner, rootDescription)
    local id = TITAN_XPP_ID
    local root = rootDescription

    Titan_Menu.AddSelector(root, id, "Show XP Bar", "ShowBar")
    Titan_Menu.AddSelector(root, id, "Show Incomplete Quests Bar", "ShowIncompleteQuests")

    Titan_Menu.AddDivider(root)

    local barGroup = Titan_Menu.AddButton(root, "Bar Text")
    Titan_Menu.AddCommand(barGroup, id, "Full (Level + XP + %)", function() SetBarFormat("full") end)
    Titan_Menu.AddCommand(barGroup, id, "Compact (Level + %)", function() SetBarFormat("compact") end)
    Titan_Menu.AddCommand(barGroup, id, "Percent Only", function() SetBarFormat("percent") end)

    Titan_Menu.AddDivider(root)

    local seps = {
        { "Use Comma Separator (1,000)", "UseSeperatorComma" },
        { "Use Period Separator (1.000)", "UseSeperatorPeriod" },
    }
    Titan_Menu.AddSelectorExclusiveList(root, id, "Separator", seps)

    Titan_Menu.AddDivider(root)

    Titan_Menu.AddSelector(root, id, "Broadcast Level Up to Guild", "BroadcastLevelUp")

    Titan_Menu.AddDivider(root)

    -- Hide default XP bar option with callback
    local hideXPBtn = Titan_Menu.AddSelector(root, id, "Hide Default Experience Bar", "HideDefaultXPBar")

    Titan_Menu.AddDivider(root)

    Titan_Menu.AddCommand(root, id, "Reset Session Data", ResetThisSession)
    Titan_Menu.AddCommand(root, id, "Refresh Time Played", RefreshPlayed)
end

local function PrepareLegacyMenu()
    TitanPanelRightClickMenu_AddTitle(TitanPlugins[TITAN_XPP_ID].menuText)

    local info

    info = {}
    info.text = "Show XP Bar"
    info.func = function()
        TitanToggleVar(TITAN_XPP_ID, "ShowBar")
        TitanPanelButton_UpdateButton(TITAN_XPP_ID)
    end
    info.checked = TitanGetVar(TITAN_XPP_ID, "ShowBar")
    TitanPanelRightClickMenu_AddButton(info, TitanPanelRightClickMenu_GetDropdownLevel())

    info = {}
    info.text = "Show Incomplete Quests Bar"
    info.func = function()
        TitanToggleVar(TITAN_XPP_ID, "ShowIncompleteQuests")
        TitanPanelButton_UpdateButton(TITAN_XPP_ID)
    end
    info.checked = TitanGetVar(TITAN_XPP_ID, "ShowIncompleteQuests")
    TitanPanelRightClickMenu_AddButton(info, TitanPanelRightClickMenu_GetDropdownLevel())

    TitanPanelRightClickMenu_AddSpacer()
    TitanPanelRightClickMenu_AddTitle("Bar Text Format")

    info = {}
    info.text = "Full (Level + XP + %)"
    info.func = function() SetBarFormat("full") end
    info.checked = (TitanGetVar(TITAN_XPP_ID, "BarTextFormat") == "full")
    TitanPanelRightClickMenu_AddButton(info, TitanPanelRightClickMenu_GetDropdownLevel())

    info = {}
    info.text = "Compact (Level + %)"
    info.func = function() SetBarFormat("compact") end
    info.checked = (TitanGetVar(TITAN_XPP_ID, "BarTextFormat") == "compact")
    TitanPanelRightClickMenu_AddButton(info, TitanPanelRightClickMenu_GetDropdownLevel())

    info = {}
    info.text = "Percent Only"
    info.func = function() SetBarFormat("percent") end
    info.checked = (TitanGetVar(TITAN_XPP_ID, "BarTextFormat") == "percent")
    TitanPanelRightClickMenu_AddButton(info, TitanPanelRightClickMenu_GetDropdownLevel())

    TitanPanelRightClickMenu_AddSpacer()

    info = {}
    info.text = "Broadcast Level Up to Guild"
    info.func = function()
        TitanToggleVar(TITAN_XPP_ID, "BroadcastLevelUp")
    end
    info.checked = TitanGetVar(TITAN_XPP_ID, "BroadcastLevelUp")
    TitanPanelRightClickMenu_AddButton(info, TitanPanelRightClickMenu_GetDropdownLevel())

    info = {}
    info.text = "Hide Default Experience Bar"
    info.func = function()
        TitanToggleVar(TITAN_XPP_ID, "HideDefaultXPBar")
        UpdateDefaultXPBar()
    end
    info.checked = TitanGetVar(TITAN_XPP_ID, "HideDefaultXPBar")
    TitanPanelRightClickMenu_AddButton(info, TitanPanelRightClickMenu_GetDropdownLevel())

    TitanPanelRightClickMenu_AddSpacer()

    info = {}
    info.text = "|cffff8800Reset Session Data|r"
    info.func = ResetThisSession
    TitanPanelRightClickMenu_AddButton(info, TitanPanelRightClickMenu_GetDropdownLevel())

    info = {}
    info.text = "Refresh Time Played"
    info.func = RefreshPlayed
    TitanPanelRightClickMenu_AddButton(info, TitanPanelRightClickMenu_GetDropdownLevel())

    TitanPanelRightClickMenu_AddSpacer()
    TitanPanelRightClickMenu_AddControlVars(TITAN_XPP_ID)
end

-- ******************************** Lifecycle *******************************

local function OnShow(self)
    if xpp.isMaxLevel then
        self:Hide()
        return
    end

    self:RegisterEvent("TIME_PLAYED_MSG")
    self:RegisterEvent("PLAYER_XP_UPDATE")
    self:RegisterEvent("PLAYER_LEVEL_UP")
    self:RegisterEvent("UPDATE_EXHAUSTION")
    self:RegisterEvent("PLAYER_UPDATE_RESTING")
    -- Quest log events for yellow bar
    self:RegisterEvent("QUEST_LOG_UPDATE")
    pcall(function() self:RegisterEvent("QUEST_TURNED_IN") end)

    if Titan_Global and Titan_Global.switch and Titan_Global.switch.has_secrets then
        -- Retail
    else
        pcall(function() self:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN") end)
    end

    RefreshPlayed()
    RefreshQuestXP()

    if not XPPTimer.running then
        XPPTimer.timer = AceTimer:ScheduleRepeatingTimer(TimerUpdate, XPPTimer.delay)
        XPPTimer.running = true
        XPPTimer.last = GetTime()
    end

    CreateBar(self)
    UpdateDefaultXPBar()
    TitanPanelButton_UpdateButton(TITAN_XPP_ID)
end

local function OnHide(self)
    pcall(function() self:UnregisterEvent("TIME_PLAYED_MSG") end)
    pcall(function() self:UnregisterEvent("PLAYER_XP_UPDATE") end)
    pcall(function() self:UnregisterEvent("PLAYER_LEVEL_UP") end)
    pcall(function() self:UnregisterEvent("UPDATE_EXHAUSTION") end)
    pcall(function() self:UnregisterEvent("PLAYER_UPDATE_RESTING") end)
    pcall(function() self:UnregisterEvent("CHAT_MSG_COMBAT_XP_GAIN") end)
    pcall(function() self:UnregisterEvent("QUEST_LOG_UPDATE") end)
    pcall(function() self:UnregisterEvent("QUEST_TURNED_IN") end)

    if XPPTimer.timer then
        AceTimer:CancelTimer(XPPTimer.timer)
    end
    XPPTimer.running = false
    XPPTimer.timer = nil
end

local function OnLoad(self)
    local notes = ""
        .. "Adds an XP progress bar with detailed leveling statistics to Titan Panel.\n"
        .. "Tracks session XP, time to level, XP/hour, rested bonus, quest XP, and more.\n"
        .. "Inspired by popular XP tracking WeakAuras.\n"
        .. "Automatically hides at max level.\n"

    local menuCtx = nil
    local menuTxt = nil
    if Titan_Menu and Titan_Menu.AddCommand then
        menuCtx = GeneratorFunction
    else
        menuTxt = PrepareLegacyMenu
    end

    self.registry = {
        id = TITAN_XPP_ID,
        category = "Information",
        version = "1.0.0",
        menuText = "XP+",
        menuContextFunction = menuCtx,
        menuTextFunction = menuTxt,
        buttonTextFunction = GetButtonText,
        tooltipTitle = "|cffeda55fTitan Panel [XP+]|r",
        tooltipTextFunction = GetTooltipText,
        icon = "Interface\\Icons\\XP_Icon",
        iconWidth = 16,
        notes = notes,
        controlVariables = {
            ShowIcon = true,
            ShowLabelText = true,
            ShowColoredText = false,
            DisplayOnRightSide = false,
        },
        savedVariables = {
            ShowIcon = 1,
            ShowLabelText = false,
            ShowBar = true,
            ShowIncompleteQuests = true,
            BroadcastLevelUp = true,
            HideDefaultXPBar = true,
            BarTextFormat = "full",
            BarFmtFull = true,
            BarFmtCompact = false,
            BarFmtPercent = false,
            UseSeperatorComma = true,
            UseSeperatorPeriod = false,
            DisplayOnRightSide = false,
        },
    }

    HookTimePlayed()

    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    ResetSession(self)
end

-- ******************************** Frame Creation *******************************

local function Create_Frames()
    if _G[TITAN_XPP_BUTTON] then return end

    local f = CreateFrame("Frame", nil, UIParent)

    local window = CreateFrame("Button", TITAN_XPP_BUTTON, f, "TitanPanelComboTemplate")
    xpp.frame = window
    window:SetFrameStrata("FULLSCREEN")
    OnLoad(window)

    window:SetScript("OnShow", function(self)
        OnShow(self)
        TitanPanelButton_OnShow(self)
    end)
    window:SetScript("OnHide", function(self)
        OnHide(self)
    end)
    window:SetScript("OnEvent", function(self, event, ...)
        OnEvent(self, event, ...)
    end)
    window:SetScript("OnClick", function(self, button)
        TitanPanelButton_OnClick(self, button)
    end)

    hooksecurefunc("TitanPanelButton_UpdateButton", function(id)
        if id ~= TITAN_XPP_ID then return end
        if xpp.isMaxLevel then return end
        local btn = _G[TITAN_XPP_BUTTON]
        if not btn then return end

        pcall(function()
            if not xpp.barCreated then
                CreateBar(btn)
            end
            UpdateBar(btn)
            UpdateDefaultXPBar()

            local ok, showBar = pcall(TitanGetVar, TITAN_XPP_ID, "ShowBar")
            if ok and showBar then
                local w = btn:GetWidth() or 0
                if w < BAR_MIN_WIDTH then
                    btn:SetWidth(BAR_MIN_WIDTH)
                end
            end
        end)
    end)

    function window:RequestTimePlayed()
        xpp_requesting = true
        RequestTimePlayed()
    end
end

if TITAN_ID then
    Create_Frames()
end

-- ******************************** Guild Broadcast (Standalone) *******************************
-- This is a separate frame, completely isolated from Titan Panel's lifecycle.
-- It survives /reload without issues because it never gets hidden/shown by Titan.

local xppBroadcastFrame = CreateFrame("Frame", "TitanXPPBroadcastFrame", UIParent)
-- Do NOT hide this frame — hidden frames don't receive events in WoW.
-- It has no size or visuals, so it's already invisible.

-- Register the addon message prefix (safe to call at load time)
pcall(function()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(ADDON_MSG_PREFIX)
    elseif RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(ADDON_MSG_PREFIX)
    end
end)

-- Listen for addon messages
xppBroadcastFrame:RegisterEvent("CHAT_MSG_ADDON")
xppBroadcastFrame:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if event ~= "CHAT_MSG_ADDON" then return end
    if prefix ~= ADDON_MSG_PREFIX then return end

    local levelStr, classToken = msg:match("^LEVELUP:(%d+):(%w+)")
    if not levelStr then return end

    local lvl = tonumber(levelStr) or 0

    -- Strip realm name from sender
    local shortName = sender and sender:match("^([^-]+)") or sender or "Unknown"

    -- Don't show notification for ourselves
    local myName = UnitName("player") or ""
    if shortName == myName then return end

    -- Class color
    local colorStr = "ffffff"
    local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if classColor then
        colorStr = string.format("%02x%02x%02x",
            math.floor(classColor.r * 255),
            math.floor(classColor.g * 255),
            math.floor(classColor.b * 255))
    end

    -- Chat notification
    local notification = string.format(
        "|cffeda55f[XP+]|r |cff%s%s|r has reached |cff00ff00level %d|r!",
        colorStr, shortName, lvl
    )
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(notification)
    end
end)

---Send a level-up broadcast to guild (called from PLAYER_LEVEL_UP handler)
---@param newLevel number
function xpp.BroadcastLevelUp(newLevel)
    local ok, broadcast = pcall(TitanGetVar, TITAN_XPP_ID, "BroadcastLevelUp")
    if not ok or not broadcast then return end
    if not IsInGuild() then return end

    local _, className = UnitClass("player")
    className = className or "WARRIOR"
    local msg = string.format("LEVELUP:%d:%s", newLevel, className)

    pcall(function()
        local sendFunc = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
        if sendFunc then
            sendFunc(ADDON_MSG_PREFIX, msg, "GUILD")
        end
    end)
end