-------------------------------------------------------------------------------
-- GB Plugin: Moon (Vana'diel moon phase)
-- File: Ashita/addons/gobbiebars/plugins/moon/plugin.lua
-- Author: Lunem
-- Version: 0.1.0
-------------------------------------------------------------------------------


require('common')

local imgui = require('imgui')
local bit   = require('bit')
local ffi   = require('ffi')
local d3d8  = require('d3d8')

-------------------------------------------------------------------------------
-- D3D texture loading (mirrors EC style)
-------------------------------------------------------------------------------

ffi.cdef[[
typedef void*               LPVOID;
typedef const char*         LPCSTR;
typedef struct IDirect3DTexture8 IDirect3DTexture8;
typedef long                HRESULT;
HRESULT D3DXCreateTextureFromFileA(LPVOID pDevice, LPCSTR pSrcFile, IDirect3DTexture8** ppTexture);
]]

local function moon_get_base_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then
        src = src:sub(2)
    end
    return src:match('^(.*[\\/])') or './'
end

local MOON_BASE = moon_get_base_dir()
local MOON_SEP  = package.config:sub(1, 1)

local function ptr_to_number(p)
    if p == nil then return nil end
    return tonumber(ffi.cast('uintptr_t', p))
end

local TEX = {}

local function load_texture_handle(path)
    if type(path) ~= 'string' or path == '' then
        return nil
    end

    local cached = TEX[path]
    if type(cached) == 'table' and cached.handle ~= nil and cached.tex ~= nil then
        return cached.handle
    end

    if d3d8 == nil or type(d3d8.get_device) ~= 'function' then
        return nil
    end
    local dev = d3d8.get_device()
    if dev == nil then
        return nil
    end

    local out = ffi.new('IDirect3DTexture8*[1]')
    local hr = ffi.C.D3DXCreateTextureFromFileA(dev, path, out)
    if hr ~= 0 or out[0] == nil then
        return nil
    end

    local tex = out[0]
    if d3d8 ~= nil and type(d3d8.gc_safe_release) == 'function' then
        tex = d3d8.gc_safe_release(tex)
    end

    local handle = ptr_to_number(tex)
    if handle ~= nil then
        TEX[path] = { handle = handle, tex = tex }
        return handle
    end

    return nil
end

local function moon_icon_path(icon)
    return MOON_BASE .. 'images' .. MOON_SEP .. icon
end

-------------------------------------------------------------------------------
-- Vana'diel time -> moon phase (from EC)
-------------------------------------------------------------------------------

local pVanaTime = ashita.memory.find('FFXiMain.dll', 0, 'B0015EC390518B4C24088D4424005068', 0, 0)

local function GetTimestamp()
    if not pVanaTime or pVanaTime == 0 then
        return nil
    end

    local pointer = ashita.memory.read_uint32(pVanaTime + 0x34)
    if not pointer or pointer == 0 then
        return nil
    end

    local rawTime = ashita.memory.read_uint32(pointer + 0x0C) + 92514960

    local ts = {}
    ts.day    = math.floor(rawTime / 3456)
    ts.hour   = math.floor(rawTime / 144) % 24
    ts.minute = math.floor((rawTime % 144) / 2.4)
    return ts
end

local function GetMoonInfo()
    local ts = GetTimestamp()
    if not ts or type(ts.day) ~= 'number' then
        return nil
    end

    local cycleLen = 84
    local d = (ts.day + 26) % cycleLen

    local half = cycleLen / 2
    local pct
    if d <= half then
        pct = math.floor(100 - (d * 100 / half) + 0.5)
    else
        pct = math.floor(((d - half) * 100 / half) + 0.5)
    end

    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end

    local waxing = (d > half)

    local phaseName
    if pct >= 90 then
        phaseName = 'Full Moon'
    elseif pct <= 10 then
        phaseName = 'New Moon'
    else
        if waxing then
            if pct >= 60 then
                phaseName = 'Waxing Gibbous'
            elseif pct >= 30 then
                phaseName = 'First Quarter'
            else
                phaseName = 'Waxing Crescent'
            end
        else
            if pct >= 60 then
                phaseName = 'Waning Gibbous'
            elseif pct >= 30 then
                phaseName = 'Last Quarter'
            else
                phaseName = 'Waning Crescent'
            end
        end
    end

    return pct, waxing, phaseName
end

local function GetMoonText()
    local pct, _, phaseName = GetMoonInfo()
    if not pct then
        return '(none)'
    end
    return string.format('%s (%d%%)', phaseName or 'Moon', pct)
end

local function MoonGetIconHandle()
    local pct, waxing = GetMoonInfo()
    if not pct then
        return nil
    end

    local filename

    if pct >= 90 then
        filename = 'moon_full.png'
    elseif pct <= 10 then
        filename = 'moon_new.png'
    else
        if waxing then
            if pct >= 60 then
                filename = 'moon_waxing_gibbous.png'
            elseif pct >= 30 then
                filename = 'moon_first_quarter.png'
            elseif pct >= 20 then
                filename = 'moon_waxing_crescent.png'
            else
                filename = 'moon_waxing_crescent_thin.png'
            end
        else
            if pct >= 60 then
                filename = 'moon_waning_gibbous.png'
            elseif pct >= 30 then
                filename = 'moon_last_quarter.png'
            elseif pct >= 20 then
                filename = 'moon_waning_crescent.png'
            else
                filename = 'moon_waning_crescent_thin.png'
            end
        end
    end

    if not filename then
        return nil
    end

    local path = moon_icon_path(filename)
    return load_texture_handle(path)
end

local function MoonGetTrendIconHandle()
    local pct, waxing = GetMoonInfo()
    if not pct then
        return nil
    end

    local filename = waxing and 'up.png' or 'down.png'
    local path = moon_icon_path(filename)
    return load_texture_handle(path)
end

-------------------------------------------------------------------------------
-- Plugin table
-------------------------------------------------------------------------------

M = {

    id   = 'moon',
    name = 'Moon',

    default = {
        bar = 'top_bar',
        x = 0,
        y = 0,
        w = 120,
        h = 32,
    },

    settings_defaults = {
        bar = 'top',
        x = 0,
        y = 0,

        font_family = 'lato',
        font_size   = 14,

        show_percent = true,  -- Show %
        size_px      = 32,    -- icon size
        text_scale   = 100,   -- percent text size (50-200)
    },
}

-------------------------------------------------------------------------------
-- Render
-------------------------------------------------------------------------------

function M.render(dl, rect, settings, font)
    if imgui == nil or type(imgui.SetCursorScreenPos) ~= 'function' then
        return
    end
    if rect == nil or rect.content_x == nil or rect.content_y == nil then
        return
    end

    local st = settings or M.settings_defaults

    local function resolve_font_family_size(family, px, fallback)
        local fb = nil
        if type(fallback) == 'userdata' or type(fallback) == 'cdata' then
            fb = fallback
        end

        family = tostring(family or 'default')
        if family == '' then family = 'default' end

        px = tonumber(px or 14) or 14
        if px < 8 then px = 8 end
        if px > 64 then px = 64 end

        if type(_G.FONT_FAMILIES) ~= 'table' then
            return fb
        end

        local cache = _G.FONT_FAMILIES[family] or _G.FONT_FAMILIES.default
        if type(cache) ~= 'table' then
            return fb
        end

        local f = cache[px]
        if type(f) == 'userdata' or type(f) == 'cdata' then
            return f
        end

        local best = nil
        local bestd = 999999

        if type(_G.PLUGIN_FONT_SIZES) == 'table' then
            for _, s in ipairs(_G.PLUGIN_FONT_SIZES) do
                local ff = cache[s]
                if type(ff) == 'userdata' or type(ff) == 'cdata' then
                    local d = math.abs((tonumber(s) or 0) - px)
                    if d < bestd then
                        bestd = d
                        best = ff
                    end
                end
            end
            if best ~= nil then
                return best
            end
        end

        for k, ff in pairs(cache) do
            if (type(ff) == 'userdata' or type(ff) == 'cdata') and type(k) == 'number' then
                local d = math.abs(k - px)
                if d < bestd then
                    bestd = d
                    best = ff
                end
            end
        end

        return best or fb
    end

    local base_fnt = (type(font) == 'userdata' or type(font) == 'cdata') and font or nil
    local fnt = resolve_font_family_size(st.font_family, tonumber(st.font_size or 14) or 14, base_fnt)
    if fnt ~= nil then
        imgui.PushFont(fnt)
    end

    -- icon size
    local icon_px = tonumber(st.size_px or 32) or 32
    if icon_px < 8  then icon_px = 8  end
    if icon_px > 96 then icon_px = 96 end

    -- percent text scale
    local text_scale = tonumber(st.text_scale or 100) or 100
    if text_scale < 50 then text_scale = 50 end
    if text_scale > 200 then text_scale = 200 end
    text_scale = text_scale / 100

    -- moon info
    local pct, waxing, phaseName = GetMoonInfo()
    local moonText = GetMoonText()
    local tooltip  = moonText
    if pct and phaseName then
        tooltip = string.format('%s %d%%', phaseName, pct or 0)
    end

    local icon_handle  = MoonGetIconHandle()
    local trend_handle = MoonGetTrendIconHandle()

    local base_x = rect.content_x
    local base_y = rect.content_y

    local x = base_x + (tonumber(st.x or 0) or 0)
    local y = base_y + (tonumber(st.y or 0) or 0)

    -- bounding box for tooltip
    local bx1 = x
    local by1 = y
    local bx2 = x + icon_px
    local by2 = y + icon_px

    -----------------------------------------------------------------------
    -- Draw moon icon + percent + arrow
    -----------------------------------------------------------------------
    if icon_handle ~= nil and imgui.Image ~= nil then
        -- icon
        imgui.SetCursorScreenPos({ x, y })
        imgui.Image(icon_handle, { icon_px, icon_px })

        -- percent text
        if st.show_percent == true and pct ~= nil then
            local text = string.format('%d%%', pct)

            -- estimate width for tooltip box
            local text_w = 0
            if imgui.CalcTextSize ~= nil then
                local tsz = imgui.CalcTextSize(text)
                if type(tsz) == 'table' then
                    local sx = tonumber(tsz.x or tsz[1]) or 0
                    text_w = sx * text_scale
                end
            end

            if imgui.SetWindowFontScale ~= nil then
                imgui.SetWindowFontScale(text_scale)
            end

            if imgui.SameLine ~= nil then
                imgui.SameLine()
            end
            imgui.TextUnformatted(text)

            if imgui.SetWindowFontScale ~= nil then
                imgui.SetWindowFontScale(1.0)
            end

            bx2 = bx2 + 4 + text_w
        end

        -- trend arrow
        if trend_handle ~= nil and imgui.Image ~= nil then
            if imgui.SameLine ~= nil then
                imgui.SameLine()
            end
            local trend_px = math.floor(icon_px * 0.5)
            if trend_px < 8 then trend_px = 8 end
            imgui.Image(trend_handle, { trend_px, trend_px })
            bx2 = bx2 + 4 + trend_px
        end
    else
        -- fallback: text only
        imgui.SetCursorScreenPos({ x, y })
        imgui.TextUnformatted(moonText or '')

        if imgui.CalcTextSize ~= nil then
            local tsz = imgui.CalcTextSize(moonText or '')
            if type(tsz) == 'table' then
                local sx = tonumber(tsz.x or tsz[1]) or 0
                bx2 = bx1 + sx
            end
        end
    end

    -----------------------------------------------------------------------
    -- Tooltip: same pattern as Weather plugin
    -----------------------------------------------------------------------
    if tooltip and tooltip ~= '' and imgui.GetMousePos ~= nil and imgui.BeginTooltip ~= nil then
        local mx, my = imgui.GetMousePos()
        if mx ~= nil and my ~= nil then
            if mx >= bx1 and mx <= bx2 and my >= by1 and my <= by2 then
                imgui.BeginTooltip()
                imgui.TextUnformatted(tooltip)
                imgui.EndTooltip()
            end
        end
    end

    if fnt ~= nil then
        imgui.PopFont()
    end
end

-------------------------------------------------------------------------------
-- Settings UI
-------------------------------------------------------------------------------

function M.draw_settings_ui(settings)
    local st = settings or M.settings_defaults
    local changed = false

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

    ---------------------------------------------------------------------------
    -- General:
    ---------------------------------------------------------------------------
    header_yellow('General:')
    imgui.Spacing()

    -- Area
    imgui.Text('Area')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)

    local cur = tostring(st.bar or 'top')

    local function area_label(v)
        if v == 'top' then return 'Top Bar' end
        if v == 'bottom' then return 'Bottom Bar' end
        if v == 'left' then return 'Left Bar' end
        if v == 'right' then return 'Right Bar' end
        if v == 'screen' then return 'Screen' end
        return tostring(v)
    end

    if imgui.BeginCombo('##gb_moon_area', area_label(cur)) then
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

    -- Position X/Y
    imgui.Text('Position')
    imgui.SameLine()

    imgui.SetNextItemWidth(110)
    local vx = { tonumber(st.x or 0) or 0 }
    if imgui.InputInt('X##gb_moon_x', vx) then
        local nx = tonumber(vx[1] or 0) or 0
        if (tonumber(st.x or 0) or 0) ~= nx then
            st.x = nx
            changed = true
        end
    end

    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local vy = { tonumber(st.y or 0) or 0 }
    if imgui.InputInt('Y##gb_moon_y', vy) then
        local ny = tonumber(vy[1] or 0) or 0
        if (tonumber(st.y or 0) or 0) ~= ny then
            st.y = ny
            changed = true
        end
    end

    -- Show %
    local sp = { st.show_percent == true }
    if imgui.Checkbox('Show %##gb_moon_show_percent', sp) then
        st.show_percent = sp[1] == true
        changed = true
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Text:
    ---------------------------------------------------------------------------
    header_yellow('Text:')
    imgui.Spacing()

    -- Font
    imgui.Text('Font')
    imgui.SameLine()
    imgui.SetNextItemWidth(180)

    local cur_ff = tostring(st.font_family or 'default')
    if imgui.BeginCombo('##gb_moon_font_family', cur_ff) then
        if imgui.Selectable('default', cur_ff == 'default') then
            st.font_family = 'default'
            cur_ff = 'default'
            changed = true
        end

        local names = build_sorted_font_names()
        for _, name in ipairs(names) do
            if imgui.Selectable(name, cur_ff == name) then
                st.font_family = name
                cur_ff = name
                changed = true
            end
        end

        imgui.EndCombo()
    end

    -- Font Size (controls % text size)
    imgui.Text('Font Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(160)
    local ts = { tonumber(st.text_scale or 100) or 100 }
    if imgui.SliderInt('##gb_moon_text_scale', ts, 50, 200) then
        local n = tonumber(ts[1] or 100) or 100
        if n < 50 then n = 50 end
        if n > 200 then n = 200 end
        if (tonumber(st.text_scale or 100) or 100) ~= n then
            st.text_scale = n
            changed = true
        end
    end

    -- Icon size
    imgui.Text('Icon Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(160)
    local sz = { tonumber(st.size_px or 32) or 32 }
    if imgui.SliderInt('##gb_moon_size_px', sz, 8, 64) then
        local npx = tonumber(sz[1] or 32) or 32
        if (tonumber(st.size_px or 32) or 32) ~= npx then
            st.size_px = npx
            changed = true
        end
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

-------------------------------------------------------------------------------
-- Settings persistence: moon.lua in per-character dir
-------------------------------------------------------------------------------

local function gb_norm_path(p)
    p = tostring(p or '')
    p = p:gsub("[/\\]+", "\\")
    return p
end

local function gb_deepcopy(t)
    if type(t) ~= 'table' then return t end
    local r = {}
    for k, v in pairs(t) do
        r[k] = gb_deepcopy(v)
    end
    return r
end

local function gb_merge(dst, src)
    if type(dst) ~= 'table' or type(src) ~= 'table' then
        return
    end
    for k, v in pairs(src) do
        if type(v) == 'table' then
            if type(dst[k]) ~= 'table' then
                dst[k] = {}
            end
            gb_merge(dst[k], v)
        else
            dst[k] = v
        end
    end
end

local function gb_serialize(val, indent)
    indent = indent or 0
    local t = type(val)
    if t == 'number' then
        return tostring(val)
    elseif t == 'boolean' then
        return val and 'true' or 'false'
    elseif t == 'string' then
        return string.format('%q', val)
    elseif t ~= 'table' then
        return 'nil'
    end

    local pad = string.rep(' ', indent)
    local parts = { '{\n' }

    for k, v in pairs(val) do
        local key
        if type(k) == 'string' and k:match('^[A-Za-z_][A-Za-z0-9_]*$') then
            key = k .. ' = '
        else
            key = '[' .. gb_serialize(k) .. '] = '
        end
        table.insert(parts, pad .. '  ' .. key .. gb_serialize(v, indent + 2) .. ',\n')
    end

    table.insert(parts, pad .. '}')
    return table.concat(parts)
end

function M.load_settings(character_dir)
    local dir = gb_norm_path(character_dir or '')
    if dir ~= '' and dir:sub(-1) ~= "\\" then
        dir = dir .. "\\"
    end

    M._settings_path = dir .. 'moon.lua'

    local st = gb_deepcopy(M.settings_defaults)

    local f = loadfile(M._settings_path)
    if type(f) == 'function' then
        local ok, t = pcall(f)
        if ok and type(t) == 'table' then
            gb_merge(st, t)
        end
    end

    M.settings = st
    return st
end

function M.save_settings()
    if type(M._settings_path) ~= 'string' or M._settings_path == '' then
        return false
    end
    if type(M.settings) ~= 'table' then
        return false
    end

    local out = "return " .. gb_serialize(M.settings, 0) .. "\n"
    local f = io.open(M._settings_path, 'w')
    if not f then
        return false
    end
    f:write(out)
    f:close()
    return true
end

return M
