-------------------------------------------------------------------------------
-- GobbieBars Help panel
-------------------------------------------------------------------------------

-- Help style configuration
local HELP_TITLE_COLOR = { 1.00, 0.95, 0.20, 1.00 } -- RGBA, warm yellow
local HELP_TITLE_SCALE = 1.1                        -- title font scale
local HELP_BODY_SCALE  = 0.9                        -- body font scale

local M = {}

-- Yellow heading helper for Troubleshooting titles
local function gb_help_heading(imgui, text)
    imgui.PushStyleColor(0, HELP_TITLE_COLOR)
    imgui.Text(text)
    imgui.PopStyleColor()
end

-- Helper: draw the help title in yellow (uses same pattern as your other addon)
local function with_help_title(imgui, s)
    local C = get_col_text_enum and get_col_text_enum() or nil
    if C then imgui.PushStyleColor(C, { 1.00, 0.95, 0.20, 1.00 }) end
    imgui.TextUnformatted(tostring(s or ''))
    if C then imgui.PopStyleColor() end
end

function M.draw_help(imgui)

    -- Title: bigger and yellow (color index 0 = text color)
    imgui.SetWindowFontScale(HELP_TITLE_SCALE)
    imgui.PushStyleColor(0, HELP_TITLE_COLOR)
    imgui.TextUnformatted('GobbieBars Help')
    imgui.PopStyleColor()

    -- Body: slightly smaller
    imgui.SetWindowFontScale(HELP_BODY_SCALE)
    imgui.Separator()
    imgui.Spacing()
    imgui.Spacing()

    ---------------------------------------------------------------------------
    -- Overview & Features
    ---------------------------------------------------------------------------
    if imgui.CollapsingHeader('Overview & Features##gb_help_overview') then
        imgui.Spacing()
        imgui.TextWrapped(
            "GobbieBars is a bar-based UI host for FFXI on Ashita. It draws one or more " ..
            "bars on the screen and lets plugins place buttons or widgets on those bars."
        )
        imgui.Spacing()

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Per-account profiles and layouts, including support for different game modes.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Per-bar and per-screen settings for size, color, texture, opacity, and behavior.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Add, remove, enable, and disable plugins from inside GobbieBars.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Add custom bar textures by dropping .png files into the textures folder (gobbiebars > assets > ui > textures).")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Live updates: most changes take effect immediately without needing a save or reload.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Ships with the Buttons plugin as the main built-in action bar system.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Includes a template so you can build your own plugins.")

        imgui.Spacing()
        imgui.Spacing()
    end

    ---------------------------------------------------------------------------
    -- Commands
    ---------------------------------------------------------------------------
    if imgui.CollapsingHeader('Commands##gb_help_commands') then
        imgui.Spacing()
        imgui.TextWrapped("GobbieBars is controlled mainly through a few /gobbiebars commands.")
        imgui.Spacing()

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("/gobbiebars ui  - open or close the GobbieBars settings window.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("/gobbiebars layout  - opens button drag mode from the Buttons settings.")

        imgui.Spacing()
        imgui.TextWrapped("You can bind these commands to keys using Ashita's /bind system if you prefer keyboard access.")
        imgui.Spacing()
        imgui.Spacing()
    end

    ---------------------------------------------------------------------------
    -- Layout & Bar Areas
    ---------------------------------------------------------------------------
    if imgui.CollapsingHeader('Layout & Bar Areas##gb_help_layout') then
        imgui.Spacing()
        imgui.TextWrapped(
            "GobbieBars uses bar areas to control where content appears. Each bar is " ..
            "assigned to an area, and plugins choose an area so their content shows on the correct bar."
        )
        imgui.Spacing()

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Use Buttons settings > Drag mode to visually reposition buttons.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Bars and normal plugins use their own bar, X, and Y settings.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Bar thickness and opacity are set in General settings per bar.")

        imgui.Spacing()
        imgui.TextWrapped(
            "If bars seem to be missing, first check that the bar is active, has non-zero " ..
            "thickness, and has a visible color and opacity."
        )
        imgui.Spacing()
        imgui.Spacing()
    end

    ---------------------------------------------------------------------------
    -- Buttons
    ---------------------------------------------------------------------------
    if imgui.CollapsingHeader('Buttons##gb_help_buttons') then
        imgui.Spacing()
        imgui.TextWrapped(
            "The Buttons plugin is the main built-in plugin shipped with GobbieBars. It " ..
            "provides configurable buttons that can run commands, macros, and actions."
        )
        imgui.Spacing()

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Font selection, including custom fonts by dropping .ttf files into the fonts folder (gobbiebars > assets > fonts).")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Settings can apply to all buttons, a specific bar, a specific screen, or individual buttons.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Extensive color settings for text, icons, borders, backgrounds, and state.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Precise positioning with X/Y values, plus Drag mode for button placement.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Full text control per category: size, color, alignment, and shadow.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Keybinds, counters, cooldown displays, and tooltips with numbers and custom text.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Keybinds can be set globally or by main or sub-job")
		
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Weaponskill and skillchain options with element icons and visual effects.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Easy button management: add, edit, duplicate, and delete buttons.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Visibility rules so buttons can be global, main-job only, or sub-job only.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Custom button icons from shipped art or your own .png files in the images folder (gobbiebars > plugins > buttons > images).")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Supports CatseyeXI commands and game content such as items, spells, weaponskills, job abilities, trusts, and mounts.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Create macros by chaining multiple commands in a single button.")

        imgui.Spacing()
        imgui.Spacing()
    end

    ---------------------------------------------------------------------------
    -- Assets
    ---------------------------------------------------------------------------
    if imgui.CollapsingHeader('Assets (Textures, Fonts, Sounds)##gb_help_assets') then
        imgui.Spacing()
        imgui.TextWrapped(
            "GobbieBars and its plugins share an assets system so you can customize " ..
            "textures, fonts, and sounds."
        )
        imgui.Spacing()

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Bar and UI textures live in the textures folder (gobbiebars > assets > ui > textures).")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Fonts live in the fonts folder (gobbiebars > assets > fonts) and can be selected in the UI.")

        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Plugins can reference sound files for alerts and feedback if provided.")

        imgui.Spacing()
        imgui.TextWrapped("If an asset does not display, check that the file exists, the path is correct, and the file type is supported.")
        imgui.Spacing()
        imgui.Spacing()
    end

    ---------------------------------------------------------------------------
    -- Troubleshooting & FAQ
    ---------------------------------------------------------------------------
    if imgui.CollapsingHeader('Troubleshooting & FAQ##gb_help_troubleshooting') then
        imgui.Spacing()
        imgui.TextWrapped("Common problems and quick checks.")
        imgui.Spacing()

        gb_help_heading(imgui, 'I do not see any bars.')
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("In General settings, make sure the bars you want (Top, Bottom, Left, Right) are Active.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Check that bar thickness is greater than 0.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Check opacity is not set to 0 and bar color is not effectively invisible.")

        imgui.Spacing()
        gb_help_heading(imgui, 'My bar does not react to mouse over.')
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("If you want hover behavior, make sure Static is unchecked for that bar.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Set the Hot zone to match or be slightly larger than the bar thickness so mouseover is easy to hit.")

        imgui.Spacing()
        gb_help_heading(imgui, 'A plugin shows in the list but nothing appears on screen.')
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Make sure the plugin is Active in its settings.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Check Area / screen selection so the plugin is mapped to the region you expect.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("If the plugin uses X and Y offsets and they are very large, reset them to 0 so it returns to a normal position.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Review job filters or visibility options that might be hiding the plugin.")

        imgui.Spacing()
        gb_help_heading(imgui, 'My layout looks wrong or elements are off-screen.')
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("If buttons are misplaced, open Buttons settings and enable Drag mode to adjust positions.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("If something is completely gone, reset its X and Y values to 0 and confirm size-related settings are not set to 0.")

        imgui.Spacing()
        gb_help_heading(imgui, 'Settings keep opening by themselves.')
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("In General, check Quick settings access (Right click, Ctrl + right click, or Disabled).")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("If it is set to Right click, frequent right clicks on bars can make it feel like settings open by themselves.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Switch to Ctrl + right click or Disabled if you prefer not to open settings with a simple right click.")

        imgui.Spacing()
        gb_help_heading(imgui, 'I want to add my own plugin.')
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Use the template in the example folder (gobbiebars > assets > example) as a starting point.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Copy the folder, rename the folder and plugin ID to your plugin name, but leave plugin.lua as-is.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Drop the folder into the plugins folder (gobbiebars > plugins) and reload GobbieBars so it can find the new plugin.")

        imgui.Spacing()
        gb_help_heading(imgui, 'Everything is broken or I want to reset.')
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Temporarily move or rename your GobbieBars configuration files.")
        imgui.Bullet()
        imgui.SameLine()
        imgui.TextWrapped("Reload the addon to generate a clean default setup, then reconfigure bars, buttons, and plugins.")

        imgui.Spacing()
        imgui.Spacing()
    end

    -- Restore default for other windows
    imgui.SetWindowFontScale(1.0)
end

return M