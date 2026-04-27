-------------------------------------------------------------------------------
-- GobbieBars Plugin: Clock
-- File: Ashita/addons/gobbiebars/plugins/clock/plugin.lua
-- Author: Lunem
-- Version: 0.1.0
-------------------------------------------------------------------------------

require('common')

local imgui = require('imgui')
local bit = require('bit')

local gb_clock_alarm_boot_done = false

-- Alarm overlay (runtime only; not saved)
local gb_clock_alarm_overlay_until = 0
local gb_clock_alarm_overlay_text = ''

-- Sound (use existing working Ashita method: ashita.misc.play_sound)

local function gb_clock_sound_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then
        src = src:sub(2)
    end
    local base = src:match('^(.*[\\/])') or './'
    local sep  = package.config:sub(1, 1)
    return base .. 'sounds' .. sep
end

local function gb_clock_title_case(s)
    s = tostring(s or ''):lower()
    s = s:gsub("(%S)(%S*)", function(a, b)
        return a:upper() .. b
    end)
    return s
end

local function gb_clock_sound_display_name(filename)
    local n = tostring(filename or '')
    n = n:gsub('%.wav$', '')
    n = n:gsub('_', ' ')
    n = gb_clock_title_case(n)
    return n
end

local function gb_clock_list_sounds()
    local dir = gb_clock_sound_dir()
    local list = {}

    if ashita ~= nil and ashita.fs ~= nil and type(ashita.fs.get_dir) == 'function' then
        local files = T(ashita.fs.get_dir(dir, '.*.wav', true))
        if type(files) == 'table' then
            files:each(function(v)
                if type(v) == 'string' and v:lower():match('%.wav$') then
                    list[#list + 1] = v
                end
            end)
        end
    end

    table.sort(list, function(a, b) return tostring(a):lower() < tostring(b):lower() end)

    -- Always include None first (stored as empty string)
    local out = { { file = '', name = 'None' } }
    for i = 1, #list do
        out[#out + 1] = { file = list[i], name = gb_clock_sound_display_name(list[i]) }
    end

    return out
end

local M = {

    id   = 'clock',
    name = 'Clock',

    -- NOTE: host uses M.default for initial placement when rebuilding blocks.
    -- Keep a baseline here; we will override it from saved settings in M.get_default().
    default = {
        bar = 'top_bar',
        x = 540,
        y = 2,
        w = 140,
        h = 34,
    },

    settings_defaults = {

        -- placement (host uses this after the gobbiebars.lua fix)
        bar = 'top',
        x = 0,
        y = 0,

        -- appearance
        font_family = 'lato',
        font_size   = 14,
        color       = { 255, 255, 255 },
        shadow      = true,

        -- time toggles
        show_vana = true,
        show_real = false,

        -- icons
        show_vana_icon = true,
        show_real_icon = true,
        icon_px_vana = 14,
        icon_px_real = 14,
        icon_gap = 6,

        -- alarm (real-world time)
        -- mode: 'exact' (HH:MM:SS) or 'in' (+HH:MM:SS countdown)
        alarm_enabled = false,
        alarm_mode = 'exact',

        -- exact time fields
        alarm_hour = 0,
        alarm_minute = 0,
        alarm_second = 0,

        -- countdown fields
        alarm_in_h = 0,
        alarm_in_m = 0,
        alarm_in_s = 0,

        -- computed/armed target (epoch seconds, local)
        alarm_target_ts = 0,
        alarm_armed = false,

        -- template text supports: {time} {in} {date} {datetime}
        alarm_text = 'Monster pop at {time} ({in})',

        -- sound (.wav in plugins/clock/sounds/)
        -- '' = None
        alarm_sound = '',

        -- alarm overlay (text when alarm fires)
        alarm_overlay_enabled = false,
        alarm_overlay_seconds = 10, -- 1..60
        alarm_overlay_x = 0,
        alarm_overlay_y = 0,

        -- repeat (minutes + seconds)
        alarm_repeat_mins = 0,
        alarm_repeat_secs = 0,

        -- format
        show_seconds = false,
    },
}

-------------------------------------------------------------------------------
-- Vana time (memory, from EC approach)
-------------------------------------------------------------------------------

local pVanaTime = nil
local function ensure_ptrs()
    if pVanaTime ~= nil then return end
    pcall(function()
        pVanaTime = ashita.memory.find('FFXiMain.dll', 0, 'B0015EC390518B4C24088D4424005068', 0, 0)
    end)
end

local function get_timestamp()
    ensure_ptrs()
    if not pVanaTime or pVanaTime == 0 then
        return nil
    end

    local pointer = ashita.memory.read_uint32(pVanaTime + 0x34)
    if not pointer or pointer == 0 then
        return nil
    end

    local rawTime = ashita.memory.read_uint32(pointer + 0x0C)
    if not rawTime then
        return nil
    end

    rawTime = rawTime + 92514960

    local ts = {}
    ts.day    = math.floor(rawTime / 3456)
    ts.hour   = math.floor(rawTime / 144) % 24
    ts.minute = math.floor((rawTime % 144) / 2.4)

    -- Optional seconds approximation (not perfect, but stable)
    ts.second = math.floor((rawTime % 2.4) * 25) % 60

    return ts
end

local function get_time_text(st)
    local ts = get_timestamp()
    if not ts then
        return '--:--'
    end

    local h = tonumber(ts.hour) or 0
    local m = tonumber(ts.minute) or 0
    local s = tonumber(ts.second) or 0

    if h < 0 then h = 0 end
    if h > 23 then h = 23 end
    if m < 0 then m = 0 end
    if m > 59 then m = 59 end
    if s < 0 then s = 0 end
    if s > 59 then s = 59 end

    if st.show_seconds == true then
        return string.format('%02d:%02d:%02d', h, m, s)
    end
    return string.format('%02d:%02d', h, m)
end

local function get_real_time_text(st)
    local t = os.date('*t')
    if type(t) ~= 'table' then
        return '--:--'
    end

    local h = tonumber(t.hour) or 0
    local m = tonumber(t.min) or 0
    local s = tonumber(t.sec) or 0

    if h < 0 then h = 0 end
    if h > 23 then h = 23 end
    if m < 0 then m = 0 end
    if m > 59 then m = 59 end
    if s < 0 then s = 0 end
    if s > 59 then s = 59 end

    if st.show_seconds == true then
        return string.format('%02d:%02d:%02d', h, m, s)
    end
    return string.format('%02d:%02d', h, m)
end

local function get_display_time_text(st)
    local parts = {}

    if st.show_vana == true then
        table.insert(parts, get_time_text(st))
    end
    if st.show_real == true then
        table.insert(parts, get_real_time_text(st))
    end

    if #parts == 0 then
        -- If user disables both, show something instead of blank.
        return '--:--'
    end

    return table.concat(parts, '  ')
end

local function gb_clock_fmt_in(seconds_left)
    seconds_left = tonumber(seconds_left or 0) or 0
    if seconds_left <= 0 then
        return 'now'
    end

    local total_s = math.ceil(seconds_left)
    if total_s <= 0 then
        return 'now'
    end

    local h = math.floor(total_s / 3600)
    local m = math.floor((total_s % 3600) / 60)
    local s = total_s % 60

    if h > 0 then
        return string.format('in %dh %dm %ds', h, m, s)
    end
    if m > 0 then
        return string.format('in %dm %ds', m, s)
    end
    return string.format('in %ds', s)
end

local function gb_clock_alarm_render_text(st)
    if type(st) ~= 'table' then return nil end
    if st.alarm_enabled ~= true then return nil end
    if st.alarm_armed ~= true then return nil end

    local target = tonumber(st.alarm_target_ts or 0) or 0
    if target <= 0 then return nil end

    local now = os.time()
    local left = target - now

    local t = os.date('*t', target)
    if type(t) ~= 'table' then
        return nil
    end

    local time_s = string.format(
        '%02d:%02d:%02d',
        tonumber(t.hour or 0) or 0,
        tonumber(t.min or 0) or 0,
        tonumber(t.sec or 0) or 0
    )
    local date_s = string.format('%04d-%02d-%02d', tonumber(t.year or 0) or 0, tonumber(t.month or 0) or 0, tonumber(t.day or 0) or 0)
    local dt_s   = date_s .. ' ' .. time_s

    local txt = tostring(st.alarm_text or '')
    if txt == '' then
        txt = 'Alarm'
    end

    -- If user did not include tokens, auto-append the computed info.
    local has_time = (txt:find('{time}', 1, true) ~= nil)
    local has_in   = (txt:find('{in}', 1, true) ~= nil)
    local has_date = (txt:find('{date}', 1, true) ~= nil)
    local has_dt   = (txt:find('{datetime}', 1, true) ~= nil)

    if (not has_time) and (not has_dt) then
        if txt:sub(-1) ~= ' ' then txt = txt .. ' ' end
        txt = txt .. 'at {time}'
    end
    if not has_in then
        txt = txt .. ' ({in})'
    end

    -- Replace tokens
    txt = txt:gsub('{datetime}', dt_s)
    txt = txt:gsub('{date}', date_s)
    txt = txt:gsub('{time}', time_s)
    txt = txt:gsub('{in}', gb_clock_fmt_in(left))

    return txt
end

-------------------------------------------------------------------------------
-- Icons (optional) - Emote plugin method (D3DXCreateTextureFromFileA + handle)
-------------------------------------------------------------------------------

local ffi   = require('ffi')
local d3d8  = require('d3d8')

ffi.cdef[[
typedef void*               LPVOID;
typedef const char*         LPCSTR;
typedef struct IDirect3DTexture8 IDirect3DTexture8;
typedef long                HRESULT;
HRESULT D3DXCreateTextureFromFileA(LPVOID pDevice, LPCSTR pSrcFile, IDirect3DTexture8** ppTexture);
]]

local function gb_clock_get_base_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then
        src = src:sub(2)
    end
    return src:match('^(.*[\\/])') or './'
end

local CLOCK_BASE = gb_clock_get_base_dir()
local CLOCK_SEP  = package.config:sub(1, 1)

local function ptr_to_number(p)
    if p == nil then return nil end
    return tonumber(ffi.cast('uintptr_t', p))
end

local TEX = {}

local function load_texture_handle(path)
    if type(path) ~= 'string' or path == '' then return nil end

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

-- Icons are stored in:
-- Ashita/addons/gobbiebars/plugins/clock/images/*.png
local function clock_icon_path(icon)
    return CLOCK_BASE .. 'images' .. CLOCK_SEP .. icon
end

local function gb_clock_get_vana_icon_handle()
    return load_texture_handle(clock_icon_path('VanaDielTime.png'))
end

local function gb_clock_get_earth_icon_handle()
    return load_texture_handle(clock_icon_path('EarthTime.png'))
end

local function gb_clock_get_alarm_icon_handle()
    return load_texture_handle(clock_icon_path('Alarm.png'))
end

-------------------------------------------------------------------------------
-- Render
-------------------------------------------------------------------------------

function M.render(dl, rect, settings, font)

    if imgui == nil or type(imgui.SetCursorScreenPos) ~= 'function' then
        return
    end

    local st = settings or M.settings_defaults

    local fnt = (type(font) == 'userdata') and font or nil
    if fnt ~= nil then imgui.PushFont(fnt) end

    local col = st.color or { 255, 255, 255 }
    local r = (tonumber(col[1]) or 255) / 255
    local g = (tonumber(col[2]) or 255) / 255
    local b = (tonumber(col[3]) or 255) / 255

    local text = get_display_time_text(st)

    -- Alarm trigger (fires once; repeat schedules next; never fires immediately on boot for stale targets)
    if st.alarm_enabled == true and st.alarm_armed == true then
        local now = os.time()
        local target = tonumber(st.alarm_target_ts or 0) or 0
        local repeat_mins = tonumber(st.alarm_repeat_mins or 0) or 0
        local repeat_secs = tonumber(st.alarm_repeat_secs or 0) or 0
        if repeat_mins < 0 then repeat_mins = 0 end
        if repeat_secs < 0 then repeat_secs = 0 end
        if repeat_secs > 59 then repeat_secs = 59 end
        local interval = math.floor((repeat_mins * 60) + repeat_secs)

        local function next_occurrence(ts, iv, tnow)
            if iv <= 0 then
                return 0
            end
            if ts <= 0 then
                return 0
            end
            if tnow < ts then
                return ts
            end
            local k = math.floor((tnow - ts) / iv) + 1
            return ts + (k * iv)
        end

        if (not gb_clock_alarm_boot_done) then
            gb_clock_alarm_boot_done = true

            -- On boot: if target is stale, do NOT play; just clear or roll forward.
            if target > 0 and now >= target then
                if interval > 0 then
                    st.alarm_target_ts = next_occurrence(target, interval, now)
                    st.alarm_armed = (st.alarm_target_ts > 0)
                else
                    st.alarm_armed = false
                    st.alarm_target_ts = 0
                end
            end
        else
            -- Normal runtime firing
            if target > 0 and now >= target then
                if st.alarm_sound ~= nil and st.alarm_sound ~= '' then
                    pcall(function()
                        ashita.misc.play_sound(addon.path:append('plugins/clock/sounds/' .. st.alarm_sound))
                    end)
                end

                -- optional overlay after firing (runtime locals)
                if st.alarm_overlay_enabled == true then
                    local secs = tonumber(st.alarm_overlay_seconds or 10) or 10
                    if secs < 1 then secs = 1 end
                    if secs > 60 then secs = 60 end

                    gb_clock_alarm_overlay_text = tostring(gb_clock_alarm_render_text(st) or st.alarm_text or '')
                    gb_clock_alarm_overlay_until = os.clock() + secs
                end

                -- optional overlay after firing
                if st.alarm_overlay_enabled == true then
                    local secs = tonumber(st.alarm_overlay_seconds or 10) or 10
                    if secs < 1 then secs = 1 end

                    gb_clock_alarm_overlay_text = tostring(gb_clock_alarm_render_text(st) or st.alarm_text or '')
                    gb_clock_alarm_overlay_until = os.clock() + secs
                end

                if interval > 0 then
                    st.alarm_target_ts = next_occurrence(target, interval, now)
                    st.alarm_armed = (st.alarm_target_ts > 0)
                else
                    st.alarm_armed = false
                    st.alarm_target_ts = 0
                end
            end
        end
    end

    local alarm_text = gb_clock_alarm_render_text(st)

    local x = rect.content_x + 8 + (tonumber(st.x or 0) or 0)
    local y = rect.content_y + 6 + (tonumber(st.y or 0) or 0)

    local function text_unformatted(s)
        if imgui.TextUnformatted ~= nil then
            imgui.TextUnformatted(s)
        else
            imgui.Text(s)
        end
    end

    local icon_px_vana = tonumber(st.icon_px_vana or 14) or 14
    if icon_px_vana < 8 then icon_px_vana = 8 end
    if icon_px_vana > 48 then icon_px_vana = 48 end

    local icon_px_real = tonumber(st.icon_px_real or 14) or 14
    if icon_px_real < 8 then icon_px_real = 8 end
    if icon_px_real > 48 then icon_px_real = 48 end

    local icon_gap = tonumber(st.icon_gap or 6) or 6
    -- vertical align icons to text
    local font_h = imgui.GetFontSize and imgui.GetFontSize() or 14

    local parts = {}
    if st.show_vana == true then
        table.insert(parts, { kind = 'vana', text = get_time_text(st) })
    end
    if st.show_real == true then
        table.insert(parts, { kind = 'real', text = get_real_time_text(st) })
    end
    if #parts == 0 then
        parts = { { kind = 'none', text = '--:--' } }
    end

    if alarm_text ~= nil and alarm_text ~= '' then
        table.insert(parts, { kind = 'alarm', text = alarm_text })
    end

    local function draw_line(px_x, px_y, shadow, layout_only)

        local cx = px_x

        if shadow == true then
            -- outline pass NEVER does layout
            px_x = 0
            px_y = 0
        end

        for i = 1, #parts do
            local p = parts[i]

            -- icon (only on main pass, not shadow pass)
            if shadow == false and imgui.Image ~= nil then
                if p.kind == 'vana' and st.show_vana_icon == true then
                    local ih = gb_clock_get_vana_icon_handle()
                    if ih ~= nil then
                        local iy = px_y + math.floor((font_h - icon_px_vana) * 0.5)
                        imgui.SetCursorScreenPos({ cx, iy })
                        imgui.Image(ih, { icon_px_vana, icon_px_vana })
                        cx = cx + icon_px_vana + icon_gap
                    end

                elseif p.kind == 'real' and st.show_real_icon == true then
                    local ih = gb_clock_get_earth_icon_handle()
                    if ih ~= nil then
                        local iy = px_y + math.floor((font_h - icon_px_real) * 0.5)
                        imgui.SetCursorScreenPos({ cx, iy })
                        imgui.Image(ih, { icon_px_real, icon_px_real })
                        cx = cx + icon_px_real + icon_gap
                    end

                elseif p.kind == 'alarm' then
                    local ih = gb_clock_get_alarm_icon_handle()
                    if ih ~= nil then
                        local iy = px_y + math.floor((font_h - icon_px_real) * 0.5)
                        imgui.SetCursorScreenPos({ cx, iy })
                        imgui.Image(ih, { icon_px_real, icon_px_real })
                        cx = cx + icon_px_real + icon_gap
                    end
                end
            end

            local txt = tostring(p.text or '')

            if shadow == true and p._tx ~= nil then
                imgui.PushStyleColor(ImGuiCol_Text, { 0.0, 0.0, 0.0, 1.0 })

                imgui.SetCursorScreenPos({ p._tx - 1, p._ty     })
                text_unformatted(txt)

                imgui.SetCursorScreenPos({ p._tx + 1, p._ty     })
                text_unformatted(txt)

                imgui.SetCursorScreenPos({ p._tx,     p._ty - 1 })
                text_unformatted(txt)

                imgui.SetCursorScreenPos({ p._tx,     p._ty + 1 })
                text_unformatted(txt)

                imgui.PopStyleColor(1)

            else
                p._tx = cx
                p._ty = px_y

                if not layout_only then
                    imgui.SetCursorScreenPos({ p._tx, p._ty })
                    imgui.PushStyleColor(ImGuiCol_Text, { r, g, b, 1.0 })
                    text_unformatted(txt)
                    imgui.PopStyleColor(1)
                end
            end

            local tw = 60
            if imgui.CalcTextSize ~= nil then
                local sz = imgui.CalcTextSize(txt)
                if type(sz) == 'table' then
                    tw = tonumber(sz.x or sz[1] or tw) or tw
                else
                    tw = tonumber(sz) or tw
                end
            end

            if shadow == false then
                cx = cx + tw + icon_gap
            end
        end
    end

    -- 1) layout pass (cache positions only)
    draw_line(x, y, false, true)

    -- 2) outline behind text
    if st.shadow == true then
        draw_line(x, y, true, false)
    end

    -- 3) main text on top
    draw_line(x, y, false, false)

    if fnt ~= nil then imgui.PopFont() end

    -- Alarm overlay window (safe isolated ImGui window; shows only while active)
    do
        local until_ts = tonumber(gb_clock_alarm_overlay_until or 0) or 0
        if until_ts > 0 and os.clock() < until_ts then
            local ox = tonumber(st.alarm_overlay_x or 0) or 0
            local oy = tonumber(st.alarm_overlay_y or 0) or 0
            local msg = tostring(gb_clock_alarm_overlay_text or '')

            if msg ~= '' then
                local io = imgui.GetIO()
                local sw = io.DisplaySize.x
                local sh = io.DisplaySize.y

                imgui.SetNextWindowBgAlpha(0.75)
                imgui.SetNextWindowPos(
                    { sw * 0.5, sh * 0.4 },
                    ImGuiCond_Always,
                    { 0.5, 0.5 }
                )

                imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 28, 22 })
                imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 2)
                imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.05, 0.05, 0.05, 0.75 })
                imgui.PushStyleColor(ImGuiCol_Border, { 0.0, 0.0, 0.0, 1.0 })

                local _open = { true }

                imgui.Begin(
                    '##gb_clock_alarm_overlay',
                    _open,
                    bit.bor(
                        ImGuiWindowFlags_NoTitleBar,
                        ImGuiWindowFlags_NoResize,
                        ImGuiWindowFlags_NoMove,
                        ImGuiWindowFlags_NoScrollbar,
                        ImGuiWindowFlags_NoSavedSettings,
                        ImGuiWindowFlags_AlwaysAutoResize
                    )
                )

                imgui.SetWindowFontScale(1.5)
                imgui.TextUnformatted(msg)
                imgui.SetWindowFontScale(1.0)

                imgui.End()

                imgui.PopStyleColor(2)
                imgui.PopStyleVar(2)
            end
        elseif until_ts > 0 and os.clock() >= until_ts then
            gb_clock_alarm_overlay_until = 0
            gb_clock_alarm_overlay_text = ''
        end
    end
end

-------------------------------------------------------------------------------
-- Settings UI
-------------------------------------------------------------------------------

function M.draw_settings_ui(settings)
    local st = settings or M.settings_defaults
    local changed = false

    -- Yellow header color (match your warm yellow look)
    local function header_yellow(text)
        imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.90, 0.70, 1.0 })
        imgui.TextUnformatted(text)
        imgui.PopStyleColor(1)
    end

    -- space between "Active" and first line
    imgui.Spacing()
    imgui.Spacing()

    ---------------------------------------------------------------------------
    -- General
    ---------------------------------------------------------------------------
    header_yellow('General:')
    imgui.Spacing()

    -- Area (above Time)
    imgui.Text('Area')
    imgui.SameLine()
    imgui.SetNextItemWidth(160)

    local cur = tostring(st.bar or 'top')
    if cur ~= 'top' and cur ~= 'bottom' and cur ~= 'left' and cur ~= 'right' and cur ~= 'screen' then
        cur = 'top'
    end
    if st.bar ~= cur then
        st.bar = cur
        changed = true
    end

    local function area_label(v)
        if v == 'top' then return 'Top Bar' end
        if v == 'bottom' then return 'Bottom Bar' end
        if v == 'left' then return 'Left Bar' end
        if v == 'right' then return 'Right Bar' end
        if v == 'screen' then return 'Screen' end
        return tostring(v)
    end

    if imgui.BeginCombo('##gb_clock_area', area_label(cur)) then
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

    -- Time line
    imgui.Text('Time')
    imgui.SameLine()

    local sv = { st.show_vana == true }
    if imgui.Checkbox("Vana'diel##gb_clock_show_vana", sv) then
        st.show_vana = sv[1] == true
        changed = true
    end

    imgui.SameLine()

    local sr = { st.show_real == true }
    if imgui.Checkbox("Real##gb_clock_show_real", sr) then
        st.show_real = sr[1] == true
        changed = true
    end

    -- Show Seconds in General
    local ss = { st.show_seconds == true }
    if imgui.Checkbox('Show Seconds##gb_clock_show_seconds', ss) then
        local nv = ss[1] == true
        if (st.show_seconds == true) ~= nv then
            st.show_seconds = nv
            changed = true
        end
    end

    -- Position
    imgui.Text('Position')
    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local vx = { tonumber(st.x or 0) or 0 }
    if imgui.InputInt('X##gb_clock_x', vx) then
        local nx = tonumber(vx[1] or 0) or 0
        if (tonumber(st.x or 0) or 0) ~= nx then
            st.x = nx
            changed = true
        end
    end
    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local vy = { tonumber(st.y or 0) or 0 }
    if imgui.InputInt('Y##gb_clock_y', vy) then
        local ny = tonumber(vy[1] or 0) or 0
        if (tonumber(st.y or 0) or 0) ~= ny then
            st.y = ny
            changed = true
        end
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Font
    ---------------------------------------------------------------------------
    header_yellow('Font:')
    imgui.Spacing()

    -- One line: Font / Font Size / Color
    imgui.Text('Font')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)

    local cur_ff = tostring(st.font_family or 'default')
    if imgui.BeginCombo('##gb_clock_font_family', cur_ff) then
        if imgui.Selectable('default', cur_ff == 'default') then
            st.font_family = 'default'
            changed = true
        end

        if type(_G.FONT_FAMILIES) == 'table' then
            for name, _ in pairs(_G.FONT_FAMILIES) do
                if type(name) == 'string' and name ~= 'default' then
                    if imgui.Selectable(name, cur_ff == name) then
                        st.font_family = name
                        changed = true
                    end
                end
            end
        end

        imgui.EndCombo()
    end

    imgui.SameLine()
    imgui.Text('Font Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)
    local fp = { tonumber(st.font_size or 14) or 14 }
    if imgui.SliderInt('##gb_clock_font_size', fp, 8, 32) then
        local npx = tonumber(fp[1] or 14) or 14
        if (tonumber(st.font_size or 14) or 14) ~= npx then
            st.font_size = npx
            changed = true
        end
    end

    imgui.SameLine()
    imgui.Text('Color')
    imgui.SameLine()
    imgui.SetNextItemWidth(120)
    local c = st.color or { 255, 255, 255 }
    local col = {
        (tonumber(c[1]) or 255) / 255,
        (tonumber(c[2]) or 255) / 255,
        (tonumber(c[3]) or 255) / 255
    }
    if imgui.ColorEdit3('##gb_clock_color', col, ImGuiColorEditFlags_NoInputs) then
        st.color = {
            math.floor(col[1] * 255 + 0.5),
            math.floor(col[2] * 255 + 0.5),
            math.floor(col[3] * 255 + 0.5),
        }
        changed = true
    end

    -- Next line: Shadow
    local sh = { st.shadow == true }
    if imgui.Checkbox('Shadow##gb_clock_shadow', sh) then
        local nv = sh[1] == true
        if (st.shadow == true) ~= nv then
            st.shadow = nv
            changed = true
        end
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Icons (unchanged layout, just keeps working)
    ---------------------------------------------------------------------------
    imgui.Text('Icons')
    imgui.SameLine()

    local svi = { st.show_vana_icon == true }
    if imgui.Checkbox("Vana##gb_clock_icon_vana", svi) then
        local nv = svi[1] == true
        if (st.show_vana_icon == true) ~= nv then
            st.show_vana_icon = nv
            changed = true
        end
    end

    imgui.SameLine()

    local sri = { st.show_real_icon == true }
    if imgui.Checkbox("Real##gb_clock_icon_real", sri) then
        local nv = sri[1] == true
        if (st.show_real_icon == true) ~= nv then
            st.show_real_icon = nv
            changed = true
        end
    end

    imgui.Text('Icon Size')
    imgui.SameLine()

    imgui.SetNextItemWidth(120)
    local ipv = { tonumber(st.icon_px_vana or 14) or 14 }
    if imgui.SliderInt('Vana##gb_clock_icon_px_vana', ipv, 8, 48) then
        local nv = tonumber(ipv[1] or 14) or 14
        if nv < 8 then nv = 8 end
        if nv > 48 then nv = 48 end
        if (tonumber(st.icon_px_vana or 14) or 14) ~= nv then
            st.icon_px_vana = nv
            changed = true
        end
    end

    imgui.SameLine()

    imgui.SetNextItemWidth(120)
    local ipr = { tonumber(st.icon_px_real or 14) or 14 }
    if imgui.SliderInt('Real##gb_clock_icon_px_real', ipr, 8, 48) then
        local nv = tonumber(ipr[1] or 14) or 14
        if nv < 8 then nv = 8 end
        if nv > 48 then nv = 48 end
        if (tonumber(st.icon_px_real or 14) or 14) ~= nv then
            st.icon_px_real = nv
            changed = true
        end
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Alarm
    ---------------------------------------------------------------------------
    header_yellow('Alarm:')
    imgui.Spacing()

    -- No Enable checkbox (arm/stop is enough). Keep alarm_enabled true so existing runtime logic works.
    if st.alarm_enabled ~= true then
        st.alarm_enabled = true
        changed = true
    end

    -- Text
    imgui.Text('Text')
    imgui.SameLine()
    imgui.SetNextItemWidth(360)
    st.alarm_text = tostring(st.alarm_text or 'Monster pop at {time} ({in})')
    local buf = { st.alarm_text }
    if imgui.InputText('##gb_clock_alarm_text', buf, 256) then
        local nv = tostring(buf[1] or '')
        if st.alarm_text ~= nv then
            st.alarm_text = nv
            changed = true
        end
    end

    -- Mode (wider)
    imgui.Text('Mode')
    imgui.SameLine()
    imgui.SetNextItemWidth(260)

    local mode = tostring(st.alarm_mode or 'exact')
    if mode ~= 'exact' and mode ~= 'in' then mode = 'exact' end
    if st.alarm_mode ~= mode then
        st.alarm_mode = mode
        changed = true
    end

    local function mode_label(v)
        if v == 'exact' then return 'Exact (HH:MM:SS)' end
        if v == 'in' then return 'In (HH:MM:SS from now)' end
        return tostring(v)
    end

    if imgui.BeginCombo('##gb_clock_alarm_mode', mode_label(mode)) then
        if imgui.Selectable(mode_label('exact'), mode == 'exact') then
            if st.alarm_mode ~= 'exact' then st.alarm_mode = 'exact'; changed = true end
            mode = 'exact'
        end
        if imgui.Selectable(mode_label('in'), mode == 'in') then
            if st.alarm_mode ~= 'in' then st.alarm_mode = 'in'; changed = true end
            mode = 'in'
        end
        imgui.EndCombo()
    end

    -- Inputs with seconds
    if mode == 'exact' then
        imgui.Text('Time')
        imgui.SameLine()
        imgui.SetNextItemWidth(90)
        local hh = { tonumber(st.alarm_hour or 0) or 0 }
        if imgui.InputInt('HH##gb_clock_alarm_hh', hh) then
            local nv = tonumber(hh[1] or 0) or 0
            if nv < 0 then nv = 0 end
            if nv > 23 then nv = 23 end
            if (tonumber(st.alarm_hour or 0) or 0) ~= nv then
                st.alarm_hour = nv
                changed = true
            end
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(90)
        local mm = { tonumber(st.alarm_minute or 0) or 0 }
        if imgui.InputInt('MM##gb_clock_alarm_mm', mm) then
            local nv = tonumber(mm[1] or 0) or 0
            if nv < 0 then nv = 0 end
            if nv > 59 then nv = 59 end
            if (tonumber(st.alarm_minute or 0) or 0) ~= nv then
                st.alarm_minute = nv
                changed = true
            end
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(90)
        local ss2 = { tonumber(st.alarm_second or 0) or 0 }
        if imgui.InputInt('SS##gb_clock_alarm_ss', ss2) then
            local nv = tonumber(ss2[1] or 0) or 0
            if nv < 0 then nv = 0 end
            if nv > 59 then nv = 59 end
            if (tonumber(st.alarm_second or 0) or 0) ~= nv then
                st.alarm_second = nv
                changed = true
            end
        end
    else
        imgui.Text('In')
        imgui.SameLine()
        imgui.SetNextItemWidth(90)
        local ih = { tonumber(st.alarm_in_h or 0) or 0 }
        if imgui.InputInt('HH##gb_clock_alarm_in_hh', ih) then
            local nv = tonumber(ih[1] or 0) or 0
            if nv < 0 then nv = 0 end
            if nv > 240 then nv = 240 end
            if (tonumber(st.alarm_in_h or 0) or 0) ~= nv then
                st.alarm_in_h = nv
                changed = true
            end
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(90)
        local im = { tonumber(st.alarm_in_m or 0) or 0 }
        if imgui.InputInt('MM##gb_clock_alarm_in_mm', im) then
            local nv = tonumber(im[1] or 0) or 0
            if nv < 0 then nv = 0 end
            if nv > 59 then nv = 59 end
            if (tonumber(st.alarm_in_m or 0) or 0) ~= nv then
                st.alarm_in_m = nv
                changed = true
            end
        end

        imgui.SameLine()
        imgui.SetNextItemWidth(90)
        local isx = { tonumber(st.alarm_in_s or 0) or 0 }
        if imgui.InputInt('SS##gb_clock_alarm_in_ss', isx) then
            local nv = tonumber(isx[1] or 0) or 0
            if nv < 0 then nv = 0 end
            if nv > 59 then nv = 59 end
            if (tonumber(st.alarm_in_s or 0) or 0) ~= nv then
                st.alarm_in_s = nv
                changed = true
            end
        end
    end

    -- State line: Idle/Armed + Arm/Start + Stop + Repeat (min/sec)
    imgui.Text('State')
    imgui.SameLine()

    local armed = (st.alarm_armed == true and (tonumber(st.alarm_target_ts or 0) or 0) > 0)
    imgui.Text(armed and 'Armed' or 'Idle')
    imgui.SameLine()

    if imgui.Button('Arm / Start##gb_clock_alarm_arm', { 110, 0 }) then
        local now = os.time()
        local target = now

        if mode == 'exact' then
            local t = os.date('*t', now)
            t.hour = tonumber(st.alarm_hour or 0) or 0
            t.min  = tonumber(st.alarm_minute or 0) or 0
            t.sec  = tonumber(st.alarm_second or 0) or 0
            if t.sec < 0 then t.sec = 0 end
            if t.sec > 59 then t.sec = 59 end
            target = os.time(t)
            if target <= now then
                target = target + 86400
            end
        else
            local dh = tonumber(st.alarm_in_h or 0) or 0
            local dm = tonumber(st.alarm_in_m or 0) or 0
            local ds = tonumber(st.alarm_in_s or 0) or 0
            if dh < 0 then dh = 0 end
            if dm < 0 then dm = 0 end
            if ds < 0 then ds = 0 end
            if dm > 59 then dm = 59 end
            if ds > 59 then ds = 59 end
            target = now + (dh * 3600) + (dm * 60) + ds
        end

        st.alarm_target_ts = target
        st.alarm_armed = true
        st.alarm_enabled = true
        changed = true
    end

    imgui.SameLine()

    if imgui.Button('Stop##gb_clock_alarm_stop', { 70, 0 }) then
        st.alarm_armed = false
        st.alarm_target_ts = 0
        changed = true
    end

    imgui.SameLine()
    imgui.Text('Repeat')
    imgui.SameLine()
    imgui.Text('min')
    imgui.SameLine()
    imgui.SetNextItemWidth(110) -- bigger so it is not cut off
    local rm = { tonumber(st.alarm_repeat_mins or 0) or 0 }
    if imgui.InputInt('##gb_clock_alarm_repeat_mins', rm) then
        local v = tonumber(rm[1] or 0) or 0
        if v < 0 then v = 0 end
        if v > 1440 then v = 1440 end
        if (tonumber(st.alarm_repeat_mins or 0) or 0) ~= v then
            st.alarm_repeat_mins = v
            changed = true
        end
    end

    imgui.SameLine()
    imgui.Text('sec')
    imgui.SameLine()
    imgui.SetNextItemWidth(90)
    local rs = { tonumber(st.alarm_repeat_secs or 0) or 0 }
    if imgui.InputInt('##gb_clock_alarm_repeat_secs', rs) then
        local v = tonumber(rs[1] or 0) or 0
        if v < 0 then v = 0 end
        if v > 59 then v = 59 end
        if (tonumber(st.alarm_repeat_secs or 0) or 0) ~= v then
            st.alarm_repeat_secs = v
            changed = true
        end
    end

    imgui.Separator()

    header_yellow('Alarm Overlay:')
    imgui.Spacing()

    local oe = { st.alarm_overlay_enabled == true }
    if imgui.Checkbox('Show overlay on fire##gb_clock_alarm_overlay_enable', oe) then
        local nv = oe[1] == true
        if (st.alarm_overlay_enabled == true) ~= nv then
            st.alarm_overlay_enabled = nv
            changed = true
        end
    end

    imgui.Text('Overlay Duration (sec)')
    imgui.SameLine()
    imgui.SetNextItemWidth(120)
    local osx = { tonumber(st.alarm_overlay_seconds or 10) or 10 }
    if imgui.InputInt('##gb_clock_alarm_overlay_seconds', osx) then
        local v = tonumber(osx[1] or 10) or 10
        if v < 1 then v = 1 end
        if v > 60 then v = 60 end
        if (tonumber(st.alarm_overlay_seconds or 10) or 10) ~= v then
            st.alarm_overlay_seconds = v
            changed = true
        end
    end

    imgui.Text('Overlay Position')
    imgui.SameLine()
    imgui.SetNextItemWidth(120)
    local opx = { tonumber(st.alarm_overlay_x or 0) or 0 }
    if imgui.InputInt('X##gb_clock_alarm_overlay_x', opx) then
        local v = tonumber(opx[1] or 0) or 0
        if (tonumber(st.alarm_overlay_x or 0) or 0) ~= v then
            st.alarm_overlay_x = v
            changed = true
        end
    end
    imgui.SameLine()
    imgui.SetNextItemWidth(120)
    local opy = { tonumber(st.alarm_overlay_y or 0) or 0 }
    if imgui.InputInt('Y##gb_clock_alarm_overlay_y', opy) then
        local v = tonumber(opy[1] or 0) or 0
        if (tonumber(st.alarm_overlay_y or 0) or 0) ~= v then
            st.alarm_overlay_y = v
            changed = true
        end
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Alarm Sound
    ---------------------------------------------------------------------------
    header_yellow('Alarm Sound:')
    imgui.Spacing()

    local sounds = gb_clock_list_sounds()

    st.alarm_sound = tostring(st.alarm_sound or '')

    local function current_sound_label()
        for _, s in ipairs(sounds) do
            if s.file == st.alarm_sound then
                return s.name
            end
        end
        return 'None'
    end

    imgui.SetNextItemWidth(240)
    if imgui.BeginCombo('##gb_clock_alarm_sound', current_sound_label()) then
        for _, s in ipairs(sounds) do
            if imgui.Selectable(s.name, s.file == st.alarm_sound) then
                if st.alarm_sound ~= s.file then
                    st.alarm_sound = s.file
                    changed = true
                end
            end
        end
        imgui.EndCombo()
    end

    imgui.SameLine()

    if imgui.Button('Test Sound##gb_clock_test_sound', { 120, 0 }) then
        if st.alarm_sound ~= nil and st.alarm_sound ~= '' then
            ashita.misc.play_sound(addon.path:append('plugins/clock/sounds/' .. st.alarm_sound))
        end
    end

    imgui.Spacing()
    imgui.Spacing()
    imgui.Spacing()
    imgui.Spacing()
	
    if changed then
        M.save_settings()
    end
end

-- Optional hook: host can call this to get a placement default that reflects saved settings.
function M.get_default(settings)
    local st = settings or {}
    local d = {}
    d.bar = tostring(st.bar or M.default.bar)
    d.x = tonumber(st.x or M.default.x) or M.default.x
    d.y = tonumber(st.y or M.default.y) or M.default.y
    d.w = tonumber(st.w or M.default.w) or M.default.w
    d.h = tonumber(st.h or M.default.h) or M.default.h
    return d
end

-------------------------------------------------------------------------------
-- Plugin-owned settings (per-character): clock.lua
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
    if type(dst) ~= 'table' or type(src) ~= 'table' then return dst end
    for k, v in pairs(src) do
        if type(v) == 'table' and type(dst[k]) == 'table' then
            gb_merge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

local function gb_serialize(v, indent)
    indent = indent or 0
    local pad = string.rep(' ', indent)

    local tv = type(v)
    if tv == 'number' then
        return tostring(v)
    elseif tv == 'boolean' then
        return v and 'true' or 'false'
    elseif tv == 'string' then
        return string.format('%q', v)
    elseif tv ~= 'table' then
        return 'nil'
    end

    local parts = {}
    table.insert(parts, '{\n')

    -- array-ish + map-ish safe serialization
    for k, val in pairs(v) do
        local key
        if type(k) == 'string' and k:match('^[A-Za-z_][A-Za-z0-9_]*$') then
            key = k .. ' = '
        else
            key = '[' .. gb_serialize(k) .. '] = '
        end
        table.insert(parts, pad .. '  ' .. key .. gb_serialize(val, indent + 2) .. ',\n')
    end

    table.insert(parts, pad .. '}')
    return table.concat(parts)
end

-- Host will pass the per-character config directory (ending with a slash or not).
function M.load_settings(character_dir)
    local dir = gb_norm_path(character_dir or '')
    if dir ~= '' and dir:sub(-1) ~= "\\" then
        dir = dir .. "\\"
    end

    M._settings_path = dir .. 'clock.lua'

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