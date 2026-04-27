-------------------------------------------------------------------------------
-- GB Internal Plugin: Buttons (Right Bar)
-- File: Ashita/addons/gobbiebars/plugins/right_bar/plugin.lua
-------------------------------------------------------------------------------

local function get_base_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1,1) == '@' then src = src:sub(2) end
    return src:match('^(.*[\\/])') or './'
end

local BASE = get_base_dir()
local SEP  = package.config:sub(1, 1)

local plugins_dir = BASE:gsub('[\\/]+$', ''):gsub('[\\/]+right_bar$', '') .. SEP
local shared = assert(loadfile(plugins_dir .. 'buttons' .. SEP .. 'shared.lua'))()

local M = {
    id   = 'buttons_right_bar',
    name = 'Buttons (Right)',
    hidden = true,

    default = { bar = 'right', x = 0, y = 0, w = 44, h = 4096 },
    settings_defaults = {},
}

function M.render(dl, rect, settings, layout_mode)
    rect.bar = 'right'
    shared.render_bar(dl, rect, settings, 'right', layout_mode)
end

function M.draw_settings_ui(settings)
    shared.draw_settings_ui(settings)
end

function M.on_right_click(rect, settings, layout_mode, mx, my)
    rect.bar = 'right'
    return shared.on_right_click(rect, settings, layout_mode, mx, my)
end

return M
