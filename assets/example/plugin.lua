-------------------------------------------------------------------------------
-- GobbieBars Plugin Template: Example
-- File: Ashita/addons/gobbiebars/plugins/example/plugin.lua
-------------------------------------------------------------------------------

require('common')

local imgui = require('imgui')

-------------------------------------------------------------------------------
-- Plugin table
-------------------------------------------------------------------------------

M = {

    -- Plugin identity used by GobbieBars
    id   = 'example',        -- must be unique; match folder name
    name = 'Example',        -- text shown in the plugin list

    -- Default layout rect used by GobbieBars when placing this plugin
    default = {
        bar = 'top_bar',     -- internal bar id used by the host
        x   = 0,
        y   = 0,
        w   = 120,
        h   = 32,
    },

    -- Per-plugin settings (editable in GobbieBars settings UI)
    -- Template only exposes: Area
    settings_defaults = {
        bar = 'top',         -- Area: top / bottom / left / right / screen
        x   = 0,
        y   = 0,
    },
}

-------------------------------------------------------------------------------
-- Render
-------------------------------------------------------------------------------

-- dl       : ImGui draw list (unused here)
-- rect     : bar rectangle (content_x, content_y, content_w, content_h, ...)
-- settings : table with saved settings for this plugin
-- font     : ImGui font object selected by GobbieBars (can be nil)
function M.render(dl, rect, settings, font)
    if imgui == nil or rect == nil or rect.content_x == nil then
        return
    end

    local st = settings or M.settings_defaults

    if type(font) == 'userdata' then
        imgui.PushFont(font)
    end

    local base_x = rect.content_x
    local base_y = rect.content_y

    local x = base_x + (tonumber(st.x or 0) or 0)
    local y = base_y + (tonumber(st.y or 0) or 0)

    -- Very simple: just draw the word "Example" at the bar origin.
    imgui.SetCursorScreenPos({ x, y })
    imgui.TextUnformatted('Example')

    if type(font) == 'userdata' then
        imgui.PopFont()
    end
end

-------------------------------------------------------------------------------
-- Settings UI
-------------------------------------------------------------------------------

-- Called from the GobbieBars settings window.
-- Return true if any setting changed so the host can save it.
function M.draw_settings_ui(settings)
    local st = settings or M.settings_defaults
    local changed = false

    -----------------------------------------------------------------------
    -- Area
    -----------------------------------------------------------------------
    imgui.Text('Area')
    imgui.SameLine()
    imgui.SetNextItemWidth(160)

    local cur = tostring(st.bar or 'top')

    local function area_label(v)
        if v == 'top'    then return 'Top Bar'    end
        if v == 'bottom' then return 'Bottom Bar' end
        if v == 'left'   then return 'Left Bar'   end
        if v == 'right'  then return 'Right Bar'  end
        if v == 'screen' then return 'Screen'     end
        return tostring(v)
    end

    if imgui.BeginCombo('##gb_example_area', area_label(cur)) then
        local opts = { 'top', 'bottom', 'left', 'right', 'screen' }
        for _, v in ipairs(opts) do
            if imgui.Selectable(area_label(v), v == cur) then
                if st.bar ~= v then
                    st.bar = v
                    cur = v
                    changed = true
                end
            end
        end
        imgui.EndCombo()
    end

    return changed
end

-------------------------------------------------------------------------------
-- Layout defaults
-------------------------------------------------------------------------------

function M.get_default(settings)
    local st = settings or {}
    local d = {}
    d.bar = tostring(st.bar or M.default.bar)
    d.x   = tonumber(st.x or M.default.x) or M.default.x
    d.y   = tonumber(st.y or M.default.y) or M.default.y
    d.w   = tonumber(st.w or M.default.w) or M.default.w
    d.h   = tonumber(st.h or M.default.h) or M.default.h
    return d
end

return M
