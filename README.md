# Titan Panel XP+

**Titan Panel XP+** is an XP tracking plugin for [Titan Panel](https://www.curseforge.com/wow/addons/titan-panel). It offers a layered progress bar and more leveling statistics than Titan Panel's built-in XP plugin, inspired by the **Luxthos Experience Group WeakAura**.

## Features

- **Layered XP bar:** Shows current XP, rested XP, and the XP available from completed and incomplete quests. Choose full, compact, or percentage-only text, or turn the bar off for a text display.
- **Detailed tooltip:** Shows current and remaining XP, time played, XP per hour, estimated time to level, rested XP, quest XP, and session gains.
- **Quest breakdown:** Separates completed and incomplete quest rewards from the current quest log. The incomplete quest overlay can be toggled independently.
- **Session tracking:** Tracks XP earned since login; reset it at any time from the menu.
- **Display options:** Choose comma or period number separators, adjust the text and label, and optionally hide Blizzard's status bar.
- **Guild notices:** Optionally sends a level-up notice to guildmates who also have XP+ installed.

XP+ hides itself when your character reaches the level cap.

## Install and use

1. Install and enable **Titan Panel**.
2. Place the `TitanPanelXPP` folder in your WoW client's `Interface/AddOns` directory. `TitanPanelXPP.toc` and `TitanPanelXPP.lua` should be directly inside that folder.
3. Enable **Titan Panel XP+** in the AddOns list and select **XP+** on the Titan bar.

Hover over XP+ for the tooltip. Right-click it to choose bar and text options, reset session data, or refresh time played.

**Hide Default Experience Bar** is enabled by default. On WoW: Forever, it hides Blizzard's status tracking area, which can also hide a watched reputation bar. Turn the option off if you want Blizzard's bar visible.

## Compatibility and validation

Version **1.1.1** supports WoW: Forever 1.60.1 (`## Interface: 16001`). The TOC also retains Retail and Classic interface entries. Titan Panel is required.

The Forever port passed Lua 5.1 syntax checks and offline tests for quest totals, level-up event order, the level cap, and TOC metadata. **It has not been tested in-game.** Bar rendering and Edit Mode behavior still need a live-client check.

## Credits

XP+ was inspired by the **Luxthos Experience Group WeakAura** and brings a similar at-a-glance leveling view to Titan Panel.
