-- Offline checks for the Forever XP and quest paths. Run with lua tests/port.lua.
TITAN_ID = "Titan"
UIParent = {}

local xp, maxXP, level = 90, 100, 10
local now = 1000

function UnitXP() return xp end
function UnitXPMax() return maxXP end
function UnitLevel() return level end
function GetMaxPlayerLevel() return 60 end
function GetMaxLevelForExpansionLevel() return 50 end -- must not override the Forever cap
function GetXPExhaustion() return 0 end
function GetTime() return now end
function time() return now end
function UnitName() return "Tester" end
function IsInGuild() return false end
function InCombatLockdown() return false end
function hooksecurefunc() end
function TitanPanelButton_UpdateButton() end
function TitanGetVar() return false end
function TitanUtils_GetButton() return TitanPanelXPPlusButton end
function TitanUtils_GetNormalText(s) return s end
function TitanUtils_GetHighlightText(s) return s end
function TitanUtils_GetGreenText(s) return s end
function TitanUtils_GetAbbrTimeText(s) return tostring(s) end
function LibStub() return {} end

local function frame(name, parent)
    local f = { parent = parent, shown = true, scripts = {} }
    function f:SetFrameStrata() end
    function f:RegisterEvent() end
    function f:UnregisterEvent() end
    function f:SetScript(event, callback) self.scripts[event] = callback end
    function f:Hide() self.shown = false end
    function f:Show() self.shown = true end
    function f:IsShown() return self.shown end
    function f:GetParent() return self.parent end
    function f:SetParent(p) self.parent = p end
    if name then _G[name] = f end
    return f
end
function CreateFrame(_, name, parent) return frame(name, parent) end

local quests = {
    { isHeader = true, questID = 100 },
    { questID = 101 },
    { questID = 102 },
    { isHidden = true, questID = 103 },
}
C_QuestLog = {
    GetNumQuestLogEntries = function() return #quests end,
    GetInfo = function(i) return quests[i] end,
    IsComplete = function(id) return id == 101 end,
    ReadyForTurnIn = function() return false end,
}
function GetQuestLogRewardXP(id)
    return ({ [100] = 900, [101] = 100, [102] = 200, [103] = 500 })[id]
end

local toc = assert(io.open("TitanPanelXPP.toc", "r"))
local metadata = toc:read("*a")
toc:close()
assert(metadata:match("## Interface:[^\n]*16001"), "Forever interface must be in the TOC")
assert(metadata:match("## Version: 1%.1%.0"), "release version must match the TOC")
assert(metadata:match("## Dependencies: Titan"), "Titan must load before this plugin")

dofile("TitanPanelXPP.lua")
local button = assert(TitanPanelXPPlusButton)
local function event(name, ...)
    button.scripts.OnEvent(button, name, ...)
end
local function tooltip()
    return button.registry.tooltipTextFunction()
end

event("PLAYER_ENTERING_WORLD", true)
assert(tooltip():find("Quest XP %(total%):.-300"), "quest scan must skip headers and hidden quests")

xp = 95
event("PLAYER_XP_UPDATE")
level, xp, maxXP = 11, 10, 120
event("PLAYER_LEVEL_UP", 11) -- level event first
event("PLAYER_XP_UPDATE")
assert(tooltip():find("Session XP:\t20"), "session XP must include XP across level-up")

xp = 115
event("PLAYER_XP_UPDATE")
level, xp, maxXP = 12, 4, 150
event("PLAYER_XP_UPDATE") -- XP event first
event("PLAYER_LEVEL_UP", 12)
assert(tooltip():find("Session XP:\t134"), "level-up event order must not double count")

level = 59
event("PLAYER_ENTERING_WORLD", false)
assert(button:IsShown(), "GetMaxPlayerLevel must take precedence over expansion caps")

level, xp, maxXP = 60, 0, 0
event("PLAYER_ENTERING_WORLD", false)
assert(not button:IsShown(), "the Forever level cap must hide the plugin")

print("Forever port checks passed")
