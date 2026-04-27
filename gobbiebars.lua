-------------------------------------------------------------------------------
-- GobbieBars (GB) - v1 Plugin Host
-- Drop-in rewrite: stability-first, no redundant code paths.
-------------------------------------------------------------------------------

addon = addon or {}
addon.name    = 'gobbiebars'
addon.author  = 'Lunem'
addon.version = '0.1.7'
addon.desc    = 'GobbieBars - layout-first bar host with internal plugins.'
addon.link    = 'https://ashitaxi.com/'

local ok, err = pcall(function()

require('common')

local imgui        = require('imgui')
local bit          = require('bit')
local ffi          = require('ffi')
local settings_mod = require('settings')
local texcache     = require('texturecache')
local gb_help      = require('gobbiebars_help')

-------------------------------------------------------------------------------
-- Helpers: safe calls, logging, type guards
-------------------------------------------------------------------------------

local function gb_log(fmt, ...)
    local s = fmt
    if select('#', ...) > 0 then
        s = string.format(fmt, ...)
    end
    print('[GobbieBars] ' .. s)
end

local gb_traceback = (debug and debug.traceback) or function(e) return tostring(e) end

-- Some Ashita builds do not expose _G.xpcall. Provide a safe fallback.
local function gb_xpcall(fn)
    if type(_G.xpcall) == 'function' then
        return _G.xpcall(fn, gb_traceback)
    end
    local ok, err = _G.pcall(fn)
    if ok then
        return true
    end
    return false, gb_traceback(err)
end

local function gb_pcall(fn, ...)
    return _G.pcall(fn, ...)
end


local function gb_is_table(t) return type(t) == 'table' end
local function gb_is_func(f)  return type(f) == 'function' end

local function gb_clamp(v, mn, mx)
    v = tonumber(v) or 0
    if v < mn then return mn end
    if v > mx then return mx end
    return v
end

local function gb_pack_col(r, g, b, a)
    r = bit.band(tonumber(r) or 0, 0xFF)
    g = bit.band(tonumber(g) or 0, 0xFF)
    b = bit.band(tonumber(b) or 0, 0xFF)
    a = bit.band(tonumber(a) or 0, 0xFF)
    return bit.bor(r, bit.lshift(g, 8), bit.lshift(b, 16), bit.lshift(a, 24))
end

-------------------------------------------------------------------------------
-- ImGui safety wrappers (prevents nil-call crashes on early login/reload)
-------------------------------------------------------------------------------

local function gb_imgui_has_core()
    return imgui ~= nil
       and gb_is_func(imgui.GetIO)
       and gb_is_func(imgui.Begin)
       and gb_is_func(imgui.End)
       and gb_is_func(imgui.GetWindowDrawList)
end

local function gb_imgui_call(fnname, ...)
    if imgui == nil then return nil end
    local f = imgui[fnname]
    if not gb_is_func(f) then return nil end
    local ok1, r1, r2, r3 = gb_pcall(f, ...)
    if not ok1 then return nil end
    return r1, r2, r3
end

local function gb_IsMouseDown(btn)
    local r = gb_imgui_call('IsMouseDown', btn)
    return r == true
end

local function gb_IsMouseClicked(btn)
    local r = gb_imgui_call('IsMouseClicked', btn)
    return r == true
end

local function gb_IsCtrlDown()
    local io = gb_imgui_call('GetIO')
    if io ~= nil and io.KeyCtrl ~= nil then
        return io.KeyCtrl == true
    end
    return false
end

-- Used to keep hover-bars open when moving into a dropdown/menu window.
-- If this is unreliable in a given Ashita build, the bar can still be held open
-- via plugin_settings.<id>.dropdown_open + hold_open[side] below.
local function gb_IsAnyWindowHovered()

    return r == true
end

-- Mouse position cache:
-- Some setups return invalid mouse coords for a few frames; do not force (0,0),
-- because that will make top/left bars behave as always-hovered.
local gb_last_mx, gb_last_my = 0, 0

local function gb_GetMousePos()
    local a, b = gb_imgui_call('GetMousePos')

    local function accept_xy(x, y)
        if type(x) ~= 'number' or type(y) ~= 'number' then return nil end
        if x ~= x or y ~= y then return nil end -- NaN guard
        if x < -100000 or y < -100000 then return nil end
        gb_last_mx, gb_last_my = x, y
        return x, y
    end

    local x, y = accept_xy(a, b)
    if x ~= nil then return x, y end

    if gb_is_table(a) then
        x = a.x or a[1]
        y = a.y or a[2]
        x, y = accept_xy(x, y)
        if x ~= nil then return x, y end
    end

    return gb_last_mx, gb_last_my
end

-------------------------------------------------------------------------------
-- Paths
-------------------------------------------------------------------------------

local function gb_get_addon_dir()
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

local addon_dir = gb_get_addon_dir()
local sep = package.config:sub(1, 1)
local plugins_dir = addon_dir .. 'plugins' .. sep

-------------------------------------------------------------------------------
-- Settings bootstrap (keep minimal; no duplicate mkdir helpers)
-------------------------------------------------------------------------------

local function gb_settings_bootstrap()
    if _G.ashita == nil then _G.ashita = {} end
    ashita.file = ashita.file or {}
    ashita.fs   = ashita.fs   or {}

    local function mkdir_p(path)
        if path == nil or path == '' then return 0 end
        os.execute(('mkdir "%s"'):format(path))
        return 1
    end

    if not gb_is_func(ashita.file.create_dir) then ashita.file.create_dir = mkdir_p end
    if not gb_is_func(ashita.fs.create_dir)   then ashita.fs.create_dir   = mkdir_p end
end

gb_settings_bootstrap()

-------------------------------------------------------------------------------
-- Win32 helpers (client rect fallback only)
-------------------------------------------------------------------------------

ffi.cdef[[
typedef struct { long left; long top; long right; long bottom; } RECT;
int   GetClientRect(void* hWnd, RECT* lpRect);
int   GetSystemMetrics(int nIndex);
]]

local SM_CXSCREEN = 0
local SM_CYSCREEN = 1

local function gb_get_hwnd()
    local hwnd = nil
    gb_pcall(function()
        if AshitaCore and AshitaCore.GetHandle then hwnd = AshitaCore:GetHandle() end
    end)
    gb_pcall(function()
        if hwnd == nil and AshitaCore and AshitaCore.GetWindowHandle then hwnd = AshitaCore:GetWindowHandle() end
    end)
    if hwnd ~= nil then hwnd = ffi.cast('void*', tonumber(hwnd)) end
    return hwnd
end

local function gb_try_client_rect(hwnd)
    if hwnd == nil then return nil, nil end
    local rc = ffi.new('RECT[1]')
    if (ffi.C.GetClientRect(hwnd, rc) ~= 0) then
        local sw = tonumber(rc[0].right - rc[0].left) or 0
        local sh = tonumber(rc[0].bottom - rc[0].top) or 0
        if sw > 0 and sh > 0 then return sw, sh end
    end
    return nil, nil
end

local last_sw, last_sh, have_last = 800, 600, true

local function gb_get_client_size()
    -- Best source: ImGui DisplaySize (Ashita often returns userdata, not table)
    local io = nil
    gb_pcall(function() io = imgui.GetIO() end)

    if io ~= nil then
        local ds = nil
        gb_pcall(function() ds = io.DisplaySize end)

        if ds ~= nil then
            local sw = tonumber(ds.x or ds[1] or 0) or 0
            local sh = tonumber(ds.y or ds[2] or 0) or 0
            if sw > 0 and sh > 0 then
                last_sw, last_sh, have_last = sw, sh, true
                return sw, sh
            end
        end
    end

    -- Win32 fallback
    local sw, sh = gb_try_client_rect(gb_get_hwnd())
    if sw ~= nil then
        last_sw, last_sh, have_last = sw, sh, true
        return sw, sh
    end

    -- Last known
    if have_last and last_sw > 0 and last_sh > 0 then
        return last_sw, last_sh
    end

    -- Screen fallback
    sw = tonumber(ffi.C.GetSystemMetrics(SM_CXSCREEN)) or 800
    sh = tonumber(ffi.C.GetSystemMetrics(SM_CYSCREEN)) or 600
    if sw <= 0 then sw = 800 end
    if sh <= 0 then sh = 600 end
    last_sw, last_sh, have_last = sw, sh, true
    return sw, sh
end

-------------------------------------------------------------------------------
-- Core state
-------------------------------------------------------------------------------

local enabled       = true
local layout_mode   = false
local ui_open       = false
local ui_help_open  = false
local ui_plugin_open_id = nil


-- Hard gate: only render once load finished successfully.
local gb_ready = false
local gb_settings = nil
local GB_DEFAULTS = nil
local gb_settings_reloaded_after_login = false
local applied_job_id = -1

-------------------------------------------------------------------------------
-- Dock (animated visible pixels per side)
-------------------------------------------------------------------------------

local DOCK = {
    last_clock = nil,
    vis = { top = 0, bottom = 0, left = 0, right = 0 },
}



-- Runtime thickness (fed into compute_bars)
local cfg = {
    thickness_top    = 36,
    thickness_bottom = 36,
    thickness_left   = 36,
    thickness_right  = 36,
};


-------------------------------------------------------------------------------
-- Font (load once) - simplified to one path; no dual load APIs
-------------------------------------------------------------------------------

local UI_FONT = nil
local UI_FONT_SIZE = 20

local function gb_file_exists(p)
    local ok1, ex = gb_pcall(function()
        return ashita and ashita.fs and gb_is_func(ashita.fs.exists) and ashita.fs.exists(p)
    end)
    return ok1 and ex == true
end

local function gb_load_font_once(fullpath, size)
    if not fullpath or fullpath == '' then return nil end
    if not gb_file_exists(fullpath) then
        gb_log('Font missing: %s', tostring(fullpath))
        return nil
    end

    -- Load font via Ashita imgui binding (THIS IS THE WORKING PATH)
if gb_is_func(imgui.AddFontFromFileTTF) then
    local ok1, f1 = gb_pcall(imgui.AddFontFromFileTTF, fullpath, tonumber(size) or 18)
    if ok1 and type(f1) == 'userdata' then
        local io = imgui.GetIO()
        if io and io.Fonts and io.Fonts.Build then
            gb_pcall(io.Fonts.Build, io.Fonts)
        end
        return f1
    end
end



    gb_log('Font load failed: %s', tostring(fullpath))
    return nil
end

-------------------------------------------------------------------------------
-- Settings: defaults + ensure tables exist
-------------------------------------------------------------------------------

local function gb_merge_defaults(dst, defs)
    if not gb_is_table(dst) then dst = {} end
    if not gb_is_table(defs) then return dst end
    for k, v in pairs(defs) do
        if dst[k] == nil then
            if gb_is_table(v) then
                local t = {}
                for kk, vv in pairs(v) do t[kk] = vv end
                dst[k] = t
            else
                dst[k] = v
            end
        end
    end
    return dst
end

local function gb_ensure_settings()
    gb_settings.layouts         = gb_settings.layouts or {}
    gb_settings.enabled_plugins = gb_settings.enabled_plugins or {}
    gb_settings.plugin_settings = gb_settings.plugin_settings or {}
    gb_settings.active_bars     = gb_settings.active_bars or { top = true, bottom = true, left = true, right = true }
    gb_settings.bar_settings    = gb_settings.bar_settings or {}
    gb_settings._ui             = gb_settings._ui or {}
    if gb_settings._ui.bar_side == nil then gb_settings._ui.bar_side = 'top' end

    gb_settings.plugin_settings.buttons = gb_settings.plugin_settings.buttons or {}
    if gb_settings.plugin_settings.buttons.game_mode == nil then
        gb_settings.plugin_settings.buttons.game_mode = 'CW'
    end


    local function ensure_bar(side)
        gb_settings.bar_settings[side] = gb_settings.bar_settings[side] or {}
        local bs = gb_settings.bar_settings[side]
        if bs.static == nil then bs.static = false end
        if bs.hot_zone == nil then bs.hot_zone = 4 end
        if bs.thickness == nil then bs.thickness = 36 end
        if type(bs.color) ~= 'table' then bs.color = { 0, 0, 0 } end
        if bs.opacity == nil then bs.opacity = 80 end
        if bs.texture == nil then bs.texture = '' end
    end

    ensure_bar('top')
    ensure_bar('bottom')
    ensure_bar('left')
    ensure_bar('right')
end

-------------------------------------------------------------------------------
-- Bars geometry + dock logic
-------------------------------------------------------------------------------

-- Forward declare so gb_update_dock sees the real blocks table (not _G.blocks).
local blocks = {}

local function gb_make_rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end

local function gb_compute_bars(sw, sh)
    local tT, tB, tL, tR = cfg.thickness_top, cfg.thickness_bottom, cfg.thickness_left, cfg.thickness_right
    local top    = gb_make_rect(0, 0, sw, tT)
    local bottom = gb_make_rect(0, sh - tB, sw, tB)

    -- Side bars are full-height so top/bottom do not push them down.
    local left  = (tL > 0) and gb_make_rect(-1, 0, tL + 1, sh) or gb_make_rect(0, 0, 0, sh)
    local right = (tR > 0) and gb_make_rect(sw - tR - 1, 0, tR + 1, sh) or gb_make_rect(sw, 0, 0, sh)

    local screen = gb_make_rect(0, 0, sw, sh)
    return { top = top, bottom = bottom, left = left, right = right, screen = screen }
end


local function gb_get_bar_rect(side, bars)
    return bars[side]
end

local function gb_point_in_rect(px, py, x1, y1, x2, y2)
    return (px >= x1 and px <= x2 and py >= y1 and py <= y2)
end

-- Hot zone is measured from the screen edge inward.
local function gb_bar_is_hot(sw, sh, side, hot_zone, mx, my)
    hot_zone = gb_clamp(hot_zone, 0, 200)
    if mx < 0 or my < 0 or mx > sw or my > sh then return false end
    if side == 'top' then
        return my <= hot_zone
    elseif side == 'bottom' then
        return my >= (sh - hot_zone)
    elseif side == 'left' then
        return mx <= hot_zone
    elseif side == 'right' then
        return mx >= (sw - hot_zone)
    end
    return false
end

-- Core dock update:
-- - If UI or layout mode is open: keep bars expanded.
-- - If bar is static: keep expanded.
-- - If an ImGui window is hovered: keep expanded (so dropdown menus can be scrolled/clicked).
-- - If plugin declares dropdown_open: keep only that bar expanded (extra safety/precision).
-- - Otherwise: hover-only behavior via hot zone / in-bar.
local function gb_update_dock(sw, sh, mx, my)
    if not gb_is_table(gb_settings) then return end

    local ab = gb_settings.active_bars or { top = true, bottom = true, left = true, right = true }
    local bs = gb_settings.bar_settings or {}

    local nowc = os.clock()
    local dt = 0.0
    if DOCK.last_clock ~= nil then
        dt = nowc - DOCK.last_clock
        if dt < 0 then dt = 0 end
        if dt > 0.25 then dt = 0.25 end
    end
    DOCK.last_clock = nowc

    local force_show = (ui_open == true) or (layout_mode == true)


    local function step(side)
        bs[side] = bs[side] or {}
        local s = bs[side]

        local thick  = gb_clamp(s.thickness or 36, 0, 256)
        local static = (s.static == true)
        local hot    = gb_clamp(s.hot_zone or 4, 0, 200)
        local speed  = 2000

        if ab[side] == false then
            DOCK.vis[side] = 0
            return thick, thick
        end

        local in_hot = gb_bar_is_hot(sw, sh, side, hot, mx, my)
        local cur_vis = gb_clamp(DOCK.vis[side] or 0, 0, thick)

        local in_bar = false
        if cur_vis > 0 then
            if side == 'top' then
                in_bar = (mx >= 0 and mx <= sw and my >= 0 and my <= cur_vis)
            elseif side == 'bottom' then
                in_bar = (mx >= 0 and mx <= sw and my >= (sh - cur_vis) and my <= sh)
            elseif side == 'left' then
                in_bar = (mx >= 0 and mx <= cur_vis and my >= 0 and my <= sh)
            elseif side == 'right' then
                in_bar = (mx >= (sw - cur_vis) and mx <= sw and my >= 0 and my <= sh)
            end
        end

        local target = 0
        if force_show or static then
            target = thick
        else
            target = (in_hot or in_bar) and thick or 0
        end



        if dt <= 0 or speed <= 0 then
            DOCK.vis[side] = target
        else
            local v = gb_clamp(DOCK.vis[side] or 0, 0, thick)
            local step_px = speed * dt
            if v < target then
                v = v + step_px
                if v > target then v = target end
            elseif v > target then
                v = v - step_px
                if v < target then v = target end
            end
            DOCK.vis[side] = gb_clamp(v, 0, thick)
        end

        return thick, gb_clamp(DOCK.vis[side] or 0, 0, thick)
    end

    local max_top, vis_top     = step('top')
    local max_bottom, vis_bot  = step('bottom')
    local max_left, vis_left   = step('left')
    local max_right, vis_right = step('right')

    -- Feed computed thickness into layout for the current frame.
    cfg.thickness_top    = (ab.top    == false) and 0 or (force_show or (bs.top and bs.top.static)) and max_top     or vis_top
    cfg.thickness_bottom = (ab.bottom == false) and 0 or (force_show or (bs.bottom and bs.bottom.static)) and max_bottom or vis_bot
    cfg.thickness_left   = (ab.left   == false) and 0 or (force_show or (bs.left and bs.left.static)) and max_left   or vis_left
    cfg.thickness_right  = (ab.right  == false) and 0 or (force_show or (bs.right and bs.right.static)) and max_right  or vis_right
end

-------------------------------------------------------------------------------
-- Bar background rendering (color + optional texture)
-------------------------------------------------------------------------------

local GB_TEX_BAR_CACHE = {}

local function gb_bar_tex_path(filename)
    if type(filename) ~= 'string' or filename == '' then return nil end
    return addon_dir .. 'assets' .. sep .. 'ui' .. sep .. filename
end

local function gb_get_bar_tex(filename)
    if type(filename) ~= 'string' or filename == '' then return nil end
    if GB_TEX_BAR_CACHE[filename] ~= nil then
        return GB_TEX_BAR_CACHE[filename]
    end

    local full = gb_bar_tex_path(filename)
    local tex = nil
    if full ~= nil and texcache ~= nil and type(texcache.GetTexture) == 'function' then
        local ok1, t = gb_pcall(texcache.GetTexture, texcache, full)
        if ok1 then tex = t end
    end

    GB_TEX_BAR_CACHE[filename] = tex
    return tex
end

-- Back-compat: your current file is calling this (and crashing).
-- Keep it as a global name so the call stops erroring.
local function gb_get_tex_preview(filename)
    return gb_get_bar_tex(filename)
end
_G.gb_get_tex_preview = gb_get_tex_preview

local function gb_draw_bar_bg(dl, bars)
    if dl == nil then return end
    if not gb_is_table(gb_settings) then return end

    local bs = gb_settings.bar_settings or {}
    local ab = gb_settings.active_bars or { top = true, bottom = true, left = true, right = true }

    local function draw_one(side, r)
        if r == nil or (r.w or 0) <= 0 or (r.h or 0) <= 0 then return end
        if ab[side] == false then return end

        local s = bs[side]
        if not gb_is_table(s) then return end

        local op = gb_clamp(tonumber(s.opacity) or 80, 0, 100)
        local a  = math.floor((op / 100) * 255 + 0.5)
        if a <= 0 then return end

        local x1, y1 = r.x, r.y
        local x2, y2 = r.x + r.w, r.y + r.h

        -- Texture first (if set)
        local tf = tostring(s.texture or '')
        if tf ~= '' then
            local tex = gb_get_bar_tex(tf)
            if tex ~= nil then
                dl:AddImage(tex, { x1, y1 }, { x2, y2 }, { 0, 0 }, { 1, 1 }, gb_pack_col(255, 255, 255, a))
                return
            end
        end

        -- Fallback solid fill
        local c = s.color
        if type(c) ~= 'table' then c = { 0, 0, 0 } end
        dl:AddRectFilled(
            { x1, y1 },
            { x2, y2 },
            gb_pack_col(c[1] or 0, c[2] or 0, c[3] or 0, a),
            0.0
        )
    end

    draw_one('top', bars.top)
    draw_one('bottom', bars.bottom)
    draw_one('left', bars.left)
    draw_one('right', bars.right)
end



local function gb_push_clip(dl, r)
    if dl == nil or r == nil then return false end
    dl:PushClipRect({ r.x, r.y }, { r.x + r.w, r.y + r.h }, true)
    return true
end

local function gb_pop_clip(dl)
    if dl ~= nil then dl:PopClipRect() end
end


-------------------------------------------------------------------------------
-- Player job
-------------------------------------------------------------------------------

local function gb_get_main_job_id()
    local job = 0
    gb_pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if mm ~= nil then
            local party = mm:GetParty()
            if party ~= nil and party.GetMemberMainJob ~= nil then
                job = party:GetMemberMainJob(0) or 0
            end
        end
    end)
    return tonumber(job) or 0
end

-------------------------------------------------------------------------------
-- Plugins: discovery + loading + enabled
-------------------------------------------------------------------------------

local plugins = {}
local plugin_list = {}

local function gb_sanitize_dir_name(s)
    if type(s) ~= 'string' then return nil end
    while #s > 0 do
        local c = s:sub(#s, #s)
        if c == '/' or c == '\\' then s = s:sub(1, #s - 1) else break end
    end
    local last = 0
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == '/' or c == '\\' then last = i end
    end
    if last > 0 then s = s:sub(last + 1) end
    if s == '' or s == '.' or s == '..' then return nil end
    return s
end

local function gb_get_character_config_dir()
    local base = ''

    gb_pcall(function()
        if AshitaCore ~= nil and AshitaCore.GetInstallPath ~= nil then
            base = AshitaCore:GetInstallPath() or ''
        end
    end)

    base = tostring(base or '')
    if base ~= '' and base:sub(-1) ~= sep then
        base = base .. sep
    end

    local name = 'unknown'
    local sid = 0

    gb_pcall(function()
        local mm = AshitaCore and AshitaCore:GetMemoryManager() or nil
        local party = mm and mm:GetParty() or nil
        if party ~= nil then
            if party.GetMemberName ~= nil then
                name = party:GetMemberName(0) or name
            end
            if party.GetMemberServerId ~= nil then
                sid = party:GetMemberServerId(0) or sid
            end
        end
    end)

    name = tostring(name or 'unknown')
    name = name:gsub('[^A-Za-z0-9_%-]', '')
    sid = tonumber(sid) or 0

    local dir = base .. 'config' .. sep .. 'addons' .. sep .. 'gobbiebars' .. sep .. name .. '_' .. tostring(sid) .. sep
    dir = dir:gsub("[/\\]+", "\\")
    return dir
end

local function gb_list_plugin_folders(path)

    local dirs = {}

    local function add_dir(name)
        name = gb_sanitize_dir_name(name)
        if name ~= nil then table.insert(dirs, name) end
    end

    -- Prefer Ashita listing if available
    local out = nil
    local candidates = {
        function()
            if ashita and ashita.fs and gb_is_func(ashita.fs.get_directory_list) then
                return ashita.fs.get_directory_list(path)
            end
        end,
        function()
            if ashita and ashita.file and gb_is_func(ashita.file.get_directory_list) then
                return ashita.file.get_directory_list(path)
            end
        end,
    }

    for i = 1, #candidates do
        local ok2, v = gb_pcall(candidates[i])
        if ok2 and gb_is_table(v) and next(v) ~= nil then
            out = v
            break
        end
    end

    if gb_is_table(out) then
        for _, v in pairs(out) do
            if type(v) == 'string' then
                add_dir(v)
            elseif gb_is_table(v) then
                add_dir(v.name or v.filename or v.file or v[1])
            end
        end
    end

    -- Windows fallback (only if Ashita returned nothing)
    if #dirs == 0 then
        local cmd = ('dir /b /ad "%s" 2>nul'):format(path:gsub('/', '\\'))
        local p = io.popen(cmd)
        if p ~= nil then
            for line in p:lines() do add_dir(line) end
            p:close()
        end
    end

    table.sort(dirs)
    return dirs
end

local function gb_load_plugin_folder(folder_name)
    folder_name = gb_sanitize_dir_name(folder_name)
    if folder_name == nil then return nil end

    local plugin_file = plugins_dir .. folder_name .. sep .. 'plugin.lua'
    local chunk = loadfile(plugin_file)
    if chunk == nil then return nil end

    local ok2, plugin = gb_pcall(chunk)
    if not ok2 then
        gb_log('Plugin "%s" skipped - error running plugin.lua: %s', tostring(folder_name), tostring(plugin))
        return nil
    end
    if not gb_is_table(plugin) then
        gb_log('Plugin "%s" skipped - plugin.lua did not return a table.', tostring(folder_name))
        return nil
    end
    if type(plugin.id) ~= 'string' or plugin.id == '' then
        gb_log('Plugin "%s" skipped - missing plugin.id.', tostring(folder_name))
        return nil
    end

    plugin.name = (type(plugin.name) == 'string') and plugin.name or plugin.id
    if not gb_is_table(plugin.default) then
        gb_log('Plugin "%s" skipped - missing plugin.default table.', tostring(folder_name))
        return nil
    end

    -- Normalize defaults
    plugin.default.bar = (type(plugin.default.bar) == 'string') and plugin.default.bar or 'top'
    plugin.default.x = tonumber(plugin.default.x) or 0
    plugin.default.y = tonumber(plugin.default.y) or 0
    plugin.default.w = tonumber(plugin.default.w) or 160
    plugin.default.h = tonumber(plugin.default.h) or 34

    -- Plugin-owned settings (preferred): let the plugin load its per-character settings file.
    if gb_is_func(plugin.load_settings) then
        local pst = plugin.load_settings(gb_get_character_config_dir())
        if gb_is_table(pst) then
            gb_settings.plugin_settings[plugin.id] = pst
        end
    else
        -- Host-owned settings (legacy fallback)
        local defs = plugin.settings_defaults or {}
        gb_settings.plugin_settings[plugin.id] = gb_merge_defaults(gb_settings.plugin_settings[plugin.id], defs)
    end

    -- Generic: first time this plugin id is seen, enable it automatically (no hardcoding).
    gb_settings.enabled_plugins = gb_settings.enabled_plugins or {}
    if gb_settings.enabled_plugins[plugin.id] == nil then
        gb_settings.enabled_plugins[plugin.id] = true
        settings_mod.save()
    end

    plugins[plugin.id] = plugin
    table.insert(plugin_list, plugin.id)
    return plugin
end



local function gb_load_all_plugins()
    plugins = {}
    plugin_list = {}

    local dirs = gb_list_plugin_folders(plugins_dir)
    for i = 1, #dirs do
        gb_load_plugin_folder(dirs[i])
    end
end

local function gb_plugin_enabled(id)
    return gb_settings.enabled_plugins[id] == true
end

local function gb_sync_buttons_internal_disabled()
    -- Buttons spawns its own 4 layout blocks; keep any internal bar plugins disabled.
    gb_settings.enabled_plugins['buttons_top_bar']    = false
    gb_settings.enabled_plugins['buttons_bottom_bar'] = false
    gb_settings.enabled_plugins['buttons_left_bar']   = false
    gb_settings.enabled_plugins['buttons_right_bar']  = false
end

local function gb_set_plugin_enabled(id, on)
    gb_settings.enabled_plugins[id] = (on == true)
    if id == 'buttons' then
        gb_sync_buttons_internal_disabled()
    end
    if settings_mod ~= nil and type(settings_mod.save) == 'function' then
        settings_mod.save()
    end
end


-------------------------------------------------------------------------------
-- Blocks: built from enabled plugins + per-job layout
-------------------------------------------------------------------------------

blocks = {}
local drag = { active = false, id = nil, offx = 0, offy = 0 }

local function gb_rebuild_blocks_from_plugins()
    blocks = {}

    for i = 1, #plugin_list do
        local pid = plugin_list[i]
        if not gb_plugin_enabled(pid) then
            goto continue
        end

        local p = plugins[pid]
        if not gb_is_table(p) or not gb_is_func(p.render) then
            goto continue
        end

        -- Allow plugins without p.default (fallback placement).
        local d = gb_is_table(p.default) and p.default or {
            bar = 'top_bar',
            x = 0,
            y = 0,
            w = 40,
            h = 40,
        }


if pid == 'buttons' then
    local d  = p.default
    local ps = gb_settings.plugin_settings['buttons'] or {}
    local w  = tonumber(ps.w) or d.w
    local h  = tonumber(ps.h) or d.h

    local bars = { 'top', 'bottom', 'left', 'right', 'screen' }
    for _, bar in ipairs(bars) do
        table.insert(blocks, {
            id  = 'buttons:' .. bar,
            pid = 'buttons',
            bar = bar,
            x   = tonumber(ps.x) or d.x,
            y   = tonumber(ps.y) or d.y,
            w   = w,
            h   = h,
        })
    end

        else
            local d = p.default
            local ps = gb_settings.plugin_settings[pid] or {}
            table.insert(blocks, {
                id  = pid,
                pid = pid,
                bar = (type(ps.bar) == 'string' and ps.bar ~= '') and ps.bar or d.bar,
                x   = tonumber(ps.x) or d.x,
                y   = tonumber(ps.y) or d.y,
                w   = d.w,
                h   = d.h,
            })

        end

        ::continue::
    end

 
end


local function gb_find_block_by_id(id)
    for i = 1, #blocks do
        if blocks[i].id == id then return blocks[i] end
    end
    return nil
end

local function gb_pick_layout_key(job_id)
    if not gb_is_table(gb_settings) or not gb_is_table(gb_settings.layouts) then
        return nil
    end

    local layouts = gb_settings.layouts
    local job_key = tostring(job_id)

    -- 1) Exact job match
    if gb_is_table(layouts[job_key]) and gb_is_table(layouts[job_key].blocks) then
        return job_key
    end

    -- 2) Last used key
    local last_key = nil
    if gb_is_table(gb_settings._ui) and type(gb_settings._ui.last_layout_key) == 'string' then
        last_key = gb_settings._ui.last_layout_key
    end
    if last_key ~= nil and gb_is_table(layouts[last_key]) and gb_is_table(layouts[last_key].blocks) then
        return last_key
    end

    -- 3) Shipped baseline (your existing layout key)
    if gb_is_table(layouts['5']) and gb_is_table(layouts['5'].blocks) then
        return '5'
    end

    -- 4) Any available layout
    for k, v in pairs(layouts) do
        if gb_is_table(v) and gb_is_table(v.blocks) then
            return tostring(k)
        end
    end

    return nil
end

local function gb_apply_layout_for_job(job_id)
    local layouts = gb_settings.layouts or {}

    -- 1) Prefer job layout
    local key = tostring(job_id)
    local lj = layouts[key]

    -- 2) Fallback: last_layout_key (stored in settings)
    if (not gb_is_table(lj) or not gb_is_table(lj.blocks)) and gb_is_table(gb_settings._ui) then
        local lk = gb_settings._ui.last_layout_key
        if lk ~= nil then
            lj = layouts[tostring(lk)]
        end
    end

    -- 3) Fallback: layout "5" (your common baseline)
    if not gb_is_table(lj) or not gb_is_table(lj.blocks) then
        lj = layouts["5"]
    end

    if not gb_is_table(lj) or not gb_is_table(lj.blocks) then
        return
    end

    -- Remember what we actually used (so next login is stable)
    gb_settings._ui = gb_settings._ui or {}
    gb_settings._ui.last_layout_key = tostring(lj == layouts[key] and key or (gb_settings._ui.last_layout_key or "5"))

    for i = 1, #blocks do
        local blk = blocks[i]
        local sb = lj.blocks[blk.id]

        -- For non-buttons plugins: plugin settings (per-character) win over layout.
        local ps = nil
        if gb_is_table(gb_settings.plugin_settings) then
            ps = gb_settings.plugin_settings[blk.pid]
        end

        if blk.pid ~= 'buttons' and gb_is_table(ps) then
            if type(ps.bar) == 'string' and ps.bar ~= '' then blk.bar = ps.bar end
            if ps.x ~= nil then blk.x = ps.x end
            if ps.y ~= nil then blk.y = ps.y end
        elseif gb_is_table(sb) then
            if blk.pid ~= 'buttons' and sb.bar ~= nil then blk.bar = sb.bar end
            if sb.x ~= nil then blk.x = sb.x end
            if sb.y ~= nil then blk.y = sb.y end
        end


        -- Clamp so blocks can't end up off-screen from bad saved X/Y.
        do
            local x = tonumber(blk.x or 0) or 0
            local y = tonumber(blk.y or 0) or 0

            if x < -300 then x = -300 end
            if x > 3000 then x = 3000 end
            if y < -300 then y = -300 end
            if y > 3000 then y = 3000 end

            blk.x = x
            blk.y = y
        end
    end
end


local function gb_save_layout_for_job(job_id)
    local key = tostring(job_id)
    gb_settings.layouts[key] = gb_settings.layouts[key] or {}
    gb_settings.layouts[key].blocks = gb_settings.layouts[key].blocks or {}

    local t = gb_settings.layouts[key].blocks
    for i = 1, #blocks do
        local blk = blocks[i]
        t[blk.id] = t[blk.id] or {}
        t[blk.id].bar = blk.bar
        t[blk.id].x   = blk.x
        t[blk.id].y   = blk.y
    end
    settings_mod.save()
end

local function gb_set_layout_mode(on)
    if on == layout_mode then return end
    layout_mode = on
    if layout_mode then
        enabled = true
        return
    end
    gb_save_layout_for_job(gb_get_main_job_id())
    drag.active = false
    drag.id = nil
end

local function gb_toggle_enabled()
    enabled = not enabled
    if not enabled then gb_set_layout_mode(false) end
end

-------------------------------------------------------------------------------
-- UI: theme + plugin manager window (General/Plugins)
-------------------------------------------------------------------------------

local gb_banner_tex  = nil
local gb_bg_1_tex    = nil
local gb_ui_bg_tex   = nil

-- Capture and restore the base ImGui colors so GobbieBars never bleeds into other addons.
local GB_BASE_STYLE = nil

local function gb_cache_base_style()
    if GB_BASE_STYLE ~= nil then return end

    local ok1, style = gb_pcall(function() return imgui.GetStyle() end)
    if not ok1 or style == nil or style.Colors == nil then
        return
    end

    GB_BASE_STYLE = { colors = {} }

    for idx, col in pairs(style.Colors) do
        if type(idx) == 'number' and type(col) == 'table' then
            GB_BASE_STYLE.colors[idx] = { col[1], col[2], col[3], col[4] }
        end
    end
end

local function gb_restore_base_style()
    if GB_BASE_STYLE == nil then return end

    local ok1, style = gb_pcall(function() return imgui.GetStyle() end)
    if not ok1 or style == nil or style.Colors == nil then
        return
    end

    for idx, src in pairs(GB_BASE_STYLE.colors) do
        local dst = style.Colors[idx]
        if type(dst) == 'table' then
            dst[1], dst[2], dst[3], dst[4] = src[1], src[2], src[3], src[4]
        end
    end
end


-- Bar texture cache (UI + bar rendering)
local gb_bar_tex_cache = {}

local function gb_get_bar_tex(file)
    if type(file) ~= 'string' or file == '' then return nil end
    if gb_bar_tex_cache[file] ~= nil then
        return gb_bar_tex_cache[file]
    end

    local tex_path = (addon_dir .. 'assets' .. sep .. 'ui' .. sep .. file):gsub("[/\\]+", "\\")
    local tex = nil
    if texcache ~= nil and type(texcache.GetTexture) == 'function' then
        tex = texcache:GetTexture(tex_path)
    end

    gb_bar_tex_cache[file] = tex
    return tex
end


local GB_TEX_PREVIEW_SIZE = 32
local gb_tex_preview_cache = {}

-- Bar textures used by the General tab texture dropdown.
local GB_BAR_TEXTURES = {
    { key = 'none', name = 'None', file = '' },
}

-- Add one texture entry (avoids duplicates, normalizes path, derives label).
local function gb_add_bar_texture(relfile)
    if type(relfile) ~= 'string' or relfile == '' then
        return
    end

    -- Normalize separators to the current platform.
    relfile = relfile:gsub('[\\/]+', sep)

    -- No duplicates.
    for i = 1, #GB_BAR_TEXTURES do
        if GB_BAR_TEXTURES[i].file == relfile then
            return
        end
    end

    -- Label from filename without extension.
    local fname = relfile
    local tail = fname:match('^.*[\\/](.+)$')
    if tail then
        fname = tail
    end
    local base = fname:gsub('%.[^.]+$', '')

    table.insert(GB_BAR_TEXTURES, {
        key  = base,
        name = base,
        file = relfile,
    })
end

-- Scan assets\ui\textures and assets\ui for texture files.
local function gb_scan_bar_textures()
    local roots = {
        { rel = 'textures' },
    }


    for i = 1, #roots do
        local rel = roots[i].rel or ''
        local base = addon_dir .. 'assets' .. sep .. 'ui' .. sep .. rel
        base = base:gsub("[/\\]+", "\\")

        local cmd = ('dir /b /a-d "%s" 2>nul'):format(base)
        local p = io.popen(cmd)
        if p ~= nil then
            for line in p:lines() do
                local name = tostring(line or '')
                local ext = name:match('%.([A-Za-z0-9]+)$')
                if ext ~= nil then
                    ext = ext:lower()
                    if ext == 'png' or ext == 'dds' or ext == 'jpg' or ext == 'jpeg' then
                        local relfile
                        if rel ~= '' then
                            relfile = rel .. sep .. name
                        else
                            relfile = name
                        end
                        gb_add_bar_texture(relfile)
                    end
                end
            end
            p:close()
        end
    end
end

-- Build the list once at load.
gb_scan_bar_textures()

local function gb_get_tex_preview(file)

    file = tostring(file or '')
    if file == '' then return nil end

    if gb_tex_preview_cache[file] ~= nil then
        local v = gb_tex_preview_cache[file]
        return (v == false) and nil or v
    end

    local path = addon_dir .. 'assets' .. sep .. 'ui' .. sep .. file
    local tex = texcache:GetTexture(path)
    gb_tex_preview_cache[file] = tex or false
    return tex
end


local function gb_push_ui_theme()
    local r, g, b = 199 / 255, 132 / 255, 79 / 255
    local rh, gh, bh = math.min(1, r * 1.10), math.min(1, g * 1.10), math.min(1, b * 1.10)
    local ra, ga, ba = math.min(1, r * 0.95), math.min(1, g * 0.95), math.min(1, b * 0.95)

    local function c(rr, gg, bb, aa) return { rr, gg, bb, aa } end

    local theme = {
        { ImGuiCol_TitleBg,            c(r,  g,  b,  0.80) },
        { ImGuiCol_TitleBgActive,      c(r,  g,  b,  0.95) },
        { ImGuiCol_TitleBgCollapsed,   c(r,  g,  b,  0.60) },

        { ImGuiCol_CheckMark,          c(r,  g,  b,  1.00) },
        { ImGuiCol_SliderGrab,         c(r,  g,  b,  1.00) },
        { ImGuiCol_SliderGrabActive,   c(rh, gh, bh, 1.00) },

        { ImGuiCol_ScrollbarBg,          c(ra, ga, ba, 0.40) },
        { ImGuiCol_ScrollbarGrab,        c(r,  g,  b,  0.75) },
        { ImGuiCol_ScrollbarGrabHovered, c(rh, gh, bh, 0.85) },
        { ImGuiCol_ScrollbarGrabActive,  c(ra, ga, ba, 1.00) },

        { ImGuiCol_Button,             c(r,  g,  b,  0.55) },
        { ImGuiCol_ButtonHovered,      c(rh, gh, bh, 0.75) },
        { ImGuiCol_ButtonActive,       c(ra, ga, ba, 0.90) },

        { ImGuiCol_Header,             c(r,  g,  b,  0.45) },
        { ImGuiCol_HeaderHovered,      c(rh, gh, bh, 0.70) },
        { ImGuiCol_HeaderActive,       c(ra, ga, ba, 0.85) },

        { ImGuiCol_Tab,                c(r,  g,  b,  0.40) },
        { ImGuiCol_TabHovered,         c(rh, gh, bh, 0.75) },
        { ImGuiCol_TabActive,          c(ra, ga, ba, 0.85) },
        { ImGuiCol_TabUnfocused,       c(r,  g,  b,  0.25) },
        { ImGuiCol_TabUnfocusedActive, c(r,  g,  b,  0.55) },

        { ImGuiCol_ResizeGrip,         c(r,  g,  b,  0.35) },
        { ImGuiCol_ResizeGripHovered,  c(rh, gh, bh, 0.70) },
        { ImGuiCol_ResizeGripActive,   c(ra, ga, ba, 0.90) },
    }

    for i = 1, #theme do
        imgui.PushStyleColor(theme[i][1], theme[i][2])
    end
    return #theme
end

local function gb_draw_plugin_manager_ui()
    if not ui_open then return end

    -- Position once when the window appears (prevents negative saved Y, keeps dragging working).
    do
        local io = imgui.GetIO()
        local dsx, dsy = io.DisplaySize.x, io.DisplaySize.y
        local ww, wh = 420, 360

        gb_settings._ui = gb_settings._ui or {}

        local sx = tonumber(gb_settings._ui.plugins_x or 0) or 0
        local sy = tonumber(gb_settings._ui.plugins_y or 0) or 0

        local px
        local py

        if sx ~= 0 or sy ~= 0 then
            px = sx
            py = sy
        else
            px = math.max(0, math.floor((dsx - ww) * 0.5))
            py = math.max(0, math.floor((dsy - wh) * 0.5))
        end

        imgui.SetNextWindowPos({ px, py }, ImGuiCond_Appearing)
    end


    imgui.SetNextWindowSize({ 420, 360 }, ImGuiCond_FirstUseEver)
    local open = { true }


    if UI_FONT ~= nil then imgui.PushFont(UI_FONT) end
    local theme_n = gb_push_ui_theme()
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0, 0, 0, 1.0 })


    if not imgui.Begin('GobbieBars - Plugins', open, bit.bor(ImGuiWindowFlags_NoCollapse, ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse)) then

        imgui.End()
        imgui.PopStyleVar(1)
        imgui.PopStyleColor(1)
        if theme_n > 0 then imgui.PopStyleColor(theme_n) end
        if UI_FONT ~= nil then imgui.PopFont() end
        ui_open = open[1]
        return
    end


    -- Clamp: prevent the settings window from being cut off (top/left).
    -- Also enforce a small margin so the top border never touches the screen edge.
    do
        local MIN_X = 12
        local MIN_Y = 12

        local wx, wy = imgui.GetWindowPos()
        local nx = (wx < MIN_X) and MIN_X or wx
        local ny = (wy < MIN_Y) and MIN_Y or wy

        if nx ~= wx or ny ~= wy then
            imgui.SetWindowPos({ nx, ny })
            wx, wy = nx, ny
        end

        gb_settings._ui = gb_settings._ui or {}
        local sx = tonumber(gb_settings._ui.plugins_x or 0) or 0
        local sy = tonumber(gb_settings._ui.plugins_y or 0) or 0

        if (sx ~= wx or sy ~= wy) and (not gb_IsMouseDown(0)) then
            gb_settings._ui.plugins_x = wx
            gb_settings._ui.plugins_y = wy
            if settings_mod ~= nil and type(settings_mod.save) == 'function' then
                settings_mod.save()
            end
        end
    end


    ui_open = open[1]


    -- REAL background: first content item
    do
        if gb_ui_bg_tex == nil then
            local bg_path = (addon_dir .. 'assets' .. sep .. 'ui' .. sep .. 'bg_1.png'):gsub("[/\\]+", "\\")
            gb_ui_bg_tex = texcache:GetTexture(bg_path)
        end

        if gb_ui_bg_tex ~= nil then
            local win_x, win_y = imgui.GetWindowPos()
            local cr_min_x, cr_min_y = imgui.GetWindowContentRegionMin()
            local cr_max_x, cr_max_y = imgui.GetWindowContentRegionMax()
            local bg_w = cr_max_x - cr_min_x
            local bg_h = cr_max_y - cr_min_y

            -- Canonical Plugin Manager background rect (screen space)
            gb_pm_bg_min_x = win_x + cr_min_x
            gb_pm_bg_min_y = win_y + cr_min_y
            gb_pm_bg_max_x = win_x + cr_max_x
            gb_pm_bg_max_y = win_y + cr_max_y



            local w = cr_max_x - cr_min_x
            local h = cr_max_y - cr_min_y

            local cx, cy = imgui.GetCursorPos()

            imgui.SetCursorPos({ cr_min_x, cr_min_y })
            imgui.Image(gb_ui_bg_tex, { w, h })
            imgui.SetCursorPos({ cx, cy })
        end
    end






    local pm_w = gb_pm_bg_max_x - gb_pm_bg_min_x
    local pm_h = gb_pm_bg_max_y - gb_pm_bg_min_y
    imgui.SetCursorScreenPos({ gb_pm_bg_min_x, gb_pm_bg_min_y })
    imgui.BeginChild('##gb_pm_canvas', { pm_w, pm_h }, false,
        bit.bor(ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse))




    -- (no inset)





    if gb_pm_base_h == nil then
        gb_pm_base_h = pm_h
        gb_pm_base_w = pm_w
    end
    local top_gap = pm_h * (405 / 997)
    local bottom_gap = pm_h * (32 / 997)

    -- Fixed header space (no scrolling)
    imgui.Dummy({ 1, top_gap })

    -- Scrollable body (only this area scrolls)
    imgui.BeginChild('##gb_pm_body', { pm_w, pm_h - top_gap - bottom_gap }, false,
        bit.bor(ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoScrollbar, ImGuiWindowFlags_NoScrollWithMouse))



    imgui.PushStyleVar(ImGuiStyleVar_CellPadding, { 6, 0 })
    if imgui.BeginTable('##gb_pm_table', 2, ImGuiTableFlags_SizingStretchProp, { 0, 0 }) then

        imgui.TableSetupColumn('left', ImGuiTableColumnFlags_WidthFixed, pm_w * (385 / 1520))

        imgui.TableSetupColumn('right', ImGuiTableColumnFlags_WidthStretch)


        imgui.TableNextRow()

        -- LEFT HEADER + SCROLL AREA
        imgui.TableSetColumnIndex(0)

        -- Header (fixed, not scrolling)
        imgui.SetCursorPos({ 40 * (pm_w / 1520), 20 * (pm_h / 997) })
        imgui.Text(string.format('Gobbiebars %s', tostring(addon.version or '?')))

        -- Help icon next to header
        imgui.SameLine()
        imgui.SetCursorPosX(imgui.GetCursorPosX() + 4)

        local help_tex = texcache:GetTexture(
            (addon_dir .. 'assets' .. sep .. 'ui' .. sep .. 'help.png'):gsub("[/\\]+", "\\")
        )

        local icon_size = imgui.GetTextLineHeight()

        if help_tex ~= nil then
            -- draw image
            local icon_pos_x, icon_pos_y = imgui.GetCursorPos()
            imgui.Image(help_tex, { icon_size, icon_size })

            -- clickable area over the image (same position as image)
            imgui.SetCursorPos({ icon_pos_x, icon_pos_y })
            if imgui.InvisibleButton('##gb_help_toggle', { icon_size, icon_size }) then
                ui_help_open = true
            end
        else
            -- fallback: text button if texture is missing
            if imgui.SmallButton('?#gb_help_toggle') then
                ui_help_open = true
            end
        end

        if imgui.IsItemHovered() then
            imgui.BeginTooltip()
            imgui.Text('Click for help')
            imgui.EndTooltip()
        end

        -- LEFT SCROLL AREA (list)
        imgui.SetCursorPos({ 0, 45 * (pm_h / 997) })

        local left_footer_h = 56 * (pm_h / 997)
        local avail_x, avail_y = imgui.GetContentRegionAvail()
        local left_scroll_h = avail_y - left_footer_h
        if left_scroll_h < 1 then left_scroll_h = 1 end

        imgui.BeginChild('##gb_left_scroll', { 0, left_scroll_h }, false, ImGuiWindowFlags_NoBackground)

            -- inset inside the left panel (scaled to art size)
            imgui.SetCursorPos({ 40 * (pm_w / 1520), 14 * (pm_h / 997) })

            if imgui.BeginTable('##gb_plugins_left_tbl', 1, ImGuiTableFlags_SizingStretchProp) then

                imgui.TableSetupColumn('Plugin', ImGuiTableColumnFlags_WidthStretch)

                -- Fixed nav: General
                imgui.TableNextRow()
                imgui.TableSetColumnIndex(0)
                if imgui.Selectable(
    'General##gb_nav_general',
    tab_main == true,
    0,
    { pm_w * (310 / 1520), 0 }
) then
    tab_main = true
    tab_plugins = false
    ui_plugin_open_id = nil
    ui_help_open = false
end


                imgui.TableSetupColumn('Plugin', ImGuiTableColumnFlags_WidthStretch)

                for i = 1, #plugin_list do
                    local pid = plugin_list[i]
                    local p = plugins[pid]
                    if p == nil or p.hidden == true then
                        goto continue_left
                    end

                    imgui.TableNextRow()
                    imgui.TableSetColumnIndex(0)

if imgui.Selectable(
    string.format('%s##gb_pl_left_sel_%s', p.name, pid),
    ui_plugin_open_id == pid,
    0,
    { pm_w * (310 / 1520), 0 }
) then
    ui_plugin_open_id = pid
    tab_main = false
    ui_help_open = false
end




                    ::continue_left::
                end

                imgui.EndTable()
            end

        imgui.EndChild()

        -- LEFT FOOTER (fixed, not scrolling)
        imgui.BeginChild('##gb_left_footer', { 0, left_footer_h }, false, ImGuiWindowFlags_NoBackground)

            local btn_w = 240 * (pm_w / 1520)
            local btn_h = 44 * (pm_h / 997)

            local ax, ay = imgui.GetContentRegionAvail()
            imgui.SetCursorPos({ (ax - btn_w) * 0.5, (ay - btn_h) * 0.5 })

local close_tex = texcache:GetTexture(
    (addon_dir .. 'assets' .. sep .. 'ui' .. sep .. 'close_button.png'):gsub("[/\\]+", "\\")
)

if close_tex ~= nil then
    -- draw image
    imgui.Image(close_tex, { btn_w, btn_h })

    -- clickable area over the image
    imgui.SetCursorPos({ imgui.GetCursorPosX(), imgui.GetCursorPosY() - btn_h })
    if imgui.InvisibleButton('##gb_left_close', { btn_w, btn_h }) then
        open[1] = false
        ui_open = false
    end
else
    -- fallback
    if imgui.Button('Close##gb_left_close', { btn_w, btn_h }) then
        open[1] = false
        ui_open = false
    end
end


        imgui.EndChild()



                -- RIGHT SCROLL AREA
        imgui.TableSetColumnIndex(1)
        imgui.BeginChild('##gb_right_scroll', { -10, 0 }, false, ImGuiWindowFlags_NoBackground)

            -- inset inside the right panel (scaled to art size)
            imgui.SetCursorPos({ 40 * (pm_w / 1520), 14 * (pm_h / 997) })

        -- If Help is open, show that instead of General or plugin settings.
        if ui_help_open then

            gb_help.draw_help(imgui)

        else

        -- If no plugin selected, show General Settings.

        -- If a plugin is selected, show that plugin's settings UI.
        if ui_plugin_open_id == nil then


            -- Game Mode (Buttons plugin)
            gb_settings.plugin_settings = gb_settings.plugin_settings or {}
            gb_settings.plugin_settings.buttons = gb_settings.plugin_settings.buttons or {}
            local bps = gb_settings.plugin_settings.buttons
            if bps.game_mode == nil then bps.game_mode = 'CW' end

            imgui.AlignTextToFramePadding()
            imgui.Text('Game Mode:')
            imgui.SameLine()
            if imgui.RadioButton('CW##gb_mode_cw', bps.game_mode == 'CW') then
                bps.game_mode = 'CW'
                settings_mod.save()
            end
            imgui.SameLine()
            if imgui.RadioButton('ACE##gb_mode_ace', bps.game_mode == 'ACE') then
                bps.game_mode = 'ACE'
                settings_mod.save()
            end
            imgui.SameLine()
            if imgui.RadioButton('WEW##gb_mode_wew', bps.game_mode == 'WEW') then
                bps.game_mode = 'WEW'
                settings_mod.save()
            end

            imgui.Separator()

            -- Quick settings access
            gb_settings.quick_settings_mode = gb_settings.quick_settings_mode or 'right'
            imgui.AlignTextToFramePadding()
            imgui.Text('Quick settings access:')
            imgui.SameLine()
            imgui.SetNextItemWidth(200)

            local modes = {
                { id = 'right',      label = 'Right click' },
                { id = 'ctrl_right', label = 'Ctrl + right click' },
                { id = 'off',        label = 'Disabled' },
            }

            local current_label = 'Right click'
            for i = 1, #modes do
                if modes[i].id == gb_settings.quick_settings_mode then
                    current_label = modes[i].label
                    break
                end
            end

            if imgui.BeginCombo('##gb_quick_settings_mode', current_label) then
                for i = 1, #modes do
                    local selected = (gb_settings.quick_settings_mode == modes[i].id)
                    if imgui.Selectable(modes[i].label, selected) then
                        gb_settings.quick_settings_mode = modes[i].id
                        settings_mod.save()
                    end
                end
                imgui.EndCombo()
            end

            imgui.Separator()

            -- Active Bars
            imgui.Text('Active Bars:')

            local ab = gb_settings.active_bars
            local v_top = { ab.top == true }
            if imgui.Checkbox('Top##gb_active_top', v_top) then ab.top = v_top[1]; settings_mod.save() end
            imgui.SameLine()
            local v_bottom = { ab.bottom == true }
            if imgui.Checkbox('Bottom##gb_active_bottom', v_bottom) then ab.bottom = v_bottom[1]; settings_mod.save() end
            imgui.SameLine()
            local v_left = { ab.left == true }
            if imgui.Checkbox('Left##gb_active_left', v_left) then ab.left = v_left[1]; settings_mod.save() end
            imgui.SameLine()
            local v_right = { ab.right == true }
            if imgui.Checkbox('Right##gb_active_right', v_right) then ab.right = v_right[1]; settings_mod.save() end

            imgui.Separator()

            -- Bar Settings editor
            local gb_label_w = 145
            local gb_value_w = 260

            local function gb_row(label)
                imgui.AlignTextToFramePadding()
                imgui.Text(label)
                imgui.SameLine(gb_label_w)
                imgui.SetNextItemWidth(gb_value_w)
            end

            gb_row('Bar Settings')
            if imgui.BeginCombo('##gb_bar_side', gb_settings._ui.bar_side) then
                local opts = { 'top', 'bottom', 'left', 'right' }
                for i = 1, #opts do
                    local s = opts[i]
                    if imgui.Selectable(s, s == gb_settings._ui.bar_side) then
                        gb_settings._ui.bar_side = s
                        settings_mod.save()
                    end
                end
                imgui.EndCombo()
            end

            local side = gb_settings._ui.bar_side
            local bs = gb_settings.bar_settings[side]
            if bs == nil then
                bs = {}
                gb_settings.bar_settings[side] = bs
                settings_mod.save()
            end

            gb_row('Static')
            local v_static = { bs.static == true }
            if imgui.Checkbox('##gb_static', v_static) then
                bs.static = v_static[1]
                settings_mod.save()
            end

            gb_row('Hot Zone')
            local v_hz = { tonumber(bs.hot_zone or 70) or 70 }
            if imgui.SliderInt('##gb_hotzone', v_hz, 0, 200) then
                bs.hot_zone = v_hz[1]
                settings_mod.save()
            end

            gb_row('Bar Thickness')
            local v_th = { tonumber(bs.thickness or 44) or 44 }
            if imgui.SliderInt('##gb_thickness', v_th, 8, 128) then
                bs.thickness = v_th[1]
                settings_mod.save()
            end

            -- Bar Color
            do
                local c = bs.color or { 0, 0, 0, 1 }
                gb_row('Bar Color')
                local v_col = { c[1], c[2], c[3], c[4] or 1 }
                if imgui.ColorEdit4('##gb_barcolor', v_col, ImGuiColorEditFlags_NoInputs) then
                    bs.color = { v_col[1], v_col[2], v_col[3], v_col[4] }
                    settings_mod.save()
                end
            end

            local v_op = { tonumber(bs.opacity or 80) or 80 }
            gb_row('Opacity')
            if imgui.SliderInt('##gb_opacity', v_op, 0, 100) then
                bs.opacity = v_op[1]
                settings_mod.save()
            end

            -- Texture (4 bars only; no screen)
            do
                local cur_tex = tostring(bs.texture or '')
                local cur_name = 'None'
                for i = 1, #GB_BAR_TEXTURES do
                    if GB_BAR_TEXTURES[i].file == cur_tex then
                        cur_name = GB_BAR_TEXTURES[i].name
                        break
                    end
                end

                gb_row('Texture')
                if imgui.BeginCombo('##gb_bar_texture', cur_name) then
                    local preview_sz = 24

                    for i = 1, #GB_BAR_TEXTURES do
                        local t = GB_BAR_TEXTURES[i]
                        local selected = (t.file == cur_tex)

                        if t.file ~= '' then
                            local tex = gb_get_tex_preview(t.file)
                            if tex ~= nil then
                                imgui.Image(tex, { preview_sz, preview_sz })
                            else
                                imgui.Dummy({ preview_sz, preview_sz })
                            end
                        else
                            imgui.Dummy({ preview_sz, preview_sz })
                        end

                        imgui.SameLine()

                        if imgui.Selectable(t.name .. '##gb_tex_' .. t.key, selected) then
                            bs.texture = t.file
                            settings_mod.save()
                        end
                    end

                    imgui.EndCombo()
                end
            end

            imgui.Separator()
            if imgui.Button('Save##gb_main_save') then
                settings_mod.save()
            end

        else
            local pid = ui_plugin_open_id
            local p = plugins[pid]

            -- Always edit the real stored table (never a throwaway {})
            gb_settings.plugin_settings = gb_settings.plugin_settings or {}
            gb_settings.plugin_settings[pid] = gb_settings.plugin_settings[pid] or {}
            local ps = gb_settings.plugin_settings[pid]

            local v_enabled = { gb_plugin_enabled(pid) }

            if imgui.Checkbox('Active##gb_pl_enabled', v_enabled) then
                gb_set_plugin_enabled(pid, v_enabled[1])
                gb_rebuild_blocks_from_plugins()
                gb_apply_layout_for_job(gb_get_main_job_id())
                gb_save_layout_for_job(gb_get_main_job_id())
                settings_mod.save()
            end

            imgui.Separator()

            -- One-time hint for Buttons plugin: explain collapsible headers
            if pid == 'buttons' then
                ps.show_button_settings_hint = (ps.show_button_settings_hint ~= false)
                if ps.show_button_settings_hint then
                    imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 1.0, 0.8, 1.0 })
                    imgui.PushTextWrapPos(0)
                    imgui.TextWrapped('Tip: click the brown "Button settings" bar below to expand or collapse its options.')
                    imgui.PopTextWrapPos()
                    imgui.PopStyleColor(1)

                    if imgui.SmallButton('Hide tip##gb_btn_settings_hint_hide') then
                        ps.show_button_settings_hint = false
                        settings_mod.save()
                    end
                    imgui.Spacing()
                end
            end


            if p ~= nil and gb_is_func(p.draw_settings_ui) then

                local bar0 = tostring(ps.bar or '')
                local x0 = tonumber(ps.x or 0) or 0
                local y0 = tonumber(ps.y or 0) or 0

                p.draw_settings_ui(ps)

                local bar1 = tostring(ps.bar or '')
                local x1 = tonumber(ps.x or 0) or 0
                local y1 = tonumber(ps.y or 0) or 0

                local placement_changed = (bar1 ~= bar0) or (x1 ~= x0) or (y1 ~= y0)

                if placement_changed then
                    gb_rebuild_blocks_from_plugins()
                    gb_save_layout_for_job(gb_get_main_job_id())
                    gb_apply_layout_for_job(gb_get_main_job_id())
                end

                -- Save plugin settings (per-plugin file) if plugin exposes a saver.
                if gb_is_table(p.settings_mod) and gb_is_func(p.settings_mod.save) then
                    p.settings_mod.save()
                elseif gb_is_func(p.save_settings) then
                    p.save_settings(ps)
                else
                    -- fallback: only saves global gobbiebars settings
                    settings_mod.save()
                end
            else
                imgui.Text('This plugin has no settings UI.')
            end

        end

        end  -- ui_help_open



        imgui.EndChild() -- ##gb_right_scroll
        imgui.EndTable()
        imgui.PopStyleVar(1)
    end


    imgui.EndChild() -- ##gb_pm_body
    imgui.EndChild() -- ##gb_pm_canvas

    imgui.End()
    imgui.PopStyleVar(1)
    imgui.PopStyleColor(1)
    if theme_n > 0 then imgui.PopStyleColor(theme_n) end
    if UI_FONT ~= nil then imgui.PopFont() end
    ui_open = open[1]
    return
end




-------------------------------------------------------------------------------
-- Prestige capture (kept as-is conceptually, cleaned slightly)
-------------------------------------------------------------------------------

_G.gb_prestige = _G.gb_prestige or {}
local gb_prestige = _G.gb_prestige

local GB_PRESTIGE_VALS = {
    ['Warrior']      = { 1, 2, 4, 6, 8 },
    ['Monk']         = { 3, 5, 8, 10, 12 },
    ['White Mage']   = { 1, 2, 4, 6, 8 },
    ['Black Mage']   = { 1, 2, 4, 6, 8 },
    ['Red Mage']     = { 1, 2, 3, 4, 5 },
    ['Thief']        = { 0, 1, 2, 3, 4 },
    ['Paladin']      = { -1, -2, -3, -4, -5 },
    ['Dark Knight']  = { 5, 10, 15, 20, 25 },
    ['Beastmaster']  = { 3, 5, 8, 10, 12 },
    ['Bard']         = { 3, 5, 8, 10, 12 },
    ['Ranger']       = { 5, 10, 15, 20, 25 },
    ['Samurai']      = { 1, 2, 3, 4, 5 },
    ['Ninja']        = { 5, 8, 10, 12, 15 },
    ['Dragoon']      = { 5, 8, 10, 12, 15 },
    ['Summoner']     = { 3, 5, 8, 10, 12 },
    ['Blue Mage']    = { 5, 8, 10, 12, 15 },
    ['Puppetmaster'] = { 1, 2, 4, 6, 8 },
    ['Dancer']       = { 1, 2, 4, 6, 8 },
    ['Scholar']      = { 1, 2, 4, 6, 8 },
    ['Geomancer']    = { 3, 5, 8, 10, 12 },
    ['Rune Fencer']  = { -1, -2, -3, -4, -5 },
}

local function gb_prestige_extract_number(paren_text)
    if type(paren_text) ~= 'string' or paren_text == '' then return nil end
    local n = paren_text:match('[-+]?%d+')
    if n == nil then return nil end
    return tonumber(n)
end

local function gb_prestige_tier_for(job, paren_text)
    if type(job) ~= 'string' or job == '' then return 0 end

    if job == 'Corsair' then
        local mode = 'ACE'
        if gb_is_table(gb_settings)
           and gb_is_table(gb_settings.plugin_settings)
           and gb_is_table(gb_settings.plugin_settings.playerjob)
           and type(gb_settings.plugin_settings.playerjob.corsair_mode) == 'string' then
            mode = gb_settings.plugin_settings.playerjob.corsair_mode:upper()
        end

        local vals = (mode == 'CW') and { 10, 20, 30, 40, 50 } or { 5, 10, 15, 20, 25 }
        local n = gb_prestige_extract_number(paren_text)
        if n == nil then return 0 end
        for i = 1, 5 do
            if vals[i] == n then return i end
        end
        return 0
    end

    local vals = GB_PRESTIGE_VALS[job]
    if type(vals) ~= 'table' then return 0 end

    local n = gb_prestige_extract_number(paren_text)
    if n == nil then return 0 end

    for i = 1, 5 do
        if vals[i] == n then return i end
    end
    return 0
end

ashita.events.register('text_in', 'gb_prestige_text_in', function(e)
    local msg = e.message
    if type(msg) ~= 'string' or msg == '' then return end

    msg = msg:gsub('[\0-\31]', '')
    msg = msg:gsub('^(%s*%[%d%d:%d%d:%d%d%]%s*)+', '')
    msg = msg:gsub('^%s+', ''):gsub('%s+$', '')

    if msg:find('=== Prestige Bonuses ===', 1, true) then
        for k in pairs(gb_prestige) do gb_prestige[k] = nil end
        _G.gb_prestige = gb_prestige
        return
    end

    local job, paren = msg:match('^([A-Za-z][A-Za-z%s]+)%s*:%s*.-%((.-)%)%s*$')
    if job and paren then
        job = job:gsub('^%s+', ''):gsub('%s+$', '')
        paren = paren:gsub('^%s+', ''):gsub('%s+$', '')
        gb_prestige[job] = gb_prestige_tier_for(job, paren)
    end
end)

-------------------------------------------------------------------------------
-- Load event
-------------------------------------------------------------------------------

ashita.events.register('load', 'gb_load', function()
    -- Defaults (golden first-run baseline)
    GB_DEFAULTS = T{
        game_mode = 'CW',
        quick_settings_mode = 'right',

        _ui = {

            bar_side = 'top',
        },

        active_bars = {
            top    = true,
            bottom = true,
            left   = true,
            right  = true,
        },

        enabled_plugins = {
        },


        plugin_settings = {},

        layouts = {
            ["5"] = {
                blocks = {
                    ["buttons:top"]    = { x = 0,    y = 0, bar = 'top' },
                    ["buttons:left"]   = { x = 0,    y = 0, bar = 'left' },
                    ["buttons:right"]  = { x = 0,    y = 0, bar = 'right' },
                    ["buttons:bottom"] = { x = 0,    y = 0, bar = 'bottom' },
                    ["playerjob"]      = { x = 1203, y = 2, bar = 'top' },
                    ["weather"]        = { x = 558,  y = 0, bar = 'top' },
                    ["emote"]          = { x = 1571, y = 2, bar = 'top' },
                },
            },
        },

        bar_settings = {
            right  = { thickness = 36, hot_zone = 41, opacity = 80,  static = false, color = { 0, 0, 0 } },
            bottom = { thickness = 36, hot_zone = 41, opacity = 80,  static = false, color = { 0, 0, 0 } },
            left   = { thickness = 36, hot_zone = 41, opacity = 80,  static = false, color = { 0, 0, 0 } },
            top    = { thickness = 36, hot_zone = 41, opacity = 80,  static = false, color = { 0, 0, 0 } },
        },
    }

    gb_settings = settings_mod.load(GB_DEFAULTS)
    if not gb_is_table(gb_settings) then gb_settings = GB_DEFAULTS end
    gb_ensure_settings()

    -- Migrate legacy root game_mode into Buttons plugin setting (one-time)
    do
        local ps = gb_settings.plugin_settings or {}
        ps.buttons = ps.buttons or {}
        if ps.buttons.game_mode == nil then
            local legacy = gb_settings.game_mode
            if type(legacy) == 'string' and legacy ~= '' then
                ps.buttons.game_mode = legacy
            else
                ps.buttons.game_mode = 'CW'
            end
            settings_mod.save()
        end
    end


    -- dropdown_open is runtime-only; never honor persisted true on boot
    do
        local ps = gb_settings.plugin_settings or {}
        if type(ps.playerjob) == 'table' then ps.playerjob.dropdown_open = false end
        if type(ps.emote) == 'table' then ps.emote.dropdown_open = false end
    end

    -- Load fonts once (addon-relative)
    local font_path = (addon_dir .. 'data' .. sep .. 'Azuza-Medium.otf'):gsub("[/\\]+", "\\")
    UI_FONT = gb_load_font_once(font_path, UI_FONT_SIZE)

    -- Plugin fonts: preload fixed sizes ONCE (NEVER load/build during render)
local plugin_font_path = (addon_dir .. 'assets' .. sep .. 'fonts' .. sep .. 'JetBrainsMono-Medium.ttf'):gsub("[/\\]+", "\\")
PLUGIN_FONT_CACHE = {}



    -- fixed sizes we support (add more later if needed)
    PLUGIN_FONT_SIZES = { 10, 12, 14, 16, 18, 20 }

-- plugin font families (generic, no plugin ids)
FONT_FAMILIES = {
    default = PLUGIN_FONT_CACHE,
}

-- Load all plugin font families from assets/fonts
do
    local font_dir = (addon_dir .. 'assets' .. sep .. 'fonts' .. sep):gsub("[/\\]+", "\\")

    if ashita.fs and ashita.fs.get_dir then
        local files = T(ashita.fs.get_dir(font_dir, '.*', false))
        files:each(function(name)
            if type(name) ~= 'string' then return end

            local ext = name:lower():match('%.([a-z0-9]+)$')
            if ext ~= 'ttf' and ext ~= 'otf' then return end

            local family = name:gsub('%.[^.]+$', '')
            if FONT_FAMILIES[family] ~= nil then return end

            local cache = {}
            local full = (font_dir .. name):gsub("[/\\]+", "\\")

            for _, s in ipairs(PLUGIN_FONT_SIZES) do
                cache[s] = gb_load_font_once(full, s)
            end

            if next(cache) ~= nil then
                FONT_FAMILIES[family] = cache
            end
        end)
    end
end







    for _, s in ipairs(PLUGIN_FONT_SIZES) do
        PLUGIN_FONT_CACHE[s] = gb_load_font_once(plugin_font_path, s)
    end

    -- default plugin font
PLUGIN_FONT_DEFAULT_SIZE = UI_FONT_SIZE
PLUGIN_FONT = PLUGIN_FONT_CACHE[PLUGIN_FONT_DEFAULT_SIZE] or PLUGIN_FONT_CACHE[18]





    -- Wipe legacy button ids (kept)
    if gb_is_table(gb_settings.layouts) then
        for _, lj in pairs(gb_settings.layouts) do
            if gb_is_table(lj) and gb_is_table(lj.blocks) then
                lj.blocks['buttons'] = nil
                lj.blocks['buttons_top'] = nil
                lj.blocks['buttons_bottom'] = nil
                lj.blocks['buttons_left'] = nil
                lj.blocks['buttons_right'] = nil
                lj.blocks['buttons_top_bar'] = nil
                lj.blocks['buttons_bottom_bar'] = nil
                lj.blocks['buttons_left_bar'] = nil
                lj.blocks['buttons_right_bar'] = nil
            end
        end
    end

    -- Plugins
    gb_load_all_plugins()
    local has_enabled_plugin = false
    for _, v in pairs(gb_settings.enabled_plugins) do
        if v == true then
            has_enabled_plugin = true
            break
        end
    end

    if not has_enabled_plugin then
        for i = 1, #plugin_list do
            gb_settings.enabled_plugins[plugin_list[i]] = true
        end
        settings_mod.save()
    end

    gb_sync_buttons_internal_disabled()
    gb_rebuild_blocks_from_plugins()

    -- Layout apply
    local job_id = gb_get_main_job_id()
    gb_apply_layout_for_job(job_id)
    applied_job_id = job_id

    local sw, sh = gb_get_client_size()
    last_sw, last_sh, have_last = sw, sh, true

    gb_ready = true
end)

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

ashita.events.register('command', 'gb_command', function(e)
    local args = e.command:args()
    if #args == 0 then return end

    local a1 = args[1]:lower()
    local a2 = (#args >= 2) and args[2]:lower() or ''

    if a1 == '/gobbiebars' then
        if a2 == '' then
            gb_toggle_enabled()
            e.blocked = true
            return
        end
        if a2 == 'layout' then
            gb_set_layout_mode(not layout_mode)
            e.blocked = true
            return
        end
        if a2 == 'ui' then
            ui_open = not ui_open
            e.blocked = true
            return
        end

        if a2 == 'kb' then
            local id = tonumber(args[3] or 0) or 0
            if id > 0 then
                local p = plugins['buttons']
                if p ~= nil and type(p.activate_button_by_id) == 'function' then
                    p.activate_button_by_id(id)
                end
            end
            e.blocked = true
            return
        end

    end
end)

-------------------------------------------------------------------------------
-- d3d_present: hard-gated, stable, plugin-isolated
-------------------------------------------------------------------------------

-- d3d_present: safe wrapper (works even if xpcall is nil on this Ashita build)
local gb_pcall_raw = _G.pcall
local gb_tb_raw    = (debug and debug.traceback) or function(e) return tostring(e) end

local function gb_try_xpcall(fn)
    if type(_G.xpcall) == 'function' then
        return _G.xpcall(fn, gb_tb_raw)
    end
    local ok, err = gb_pcall_raw(fn)
    if ok then
        return true
    end
    -- Force a traceback string even without xpcall:
    return false, gb_tb_raw(err)
end

local function gb_present_body()
    -- HARD FIRST-LOGIN GUARD: ImGui not ready yet
    if imgui == nil
       or type(imgui.Begin) ~= 'function'
       or type(imgui.End) ~= 'function'
       or type(imgui.GetWindowDrawList) ~= 'function'
    then
        return
    end


    -- Hard gates (first-login protection)
    if gb_ready ~= true then return end
    if not gb_imgui_has_core() then return end
    if not gb_is_table(gb_settings) then return end

    -- Remember the base ImGui colors once so we can restore them after drawing.
    gb_cache_base_style()


    if (not enabled) and (not layout_mode) and (not ui_open) then
        return
    end

    local job_id = gb_get_main_job_id()

    -- Reload settings after login, once job != 0
    if (not gb_settings_reloaded_after_login) and (job_id ~= 0) then
        if gb_is_table(GB_DEFAULTS) and gb_is_table(settings_mod) and gb_is_func(settings_mod.load) then
            local ok2, t = gb_pcall_raw(settings_mod.load, GB_DEFAULTS)
            if ok2 and gb_is_table(t) then
                gb_settings = t
                gb_ensure_settings()

                -- dropdown_open is runtime-only; never honor persisted true on boot/reload
                do
                    local ps = gb_settings.plugin_settings or {}
                    if type(ps.playerjob) == 'table' then ps.playerjob.dropdown_open = false end
                    if type(ps.emote) == 'table' then ps.emote.dropdown_open = false end
                end
            end
        end

        -- Re-seed + persist on first-run (reload wipes in-memory seeding otherwise)
        gb_load_all_plugins()

        local has_enabled_plugin = false
        for _, v in pairs(gb_settings.enabled_plugins) do
            if v == true then
                has_enabled_plugin = true
                break
            end
        end

        if not has_enabled_plugin then
            for i = 1, #plugin_list do
                gb_settings.enabled_plugins[plugin_list[i]] = true
            end
            settings_mod.save()
        end

        gb_sync_buttons_internal_disabled()
        gb_rebuild_blocks_from_plugins()
        gb_apply_layout_for_job(job_id)
        applied_job_id = job_id
        gb_settings_reloaded_after_login = true
    end

    if applied_job_id ~= job_id then
        gb_apply_layout_for_job(job_id)
        applied_job_id = job_id
    end

    gb_pcall_raw(gb_draw_plugin_manager_ui)

    -- Centralized per-frame plugin present hook (dropdowns, overlays, etc.)
    -- Plugins must not register their own d3d_present.
    for i = 1, #plugin_list do
        local pid = plugin_list[i]
        if gb_plugin_enabled(pid) then
            local p = plugins[pid]
            if p ~= nil and gb_is_func(p.present) then
                if PLUGIN_FONT ~= nil then imgui.PushFont(PLUGIN_FONT) end
                gb_pcall_raw(p.present, gb_settings.plugin_settings[pid], layout_mode)
                if PLUGIN_FONT ~= nil then imgui.PopFont() end
            end


        end
    end



    if (not enabled) and (not layout_mode) then
        return
    end

    local sw, sh = gb_get_client_size()
    local mx, my = gb_GetMousePos()

    -- Global mouse (for plugins that cannot read io.MousePos reliably on this build)
    _G.gb_mouse = _G.gb_mouse or {}
    _G.gb_mouse.x = mx
    _G.gb_mouse.y = my

    -- Tooltip bridge (plugins set _G.gb_tooltip.text, host draws it)
    _G.gb_tooltip = _G.gb_tooltip or {}
    _G.gb_tooltip.text = nil





    -- Freeze dock only while interacting
    local pre_bars = gb_compute_bars(sw, sh)
    local in_any_bar =
        gb_point_in_rect(mx, my, pre_bars.top.x, pre_bars.top.y, pre_bars.top.x + pre_bars.top.w, pre_bars.top.y + pre_bars.top.h) or
        gb_point_in_rect(mx, my, pre_bars.bottom.x, pre_bars.bottom.y, pre_bars.bottom.x + pre_bars.bottom.w, pre_bars.bottom.y + pre_bars.bottom.h) or
        gb_point_in_rect(mx, my, pre_bars.left.x, pre_bars.left.y, pre_bars.left.x + pre_bars.left.w, pre_bars.left.y + pre_bars.left.h) or
        gb_point_in_rect(mx, my, pre_bars.right.x, pre_bars.right.y, pre_bars.right.x + pre_bars.right.w, pre_bars.right.y + pre_bars.right.h)

    local in_any_screen = false
    do
        local sr = pre_bars.screen
        if sr ~= nil and sr.w > 0 and sr.h > 0 then
            for i = 1, #blocks do
                local blk = blocks[i]
                if blk ~= nil and blk.bar == 'screen' then
                    local bx1 = sr.x + (tonumber(blk.x) or 0)
                    local by1 = sr.y + (tonumber(blk.y) or 0)
                    local bw  = (tonumber(blk.w) or 0)
                    local bh  = (tonumber(blk.h) or 0)
                    local bx2 = bx1 + bw
                    local by2 = by1 + bh
                    if gb_point_in_rect(mx, my, bx1, by1, bx2, by2) then
                        in_any_screen = true
                        break
                    end
                end
            end
        end
    end

    local is_interacting = layout_mode or gb_IsMouseDown(0) or gb_IsMouseDown(1)

    if (not is_interacting) or (not in_any_bar) then
        gb_update_dock(sw, sh, mx, my)
    end

    local bars = gb_compute_bars(sw, sh)

    -- INPUT CAPTURE LAYER (prevents click-through to the game)
    -- Capture while on a bar, or on a screen-block, or while layout/ui is open.
    local gb_capture_input = (layout_mode == true) or (ui_open == true) or (in_any_bar == true) or (in_any_screen == true)


    if gb_capture_input then
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
        imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0)
        imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 0)

        imgui.SetNextWindowBgAlpha(0.0)
        imgui.SetNextWindowSize({ sw + 4, sh + 4 }, ImGuiCond_Always)
        imgui.SetNextWindowPos({ -2, -2 }, ImGuiCond_Always)

        local input_flags = bit.bor(
            ImGuiWindowFlags_NoTitleBar,
            ImGuiWindowFlags_NoResize,
            ImGuiWindowFlags_NoMove,
            ImGuiWindowFlags_NoScrollbar,
            ImGuiWindowFlags_NoScrollWithMouse,
            ImGuiWindowFlags_NoSavedSettings,
            ImGuiWindowFlags_NoBringToFrontOnFocus,
            ImGuiWindowFlags_NoFocusOnAppearing,
            ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoBackground
        )

        imgui.Begin('##gb_input', true, input_flags)

        local ab = gb_settings.active_bars or { top = true, bottom = true, left = true, right = true }

        local function cap_rect(id, r)
            if r == nil then return end
            if (r.w or 0) <= 0 or (r.h or 0) <= 0 then return end
            imgui.SetCursorScreenPos({ r.x, r.y })
            imgui.InvisibleButton(id, { r.w, r.h })
        end

        if ab.top ~= false then cap_rect('##gb_cap_top', bars.top) end
        if ab.bottom ~= false then cap_rect('##gb_cap_bottom', bars.bottom) end
        if ab.left ~= false then cap_rect('##gb_cap_left', bars.left) end
        if ab.right ~= false then cap_rect('##gb_cap_right', bars.right) end

        -- Screen blocks (capture only over their rectangles)
        do
            local sr = bars.screen
            if sr ~= nil and sr.w > 0 and sr.h > 0 then
                for i = 1, #blocks do
                    local blk = blocks[i]
                    if blk ~= nil and blk.bar == 'screen' then
                        local bx1 = sr.x + (tonumber(blk.x) or 0)
                        local by1 = sr.y + (tonumber(blk.y) or 0)
                        local bw  = (tonumber(blk.w) or 0)
                        local bh  = (tonumber(blk.h) or 0)
                        if bw > 0 and bh > 0 then
                            imgui.SetCursorScreenPos({ bx1, by1 })
                            imgui.InvisibleButton('##gb_cap_screen_' .. tostring(blk.id), { bw, bh })
                        end
                    end
                end
            end
        end

        imgui.End()
        imgui.PopStyleVar(3)
    end



    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0, 0 })
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0)
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 0)

    imgui.SetNextWindowBgAlpha(0.0)
    imgui.SetNextWindowSize({ sw + 4, sh + 4 }, ImGuiCond_Always)
    imgui.SetNextWindowPos({ -2, -2 }, ImGuiCond_Always)

    local wnd_flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoMove,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoScrollWithMouse,
        ImGuiWindowFlags_NoInputs,
        ImGuiWindowFlags_NoSavedSettings,
        ImGuiWindowFlags_NoBringToFrontOnFocus
    )

    if UI_FONT ~= nil then imgui.PushFont(UI_FONT) end

    imgui.Begin('##gb_root', true, wnd_flags)
    local dl = imgui.GetWindowDrawList()

    -- First-login protection: draw list can be nil for a few frames.
    if dl == nil then
        imgui.End()
        if UI_FONT ~= nil then imgui.PopFont() end
        imgui.PopStyleVar(3)
        return
    end


    -- Screen grid (layout mode only) + snap-to-grid for screen blocks
    local screen_grid_px = 16
    local screen_grid_col = gb_pack_col(120, 120, 120, 60)

    local function draw_screen_grid()
        if not layout_mode then return end
        local sr = bars.screen
        if sr == nil or sr.w <= 0 or sr.h <= 0 then return end

        local x0 = sr.x
        local y0 = sr.y
        local x1 = sr.x + sr.w
        local y1 = sr.y + sr.h

        local step = tonumber(screen_grid_px) or 16
        if step < 4 then step = 4 end
        if step > 128 then step = 128 end

        local x = x0
        while x <= x1 do
            dl:AddLine({ x, y0 }, { x, y1 }, screen_grid_col, 1.0)
            x = x + step
        end

        local y = y0
        while y <= y1 do
            dl:AddLine({ x0, y }, { x1, y }, screen_grid_col, 1.0)
            y = y + step
        end
    end

    local handle_h = 0



    -- Drag select
    if layout_mode and (not drag.active) and gb_IsMouseClicked(0) then
        for i = #blocks, 1, -1 do
            local blk = blocks[i]
            local br = gb_get_bar_rect(blk.bar, bars)
            if br ~= nil then
                local bx1 = br.x + blk.x
                local by1 = br.y + blk.y
                local bx2 = bx1 + blk.w
                local by2 = by1 + blk.h
                if gb_point_in_rect(mx, my, bx1, by1, bx2, by2) then
                    drag.active = true
                    drag.id = blk.id
                    drag.offx = mx - bx1
                    drag.offy = my - by1
                    break
                end
            end
        end
    end

    -- Drag move
    if drag.active and drag.id ~= nil then
        local blk = gb_find_block_by_id(drag.id)
        if blk ~= nil then
            local br = gb_get_bar_rect(blk.bar, bars)
            if br ~= nil then
                if gb_IsMouseDown(0) then
                    local nx = mx - drag.offx - br.x
                    local ny = my - drag.offy - br.y

                    local eff_w = blk.w
                    local eff_h = blk.h

                    local pid_for_size = blk.pid or blk.id
                    if blk.bar == 'left' or blk.bar == 'right'
                       or ((blk.bar == 'top' or blk.bar == 'bottom') and pid_for_size == 'buttons')
                    then
                        eff_w = br.w
                        eff_h = br.h
                    end


                    local max_x = br.w - eff_w
                    local max_y = br.h - eff_h
                    if max_x < 0 then max_x = 0 end
                    if max_y < 0 then max_y = 0 end

                    nx = gb_clamp(nx, 0, max_x)
                    ny = gb_clamp(ny, 0, max_y)

                    if blk.bar == 'screen' then
                        local g = tonumber(screen_grid_px) or 16
                        if g < 4 then g = 4 end
                        if g > 128 then g = 128 end
                        nx = math.floor((nx / g) + 0.5) * g
                        ny = math.floor((ny / g) + 0.5) * g
                        nx = gb_clamp(nx, 0, max_x)
                        ny = gb_clamp(ny, 0, max_y)
                    end

                    blk.x = math.floor(nx + 0.5)
                    blk.y = math.floor(ny + 0.5)
                else
                    drag.active = false
                    drag.id = nil
                    gb_save_layout_for_job(job_id)
                end
            else
                drag.active = false
                drag.id = nil
                gb_save_layout_for_job(job_id)
            end
        else
            drag.active = false
            drag.id = nil
            gb_save_layout_for_job(job_id)
        end
    end

    local function render_one_block(blk)
        local br = gb_get_bar_rect(blk.bar, bars)
        if br == nil or br.w <= 0 or br.h <= 0 then return end

        local bx1 = br.x + blk.x
        local by1 = br.y + blk.y

        local bw = blk.w
        local bh = blk.h
        if blk.bar == 'left' or blk.bar == 'right' then
            bw = br.w
            bh = br.h
        end

        local bx2 = bx1 + bw
        local by2 = by1 + bh

        local hh = 0

        local pid = blk.pid or blk.id
        local p = plugins[pid]
        if p ~= nil and gb_is_func(p.render) then
            local rect = {
                x = bx1, y = by1, w = bw, h = bh,
                content_x = bx1, content_y = by1 + hh,
                content_w = bw, content_h = bh - hh,
                bar = blk.bar,
            }

            if gb_IsMouseClicked(1) and gb_point_in_rect(mx, my, bx1, by1, bx2, by2) then
                -- Always let plugin handle right-click first.
                if gb_is_func(p.on_right_click) then
                    gb_pcall_raw(p.on_right_click, rect, gb_settings.plugin_settings[pid], layout_mode, mx, my)
                end

                -- Then optionally open GobbieBars settings depending on quick_settings_mode.
                local mode = (gb_settings and gb_settings.quick_settings_mode) or 'right'
                local open_settings = false

                if mode == 'right' then
                    open_settings = true
                elseif mode == 'ctrl_right' then
                    open_settings = gb_IsCtrlDown()
                else
                    open_settings = false
                end

                if open_settings then
                    ui_open = true
                    ui_plugin_open_id = pid
                end
            end


            local clipped = gb_push_clip(dl, br)

            local okr, errr = gb_try_xpcall(function()
                local ps = gb_settings.plugin_settings[pid] or {}

                -- Plugin font (family + size aware)
local family = tostring(ps.font_family or 'default')
local cache  = FONT_FAMILIES[family] or FONT_FAMILIES.default

local fnt = nil
do
    local req = tonumber(ps.font_size)
    if req ~= nil and type(cache) == 'table' then
        local best_s = nil
        local best_d = nil
        for _, s in ipairs(PLUGIN_FONT_SIZES) do
            local d = math.abs(req - s)
            if best_d == nil or d < best_d then
                best_d = d
                best_s = s
            end
        end
        if best_s ~= nil and cache[best_s] ~= nil then
            fnt = cache[best_s]
        end
    end
end


-- (removed: plugin-specific font logic must live in the plugin)




                if fnt ~= nil then imgui.PushFont(fnt) end
                p.render(dl, rect, ps, layout_mode, fnt)

                if fnt ~= nil then imgui.PopFont() end
            end)


            if not okr then
                print('[GobbieBars] Plugin render failed (' .. tostring(pid) .. '):')
                print(tostring(errr))
            end


            if clipped then gb_pop_clip(dl) end
        else
            if layout_mode then
                gb_pcall_raw(function()
                    dl:AddText({ bx1 + 8, by1 + 12 }, gb_pack_col(255, 255, 255, 255), pid)
                end)
            end
        end
    end

    -- Pass 1: screen blocks (render under bars)
    do
        for i = 1, #blocks do
            local blk = blocks[i]
            if blk ~= nil and blk.bar == 'screen' then
                render_one_block(blk)
            end
        end
        draw_screen_grid()
    end

    -- Bar backgrounds (render above screen)
    gb_draw_bar_bg(dl, bars)

    -- Pass 2: docked blocks
    for i = 1, #blocks do
        local blk = blocks[i]
        if blk ~= nil and blk.bar ~= 'screen' then
            render_one_block(blk)
        end
    end


    imgui.End()

    -- Host tooltip bridge draw (plugins set _G.gb_tooltip.text, host draws it)
    if _G.gb_tooltip ~= nil and type(_G.gb_tooltip.text) == 'string' and _G.gb_tooltip.text ~= '' then
        imgui.SetNextWindowBgAlpha(0.90)
        imgui.SetNextWindowPos({ mx + 16, my + 16 }, ImGuiCond_Always)

        local tip_flags = bit.bor(
            ImGuiWindowFlags_NoTitleBar,
            ImGuiWindowFlags_AlwaysAutoResize,
            ImGuiWindowFlags_NoMove,
            ImGuiWindowFlags_NoResize,
            ImGuiWindowFlags_NoScrollbar,
            ImGuiWindowFlags_NoSavedSettings,
            ImGuiWindowFlags_NoBringToFrontOnFocus,
            ImGuiWindowFlags_NoFocusOnAppearing,
            ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoInputs
        )

        imgui.Begin('##gb_tooltip', true, tip_flags)
        imgui.TextUnformatted(_G.gb_tooltip.text)
        imgui.End()
    end

    if UI_FONT ~= nil then imgui.PopFont() end
    imgui.PopStyleVar(3)

    -- Restore ImGui colors so other addons are not affected by GobbieBars theme.
    gb_restore_base_style()
end



ashita.events.register('d3d_present', 'gb_present', function()
    local okp, errp = gb_try_xpcall(gb_present_body)
    if not okp then
        print('[GobbieBars] d3d_present swallowed error:')
        print(tostring(errp))
    end
end)

end)

if not ok then
    print(string.format('[GobbieBars] Load error: %s', tostring(err)))
end
