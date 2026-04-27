-------------------------------------------------------------------------------
-- GobbieBars Plugin: Day
-- File: Ashita/addons/gobbiebars/plugins/day/plugin.lua
-- Author: Lunem
-- Version: 0.1.0
-------------------------------------------------------------------------------

require('common')

local imgui    = require('imgui')
local ffi      = require('ffi')
local bit      = require('bit')
local texcache = require('texturecache')

local M = {
    id   = 'day',
    name = 'Day',
    default = {
        bar = 'top',
        x   = 0,
        y   = 0,
        w   = 360,
        h   = 36,
    },
    settings_defaults = {
        bar = 'top',
        x   = 0,
        y   = 0,

        show_day_text     = true,
        show_opp_element  = true,
        show_opp_text     = true,
        show_next_day_tooltip = true,

        -- split sizes
        text_font_family = 'default',
        text_font_px     = 14, -- 8..24
        icon_px          = 22, -- 12..40
    },
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function clamp(v, mn, mx)
    v = tonumber(v) or 0
    if v < mn then return mn end
    if v > mx then return mx end
    return v
end

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

local function point_in_rect(px, py, x1, y1, x2, y2)
    if x2 < x1 then x1, x2 = x2, x1 end
    if y2 < y1 then y1, y2 = y2, y1 end
    return (px >= x1 and px <= x2 and py >= y1 and py <= y2)
end

-------------------------------------------------------------------------------
-- Paths (plugin-local)
-------------------------------------------------------------------------------

local function get_base_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then src = src:sub(2) end
    return src:match('^(.*[\\/])') or './'
end

local BASE = get_base_dir()
local SEP  = package.config:sub(1, 1)

-------------------------------------------------------------------------------
-- Texture helpers
-------------------------------------------------------------------------------

local TEX = {}

local function tex_get(path)
    if type(path) ~= 'string' or path == '' then return nil end
    local t = TEX[path]
    if t == false then return nil end
    if t ~= nil then return t end
    local ok, v = pcall(function() return texcache:GetTexture(path) end)
    if ok and v ~= nil then
        TEX[path] = v
        return v
    end
    TEX[path] = false
    return nil
end

local function draw_tex(tex, w, h)
    if tex == nil then
        if imgui.Dummy then pcall(imgui.Dummy, { w, h }) end
        return
    end

    if type(tex) == 'table' and tex.Texture ~= nil then
        pcall(imgui.Image, tex.Texture, { w, h })
        return
    end

    local id = nil
    pcall(function()
        id = tonumber(ffi.cast('uintptr_t', tex))
    end)
    if id ~= nil then
        pcall(imgui.Image, id, { w, h })
        return
    end

    if imgui.Dummy then pcall(imgui.Dummy, { w, h }) end
end

-------------------------------------------------------------------------------
-- Vana timestamp (memory method from EC)
-------------------------------------------------------------------------------

local pVanaTime = ashita.memory.find('FFXiMain.dll', 0, 'B0015EC390518B4C24088D4424005068', 0, 0)

local function GetTimestamp()
    if not pVanaTime or pVanaTime == 0 then return nil end

    local pointer = ashita.memory.read_uint32(pVanaTime + 0x34)
    if not pointer or pointer == 0 then return nil end

    local rawTime = ashita.memory.read_uint32(pointer + 0x0C) + 92514960

    local ts = {}
    ts.day    = math.floor(rawTime / 3456)
    ts.hour   = math.floor(rawTime / 144) % 24
    ts.minute = math.floor((rawTime % 144) / 2.4)
    return ts
end

-------------------------------------------------------------------------------
-- Day + weakness data (from EC)
-------------------------------------------------------------------------------

local weekdayNames = {
    [1] = 'Firesday',
    [2] = 'Earthsday',
    [3] = 'Watersday',
    [4] = 'Windsday',
    [5] = 'Iceday',
    [6] = 'Lightningday',
    [7] = 'Lightsday',
    [8] = 'Darksday',
}

local dayIconFiles = {
    [1] = 'firesday.png',
    [2] = 'earthsday.png',
    [3] = 'watersday.png',
    [4] = 'windsday.png',
    [5] = 'iceday.png',
    [6] = 'lightningday.png',
    [7] = 'lightsday.png',
    [8] = 'darksday.png',
}

local dayTextColors = {
    Firesday     = { 1.000, 0.000, 0.000, 1.0 },
    Earthsday    = { 0.722, 0.573, 0.125, 1.0 },
    Watersday    = { 0.212, 0.298, 0.827, 1.0 },
    Windsday     = { 0.145, 0.612, 0.145, 1.0 },
    Iceday       = { 0.314, 0.733, 0.733, 1.0 },
    Lightningday = { 0.714, 0.145, 0.714, 1.0 },
    Lightsday    = { 1.000, 1.000, 1.000, 1.0 },
    Darksday     = { 0.471, 0.439, 0.471, 1.0 },
}

local dayIndexToElement = {
    [1] = 'Fire',
    [2] = 'Earth',
    [3] = 'Water',
    [4] = 'Wind',
    [5] = 'Ice',
    [6] = 'Lightning',
    [7] = 'Light',
    [8] = 'Dark',
}

local WeaknessElementMap = {
    Fire      = 'Water',
    Ice       = 'Fire',
    Wind      = 'Ice',
    Earth     = 'Wind',
    Lightning = 'Earth',
    Water     = 'Lightning',
    Light     = 'Dark',
    Dark      = 'Light',
}

local elementIconFiles = {
    Fire      = 'fire.png',
    Ice       = 'ice.png',
    Wind      = 'Winds.png',
    Earth     = 'earth.png',
    Lightning = 'lightning.png',
    Water     = 'Water.png',
    Light     = 'light.png',
    Dark      = 'dark.png',
}

local elementTextColors = {
    Fire      = { 1.000, 0.000, 0.000, 1.0 },
    Earth     = { 0.722, 0.573, 0.125, 1.0 },
    Water     = { 0.212, 0.298, 0.827, 1.0 },
    Wind      = { 0.145, 0.612, 0.145, 1.0 },
    Ice       = { 0.314, 0.733, 0.733, 1.0 },
    Lightning = { 0.714, 0.145, 0.714, 1.0 },
    Light     = { 1.000, 1.000, 1.000, 1.0 },
    Dark      = { 0.471, 0.439, 0.471, 1.0 },
}

local function get_day_index()
    local ts = GetTimestamp()
    if not ts or type(ts.day) ~= 'number' then return nil end
    return (ts.day % 8) + 1
end

local function get_day_name(idx)
    return weekdayNames[idx] or '(none)'
end

local function get_next_day_name(idx)
    local n = (idx % 8) + 1
    return weekdayNames[n] or '(none)'
end

local function get_day_icon(idx)
    local f = dayIconFiles[idx]
    if not f then return nil end
    return tex_get(BASE .. 'days' .. SEP .. f)
end

local function get_weakness(idx)
    local elem = dayIndexToElement[idx]
    if not elem then return nil end
    return WeaknessElementMap[elem]
end

local function get_weakness_icon(elem)
    local f = elementIconFiles[elem]
    if not f then return nil end
    return tex_get(BASE .. 'elements' .. SEP .. f)
end

-------------------------------------------------------------------------------
-- Render
-------------------------------------------------------------------------------

function M.render(dl, rect, settings, layout_mode)
    local st = settings or {}

    if st.show_day_text == nil then st.show_day_text = M.settings_defaults.show_day_text end
    if st.show_opp_element == nil then st.show_opp_element = M.settings_defaults.show_opp_element end
    if st.show_opp_text == nil then st.show_opp_text = M.settings_defaults.show_opp_text end
    if st.show_next_day_tooltip == nil then st.show_next_day_tooltip = M.settings_defaults.show_next_day_tooltip end

    if st.text_font_family == nil then st.text_font_family = M.settings_defaults.text_font_family end
    if st.text_font_px == nil then st.text_font_px = M.settings_defaults.text_font_px end
    if st.icon_px == nil then st.icon_px = M.settings_defaults.icon_px end

    local idx = get_day_index()
    if idx == nil then return end

    local day_name  = get_day_name(idx)
    local next_name = get_next_day_name(idx)

    local day_icon  = get_day_icon(idx)
    local opp_elem  = get_weakness(idx)
    local opp_icon  = (opp_elem ~= nil) and get_weakness_icon(opp_elem) or nil

    local ox = tonumber(st.x or 0) or 0
    local oy = tonumber(st.y or 0) or 0

    local x = rect.content_x + 8 + ox
    local y = rect.content_y + 4 + oy

    local text_px = clamp(st.text_font_px, 8, 24)
    local icon_px = clamp(st.icon_px, 12, 40)

    local fnt = resolve_font_family_size(st.text_font_family, text_px, nil)
    local pushed = false
    if fnt ~= nil and imgui.PushFont ~= nil then
        imgui.PushFont(fnt)
        pushed = true
    end

    local mx, my = imgui.GetMousePos()

    local gap = 6

    -- Compute hover width using current font (after PushFont)
    local w = 0
    w = w + icon_px

    if st.show_day_text == true then
        w = w + gap
        local tw = 0
        if imgui.CalcTextSize then
            local sz = imgui.CalcTextSize(day_name)
            if type(sz) == 'table' then
                tw = tonumber(sz.x or sz[1] or 0) or 0
            end
        end
        w = w + tw
    end

    if st.show_opp_element == true and opp_icon ~= nil and opp_elem ~= nil then
        w = w + gap + icon_px
        if st.show_opp_text == true then
            w = w + gap
            local tw2 = 0
            if imgui.CalcTextSize then
                local sz2 = imgui.CalcTextSize(opp_elem)
                if type(sz2) == 'table' then
                    tw2 = tonumber(sz2.x or sz2[1] or 0) or 0
                end
            end
            w = w + tw2
        end
    end

    local hover_x1 = x
    local hover_y1 = y
    local hover_x2 = x + w
    local hover_y2 = y + math.max(icon_px, (imgui.GetTextLineHeight and imgui.GetTextLineHeight() or icon_px))

    local is_hovered = point_in_rect(mx, my, hover_x1, hover_y1, hover_x2, hover_y2)

    if imgui.SetCursorScreenPos == nil then
        if pushed and imgui.PopFont ~= nil then imgui.PopFont() end
        return
    end

    imgui.SetCursorScreenPos({ x, y })

    -- Align icon vertically to text line
    local line_h = (imgui.GetTextLineHeight and imgui.GetTextLineHeight()) or icon_px
    local icon_y_off = math.floor((line_h - icon_px) * 0.5)
    if icon_y_off < 0 then icon_y_off = 0 end

    -- Day icon
    if day_icon ~= nil then
        imgui.SetCursorScreenPos({ x, y + icon_y_off })
        draw_tex(day_icon, icon_px, icon_px)
        if imgui.SameLine then imgui.SameLine() end
    end

    -- Move cursor back to text baseline area
    imgui.SetCursorScreenPos({ x + icon_px + gap, y })

    -- Day text (color-coded)
    if st.show_day_text == true then
        local col = dayTextColors[day_name]
        local COL_Text = rawget(_G, 'ImGuiCol_Text') or (imgui.Col and imgui.Col.Text) or imgui.Col_Text
        if col and COL_Text and imgui.PushStyleColor and imgui.PopStyleColor then
            imgui.PushStyleColor(COL_Text, col)
            if imgui.TextUnformatted then imgui.TextUnformatted(day_name) else imgui.Text(day_name) end
            imgui.PopStyleColor(1)
        else
            if imgui.TextUnformatted then imgui.TextUnformatted(day_name) else imgui.Text(day_name) end
        end
        if imgui.SameLine then imgui.SameLine() end
    end

    -- Weakness element icon + text (icon and text are independent)
    if opp_elem ~= nil then

        -- icon
        if st.show_opp_element == true and opp_icon ~= nil then
            local cx, cy = imgui.GetCursorScreenPos()
            imgui.SetCursorScreenPos({ cx + gap, y + icon_y_off })
            draw_tex(opp_icon, icon_px, icon_px)
            if imgui.SameLine then imgui.SameLine() end
        end

        -- text
        if st.show_opp_text == true then
            local tx, ty = imgui.GetCursorScreenPos()
            imgui.SetCursorScreenPos({ tx + gap, y })
            local col = elementTextColors[opp_elem]
            local COL_Text = rawget(_G, 'ImGuiCol_Text') or (imgui.Col and imgui.Col.Text) or imgui.Col_Text
            if col and COL_Text and imgui.PushStyleColor and imgui.PopStyleColor then
                imgui.PushStyleColor(COL_Text, col)
                if imgui.TextUnformatted then imgui.TextUnformatted(opp_elem) else imgui.Text(opp_elem) end
                imgui.PopStyleColor(1)
            else
                if imgui.TextUnformatted then imgui.TextUnformatted(opp_elem) else imgui.Text(opp_elem) end
            end
        end
    end

    if pushed and imgui.PopFont ~= nil then
        imgui.PopFont()
    end

    -- Tooltip
    if st.show_next_day_tooltip == true and (not layout_mode) and is_hovered then
        imgui.BeginTooltip()
        if imgui.TextUnformatted then
            imgui.TextUnformatted('Next day: ' .. tostring(next_name or '(none)'))
        else
            imgui.Text('Next day: ' .. tostring(next_name or '(none)'))
        end
        imgui.EndTooltip()
    end
end

-------------------------------------------------------------------------------
-- Settings UI
-------------------------------------------------------------------------------

function M.draw_settings_ui(settings)
    local st = settings or M.settings_defaults

    if st.bar == nil then st.bar = M.settings_defaults.bar end
    if st.x == nil then st.x = M.settings_defaults.x end
    if st.y == nil then st.y = M.settings_defaults.y end

    if st.show_day_text == nil then st.show_day_text = M.settings_defaults.show_day_text end
    if st.show_opp_element == nil then st.show_opp_element = M.settings_defaults.show_opp_element end
    if st.show_opp_text == nil then st.show_opp_text = M.settings_defaults.show_opp_text end
    if st.show_next_day_tooltip == nil then st.show_next_day_tooltip = M.settings_defaults.show_next_day_tooltip end

    if st.text_font_family == nil then st.text_font_family = M.settings_defaults.text_font_family end
    if st.text_font_px == nil then st.text_font_px = M.settings_defaults.text_font_px end
    if st.icon_px == nil then st.icon_px = M.settings_defaults.icon_px end

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
    -- Global:
    ---------------------------------------------------------------------------
    header_yellow('Global:')
    imgui.Spacing()

    -- Area
    imgui.Text('Area')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)
    local cur = tostring(st.bar or 'top')
    if imgui.BeginCombo('##gb_day_bar', cur) then
        for _, s in ipairs({ 'top', 'bottom', 'left', 'right', 'screen' }) do
            if imgui.Selectable(s, s == cur) then
                st.bar = s
                cur = s
            end
        end
        imgui.EndCombo()
    end

    -- Position (no separator between Area and Position)
    imgui.Text('Position')
    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local vx = { tonumber(st.x or 0) or 0 }
    if imgui.InputInt('X##gb_day_x', vx) then
        st.x = tonumber(vx[1] or 0) or 0
    end
    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local vy = { tonumber(st.y or 0) or 0 }
    if imgui.InputInt('Y##gb_day_y', vy) then
        st.y = tonumber(vy[1] or 0) or 0
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Display:
    ---------------------------------------------------------------------------
    header_yellow('Display:')
    imgui.Spacing()

    local v1 = { st.show_day_text == true }
    if imgui.Checkbox('Show Day', v1) then
        st.show_day_text = (v1[1] == true)
    end

    local v2 = { st.show_opp_element == true }
    if imgui.Checkbox('Show Weakness Element', v2) then
        st.show_opp_element = (v2[1] == true)
    end

    local v3 = { st.show_opp_text == true }
    if imgui.Checkbox('Show Weakness Text', v3) then
        st.show_opp_text = (v3[1] == true)
    end

    local v4 = { st.show_next_day_tooltip == true }
    if imgui.Checkbox('Show Next Day Tooltip', v4) then
        st.show_next_day_tooltip = (v4[1] == true)
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Text:
    ---------------------------------------------------------------------------
    header_yellow('Text:')
    imgui.Spacing()

    imgui.Text('Font')
    imgui.SameLine()
    imgui.SetNextItemWidth(180)

    local cur_ff = tostring(st.text_font_family or 'default')
    if imgui.BeginCombo('##gb_day_font_family', cur_ff) then
        if imgui.Selectable('default', cur_ff == 'default') then
            st.text_font_family = 'default'
            cur_ff = 'default'
        end

        local names = build_sorted_font_names()
        for _, name in ipairs(names) do
            if imgui.Selectable(name, cur_ff == name) then
                st.text_font_family = name
                cur_ff = name
            end
        end

        imgui.EndCombo()
    end

    imgui.Text('Font Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)
    local vpx = { clamp(st.text_font_px, 8, 24) }
    if imgui.SliderInt('##gb_day_text_font_px', vpx, 8, 24) then
        st.text_font_px = tonumber(vpx[1] or 14) or 14
    end

    imgui.Text('Icon Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)
    local vix = { clamp(st.icon_px, 12, 40) }
    if imgui.SliderInt('##gb_day_icon_px', vix, 12, 40) then
        st.icon_px = tonumber(vix[1] or 22) or 22
    end
end

return M