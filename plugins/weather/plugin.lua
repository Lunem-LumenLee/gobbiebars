-------------------------------------------------------------------------------
-- GobbieBars Plugin: Weather
-- File: Ashita/addons/gobbiebars/plugins/weather/plugin.lua
-- Author: Lunem
-- Version: 0.1.0
-------------------------------------------------------------------------------

require('common')

local imgui = require('imgui')
local bit   = require('bit')
local ffi   = require('ffi')
local d3d8  = require('d3d8')

ffi.cdef[[
typedef void*               LPVOID;
typedef const char*         LPCSTR;
typedef struct IDirect3DTexture8 IDirect3DTexture8;
typedef long                HRESULT;
HRESULT D3DXCreateTextureFromFileA(LPVOID pDevice, LPCSTR pSrcFile, IDirect3DTexture8** ppTexture);
]]

-------------------------------------------------------------------------------
-- Helpers (MATCH Position plugin behavior)
-------------------------------------------------------------------------------

local function clampi(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return math.floor(v)
end

local function color_to_u32_any(c)
    -- Accepts either {255,255,255,255} or {1,1,1,1}
    c = c or { 255, 255, 255, 255 }

    local r = tonumber(c[1] or 255) or 255
    local g = tonumber(c[2] or 255) or 255
    local b = tonumber(c[3] or 255) or 255
    local a = tonumber(c[4] or 255) or 255

    if r <= 1 and g <= 1 and b <= 1 and a <= 1 then
        r = math.floor(r * 255 + 0.5)
        g = math.floor(g * 255 + 0.5)
        b = math.floor(b * 255 + 0.5)
        a = math.floor(a * 255 + 0.5)
    end

    r = clampi(r, 0, 255)
    g = clampi(g, 0, 255)
    b = clampi(b, 0, 255)
    a = clampi(a, 0, 255)

    -- ABGR for ImGui drawlist
    return (a * 0x1000000) + (b * 0x10000) + (g * 0x100) + r
end

local function area_label(v)
    if v == 'top'    then return 'Top Bar'    end
    if v == 'bottom' then return 'Bottom Bar' end
    if v == 'left'   then return 'Left Bar'   end
    if v == 'right'  then return 'Right Bar'  end
    if v == 'screen' then return 'Screen'     end
    return tostring(v)
end

local function get_dir_of_this_file()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then src = src:sub(2) end
    local last = 0
    for i = 1, #src do
        local c = src:sub(i, i)
        if c == '/' or c == '\\' then last = i end
    end
    if last > 0 then return src:sub(1, last) end
    return './'
end

local SEP  = package.config:sub(1, 1)
local BASE = get_dir_of_this_file()

-------------------------------------------------------------------------------
-- Load weather helper (your weather.lua)
-------------------------------------------------------------------------------

local weather = nil
do
    local chunk = loadfile(BASE .. 'weather.lua')
    if chunk ~= nil then
        local ok, mod = pcall(chunk)
        if ok and type(mod) == 'table' then
            weather = mod
        end
    end
end

-------------------------------------------------------------------------------
-- Texture loading (unchanged)
-------------------------------------------------------------------------------

local TEX = {}
local RETRY_SECONDS = 2.0

local function ptr_to_number(p)
    if p == nil then return nil end
    local n = tonumber(ffi.cast('uintptr_t', p))
    if type(n) ~= 'number' then return nil end
    return n
end

local function now_seconds()
    return os.clock()
end

local function try_load_texture(path)
    local out = ffi.new('IDirect3DTexture8*[1]')
    local hr = ffi.C.D3DXCreateTextureFromFileA(d3d8.get_device(), path, out)
    if hr ~= 0 or out[0] == nil then
        return nil
    end

    local tex_ptr = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', out[0]))
    local handle = ptr_to_number(tex_ptr)
    if handle == nil then
        return nil
    end

    return handle, tex_ptr
end

local function get_texture_handle(path)
    if type(path) ~= 'string' or path == '' then return nil end

    local cached = TEX[path]
    if type(cached) == 'table' then
        if cached.handle ~= nil and cached.tex ~= nil then
            return cached.handle
        end
        if cached.fail == true then
            local t = cached.last_try or 0
            if (now_seconds() - t) < RETRY_SECONDS then
                return nil
            end
        end
    end

    local handle, tex_ptr = try_load_texture(path)
    if handle ~= nil then
        TEX[path] = { handle = handle, tex = tex_ptr }
        return handle
    end

    TEX[path] = { fail = true, last_try = now_seconds() }
    return nil
end

local function icon_path_for_weather_id(id)
    return BASE .. 'images' .. SEP .. tostring(id) .. '.png'
end

-------------------------------------------------------------------------------
-- Plugin
-------------------------------------------------------------------------------

local M = {
    id   = 'weather',
    name = 'Weather',
    icon = 0,

    default = { bar = 'top', x = 0, y = 0, w = 220, h = 34 },

    -- Match Position style keys
    settings_defaults = {
        bar         = 'top',                -- Area
        x           = 0,                    -- Position X offset
        y           = 0,                    -- Position Y offset

        show_text   = true,                -- Show text toggle

        font_family = 'calibri',           -- Font name text (uses _G.FONT_FAMILIES list)
        font_size   = 32,                  -- Font Size (SetWindowFontScale)

        font_color  = { 255, 255, 255, 255 },

        icon_size   = 17,                  -- Icon size
    },
}

-------------------------------------------------------------------------------
-- Render
-------------------------------------------------------------------------------

function M.render(dl, rect, settings)
    local st = settings or M.settings_defaults
    if not dl or not rect then return end

    if weather == nil then
        dl:AddText({ rect.content_x + 8, rect.content_y + 4 }, color_to_u32_any({ 255, 80, 80, 255 }), 'Weather: helper not loaded')
        return
    end

    local id  = weather.get_weather_id()
    local txt = weather.get_weather_text(id)

    local icon_px = clampi(st.icon_size or 17, 8, 64)

    local draw_x = rect.content_x + 8 + (tonumber(st.x) or 0)
    local draw_y = rect.content_y + 4 + (tonumber(st.y) or 0)

    -- Icon
    if type(id) == 'number' then
        local path = icon_path_for_weather_id(id)
        local tex_handle = get_texture_handle(path)
        if tex_handle ~= nil then
            dl:AddImage(tex_handle, { draw_x, draw_y }, { draw_x + icon_px, draw_y + icon_px })
        end
    end

    -- Text
    if st.show_text == true then
        local color = color_to_u32_any(st.font_color or { 255, 255, 255, 255 })

        -- Scale using font_size (same as Position plugin)
        local base  = 14
        local fs    = tonumber(st.font_size) or base
        local scale = fs / base
        if scale < 0.5 then scale = 0.5 end
        if scale > 3.0 then scale = 3.0 end

        imgui.SetWindowFontScale(scale)
        dl:AddText({ draw_x + icon_px + 8, draw_y + 1 }, color, txt)
        imgui.SetWindowFontScale(1.0)
    end
end

-------------------------------------------------------------------------------
-- Settings UI (MATCH Position layout)
-------------------------------------------------------------------------------

function M.draw_settings_ui(settings)
    local st = settings or M.settings_defaults

    local function header_yellow(text)
        imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.90, 0.70, 1.0 })
        if imgui.TextUnformatted then imgui.TextUnformatted(text) else imgui.Text(text) end
        imgui.PopStyleColor(1)
    end

    local function build_sorted_font_names()
        local names = {}
        local seen = {}

        if type(_G.FONT_FAMILIES) == 'table' then
            for name, _ in pairs(_G.FONT_FAMILIES) do
                if type(name) == 'string' then
                    local trimmed = name:gsub('^%s+', ''):gsub('%s+$', '')
                    local key = trimmed:lower()
                    if trimmed ~= 'default' and not seen[key] then
                        seen[key] = true
                        names[#names + 1] = trimmed
                    end
                end
            end
        end

        table.sort(names, function(a, b) return a:lower() < b:lower() end)
        return names
    end

    -- space between "Active" and first line
    imgui.Spacing()
    imgui.Spacing()

    ------------------------------------------------------------------------
    -- General:
    ------------------------------------------------------------------------
    header_yellow('General:')
    imgui.Spacing()

    -- Area
    imgui.Text('Area')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)

    local cur_area = tostring(st.bar or 'top')
    if imgui.BeginCombo('##weather_area', area_label(cur_area)) then
        for _, v in ipairs({ 'top', 'bottom', 'left', 'right', 'screen' }) do
            if imgui.Selectable(area_label(v), v == cur_area) then
                st.bar = v
                cur_area = v
            end
        end
        imgui.EndCombo()
    end

    -- Position X/Y on one line
    imgui.Text('Position')
    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local px = { tonumber(st.x or 0) or 0 }
    if imgui.InputInt('X##weather_pos_x', px) then
        st.x = tonumber(px[1] or 0) or 0
    end

    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local py = { tonumber(st.y or 0) or 0 }
    if imgui.InputInt('Y##weather_pos_y', py) then
        st.y = tonumber(py[1] or 0) or 0
    end

    -- Show Text
    imgui.Text('Show Text')
    imgui.SameLine()
    local stxt = { st.show_text == true }
    if imgui.Checkbox('##weather_show_text', stxt) then
        st.show_text = (stxt[1] == true)
    end

    imgui.Separator()

    ------------------------------------------------------------------------
    -- Text:
    ------------------------------------------------------------------------
    header_yellow('Text:')
    imgui.Spacing()

    -- Font
    imgui.Text('Font')
    imgui.SameLine()
    imgui.SetNextItemWidth(180)

    local cur_font = tostring(st.font_family or 'default')
    if imgui.BeginCombo('##weather_font_family', cur_font) then
        if imgui.Selectable('default', cur_font == 'default') then
            st.font_family = 'default'
            cur_font = 'default'
        end

        local names = build_sorted_font_names()
        for _, name in ipairs(names) do
            if imgui.Selectable(name, cur_font == name) then
                st.font_family = name
                cur_font = name
            end
        end

        imgui.EndCombo()
    end

    -- Font Size
    imgui.Text('Font Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(180)
    local fs = { tonumber(st.font_size or 32) or 32 }
    if imgui.SliderInt('##weather_font_size', fs, 10, 64) then
        st.font_size = tonumber(fs[1] or 32) or 32
    end

    -- Font Color (picker only)
    st.font_color = st.font_color or { 255, 255, 255, 255 }

    local c = { st.font_color[1], st.font_color[2], st.font_color[3], st.font_color[4] }
    if c[1] > 1 or c[2] > 1 or c[3] > 1 or c[4] > 1 then
        c[1] = c[1] / 255
        c[2] = c[2] / 255
        c[3] = c[3] / 255
        c[4] = c[4] / 255
    end

    imgui.Text('Font Color')
    imgui.SameLine()
    imgui.SetNextItemWidth(240)

    if imgui.ColorEdit4('##weather_font_color', c, ImGuiColorEditFlags_NoInputs) then
        st.font_color[1] = c[1]
        st.font_color[2] = c[2]
        st.font_color[3] = c[3]
        st.font_color[4] = c[4]
    end

    -- Icon Size
    imgui.Text('Icon Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(180)
    local isz = { tonumber(st.icon_size or 17) or 17 }
    if imgui.SliderInt('##weather_icon_size', isz, 8, 64) then
        st.icon_size = tonumber(isz[1] or 17) or 17
    end
end

return M