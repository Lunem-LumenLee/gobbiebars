-------------------------------------------------------------------------------
-- GobbieBars Plugin: Buttons
-- File: Ashita/addons/gobbiebars/plugins/buttons/plugin.lua
-- Author: Lunem
-- Version: 0.1.8
-------------------------------------------------------------------------------

local function get_base_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1,1) == '@' then src = src:sub(2) end
    return src:match('^(.*[\\/])') or './'
end

local BASE = get_base_dir()
local shared = assert(loadfile(BASE .. 'shared.lua'))()

local M = {
    id   = 'buttons',
    name = 'Buttons',
    default = {
        bar = 'top',
        x = 0, y = 0, w = 4096, h = 44,
    },

    settings_defaults = {
        font_size = 14,
    },

}

-- Render buttons for the bar this plugin box is placed on.
function M.render(dl, rect, settings, layout_mode)
    local bar = rect and rect.bar or M.default.bar or 'top'
    shared.render_bar(dl, rect, settings, bar, layout_mode)
end



function M.draw_settings_ui(settings)
    shared.draw_settings_ui(settings)
end

function M.on_right_click(rect, settings, layout_mode, mx, my)
    if type(shared.on_right_click) == 'function' then
        return shared.on_right_click(rect, settings, layout_mode, mx, my)
    end
    return false
end


return M
