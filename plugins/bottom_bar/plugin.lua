-------------------------------------------------------------------------------
-- GB Internal Plugin: Buttons (Bottom Bar)
-- File: Ashita/addons/gobbiebars/plugins/bottom_bar/plugin.lua
-------------------------------------------------------------------------------

local function get_base_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1,1) == '@' then src = src:sub(2) end
    return src:match('^(.*[\\/])') or './'
end

local BASE = get_base_dir()
local SEP  = package.config:sub(1, 1)

local plugins_dir = BASE:gsub('[\\/]+$', ''):gsub('[\\/]+bottom_bar$', '') .. SEP
local shared = assert(loadfile(plugins_dir .. 'buttons' .. SEP .. 'shared.lua'))()

local M = {
    id   = 'buttons_bottom_bar',
    name = 'Buttons (Bottom)',
    hidden = true,

    default = { bar = 'bottom', x = 0, y = 0, w = 4096, h = 44 },
    settings_defaults = {},
}

function M.render(dl, rect, settings, layout_mode)
    rect.bar = 'bottom'
    shared.render_bar(dl, rect, settings, 'bottom', layout_mode)
end

function M.draw_settings_ui(settings)
    shared.draw_settings_ui(settings)
end

function M.on_right_click(rect, settings, layout_mode, mx, my)
    rect.bar = 'bottom'
    return shared.on_right_click(rect, settings, layout_mode, mx, my)
end

return M
