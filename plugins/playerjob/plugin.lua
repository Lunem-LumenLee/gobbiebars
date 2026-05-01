-------------------------------------------------------------------------------
-- GB Plugin: Player Job + Level (dropdown + prestige stars + job icons)
-- File: Ashita/addons/gobbiebars/plugins/playerjob/plugin.lua
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
-- Plugin persistent state
-------------------------------------------------------------------------------

local STATE = nil
local PJ_PRESENT_HOOKED = false

-------------------------------------------------------------------------------
-- Paths / persistence
-------------------------------------------------------------------------------

local function get_base_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then src = src:sub(2) end
    return src:match('^(.*[\\/])') or './'
end

local BASE = get_base_dir()
local SEP  = package.config:sub(1, 1)

local function gb_root_dir()
    local p = BASE:gsub('[\\/]+$', '')
    p = p:gsub('[\\/]+plugins[\\/]+playerjob$', '')
    return p .. SEP
end

local function data_path()
    local name = nil
    local id = nil

    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if not mm then return end

        local party = mm:GetParty()
        if party then
            if party.GetMemberName then
                name = party:GetMemberName(0)
            end
            if party.GetMemberServerId then
                id = party:GetMemberServerId(0)
            elseif party.GetMemberID then
                id = party:GetMemberID(0)
            end
        end

        if (name == nil or name == '') then
            local player = mm:GetPlayer()
            if player and player.GetName then
                name = player:GetName()
            end
            if (id == nil) and player and player.GetServerId then
                id = player:GetServerId()
            elseif (id == nil) and player and player.GetID then
                id = player:GetID()
            end
        end
    end)

    name = tostring(name or ''):gsub('%s+', '')
    id = tonumber(id or 0) or 0

    if name ~= '' and id > 0 then
        local root = gb_root_dir()
        root = root:gsub('[\\/]+$', '')
        root = root:gsub('[\\/]+addons[\\/]+gobbiebars$', '')

        return root .. SEP .. 'config' .. SEP .. 'addons' .. SEP .. 'gobbiebars'
            .. SEP .. name .. '_' .. tostring(id) .. SEP .. 'playerjob.lua'
    end

    return gb_root_dir() .. 'data' .. SEP .. 'gobbiebars_playerjob.lua'
end

local function ensure_dir(path)
    pcall(function()
        local dir = path:gsub('[\\/][^\\/]+$', '')
        if ashita and ashita.fs and ashita.fs.create_dir then
            ashita.fs.create_dir(dir)
        end
    end)
end

local function esc(s)
    s = tostring(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('\r', '\\r'):gsub('\n', '\\n'):gsub('\t', '\\t')
    s = s:gsub('"', '\\"')
    return '"' .. s .. '"'
end

local function is_ident(k)
    return type(k) == 'string' and k:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

local function dump(v, indent)
    indent = indent or 0
    local pad = string.rep(' ', indent)

    local t = type(v)
    if t == 'nil' then return 'nil' end
    if t == 'number' or t == 'boolean' then return tostring(v) end
    if t == 'string' then return esc(v) end
    if t ~= 'table' then return 'nil' end

    local is_array = true
    local n = 0
    for k, _ in pairs(v) do
        if type(k) ~= 'number' then is_array = false break end
        if k > n then n = k end
    end

    if is_array then
        local out = { '{' }
        for i = 1, n do
            out[#out + 1] = pad .. '  ' .. dump(v[i], indent + 2) .. ','
        end
        out[#out + 1] = pad .. '}'
        return table.concat(out, '\n')
    end

    local out = { '{' }
    for k, val in pairs(v) do
        local key
        if is_ident(k) then
            key = k
        else
            key = '[' .. dump(k, 0) .. ']'
        end
        out[#out + 1] = pad .. '  ' .. key .. ' = ' .. dump(val, indent + 2) .. ','
    end
    out[#out + 1] = pad .. '}'
    return table.concat(out, '\n')
end

local function merge_defaults(dst, defs)
    if type(dst) ~= 'table' then dst = {} end
    if type(defs) ~= 'table' then return dst end
    for k, v in pairs(defs) do
        if dst[k] == nil then
            if type(v) == 'table' then
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

local function load_state(defaults)
    if STATE ~= nil then
        if defaults then STATE = merge_defaults(STATE, defaults) end
        return STATE
    end

    local p = data_path()
    local ok, chunk = pcall(loadfile, p)
    if ok and chunk ~= nil then
        local ok2, t = pcall(chunk)
        if ok2 and type(t) == 'table' then
            STATE = t
        end
    end

    if STATE == nil then
        STATE = {}
    end

    if defaults then
        STATE = merge_defaults(STATE, defaults)
    end

    return STATE
end

local function save_state()
    local p = data_path()
    ensure_dir(p)
    local f = io.open(p, 'w')
    if not f then return end
    f:write('return ', dump(STATE or {}, 0), '\n')
    f:close()
end

-------------------------------------------------------------------------------
-- Plugin definition
-------------------------------------------------------------------------------

local M = {
    id   = 'playerjob',
    name = 'Player Job',
    default = {
        bar = 'top',
        x = 24,
        y = 8,
        w = 460,
        h = 34,
    },

    settings_defaults = {
        dropdown_open = false,

        dropdown_w      = 180,
        dropdown_h      = 320,
        dropdown_line_h = 18,
        dropdown_pad    = 8,

        x = 0,
        y = 0,

        game_mode = 'CW',
        show_jobicons = true,
        jobicon_style = '',
        jobicon_size  = 14,
        show_jobname = true,
        show_prestige = true,
        sort_by = 'level',
        font_scale = 1.0,
        font_name = 'default',
        bar_font_name = 'default',
        bar_current_job = false,
        hide_zero_jobs = false,

        -- Progress text on the bar (right side)
        show_progress = true,
        show_progress_percent = true,

        -- Bar text size in pixels (separate from dropdown font_scale)
        -- This is converted to an ImGui font scale internally.
        bar_font_px = 14,

        -- Backward-compat (if an older saved file has bar_font_scale, we use it only if bar_font_px is missing)
        bar_font_scale = 1.20,

    },

}

local JOBS = {
    { id =  1, name = 'Warrior',      abbr = 'WAR' },
    { id =  2, name = 'Monk',         abbr = 'MNK' },
    { id =  3, name = 'White Mage',   abbr = 'WHM' },
    { id =  4, name = 'Black Mage',  abbr = 'BLM' },
    { id =  5, name = 'Red Mage',    abbr = 'RDM' },
    { id =  6, name = 'Thief',       abbr = 'THF' },
    { id =  7, name = 'Paladin',     abbr = 'PLD' },
    { id =  8, name = 'Dark Knight', abbr = 'DRK' },
    { id =  9, name = 'Beastmaster', abbr = 'BST' },
    { id = 10, name = 'Bard',        abbr = 'BRD' },
    { id = 11, name = 'Ranger',      abbr = 'RNG' },
    { id = 12, name = 'Samurai',     abbr = 'SAM' },
    { id = 13, name = 'Ninja',       abbr = 'NIN' },
    { id = 14, name = 'Dragoon',     abbr = 'DRG' },
    { id = 15, name = 'Summoner',    abbr = 'SMN' },
    { id = 16, name = 'Blue Mage',   abbr = 'BLU' },
    { id = 17, name = 'Corsair',     abbr = 'COR' },
    { id = 18, name = 'Puppetmaster',abbr = 'PUP' },
    { id = 19, name = 'Dancer',      abbr = 'DNC' },
    { id = 20, name = 'Scholar',     abbr = 'SCH' },
    { id = 21, name = 'Geomancer',   abbr = 'GEO' },
    { id = 22, name = 'Rune Fencer', abbr = 'RUN' },
}

-------------------------------------------------------------------------------
-- Rendering helpers
-------------------------------------------------------------------------------

local function col32(r, g, b, a)
    r = bit.band(r or 255, 0xFF)
    g = bit.band(g or 255, 0xFF)
    b = bit.band(b or 255, 0xFF)
    a = bit.band(a or 255, 0xFF)
    return bit.bor(r, bit.lshift(g, 8), bit.lshift(b, 16), bit.lshift(a, 24))
end

local TEX = {}
local function ptr_to_number(p)
    if p == nil then return nil end
    return tonumber(ffi.cast('uintptr_t', p))
end

local function load_texture_handle(path)
    if type(path) ~= 'string' or path == '' then return nil end

    local cached = TEX[path]
    if type(cached) == 'table' and cached.handle ~= nil and cached.tex ~= nil then
        return cached.handle
    end

    -- Fresh install / first-login safety: device can be nil briefly.
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

    if type(d3d8.gc_safe_release) ~= 'function' then
        return nil
    end

    local tex = d3d8.gc_safe_release(out[0])

    local handle = ptr_to_number(tex)
    if handle ~= nil then
        TEX[path] = { handle = handle, tex = tex }
        return handle
    end

    return nil
end

local STAR_HANDLE = nil
local STAR_PATH   = BASE .. 'images' .. SEP .. 'star.png'


local JOBICON_HANDLES = {}
local function get_job_icon_handle(style, abbr_lower)
    if type(style) ~= 'string' or style == '' then return nil end
    if type(abbr_lower) ~= 'string' or abbr_lower == '' then return nil end

    JOBICON_HANDLES[style] = JOBICON_HANDLES[style] or {}
    local h = JOBICON_HANDLES[style][abbr_lower]
    if h ~= nil then return h end

    local p = BASE .. 'images' .. SEP .. 'jobs' .. SEP .. style .. SEP .. abbr_lower .. '.png'
    h = load_texture_handle(p)
    JOBICON_HANDLES[style][abbr_lower] = h
    return h
end

local ICON_STYLE_CACHE = { list = nil, last = 0.0 }
local function list_icon_styles()
    local now = os.clock()
    if ICON_STYLE_CACHE.list ~= nil and (now - ICON_STYLE_CACHE.last) < 2.0 then
        return ICON_STYLE_CACHE.list
    end

    local styles = {}
    local ok, files = pcall(function()
        return ashita.fs.get_directory(BASE .. 'images' .. SEP .. 'jobs')
    end)

    if ok and type(files) == 'table' then
        for _, f in ipairs(files) do
            if type(f) == 'string' then
                local name = f:gsub('^.*[\\/]', '')
                if name ~= '' and name ~= '.' and name ~= '..' then
                    styles[#styles + 1] = name
                end
            end
        end
    end

    table.sort(styles, function(a,b) return a:lower() < b:lower() end)
    ICON_STYLE_CACHE.list = styles
    ICON_STYLE_CACHE.last = now
    return styles
end

local function get_main_job_level()
    local job, lvl
    pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty()
        job = party:GetMemberMainJob(0)
        if party.GetMemberMainJobLevel ~= nil then
            lvl = party:GetMemberMainJobLevel(0)
        elseif party.GetMemberMainJobLvl ~= nil then
            lvl = party:GetMemberMainJobLvl(0)
        else
            lvl = party:GetMemberJobLevel(0)
        end
    end)
    return job, lvl
end

local function get_all_job_levels()
    local out = {}
    pcall(function()
        local p = AshitaCore:GetMemoryManager():GetPlayer()
        for _, j in ipairs(JOBS) do
            out[j.id] = tonumber(p:GetJobLevel(j.id)) or 0
        end
    end)
    return out
end

local function in_rect(mx, my, x1, y1, x2, y2)
    return mx >= x1 and mx <= x2 and my >= y1 and my <= y2
end

local TYPE_ORDER = {
    'Paladin', 'Rune Fencer', 'Ninja',
    'White Mage', 'Scholar',
    'Bard', 'Corsair', 'Geomancer', 'Red Mage',
    'Warrior', 'Monk', 'Dragoon', 'Samurai', 'Dark Knight', 'Thief', 'Dancer',
    'Ranger',
    'Black Mage', 'Blue Mage',
    'Summoner', 'Beastmaster', 'Puppetmaster',
}
local TYPE_RANK = {}
do
    local r = 1
    for _, n in ipairs(TYPE_ORDER) do
        if TYPE_RANK[n] == nil then
            TYPE_RANK[n] = r
            r = r + 1
        end
    end
end

local function build_sorted_jobs(levels, sort_by)
    local list = {}
    for _, j in ipairs(JOBS) do
        list[#list + 1] = j
    end

    sort_by = tostring(sort_by or 'level'):lower()
    if sort_by == 'alpha' then
        table.sort(list, function(a,b) return a.name:lower() < b.name:lower() end)
        return list
    end

    if sort_by == 'type' then
        table.sort(list, function(a,b)
            local ra = TYPE_RANK[a.name] or 9999
            local rb = TYPE_RANK[b.name] or 9999
            if ra ~= rb then return ra < rb end
            return a.name:lower() < b.name:lower()
        end)
        return list
    end

    table.sort(list, function(a,b)
        local la = tonumber(levels[a.id] or 0) or 0
        local lb = tonumber(levels[b.id] or 0) or 0
        if la ~= lb then return la > lb end
        return a.name:lower() < b.name:lower()
    end)
    return list
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

-------------------------------------------------------------------------------
-- Dropdown renderer (ImGui window)
-- NOTE: This is called from d3d_present, not from M.render.
-------------------------------------------------------------------------------

local function gb_pj_draw_dropdown(st)
    if st.dropdown_open ~= true then
        return
    end

    local rt = st._gb_pj_rt
    if type(rt) ~= 'table' then
        return
    end

    local pad   = tonumber(st.dropdown_pad) or 8
    local lineh = tonumber(st.dropdown_line_h) or 18
    local rowgap = 6
    local rowh  = lineh + rowgap
    local top_inset = 3

    local w = tonumber(st.dropdown_w) or 180
    if w < 120 then w = 120 end
    if w > 360 then w = 360 end

    local px1 = tonumber(rt.px1) or 0
    local py1 = tonumber(rt.py1) or 0
    local job = tonumber(rt.job) or 0

    local levels = get_all_job_levels()
    local sorted = build_sorted_jobs(levels, st.sort_by)

    local maxh = tonumber(st.dropdown_h or 320) or 320
    if maxh < 120 then maxh = 120 end
    if maxh > 600 then maxh = 600 end

    local h = maxh

    imgui.SetNextWindowPos({ px1, py1 }, ImGuiCond_Always)
    imgui.SetNextWindowSize({ w, h }, ImGuiCond_Always)

    local win_flags =
        bit.bor(
            ImGuiWindowFlags_NoTitleBar,
            ImGuiWindowFlags_NoResize,
            ImGuiWindowFlags_NoMove,
            ImGuiWindowFlags_NoSavedSettings,
            ImGuiWindowFlags_NoNav,
            ImGuiWindowFlags_NoBackground
        )

    imgui.PushStyleColor(ImGuiCol_Header,        { 0.62, 0.44, 0.20, 1.00 })
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, { 0.70, 0.50, 0.22, 1.00 })
    imgui.PushStyleColor(ImGuiCol_HeaderActive,  { 0.76, 0.55, 0.24, 1.00 })

    if imgui.Begin('##gb_playerjob_dropdown', { true }, win_flags) then
        local dd_font = resolve_font_family_size(st.font_name, 14, nil)
        if dd_font ~= nil then imgui.PushFont(dd_font) end
        imgui.SetWindowFontScale(tonumber(st.font_scale or 1.0) or 1.0)

        if imgui.BeginChild('##gb_playerjob_dropdown_list', { 0, 0 }, false) then
            imgui.SetCursorPosY(imgui.GetCursorPosY() + top_inset)

            local visible = {}
            for _, j in ipairs(sorted) do
                local jlvl = tonumber(levels[j.id] or 0) or 0
                if jlvl > 75 then jlvl = 75 end
                if not (st.hide_zero_jobs == true and jlvl <= 0) then
                    visible[#visible + 1] = { j = j, lvl = jlvl }
                end
            end

            local avail_w = imgui.GetContentRegionAvail()
            local gap = 10
            local col_w = (avail_w - gap) / 2

            local function draw_cell(entry, col_index, row_index)
                if entry == nil then
                    imgui.Selectable('##gb_pj_empty_' .. tostring(col_index) .. '_' .. tostring(row_index), false, 0, { col_w, rowh })
                    return
                end

                local j = entry.j
                local jlvl = entry.lvl

                local stars = 0
                if st.show_prestige == true and _G.gb_prestige ~= nil and _G.gb_prestige[j.name] ~= nil then
                    stars = tonumber(_G.gb_prestige[j.name]) or 0
                end
                if stars < 0 then stars = 0 end
                if stars > 5 then stars = 5 end

                local isz = tonumber(st.jobicon_size or 15) or 15
                if isz < 15 then isz = 15 end
                if isz > 50 then isz = 50 end

                local style = tostring(st.jobicon_style or '')
                if style == '' then
                    local styles = list_icon_styles()
                    if styles[1] ~= nil then
                        style = styles[1]
                        st.jobicon_style = style
                        save_state()
                    end
                end

                local start_x = imgui.GetCursorPosX()
                local start_y = imgui.GetCursorPosY()
                local text_h  = imgui.GetTextLineHeight()

                if imgui.Selectable('##gb_pj_pick_' .. tostring(j.id) .. '_' .. tostring(col_index), (j.id == job), 0, { col_w, rowh }) then
                    st.dropdown_open = false
                    save_state()
                end

                imgui.SetCursorPosX(start_x + 6)
                imgui.SetCursorPosY(start_y)

                if st.show_jobicons == true and style ~= '' then
                    local ih = get_job_icon_handle(style, j.abbr:lower())
                    if ih ~= nil then
                        imgui.SetCursorPosY(start_y + ((rowh - isz) * 0.5))
                        imgui.Image(ih, { isz, isz })
                        imgui.SetCursorPosY(start_y)
                        imgui.SameLine()
                    end
                end

                if st.show_jobname == true then
                    imgui.SetCursorPosY(start_y + ((rowh - text_h) * 0.5))
                    imgui.Text(j.abbr)
                    imgui.SameLine()
                end

                local lvl_text = tostring(jlvl)
                local lvl_w = imgui.CalcTextSize(lvl_text)

                local stars_w = 0
                if st.show_prestige == true and STAR_HANDLE ~= nil and stars > 0 then
                    stars_w = (stars * 12) + ((stars - 1) * 2) + 4
                end

                local block_w = stars_w + lvl_w
                local min_x = imgui.GetCursorPosX() + 6
                local right_x = (start_x + col_w) - block_w - 6
                if right_x < min_x then right_x = min_x end

                imgui.SetCursorPosX(right_x)
                imgui.SetCursorPosY(start_y)

                if st.show_prestige == true and STAR_HANDLE ~= nil and stars > 0 then
                    imgui.SetCursorPosY(start_y + ((rowh - 12) * 0.5))
                    for i = 1, stars do
                        imgui.Image(STAR_HANDLE, { 12, 12 })
                        if i < stars then
                            imgui.SameLine()
                            imgui.SetCursorPosX(imgui.GetCursorPosX() + 2)
                        end
                    end
                    imgui.SameLine()
                    imgui.SetCursorPosY(start_y)
                end

                imgui.SetCursorPosY(start_y + ((rowh - text_h) * 0.5))
                imgui.Text(lvl_text)

                imgui.SetCursorPosY(start_y + rowh)
            end

            local total_rows = (#visible + 1) / 2
            for r = 1, total_rows do
                local i1 = (r - 1) * 2 + 1
                local i2 = i1 + 1

                draw_cell(visible[i1], 1, r)
                imgui.SameLine(0, gap)
                draw_cell(visible[i2], 2, r)
            end
            imgui.EndChild()
        end

        imgui.SetWindowFontScale(1.0)
        if dd_font ~= nil then imgui.PopFont() end
        imgui.PopStyleColor(3)
    end
    imgui.End()
end

-------------------------------------------------------------------------------
-- Present hook: keeps dropdown alive even when bar collapses
-------------------------------------------------------------------------------

local function gb_playerjob_present()
    if imgui == nil
        or type(imgui.GetIO) ~= 'function'
        or type(imgui.Begin) ~= 'function'
        or type(imgui.End) ~= 'function'
    then
        return
    end

    local st = load_state(M.settings_defaults)

    -- HARD GUARD: do nothing until anchor exists
    if st.dropdown_open ~= true then
        return
    end

    if type(st._gb_pj_rt) ~= 'table' then
        return
    end

    if STAR_HANDLE == nil then
        STAR_HANDLE = load_texture_handle(STAR_PATH)
    end

    gb_pj_draw_dropdown(st)
end



local function ensure_present_hook()
    -- No-op: d3d_present is owned by the host (gobbiebars.lua).
end


-------------------------------------------------------------------------------
-- Main bar render: draw text and toggle dropdown; update dropdown anchor
-------------------------------------------------------------------------------

function M.render(dl, rect, settings)

    ensure_present_hook()

    if imgui == nil
        or type(imgui.GetMousePos) ~= 'function'
        or type(imgui.IsMouseClicked) ~= 'function'
        or type(imgui.CalcTextSize) ~= 'function'
    then
        return
    end

    local st = load_state(M.settings_defaults)
    M._st = st

    if STAR_HANDLE == nil then
        STAR_HANDLE = load_texture_handle(STAR_PATH)
    end

    local job, lvl = get_main_job_level()

    local subjob = 0
    local sublvl = 0

    local prog_label = nil
    local prog_pct   = nil
    local prog_cur   = nil
    local prog_need  = nil

    pcall(function()
        local p = AshitaCore:GetMemoryManager():GetPlayer()
        if p ~= nil then
            if p.GetSubJob then subjob = tonumber(p:GetSubJob()) or 0 end
            if p.GetSubJobLevel then sublvl = tonumber(p:GetSubJobLevel()) or 0 end

            local lvl0 = tonumber(lvl) or 0

            local exp_cur  = tonumber(p:GetExpCurrent()) or 0
            local exp_need = tonumber(p:GetExpNeeded()) or 0

            local limit_mode = false
            if p.GetIsLimitModeEnabled then
                limit_mode = (p:GetIsLimitModeEnabled() == true)
            end
            if (not limit_mode) and p.GetIsExperiencePointsLocked then
                limit_mode = (p:GetIsExperiencePointsLocked() == true)
            end

            -- HXUIPlus logic:
            -- LP mode if EXP current hits sentinel (55999) OR limit mode enabled while level >= 75.
            local meritMode = (exp_cur == 55999) or (limit_mode and (lvl0 >= 75))

            if meritMode then
                local lp = tonumber(p:GetLimitPoints()) or 0
                local maxlp = 10000
                prog_label = 'LP'
                prog_cur = lp
                prog_need = maxlp
            else
                if exp_need > 0 then
                    prog_label = 'EXP'
                    prog_cur = exp_cur
                    prog_need = exp_need
                end
            end


        end
    end)


    local function job_abbr(id)
        for _, j in ipairs(JOBS) do
            if j.id == id then return j.abbr end
        end
        return '?'
    end

    local main_abbr = job_abbr(job)
    local sub_abbr  = (subjob ~= 0) and job_abbr(subjob) or '?'

    local left_text
    if job and lvl then
                if st.bar_current_job == true then
            left_text = ''
        else
            left_text = string.format('%s %d / %s %d', main_abbr, lvl, sub_abbr, sublvl)
        end
    else
        left_text = '?: ? / ?: ?'
    end

    -- Build right-side progress text (EXP/LP) and/or percent
    local right_text = ''

    local pct = nil
    if prog_label ~= nil and prog_cur ~= nil and prog_need ~= nil and prog_need > 0 then
        pct = math.floor((prog_cur / prog_need) * 100 + 0.5)
        if pct < 0 then pct = 0 end
        if pct > 999 then pct = 999 end
    end

    if pct ~= nil then
        if st.show_progress == true then
            right_text = string.format('%s (%d / %d)', prog_label, prog_cur, prog_need)
        end

        if st.show_progress_percent == true then
            local pct_text = string.format('%d%%', pct)
            if right_text ~= '' then
                right_text = right_text .. ' ' .. pct_text
            else
                right_text = pct_text
            end
        end
    end


    local ox = tonumber(st.x or 0) or 0
    local oy = tonumber(st.y or 0) or 0

    local x = rect.content_x + 8 + ox
    local y = rect.content_y + 4 + oy

    -- Robust width helper (Ashita bindings can return number OR table)
    local function text_w(s)
        local a, b = imgui.CalcTextSize(tostring(s or ''))
        if type(a) == 'number' then
            return a
        elseif type(a) == 'table' then
            return tonumber(a.x or a[1] or 0) or 0
        end
        return tonumber(a) or 0
    end

    -- Draw scaled bar text using ImGui text (so scaling works)
    local can_scale = (imgui.SetWindowFontScale ~= nil)

    -- Pixel-based sizing: derive scale from px so you can go smaller than 0.75.
    local BASE_PX = 18
    local bar_px = tonumber(st.bar_font_px or 0) or 0

    -- Backward-compat: if bar_font_px not present, derive from old bar_font_scale
    if bar_px <= 0 then
        local old = tonumber(st.bar_font_scale or 1.0) or 1.0
        bar_px = math.floor((old * BASE_PX) + 0.5)
    end

    -- Clamp pixels (adjust if you want even smaller/larger)
    if bar_px < 8 then bar_px = 8 end
    if bar_px > 32 then bar_px = 32 end

    local bar_scale = bar_px / BASE_PX


    local function text_unformatted(s)
        if imgui.TextUnformatted ~= nil then
            imgui.TextUnformatted(s)
        else
            imgui.Text(s)
        end
    end

    local function draw_shadowed(sx, sy, text)
        imgui.SetCursorScreenPos({ sx + 1, sy + 1 })
        imgui.PushStyleColor(ImGuiCol_Text, { 0.0, 0.0, 0.0, 1.0 })
        text_unformatted(text)
        imgui.PopStyleColor(1)

        imgui.SetCursorScreenPos({ sx, sy })
        imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 1.0, 1.0, 1.0 })
        text_unformatted(text)
        imgui.PopStyleColor(1)
    end

    local click_left   = x
    local click_top    = y
    local click_right  = x
    local click_bottom = y + bar_px

    local function update_click_bounds()
        if imgui.GetItemRectMin == nil or imgui.GetItemRectMax == nil then
            return
        end

        local mn = imgui.GetItemRectMin()
        local mxr = imgui.GetItemRectMax()

        local mnx = x
        local mny = y
        local mxx = x
        local mxy = y + bar_px

        if type(mn) == 'table' then
            mnx = tonumber(mn.x or mn[1] or x) or x
            mny = tonumber(mn.y or mn[2] or y) or y
        else
            mnx = tonumber(mn or x) or x
        end

        if type(mxr) == 'table' then
            mxx = tonumber(mxr.x or mxr[1] or x) or x
            mxy = tonumber(mxr.y or mxr[2] or (y + bar_px)) or (y + bar_px)
        else
            mxx = tonumber(mxr or x) or x
        end

        if mnx < click_left then click_left = mnx end
        if mny < click_top then click_top = mny end
        if mxx > click_right then click_right = mxx end
        if mxy > click_bottom then click_bottom = mxy end
    end

    local bar_font = resolve_font_family_size(st.bar_font_name, 18, nil)
    if bar_font ~= nil then imgui.PushFont(bar_font) end

    local old_scale = nil
    if can_scale then
        -- We do not have a getter; assume 1.0 and restore to 1.0 after.
        old_scale = 1.0
        imgui.SetWindowFontScale(bar_scale)
    end

    if left_text ~= '' then
        draw_shadowed(x, y, left_text)
        update_click_bounds()
    end

    if right_text ~= '' then
        -- Get the actual rendered end X of the left text (respects SetWindowFontScale).
        local left_max_x = x
        if imgui.GetItemRectMax ~= nil then
            local r = imgui.GetItemRectMax()
            if type(r) == 'table' then
                left_max_x = tonumber(r.x or r[1] or x) or x
            elseif type(r) == 'number' then
                left_max_x = r
            end
        end

        local pad = 8
        local right_edge = rect.content_x + rect.content_w - 8 + ox
        local rx_base = left_max_x + pad
        local avail_w = right_edge - rx_base
        if avail_w < 0 then avail_w = 0 end

        -- Measure rendered width of text by drawing invisibly offscreen.
        local function measure_w(txt)
            txt = tostring(txt or '')
            if txt == '' then return 0 end
            if imgui.GetItemRectMin == nil or imgui.GetItemRectMax == nil then
                return 0
            end

            local opx, opy = imgui.GetCursorScreenPos()
            local old_pos
            if type(opx) == 'table' then
                local t = opx
                old_pos = { tonumber(t.x or t[1] or 0) or 0, tonumber(t.y or t[2] or 0) or 0 }
            else
                old_pos = { tonumber(opx or 0) or 0, tonumber(opy or 0) or 0 }
            end

            imgui.SetCursorScreenPos({ -10000, -10000 })
            imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 1.0, 1.0, 0.0 })
            text_unformatted(txt)
            imgui.PopStyleColor(1)

            local mn1 = imgui.GetItemRectMin()
            local mx1 = imgui.GetItemRectMax()

            local mnx = 0
            local mxx = 0

            if type(mn1) == 'table' then
                mnx = tonumber(mn1.x or mn1[1] or 0) or 0
            else
                mnx = tonumber(mn1 or 0) or 0
            end

            if type(mx1) == 'table' then
                mxx = tonumber(mx1.x or mx1[1] or 0) or 0
            else
                mxx = tonumber(mx1 or 0) or 0
            end

            imgui.SetCursorScreenPos({ old_pos[1], old_pos[2] })

            local w = mxx - mnx
            if w < 0 then w = 0 end
            return w
        end

        -- Build deterministic fallbacks (never allow partial cut-off).
        local pct_text = nil
        if pct ~= nil and st.show_progress_percent == true then
            pct_text = string.format('%d%%', pct)
        end

        local mid_text = nil
        if prog_label ~= nil and prog_cur ~= nil and prog_need ~= nil and prog_need > 0 then
            mid_text = string.format('(%d / %d)', prog_cur, prog_need)
        end

        local label_text = prog_label

        local rt = right_text
        if avail_w > 0 then
            if measure_w(rt) > avail_w then
                if pct_text ~= nil and measure_w(pct_text) <= avail_w then
                    rt = pct_text
                elseif mid_text ~= nil and measure_w(mid_text) <= avail_w then
                    rt = mid_text
                elseif label_text ~= nil and measure_w(label_text) <= avail_w then
                    rt = label_text
                else
                    rt = ''
                end
            end
        else
            rt = ''
        end

        if rt ~= '' then
            local rw = measure_w(rt)
            local rx = rx_base

            -- If it still overflows (shouldn't, but safety), shift left to keep whole text visible.
            if rw > 0 and (rx + rw) > right_edge then
                rx = right_edge - rw
            end

            if imgui.PushClipRect ~= nil and imgui.PopClipRect ~= nil then
                imgui.PushClipRect(
                    { rect.content_x + 4 + ox, rect.content_y + oy },
                    { rect.content_x + rect.content_w - 4 + ox, rect.content_y + rect.content_h + oy },
                    true
                )
                draw_shadowed(rx, y, rt)
                update_click_bounds()
                imgui.PopClipRect()
            else
                draw_shadowed(rx, y, rt)
                update_click_bounds()
            end
        end
    end




    if can_scale then
        imgui.SetWindowFontScale(old_scale or 1.0)
    end

    if bar_font ~= nil then imgui.PopFont() end

    local mx, my = imgui.GetMousePos()

    local cx1 = click_left - 2
    local cx2 = click_right + 2
    local cy1 = click_top - 2
    local cy2 = click_bottom + 2

    if in_rect(mx, my, cx1, cy1, cx2, cy2) and imgui.IsMouseClicked(0) then
        st.dropdown_open = not (st.dropdown_open == true)
        save_state()
    end

    if st.dropdown_open ~= true then
        return
    end

    -- Update anchor every frame while bar is visible.
    st._gb_pj_rt = st._gb_pj_rt or {}

    local io = imgui.GetIO and imgui.GetIO() or nil
    local dw = tonumber(st.dropdown_w or 180) or 180
    local dh = tonumber(st.dropdown_h or 320) or 320

    local px1 = rect.content_x + 6 + ox
    local py1 = rect.content_y + rect.content_h - 8 + oy

    if io and io.DisplaySize then
        local sw = tonumber(io.DisplaySize.x or io.DisplaySize[1] or 0) or 0
        local sh = tonumber(io.DisplaySize.y or io.DisplaySize[2] or 0) or 0

        if (py1 + dh) > (sh - 8) then
            py1 = rect.content_y - dh + 8 + oy
        end

        if (px1 + dw) > (sw - 8) then
            px1 = (sw - 8) - dw
        end
        if px1 < 8 then px1 = 8 end
        if py1 < 8 then py1 = 8 end
    end

    st._gb_pj_rt.px1 = px1
    st._gb_pj_rt.py1 = py1
    st._gb_pj_rt.job = job
end

-------------------------------------------------------------------------------
-- Settings UI (unchanged behavior)
-------------------------------------------------------------------------------

function M.draw_settings_ui(settings)
    local st = load_state(M.settings_defaults)

    st.x = tonumber(st.x or 0) or 0
    st.y = tonumber(st.y or 0) or 0

    imgui.Spacing()
    imgui.Spacing()

    local function header(text)
        imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.9, 0.7, 1.0 })
        imgui.Text(text)
        imgui.PopStyleColor(1)
    end

    local function save_host()
        if type(settings) == 'table' then
            if type(settings.save) == 'function' then settings.save() return end
            if type(settings.Save) == 'function' then settings.Save() return end
        end
    end

    local function area_value()
        if type(settings) == 'table' and settings.bar ~= nil then
            return tostring(settings.bar)
        end
        if st.bar ~= nil then
            return tostring(st.bar)
        end
        return tostring(M.default.bar or 'top')
    end

    local function set_area(v)
        if type(settings) == 'table' then
            settings.bar = v
            save_host()
        else
            st.bar = v
            save_state()
        end
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

    local function draw_font_combo(label, id, key, width)
        width = width or 180

        local cur = tostring(st[key] or 'default')
        if cur == '' then cur = 'default' end

        imgui.Text(label)
        imgui.SameLine()

        imgui.SetNextItemWidth(width)
        if imgui.BeginCombo(id, cur) then
            if imgui.Selectable('default', cur == 'default') then
                st[key] = 'default'
                save_state()
                cur = 'default'
            end

            local names = build_sorted_font_names()
            for _, name in ipairs(names) do
                if imgui.Selectable(name, cur == name) then
                    st[key] = name
                    save_state()
                    cur = name
                end
            end

            imgui.EndCombo()
        end
    end

    header('General')

    local cur_area = area_value()
    local area_label = cur_area
    if cur_area == 'top' then area_label = 'Top' end
    if cur_area == 'bottom' then area_label = 'Bottom' end
    if cur_area == 'left' then area_label = 'Left' end
    if cur_area == 'right' then area_label = 'Right' end
    if cur_area == 'screen' then area_label = 'Screen' end

    imgui.Text('Area')
    imgui.SameLine()
    imgui.SetNextItemWidth(160)
    if imgui.BeginCombo('##gb_pj_area', area_label, ImGuiComboFlags_None) then
        if imgui.Selectable('Top', cur_area == 'top') then set_area('top') end
        if imgui.Selectable('Bottom', cur_area == 'bottom') then set_area('bottom') end
        if imgui.Selectable('Left', cur_area == 'left') then set_area('left') end
        if imgui.Selectable('Right', cur_area == 'right') then set_area('right') end
        if imgui.Selectable('Screen', cur_area == 'screen') then set_area('screen') end
        imgui.EndCombo()
    end

    imgui.Text('Position')
    imgui.SameLine()

    imgui.SetNextItemWidth(140)
    local vx = { st.x }
    if imgui.InputInt('X##gb_pj_x', vx) then
        st.x = tonumber(vx[1] or 0) or 0
        save_state()
    end

    imgui.SameLine()

    imgui.SetNextItemWidth(140)
    local vy = { st.y }
    if imgui.InputInt('Y##gb_pj_y', vy) then
        st.y = tonumber(vy[1] or 0) or 0
        save_state()
    end

    imgui.Separator()

    header('Display')

    local jn = { st.show_jobname == true }
    if imgui.Checkbox('Job Name', jn) then
        st.show_jobname = jn[1]
        save_state()
    end

    local hz = { st.hide_zero_jobs == true }
    if imgui.Checkbox('Hide Lv.0 Jobs', hz) then
        st.hide_zero_jobs = hz[1]
        save_state()
    end

    local pr = { st.show_prestige == true }
    if imgui.Checkbox('Prestige', pr) then
        st.show_prestige = pr[1]
        save_state()
    end

    local sp = { st.show_progress == true }
    if imgui.Checkbox('Show XP/LP', sp) then
        st.show_progress = sp[1]
        save_state()
    end

    local spp = { st.show_progress_percent == true }
    if imgui.Checkbox('Show Percent', spp) then
        st.show_progress_percent = spp[1]
        save_state()
    end

    imgui.Separator()

    header('Font')

    draw_font_combo('Font', '##gb_pj_font', 'font_name', 220)

    imgui.Text('Font Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)
    local fs = { tonumber(st.font_scale or 1.0) or 1.0 }
    if imgui.SliderFloat('##gb_pj_font_scale', fs, 0.75, 1.50, '%.2f') then
        st.font_scale = tonumber(fs[1] or 1.0) or 1.0
        save_state()
    end

    imgui.Separator()

    header('Job Icons')

    local ji = { st.show_jobicons == true }
    if imgui.Checkbox('Show Job Icons', ji) then
        st.show_jobicons = ji[1]
        save_state()
    end

    if st.show_jobicons == true then
        imgui.Text('Job Icon Size')
        imgui.SameLine()
        imgui.SetNextItemWidth(110)

        local isz = { tonumber(st.jobicon_size or 15) or 15 }
        if isz[1] < 15 then isz[1] = 15 end

        if imgui.SliderInt('##gb_pj_jobicon_size', isz, 15, 50) then
            if isz[1] < 15 then isz[1] = 15 end
            st.jobicon_size = isz[1]
            save_state()
        end
    end

    imgui.Text('Job Icon Theme')
    imgui.SameLine()

    local styles = list_icon_styles()
    local cur = tostring(st.jobicon_style or '')
    if cur == '' and styles[1] ~= nil then
        cur = styles[1]
        st.jobicon_style = cur
        save_state()
    end

    imgui.SetNextItemWidth(160)
    if imgui.BeginCombo('##gb_jobicon_style', cur ~= '' and cur or '(none)', ImGuiComboFlags_None) then
        for _, s in ipairs(styles) do
            if imgui.Selectable(s, s == cur) then
                st.jobicon_style = s
                save_state()
            end
        end
        imgui.EndCombo()
    end

    imgui.Separator()

    header('Layout')

    imgui.Text('Bar Font Size (px)')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)

    local BASE_PX = 18
    local px = tonumber(st.bar_font_px or 0) or 0
    if px <= 0 then
        local old = tonumber(st.bar_font_scale or 1.0) or 1.0
        px = math.floor((old * BASE_PX) + 0.5)
    end

    local vpx = { px }
    if imgui.SliderInt('##gb_pj_bar_font_px', vpx, 8, 20) then
        st.bar_font_px = tonumber(vpx[1] or px) or px
        save_state()
    end

    draw_font_combo('Bar Font', '##gb_pj_bar_font', 'bar_font_name', 220)

    local bcj = { st.bar_current_job == true }
    if imgui.Checkbox('Hide Job/Subjob', bcj) then
        st.bar_current_job = bcj[1]
        save_state()
    end

    imgui.Text('Width')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)
    local dw = { tonumber(st.dropdown_w or 180) or 180 }
    if imgui.SliderInt('##gb_pj_dropdown_w', dw, 120, 360) then
        st.dropdown_w = tonumber(dw[1] or 180) or 180
        save_state()
    end

    imgui.Text('Height')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)
    local dh = { tonumber(st.dropdown_h or 320) or 320 }
    if imgui.SliderInt('##gb_pj_dropdown_h', dh, 120, 600) then
        st.dropdown_h = tonumber(dh[1] or 320) or 320
        save_state()
    end

    imgui.Text('Sort By')
    imgui.SameLine()

    local sort_label = 'Level (High-Low)'
    local sb = tostring(st.sort_by or 'level'):lower()
    if sb == 'alpha' then sort_label = 'Alphabetical (A-Z)' end
    if sb == 'type'  then sort_label = 'Type' end

    imgui.SetNextItemWidth(160)
    if imgui.BeginCombo('##gb_sort_by', sort_label, ImGuiComboFlags_None) then
        if imgui.Selectable('Level (High-Low)', sb == 'level') then
            st.sort_by = 'level'
            save_state()
        end
        if imgui.Selectable('Alphabetical (A-Z)', sb == 'alpha') then
            st.sort_by = 'alpha'
            save_state()
        end
        if imgui.Selectable('Type', sb == 'type') then
            st.sort_by = 'type'
            save_state()
        end
        imgui.EndCombo()
    end

    imgui.Separator()
    imgui.Text('Shortcut: /playerjob')
end

function M.present(settings, layout_mode)
    gb_playerjob_present()
end

-- Command: /playerjob [open|close|toggle]
ashita.events.register('command', 'gb_playerjob_command', function(e)
    local args = e.command:args()
    if not args or #args == 0 then
        return
    end

    local cmd = tostring(args[1] or ''):lower()
    if cmd ~= '/playerjob' then
        return
    end

    e.blocked = true

    local st = M._st or load_state(M.settings_defaults)

    local sub = tostring(args[2] or 'toggle'):lower()
    if sub == 'open' then
        st.dropdown_open = true
    elseif sub == 'close' then
        st.dropdown_open = false
    else
        st.dropdown_open = not (st.dropdown_open == true)
    end

    save_state()
end)

return M

