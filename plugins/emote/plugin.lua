-------------------------------------------------------------------------------
-- GobbieBars Plugin: Emote
-- File: Ashita/addons/gobbiebars/plugins/emote/plugin.lua
-- Author: Lunem
-- Version: 0.1.1
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
local EM_PRESENT_HOOKED = false

-------------------------------------------------------------------------------
-- Paths / persistence
-------------------------------------------------------------------------------

local function get_base_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then
        src = src:sub(2)
    end
    return src:match('^(.*[\\/])') or './'
end

local BASE = get_base_dir()
local SEP  = package.config:sub(1, 1)

local function gb_root_dir()
    local p = BASE:gsub('[\\/]+$', '')
    p = p:gsub('[\\/]+plugins[\\/]+emote$', '')
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
            .. SEP .. name .. '_' .. tostring(id) .. SEP .. 'emote.lua'
    end

    return gb_root_dir() .. 'data' .. SEP .. 'gobbiebars_emote.lua'
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
        if type(k) ~= 'number' then
            is_array = false
            break
        end
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
                for kk, vv in pairs(v) do
                    t[kk] = vv
                end
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
        if defaults then
            STATE = merge_defaults(STATE, defaults)
        end
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

    -- Runtime-only: never start with dropdown open on a fresh boot.
    if STATE._gb_em_booted ~= true then
        STATE.dropdown_open = false
        STATE._gb_em_booted = true
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
-- Ashita/addons/gobbiebars/plugins/emote/images/*.png
local function emote_icon_path(icon)
    return BASE .. 'images' .. SEP .. icon
end

-------------------------------------------------------------------------------
-- Emote definitions
-------------------------------------------------------------------------------

local EMOTES = {
    { key = 'amazed',    name = 'Amazed',                cmd = '/amazed',    icon = 'amazed.png' },
    { key = 'angry',     name = 'Angry',                 cmd = '/angry',     icon = 'angry.png' },
    { key = 'blush',     name = 'Blush',                 cmd = '/blush',     icon = 'blush.png' },
    { key = 'bow',       name = 'Bow',                   cmd = '/bow',       icon = 'bow.png' },
    { key = 'cheer',     name = 'Cheer',                 cmd = '/cheer',     icon = 'cheer.png' },
    { key = 'clap',      name = 'Clap / Praise',         cmd = '/clap',      icon = 'clap.png' },
    { key = 'comfort',   name = 'Comfort',               cmd = '/comfort',   icon = 'comfort.png' },
    { key = 'cry',       name = 'Cry',                   cmd = '/cry',       icon = 'cry.png' },
    { key = 'dance1',    name = 'Dance1',                cmd = '/dance1',    icon = 'dance1.png' },
    { key = 'dance2',    name = 'Dance2',                cmd = '/dance2',    icon = 'dance2.png' },
    { key = 'dance3',    name = 'Dance3',                cmd = '/dance3',    icon = 'dance3.png' },
    { key = 'dance4',    name = 'Dance4',                cmd = '/dance4',    icon = 'dance4.png' },
    { key = 'disgusted', name = 'Disgusted',             cmd = '/disgusted', icon = 'disgusted.png' },
    { key = 'doubt',     name = 'Doubt',                 cmd = '/doubt',     icon = 'doubt.png' },
    { key = 'doze',      name = 'Doze',                  cmd = '/doze',      icon = 'doze.png' },
    { key = 'farewell',  name = 'Farewell / Goodbye',    cmd = '/farewell',  icon = 'farewell.png' },
    { key = 'huh',       name = 'Huh',                   cmd = '/huh',       icon = 'huh.png' },
    { key = 'hurray',    name = 'Hurray',                cmd = '/hurray',    icon = 'hurray.png' },
    { key = 'joy',       name = 'Joy',                   cmd = '/joy',       icon = 'joy.png' },
    { key = 'jump',      name = 'Jump',                  cmd = '/jump',      icon = 'jump.png' },
    { key = 'kneel',     name = 'Kneel',                 cmd = '/kneel',     icon = 'kneel.png' },
    { key = 'laugh',     name = 'Laugh',                 cmd = '/laugh',     icon = 'laugh.png' },
    { key = 'no',        name = 'No',                    cmd = '/no',        icon = 'no.png' },
    { key = 'panic',     name = 'Panic',                 cmd = '/panic',     icon = 'panic.png' },
    { key = 'point',     name = 'Point',                 cmd = '/point',     icon = 'point.png' },
    { key = 'psych',     name = 'Psych',                 cmd = '/psych',     icon = 'psych.png' },
    { key = 'salute',    name = 'Salute',                cmd = '/salute',    icon = 'salute.png' },
    { key = 'shocked',   name = 'Shocked / Surprised',   cmd = '/shocked',   icon = 'shocked.png' },
    { key = 'sigh',      name = 'Sigh / Stagger / Sulk', cmd = '/sigh',      icon = 'sigh.png' },
    { key = 'sit',       name = 'Sit',                   cmd = '/sit',       icon = 'sit.png' },
    { key = 'sitchair',  name = 'Sitchair',              cmd = '/sitchair',  icon = 'sitchair.png' },
    { key = 'think',     name = 'Think',                 cmd = '/think',     icon = 'think.png' },
    { key = 'toss',      name = 'Toss',                  cmd = '/toss',      icon = 'toss.png' },
    { key = 'upset',     name = 'Upset',                 cmd = '/upset',     icon = 'upset.png' },
    { key = 'wave',      name = 'Wave',                  cmd = '/wave',      icon = 'wave.png' },
    { key = 'welcome',   name = 'Welcome',               cmd = '/welcome',   icon = 'welcome.png' },
    { key = 'yes',       name = 'Nod / Yes',             cmd = '/yes',       icon = 'yes.png' },
    { key = 'fume',      name = 'Fume',                  cmd = '/fume',      icon = 'fume.png' },
    { key = 'poke',      name = 'Poke',                  cmd = '/poke',      icon = 'poke.png' },
}

local JOBS = {
    { id =  1, abbr = 'WAR' },
    { id =  2, abbr = 'MNK' },
    { id =  3, abbr = 'WHM' },
    { id =  4, abbr = 'BLM' },
    { id =  5, abbr = 'RDM' },
    { id =  6, abbr = 'THF' },
    { id =  7, abbr = 'PLD' },
    { id =  8, abbr = 'DRK' },
    { id =  9, abbr = 'BST' },
    { id = 10, abbr = 'BRD' },
    { id = 11, abbr = 'RNG' },
    { id = 12, abbr = 'SAM' },
    { id = 13, abbr = 'NIN' },
    { id = 14, abbr = 'DRG' },
    { id = 15, abbr = 'SMN' },
    { id = 16, abbr = 'BLU' },
    { id = 17, abbr = 'COR' },
    { id = 18, abbr = 'PUP' },
    { id = 19, abbr = 'DNC' },
    { id = 20, abbr = 'SCH' },
    { id = 21, abbr = 'GEO' },
    { id = 22, abbr = 'RUN' },
}

-------------------------------------------------------------------------------
-- Data helpers
-------------------------------------------------------------------------------

local function get_job_levels()
    local out = {}
    pcall(function()
        local p = AshitaCore:GetMemoryManager():GetPlayer()
        if not p then return end
        for _, j in ipairs(JOBS) do
            out[j.id] = tonumber(p:GetJobLevel(j.id)) or 0
        end
    end)
    return out
end

local function apply_emote_defaults(st)
    st.emotes = st.emotes or {}
    for _, e in ipairs(EMOTES) do
        st.emotes[e.key] = st.emotes[e.key] or {}
        local t = st.emotes[e.key]
        if t.enabled == nil then t.enabled = true end
        if t.silent == nil then t.silent = false end
        if t.favored == nil then t.favored = false end
    end

    -- Column enable toggles (settings UI)
    if st.col_em_use_enabled == nil then st.col_em_use_enabled = true end
    if st.col_em_silent_enabled == nil then st.col_em_silent_enabled = true end
    if st.col_em_fav_enabled == nil then st.col_em_fav_enabled = true end
    if st.col_job_use_enabled == nil then st.col_job_use_enabled = true end
    if st.col_job_fav_enabled == nil then st.col_job_fav_enabled = true end

    st.jobemotes = st.jobemotes or {}
    for _, j in ipairs(JOBS) do
        local k = j.abbr:lower()
        st.jobemotes[k] = st.jobemotes[k] or {}
        local t = st.jobemotes[k]
        if t.enabled == nil then t.enabled = true end
        if t.favored == nil then t.favored = false end
    end
end

local function all_emotes_true(st, field)
    if type(st) ~= 'table' or type(st.emotes) ~= 'table' then
        return false
    end
    for _, e in ipairs(EMOTES) do
        local cfg = st.emotes[e.key]
        if type(cfg) ~= 'table' or cfg[field] ~= true then
            return false
        end
    end
    return true
end

local function set_all_emotes(st, field, v)
    if type(st) ~= 'table' or type(st.emotes) ~= 'table' then
        return
    end
    for _, e in ipairs(EMOTES) do
        local cfg = st.emotes[e.key]
        if type(cfg) ~= 'table' then
            cfg = { enabled = true, silent = false, favored = false }
            st.emotes[e.key] = cfg
        end
        cfg[field] = (v == true)
    end
    save_state()
end

-- Sorting (settings UI)
local function gb_sort_toggle(st, col)
    st._sort = st._sort or { col = 'name', asc = true }
    if st._sort.col == col then
        st._sort.asc = not (st._sort.asc == true)
    else
        st._sort.col = col
        st._sort.asc = true
    end
    save_state()
end

local function gb_sort_emotes_list(st)
    local list = {}
    local order = {}
    for i = 1, #EMOTES do
        list[i] = EMOTES[i]
        order[EMOTES[i]] = i
    end

    st._sort = st._sort or { col = 'name', asc = true }
    local col = tostring(st._sort.col or 'name')
    local asc = (st._sort.asc == true)

    local function bool_key(e, field)
        local cfg = st.emotes and st.emotes[e.key]
        return (type(cfg) == 'table' and cfg[field] == true) and 1 or 0
    end

    table.sort(list, function(a, b)
        -- Boolean column sorts: primary = checkbox value, tie = original EMOTES order (not name)
        if col == 'enabled' or col == 'silent' or col == 'favored' then
            local ka = bool_key(a, col)
            local kb = bool_key(b, col)

            if ka ~= kb then
                -- asc=true: true first; asc=false: false first
                return asc and (ka > kb) or (ka < kb)
            end

            local oa = order[a] or 0
            local ob = order[b] or 0
            if oa ~= ob then
                return oa < ob
            end
            return false
        end

        -- Name column sort (Emote header)
        local na = tostring(a.name or ''):lower()
        local nb = tostring(b.name or ''):lower()
        if na == nb then
            return false
        end
        return asc and (na < nb) or (na > nb)
    end)

    return list
end



local function tiny_checkbox(id, v)
    imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 1, 1 })
    imgui.PushStyleVar(ImGuiStyleVar_ItemSpacing, { 4, 2 })
    local changed = imgui.Checkbox(id, v)
    imgui.PopStyleVar(2)
    return changed
end

local function in_rect(mx, my, x1, y1, x2, y2)
    return mx >= x1 and mx <= x2 and my >= y1 and my <= y2
end

local function begin_disabled(disabled)
    if disabled ~= true then return false end
    if imgui.BeginDisabled ~= nil then
        imgui.BeginDisabled(true)
        return true
    end
    if imgui.PushItemFlag ~= nil and imgui.PushStyleVar ~= nil and ImGuiItemFlags_Disabled ~= nil and ImGuiStyleVar_Alpha ~= nil then
        imgui.PushItemFlag(ImGuiItemFlags_Disabled, true)
        imgui.PushStyleVar(ImGuiStyleVar_Alpha, imgui.GetStyle().Alpha * 0.5)
        return true
    end
    return false
end

local function end_disabled(pushed)
    if pushed ~= true then return end
    if imgui.EndDisabled ~= nil then
        imgui.EndDisabled()
        return
    end
    if imgui.PopItemFlag ~= nil and imgui.PopStyleVar ~= nil then
        imgui.PopStyleVar(1)
        imgui.PopItemFlag(1)
    end
end

local function small_checkbox(id, v)
    if imgui.PushStyleVar ~= nil and ImGuiStyleVar_FramePadding ~= nil then
        imgui.PushStyleVar(ImGuiStyleVar_FramePadding, { 1, 1 })
        local changed = imgui.Checkbox(id, v)
        imgui.PopStyleVar(1)
        return changed
    end
    return imgui.Checkbox(id, v)
end

local function queue_cmd(cmd)
    cmd = tostring(cmd or '')
    if cmd == '' then return end

    pcall(function()
        if AshitaCore and AshitaCore.GetChatManager then
            local cm = AshitaCore:GetChatManager()
            if cm and cm.QueueCommand then
                cm:QueueCommand(1, cmd)
                return
            end
        end
        if ashita and ashita.chat and ashita.chat.queue_command then
            ashita.chat.queue_command(1, cmd)
            return
        end
    end)
end

local function build_dropdown_list(st)
    local out = {}

    -- Emotes
    do
        local em = {}

        -- Primary: include enabled emotes
        for _, e in ipairs(EMOTES) do
            local cfg = st.emotes and st.emotes[e.key]
            if cfg and cfg.enabled == true then
                em[#em + 1] = e
            end
        end



        table.sort(em, function(a, b)
            local ca = (st.emotes and st.emotes[a.key]) or nil
            local cb = (st.emotes and st.emotes[b.key]) or nil
            local fa = (ca and ca.favored == true) and 1 or 0
            local fb = (cb and cb.favored == true) and 1 or 0
            if fa ~= fb then return fa > fb end
            return tostring(a.name or ''):lower() < tostring(b.name or ''):lower()
        end)

        for i = 1, #em do
            local e = em[i]
            out[#out + 1] = {
                kind = 'emote',
                key = e.key,
                name = e.name,
                cmd = e.cmd,
                icon = e.icon,
            }
        end
    end


    -- Job Emotes (only jobs with level > 0)
    do
        local levels = get_job_levels()
        local jobs = {}

        for _, j in ipairs(JOBS) do
            local lvl = tonumber(levels[j.id] or 0) or 0
            if lvl > 0 then
                local k = j.abbr:lower()
                local cfg = st.jobemotes and st.jobemotes[k]
                if type(cfg) ~= 'table' then cfg = {} end
                if cfg.enabled == true then
                    jobs[#jobs + 1] = {
                        abbr = j.abbr,
                        key = k,
                        favored = (cfg.favored == true),
                        icon = k .. '.png',
                    }

                end
            end
        end

        table.sort(jobs, function(a, b)
            local fa = a.favored and 1 or 0
            local fb = b.favored and 1 or 0
            if fa ~= fb then return fa > fb end
            return a.abbr:lower() < b.abbr:lower()
        end)

        if #jobs > 0 then
            out[#out + 1] = { kind = 'sep', name = 'Job Emotes' }
            for i = 1, #jobs do
                local j = jobs[i]
                out[#out + 1] = {
                    kind = 'job',
                    key = j.key,
                    name = j.abbr,
                    cmd = '/jobemote ' .. j.key,
                    icon = j.icon,
                }
            end
        end
    end

    return out
end


local function get_avail_w()
    local a = imgui.GetContentRegionAvail()
    if type(a) == 'table' then
        return a[1] or 0
    end
    return tonumber(a) or 0
end

local function get_screen_size()
    local sw = 1920
    local sh = 1080

    pcall(function()
        if imgui ~= nil and type(imgui.GetIO) == 'function' then
            local io = imgui.GetIO()
            if io ~= nil then
                local ds = io.DisplaySize or io.display_size
                if type(ds) == 'table' then
                    sw = tonumber(ds.x or ds[1] or sw) or sw
                    sh = tonumber(ds.y or ds[2] or sh) or sh
                elseif ds ~= nil then
                    sw = tonumber(ds.x or sw) or sw
                    sh = tonumber(ds.y or sh) or sh
                end
            end
        end
    end)

    return sw, sh
end

local function clamp_dropdown_position(x, y, w, h)
    local sw, sh = get_screen_size()

    if x + w > sw then x = sw - w - 4 end
    if y + h > sh then y = sh - h - 4 end
    if x < 4 then x = 4 end
    if y < 4 then y = 4 end

    return x, y
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

-------------------------------------------------------------------------------
-- Plugin definition
-------------------------------------------------------------------------------

local M = {
    id   = 'emote',
    name = 'Emote',

    default = {
        bar = 'top',
        x = 24,
        y = 8,
        w = 220,
        h = 34,
    },

    settings_defaults = {
        dropdown_open = false,

        dropdown_w      = 240,
        dropdown_h      = 320,
        dropdown_line_h = 18,

        x = 0,
        y = 0,

        display_mode = 'text',
        display_icon = 'amazed.png',
        display_icon_size = 26,

        icon_size = 26,
        font_name = 'default',
        font_px = 14,
        font_scale = 1.0,

        bar_font_scale = 1.0,

        emotes = {},
        jobemotes = {},
    },

}

-------------------------------------------------------------------------------
-- Dropdown renderer (ImGui window)
-- NOTE: This is called from d3d_present, not from M.render.
-------------------------------------------------------------------------------

local function gb_em_draw_dropdown(st)

    if st.dropdown_open ~= true then
        return
    end


    local rt = st._gb_em_rt
    if type(rt) ~= 'table' then
        return
    end

    local lineh = tonumber(st.dropdown_line_h) or 18
    local rowgap = 8
    local rowh  = lineh + rowgap
    local top_inset = 4

    local w = tonumber(st.dropdown_w) or 240
    if w < 160 then w = 160 end
    if w > 520 then w = 520 end

    local h = tonumber(st.dropdown_h or 320) or 320
    if h < 120 then h = 120 end
    if h > 700 then h = 700 end

    local wx = tonumber(rt.px1) or 0
    local wy = tonumber(rt.py1) or 0

    imgui.SetNextWindowPos({ wx, wy }, ImGuiCond_Always)
    imgui.SetNextWindowSize({ w, h }, ImGuiCond_Always)

    local win_flags = bit.bor(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoMove,
        ImGuiWindowFlags_NoSavedSettings,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground
    )

    -- Golden brown selection
    imgui.PushStyleColor(ImGuiCol_Header,        { 0.62, 0.44, 0.20, 1.00 })
    imgui.PushStyleColor(ImGuiCol_HeaderHovered, { 0.70, 0.50, 0.22, 1.00 })
    imgui.PushStyleColor(ImGuiCol_HeaderActive,  { 0.76, 0.55, 0.24, 1.00 })

    local dd_font = resolve_font_family_size(st.font_name, st.font_px, nil)
    if dd_font ~= nil then imgui.PushFont(dd_font) end

    if imgui.Begin('##gb_emote_dropdown', { true }, win_flags) then

        imgui.SetWindowFontScale(tonumber(st.font_scale or 1.0) or 1.0)


        local list = build_dropdown_list(st)
        if type(list) ~= 'table' then
            list = {}
        end



        if imgui.BeginChild('##gb_emote_dropdown_list', { 0, 0 }, false) then
            imgui.SetCursorPosY(imgui.GetCursorPosY() + top_inset)

            local a = imgui.GetContentRegionAvail()
            local avail_w = 0
            if type(a) == 'table' then
                avail_w = tonumber(a[1] or a.x or 0) or 0
            else
                avail_w = tonumber(a) or 0
            end

            local icon = tonumber(st.icon_size or 18) or 18
            if icon < 12 then icon = 12 end
            if icon > 48 then icon = 48 end

            for i, e in ipairs(list) do
                local start_x = imgui.GetCursorPosX()
                local start_y = imgui.GetCursorPosY()
                local text_h  = imgui.GetTextLineHeight()

                if e.kind == 'sep' then
                    imgui.SetCursorPosX(start_x + 6)
                    imgui.SetCursorPosY(start_y + ((rowh - text_h) * 0.5))
                    imgui.Text(tostring(e.name or ''))
                    imgui.SetCursorPosY(start_y + rowh)
                else
                    if imgui.Selectable('##gb_em_pick_' .. tostring(e.kind) .. '_' .. tostring(e.key) .. '_' .. tostring(i), false, 0, { avail_w, rowh }) then
                        local cmd = tostring(e.cmd or '')
                        if e.kind == 'emote' then
                            local cfg = st.emotes[e.key] or {}
                            if cfg.silent == true then
                                cmd = cmd .. ' motion'
                            end
                        end
                        queue_cmd(cmd)
                        st.dropdown_open = false
                        save_state()
                    end

                    imgui.SetCursorPosX(start_x + 6)
                    imgui.SetCursorPosY(start_y)

                    local ih = nil
                    if e.icon ~= nil and e.icon ~= '' then
                        ih = load_texture_handle(emote_icon_path(e.icon))
                    end
                    if ih ~= nil then
                        imgui.SetCursorPosY(start_y + ((rowh - icon) * 0.5))
                        imgui.Image(ih, { icon, icon })
                        imgui.SetCursorPosY(start_y)
                        imgui.SameLine()
                    end

                    imgui.SetCursorPosY(start_y + ((rowh - text_h) * 0.5))
                    imgui.Text(tostring(e.name or ''))
                end


                imgui.SetCursorPosY(start_y + rowh)
            end

            imgui.EndChild()
        end

        imgui.SetWindowFontScale(1.0)
    end

    imgui.End()
    if dd_font ~= nil then imgui.PopFont() end
    imgui.PopStyleColor(3)
end

-------------------------------------------------------------------------------
-- Present hook: keeps dropdown alive even when bar collapses
-------------------------------------------------------------------------------

local function gb_emote_present()
    if imgui == nil
        or type(imgui.GetIO) ~= 'function'
        or type(imgui.Begin) ~= 'function'
        or type(imgui.End) ~= 'function'
    then
        return
    end

	local st = load_state(M.settings_defaults)
    apply_emote_defaults(st)
    M._st = st

    if st.dropdown_open ~= true then
        return
    end

    if type(st._gb_em_rt) ~= 'table' then
        return
    end

    gb_em_draw_dropdown(st)
end

local function ensure_present_hook()
    -- No-op: d3d_present is owned by the host (gobbiebars.lua).
end


-------------------------------------------------------------------------------
-- Main bar render: draw label and toggle dropdown; update dropdown anchor
-------------------------------------------------------------------------------

function M.render(dl, rect, settings)
    ensure_present_hook()

    if imgui == nil
        or type(imgui.GetMousePos) ~= 'function'
        or type(imgui.IsMouseClicked) ~= 'function'
    then
        return
    end

    local st = load_state(M.settings_defaults)
    apply_emote_defaults(st)


    -- Safe mouse position (Ashita imgui can return numbers or a table)
    local mx, my = 0, 0
    do
        local a, b = imgui.GetMousePos()
        if type(a) == 'number' and type(b) == 'number' then
            mx, my = a, b
        elseif type(a) == 'table' then
            mx = tonumber(a.x or a[1] or 0) or 0
            my = tonumber(a.y or a[2] or 0) or 0
        end
    end

    local ox = tonumber(st.x or 0) or 0
    local oy = tonumber(st.y or 0) or 0

    local x = rect.content_x + 8 + ox
    local y = rect.content_y + 4 + oy

    local display_mode = tostring(st.display_mode or 'text')
    if display_mode ~= 'text' and display_mode ~= 'icon' then
        display_mode = 'text'
    end

    local click_w = 1
    local click_h = 22
    local display_text = 'Emote'

    local function gb_em_text_w(txt)
        txt = tostring(txt or '')
        if imgui.CalcTextSize ~= nil then
            local a, b = imgui.CalcTextSize(txt)
            if type(a) == 'number' then
                return tonumber(a or 0) or 0
            elseif type(a) == 'table' then
                return tonumber(a.x or a[1] or 0) or 0
            end
        end
        return #txt * 8
    end

    if display_mode == 'icon' then
        local icon_size = tonumber(st.display_icon_size or 26) or 26
        if icon_size < 12 then icon_size = 12 end
        if icon_size > 64 then icon_size = 64 end

        click_w = icon_size
        click_h = icon_size

        if dl ~= nil then
            local ih = load_texture_handle(emote_icon_path(st.display_icon or 'amazed.png'))
            if ih ~= nil and dl.AddImage ~= nil then
                dl:AddImage(ih, { x, y }, { x + icon_size, y + icon_size })
            else
                dl:AddText({ x, y }, col32(255, 255, 255, 255), display_text)
            end
        end
    else
        -- Header label (scaled)
        local bar_scale = tonumber(st.bar_font_scale or 1.0) or 1.0
        if bar_scale < 0.75 then bar_scale = 0.75 end
        if bar_scale > 2.00 then bar_scale = 2.00 end

        click_w = math.floor((gb_em_text_w(display_text) * bar_scale) + 0.5)
        if click_w < 1 then click_w = 1 end

        click_h = math.floor((18 * bar_scale) + 0.5)
        if click_h < 12 then click_h = 12 end

        if dl ~= nil then
            if imgui.SetWindowFontScale ~= nil then
                imgui.SetWindowFontScale(bar_scale)
            end
            dl:AddText({ x, y }, col32(255, 255, 255, 255), display_text)
            if imgui.SetWindowFontScale ~= nil then
                imgui.SetWindowFontScale(1.0)
            end
        end
    end

    -- Toggle dropdown by clicking display area
    local cx1 = x - 2
    local cx2 = x + click_w + 2
    local cy1 = y - 2
    local cy2 = y + click_h + 2

    if imgui.IsMouseClicked ~= nil and in_rect(mx, my, cx1, cy1, cx2, cy2) and imgui.IsMouseClicked(0) then
        st.dropdown_open = not (st.dropdown_open == true)
        save_state()
    end

    if st.dropdown_open ~= true then
        return
    end

    local area = 'top'
    if type(settings) == 'table' and type(settings.bar) == 'string' then
        area = settings.bar
    end

    if area ~= 'top' and area ~= 'bottom' and area ~= 'left' and area ~= 'right' and area ~= 'screen' then
        area = 'top'
    end

    local dw = tonumber(st.dropdown_w or 240) or 240
    local dh = tonumber(st.dropdown_h or 320) or 320

    if dw < 160 then dw = 160 end
    if dw > 520 then dw = 520 end
    if dh < 120 then dh = 120 end
    if dh > 700 then dh = 700 end

    local px = x
    local py = y + click_h + 4

    if area == 'bottom' then
        px = x
        py = y - dh - 4
    elseif area == 'left' then
        px = x + click_w + 8
        py = y
    elseif area == 'right' then
        px = x - dw - 8
        py = y
    elseif area == 'screen' then
        px = x
        py = y + click_h + 4
    end

    px, py = clamp_dropdown_position(px, py, dw, dh)

    -- Update anchor every frame while bar is visible.
    st._gb_em_rt = st._gb_em_rt or {}
    st._gb_em_rt.px1 = px
    st._gb_em_rt.py1 = py
end

-------------------------------------------------------------------------------
-- Settings UI (kept as-is)
-------------------------------------------------------------------------------

function M.draw_settings_ui(settings)
    local st = load_state(M.settings_defaults)
    apply_emote_defaults(st)

    -- Ensure emote defaults exist before any sorting / table render.
    st.emotes = st.emotes or {}
    for _, e in ipairs(EMOTES) do
        st.emotes[e.key] = st.emotes[e.key] or { enabled = true, silent = false, favored = false }
        local t = st.emotes[e.key]
        if t.enabled == nil then t.enabled = true end
        if t.silent == nil then t.silent = false end
        if t.favored == nil then t.favored = false end
    end

    st.x = tonumber(st.x or 0) or 0
    st.y = tonumber(st.y or 0) or 0
    st.font_name = tostring(st.font_name or 'default')
    if st.font_name == '' then st.font_name = 'default' end
    st.font_px = tonumber(st.font_px or 14) or 14
    if st.font_px < 8 then st.font_px = 8 end
    if st.font_px > 24 then st.font_px = 24 end

    local function header_yellow(text)
        imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.90, 0.70, 1.0 })
        if imgui.TextUnformatted then imgui.TextUnformatted(text) else imgui.Text(text) end
        imgui.PopStyleColor(1)
    end

    -- space between "Active" and first line
    imgui.Spacing()
    imgui.Spacing()

    local display_mode = tostring(st.display_mode or 'text')
    if display_mode ~= 'text' and display_mode ~= 'icon' then
        display_mode = 'text'
    end

    local display_label = 'Text'
    if display_mode == 'icon' then display_label = 'Icon' end

    header_yellow('General:')

    local host_settings = settings
    if type(host_settings) ~= 'table' then
        host_settings = {}
    end

    local cur_area = tostring(host_settings.bar or M.default.bar or 'top')
    if cur_area ~= 'top' and cur_area ~= 'bottom' and cur_area ~= 'left' and cur_area ~= 'right' and cur_area ~= 'screen' then
        cur_area = 'top'
    end

    local area_label = cur_area
    if cur_area == 'top' then area_label = 'Top' end
    if cur_area == 'bottom' then area_label = 'Bottom' end
    if cur_area == 'left' then area_label = 'Left' end
    if cur_area == 'right' then area_label = 'Right' end
    if cur_area == 'screen' then area_label = 'Screen' end

    imgui.Text('Area')
    imgui.SameLine()
    imgui.SetNextItemWidth(160)

    if imgui.BeginCombo('##gb_em_area', area_label, ImGuiComboFlags_None) then
        if imgui.Selectable('Top', cur_area == 'top') then host_settings.bar = 'top' end
        if imgui.Selectable('Bottom', cur_area == 'bottom') then host_settings.bar = 'bottom' end
        if imgui.Selectable('Left', cur_area == 'left') then host_settings.bar = 'left' end
        if imgui.Selectable('Right', cur_area == 'right') then host_settings.bar = 'right' end
        if imgui.Selectable('Screen', cur_area == 'screen') then host_settings.bar = 'screen' end
        imgui.EndCombo()
    end

    imgui.Text('Display')
    imgui.SameLine()
    imgui.SetNextItemWidth(160)

    if imgui.BeginCombo('##gb_em_display_mode', display_label, ImGuiComboFlags_None) then
        if imgui.Selectable('Text', display_mode == 'text') then
            st.display_mode = 'text'
            save_state()
        end
        if imgui.Selectable('Icon', display_mode == 'icon') then
            st.display_mode = 'icon'
            st.display_icon = 'amazed.png'
            save_state()
        end
        imgui.EndCombo()
    end

    imgui.SameLine()
    imgui.Text('Display Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(140)

    local display_size_mode = tostring(st.display_mode or 'text')
    if display_size_mode ~= 'text' and display_size_mode ~= 'icon' then
        display_size_mode = 'text'
    end

    if display_size_mode == 'icon' then
        local disz = { tonumber(st.display_icon_size or 26) or 26 }
        if disz[1] < 12 then disz[1] = 12 end
        if disz[1] > 64 then disz[1] = 64 end

        if imgui.SliderInt('##gb_em_display_icon_size', disz, 12, 64) then
            st.display_icon_size = tonumber(disz[1] or 26) or 26
            save_state()
        end
    else
        local dfs = { tonumber(st.bar_font_scale or 1.0) or 1.0 }

        if imgui.SliderFloat('##gb_em_display_text_size', dfs, 0.75, 2.00, '%.2f') then
            st.bar_font_scale = tonumber(dfs[1] or 1.0) or 1.0
            save_state()
        end
    end

    imgui.Text('Position')
    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local vx = { st.x }
    if imgui.InputInt('X##gb_em_x', vx) then
        st.x = tonumber(vx[1] or 0) or 0
        save_state()
    end

    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local vy = { st.y }
    if imgui.InputInt('Y##gb_em_y', vy) then
        st.y = tonumber(vy[1] or 0) or 0
        save_state()
    end

    imgui.Separator()

    header_yellow('List:')

    local col_label_w = 90
    local col_slider_w = 140
    local col_gap = 60
    local col2_x = col_label_w + col_slider_w + col_gap

    imgui.AlignTextToFramePadding()
    imgui.Text('Width')
    imgui.SameLine(col_label_w)
    imgui.SetNextItemWidth(col_slider_w)
    local dw = { tonumber(st.dropdown_w or 240) or 240 }
    if imgui.SliderInt('##gb_em_dropdown_w', dw, 160, 520) then
        st.dropdown_w = tonumber(dw[1] or 240) or 240
        save_state()
    end

    imgui.SameLine(col2_x)
    imgui.AlignTextToFramePadding()
    imgui.Text('Height')
    imgui.SameLine(col2_x + col_label_w)
    imgui.SetNextItemWidth(col_slider_w)
    local dh = { tonumber(st.dropdown_h or 320) or 320 }
    if imgui.SliderInt('##gb_em_dropdown_h', dh, 120, 700) then
        st.dropdown_h = tonumber(dh[1] or 320) or 320
        save_state()
    end

    imgui.AlignTextToFramePadding()
    imgui.Text('Icon Size')
    imgui.SameLine(col_label_w)
    imgui.SetNextItemWidth(col_slider_w)
    local isz = { tonumber(st.icon_size or 18) or 18 }
    if isz[1] < 12 then isz[1] = 12 end
    if imgui.SliderInt('##gb_em_icon_size', isz, 12, 48) then
        if isz[1] < 12 then isz[1] = 12 end
        st.icon_size = isz[1]
        save_state()
    end

    imgui.Text('Font')
    imgui.SameLine(col_label_w)
    imgui.SetNextItemWidth(180)

    local cur_font = tostring(st.font_name or 'default')
    if cur_font == '' then cur_font = 'default' end

    if imgui.BeginCombo('##gb_em_font_name', cur_font, ImGuiComboFlags_None) then
        if imgui.Selectable('default', cur_font == 'default') then
            st.font_name = 'default'
            cur_font = 'default'
            save_state()
        end

        local names = build_sorted_font_names()
        for _, name in ipairs(names) do
            if imgui.Selectable(name, cur_font == name) then
                st.font_name = name
                cur_font = name
                save_state()
            end
        end

        imgui.EndCombo()
    end

    imgui.SameLine(col2_x)
    imgui.AlignTextToFramePadding()
    imgui.Text('Font Size')
    imgui.SameLine(col2_x + col_label_w)
    imgui.SetNextItemWidth(col_slider_w)
    local fpx = { tonumber(st.font_px or 14) or 14 }
    if fpx[1] < 8 then fpx[1] = 8 end
    if fpx[1] > 24 then fpx[1] = 24 end
    if imgui.SliderInt('##gb_em_font_px', fpx, 8, 24) then
        st.font_px = tonumber(fpx[1] or 14) or 14
        save_state()
    end

    imgui.Separator()
    header_yellow('Emotes:')
    imgui.Separator()


    local left_pad = 12


    local label_scale = 0.85
    local can_scale = (imgui.SetWindowFontScale ~= nil)

    local icon = tonumber(st.icon_size or 26) or 26
    if icon < 12 then icon = 12 end
    if icon > 48 then icon = 48 end

    if imgui.BeginTable ~= nil and imgui.BeginTable('##gb_em_table', 4, bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerV, ImGuiTableFlags_SizingFixedFit)) then

        imgui.TableSetupColumn('Use',    ImGuiTableColumnFlags_WidthFixed, 40)
        imgui.TableSetupColumn('Silent', ImGuiTableColumnFlags_WidthFixed, 52)
        imgui.TableSetupColumn('Fav',    ImGuiTableColumnFlags_WidthFixed, 40)
        imgui.TableSetupColumn('Emote',  ImGuiTableColumnFlags_WidthStretch)

        -- Sort state (manual)
        st._sort = st._sort or { col = 'name', asc = true }

        -- Header row (only Emote sorts)
        imgui.TableNextRow(ImGuiTableRowFlags_Headers)

        local function gb_name_label()
            if st._sort ~= nil and st._sort.col == 'name' then
                local arrow = (st._sort.asc == true) and '^' or 'v'
                return 'Emote ' .. arrow
            end
            return 'Emote'
        end

        imgui.TableSetColumnIndex(0)
        imgui.Text('Use')
        if imgui.IsItemHovered() then
            imgui.BeginTooltip()
            imgui.Text('Use: show this emote in the dropdown list.')
            imgui.EndTooltip()
        end

        imgui.TableSetColumnIndex(1)
        imgui.Text('Silent')
        if imgui.IsItemHovered() then
            imgui.BeginTooltip()
            imgui.Text('Silent: adds "motion" so the emote plays without chat text.')
            imgui.EndTooltip()
        end

        imgui.TableSetColumnIndex(2)
        imgui.Text('Fav')
        if imgui.IsItemHovered() then
            imgui.BeginTooltip()
            imgui.Text('Fav: pins this emote to the top of the dropdown.')
            imgui.EndTooltip()
        end

        imgui.TableSetColumnIndex(3)
        local w3 = imgui.GetColumnWidth()
        if imgui.Selectable(gb_name_label() .. '##gb_em_sort_name', false, 0, { w3, 0 }) then gb_sort_toggle(st, 'name') end
        if imgui.IsItemHovered() then
            imgui.BeginTooltip()
            imgui.Text('Emote: sort by name.')
            imgui.EndTooltip()
        end




        -- Header row (toggle all)
        imgui.TableNextRow()
        imgui.TableSetColumnIndex(0)
        imgui.SetCursorPosX(imgui.GetCursorPosX() + left_pad)
        local h_use = { all_emotes_true(st, 'enabled') }
        if tiny_checkbox('##gb_em_all_use', h_use) then set_all_emotes(st, 'enabled', h_use[1]) end

        imgui.TableSetColumnIndex(1)
        local h_sil = { all_emotes_true(st, 'silent') }
        if tiny_checkbox('##gb_em_all_silent', h_sil) then set_all_emotes(st, 'silent', h_sil[1]) end

        imgui.TableSetColumnIndex(2)
        local h_fav = { all_emotes_true(st, 'favored') }
        if tiny_checkbox('##gb_em_all_fav', h_fav) then set_all_emotes(st, 'favored', h_fav[1]) end

        imgui.TableSetColumnIndex(3)
        if can_scale then imgui.SetWindowFontScale(label_scale) end
        imgui.TextDisabled('All')
        if can_scale then imgui.SetWindowFontScale(1.0) end

        local sorted_emotes = EMOTES
        local ok_sort, tmp = pcall(gb_sort_emotes_list, st)
        if ok_sort and type(tmp) == 'table' then
            sorted_emotes = tmp
        end

        for _, e in ipairs(sorted_emotes) do
            local cfg = st.emotes[e.key]

            if cfg == nil then
                st.emotes[e.key] = { enabled = true, silent = false, favored = false }
                cfg = st.emotes[e.key]
            end

            imgui.TableNextRow()

            imgui.TableSetColumnIndex(0)
            imgui.SetCursorPosX(imgui.GetCursorPosX() + left_pad)
            local en = { cfg.enabled == true }
            if tiny_checkbox('##gb_em_en_' .. e.key, en) then cfg.enabled = en[1]; save_state() end

            imgui.TableSetColumnIndex(1)
            local sl = { cfg.silent == true }
            if tiny_checkbox('##gb_em_sil_' .. e.key, sl) then cfg.silent = sl[1]; save_state() end

            imgui.TableSetColumnIndex(2)
            local fv = { cfg.favored == true }
            if tiny_checkbox('##gb_em_fav_' .. e.key, fv) then cfg.favored = fv[1]; save_state() end

            imgui.TableSetColumnIndex(3)
            local ih = load_texture_handle(emote_icon_path(e.icon))
            if ih ~= nil then
                imgui.Image(ih, { icon, icon })
                imgui.SameLine()
            end
            imgui.Text(e.name)
        end

        imgui.EndTable()
    end


    -- Job Emotes
    imgui.Separator()
    imgui.Text('Job Emotes')
    imgui.Separator()

    local levels = get_job_levels()

    local function all_job_true(field)
        for _, j in ipairs(JOBS) do
            local lvl = tonumber(levels[j.id] or 0) or 0
            if lvl > 0 then
                local key = j.abbr:lower()
                local cfg = st.jobemotes and st.jobemotes[key]
                if type(cfg) ~= 'table' or cfg[field] ~= true then
                    return false
                end
            end
        end
        return true
    end

    local function set_all_job(field, v)
        for _, j in ipairs(JOBS) do
            local lvl = tonumber(levels[j.id] or 0) or 0
            if lvl > 0 then
                local key = j.abbr:lower()
                st.jobemotes[key] = st.jobemotes[key] or { enabled = true, favored = false }
                st.jobemotes[key][field] = (v == true)
            end
        end
        save_state()
    end

    if imgui.BeginTable ~= nil and imgui.BeginTable('##gb_em_job_table', 3, bit.bor(ImGuiTableFlags_RowBg, ImGuiTableFlags_BordersInnerV, ImGuiTableFlags_SizingFixedFit)) then
        imgui.TableSetupColumn('Use', ImGuiTableColumnFlags_WidthFixed, 40)
        imgui.TableSetupColumn('Fav', ImGuiTableColumnFlags_WidthFixed, 40)
        imgui.TableSetupColumn('Job', ImGuiTableColumnFlags_WidthStretch)
        imgui.TableHeadersRow()

        -- Header row (toggle all)
        imgui.TableNextRow()
        imgui.TableSetColumnIndex(0)
        imgui.SetCursorPosX(imgui.GetCursorPosX() + left_pad)
        local hj_use = { all_job_true('enabled') }
        if tiny_checkbox('##gb_emj_all_use', hj_use) then set_all_job('enabled', hj_use[1]) end

        imgui.TableSetColumnIndex(1)
        local hj_fav = { all_job_true('favored') }
        if tiny_checkbox('##gb_emj_all_fav', hj_fav) then set_all_job('favored', hj_fav[1]) end

        imgui.TableSetColumnIndex(2)
        if can_scale then imgui.SetWindowFontScale(label_scale) end
        imgui.TextDisabled('All')
        if can_scale then imgui.SetWindowFontScale(1.0) end

        for _, j in ipairs(JOBS) do
            local lvl = tonumber(levels[j.id] or 0) or 0
            if lvl > 0 then
                local key = j.abbr:lower()
                local cfg = st.jobemotes[key]
                if cfg == nil then
                    st.jobemotes[key] = { enabled = true, favored = false }
                    cfg = st.jobemotes[key]
                end

                imgui.TableNextRow()

                imgui.TableSetColumnIndex(0)
                imgui.SetCursorPosX(imgui.GetCursorPosX() + left_pad)
                local en = { cfg.enabled == true }
                if tiny_checkbox('##gb_emj_en_' .. key, en) then cfg.enabled = en[1]; save_state() end

                imgui.TableSetColumnIndex(1)
                local fv = { cfg.favored == true }
                if tiny_checkbox('##gb_emj_fav_' .. key, fv) then cfg.favored = fv[1]; save_state() end

                imgui.TableSetColumnIndex(2)

                local jicon = load_texture_handle(emote_icon_path(key .. '.png'))
                if jicon ~= nil then
                    imgui.Image(jicon, { icon, icon })
                    imgui.SameLine()
                end

                imgui.Text(string.format('%s', j.abbr, key))

            end
        end

        imgui.EndTable()
    end

end

function M.present(settings, layout_mode)
    gb_emote_present()
end

-- Command: /emote [open|close|toggle]
ashita.events.register('command', 'gb_emote_command', function(e)
    local args = e.command:args()
    if not args or #args == 0 then
        return
    end

    local cmd = tostring(args[1] or ''):lower()
    if cmd ~= '/emote' then
        return
    end

    e.blocked = true

    local st = M._st or load_state(M.settings_defaults)
    apply_emote_defaults(st)

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

