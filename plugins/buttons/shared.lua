-------------------------------------------------------------------------------
-- GobbieBars - Buttons (shared)
-- File: Ashita/addons/gobbiebars/plugins/buttons/shared.lua
-------------------------------------------------------------------------------

require('common')

pcall(function()
    local mm = AshitaCore:GetMemoryManager()
    if not mm then return end

    local mt = getmetatable(mm)
    local idx = mt and mt.__index or nil
    if not idx then
        return
    end

    -- (intentional no-op scan; left as-is)
    for k, v in pairs(idx) do
        if type(v) == 'function' and tostring(k):lower():find('recast', 1, true) then
            -- placeholder
        end
    end
end)

local imgui = require('imgui')
local bit   = require('bit')
local ffi   = require('ffi')
local d3d8  = require('d3d8')

local gb_texcache  = require('texturecache')
local struct       = require('struct')
local player_state = require('state.player')
local skillchain = nil
do
    local ok_sc, mod = pcall(require, 'state.skillchain')
    if ok_sc and mod ~= nil then
        skillchain = mod
        -- (no-op) removed chat spam

    else
        print('[GobbieBars][buttons] skillchain module FAILED to load: ' .. tostring(mod))
    end
end


ffi.cdef[[
typedef void*               LPVOID;
typedef const char*         LPCSTR;
typedef struct IDirect3DTexture8 IDirect3DTexture8;
typedef long                HRESULT;
HRESULT D3DXCreateTextureFromFileA(LPVOID pDevice, LPCSTR pSrcFile, IDirect3DTexture8** ppTexture);

unsigned long long GetTickCount64(void);
]]

local M = {}

-------------------------------------------------------------------------------
-- Debug flags
-------------------------------------------------------------------------------
-- DEBUG: spell picker instrumentation (set false after fix)
local GB_DEBUG_SPELL_PICKER = false

-------------------------------------------------------------------------------
-- Forward declarations
-------------------------------------------------------------------------------
local EDIT = nil

-------------------------------------------------------------------------------
-- Commands module loader (commands.lua sits next to this file)
-------------------------------------------------------------------------------
local function load_commands_module()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then src = src:sub(2) end
    local base = src:match('^(.*[\\/])') or './'

    local p = base .. 'commands.lua'
    local ok, chunk = pcall(loadfile, p)
    if not ok or not chunk then
        return { CW = {}, ACE = {}, WEW = {} }
    end

    local ok2, mod = pcall(chunk)
    if not ok2 or type(mod) ~= 'table' then
        return { CW = {}, ACE = {}, WEW = {} }
    end

    mod.CW  = (type(mod.CW)  == 'table') and mod.CW  or {}
    mod.ACE = (type(mod.ACE) == 'table') and mod.ACE or {}
    mod.WEW = (type(mod.WEW) == 'table') and mod.WEW or {}
    return mod
end

local COMMANDS = load_commands_module()

-------------------------------------------------------------------------------
-- Macro queue (multi-line + /wait support) - wall clock ms
-------------------------------------------------------------------------------
-- Each entry: { cmd = "text", at_ms = <GetTickCount64 when to send> }
local macro_queue = {}
local macro_last_tick_ms = 0
local macro_tick_registered = false

local function now_ms()
    local v = 0

    local ok, r = pcall(function()
        return ffi.C.GetTickCount64()
    end)
    if ok then
        v = tonumber(r) or 0
    end

    -- Fallback: if GetTickCount64 is unavailable / returns 0, use os.clock().
    -- This is still good enough for pulsing animations.
    if v <= 0 then
        v = math.floor((tonumber(os.clock() or 0) or 0) * 1000.0)
    end

    return v
end


-- 0..1 pulse using a sine wave
local function pulse01(period_ms)
    period_ms = tonumber(period_ms or 800) or 800
    if period_ms <= 0 then period_ms = 800 end
    local t = (now_ms() % period_ms) / period_ms
    return (math.sin(t * (2.0 * math.pi)) + 1.0) * 0.5
end


local function dispatch_cmd(cmd)
    if type(cmd) ~= 'string' then return end
    cmd = cmd:gsub('^%s+', ''):gsub('%s+$', '')
    if cmd == '' then return end

    -- Windower-style: "input /echo <payload>" -> "<payload>"
    do
        local payload = cmd:match('^input%s+/?echo%s+(.+)$')
        if payload then
            cmd = payload:gsub('^%s+', ''):gsub('%s+$', '')
        end
    end

    local lower = cmd:lower()
    if lower:match('^https?://') or lower:match('^discord://') then
        pcall(function()
            os.execute('start "" "' .. tostring(cmd) .. '"')
        end)
        return
    end

    local cm = nil
    pcall(function() cm = AshitaCore:GetChatManager() end)
    if cm and cm.QueueCommand then
        -- IMPORTANT: Ashita expects an integer delay here.
        cm:QueueCommand(0, cmd)
    end
end

local function enqueue_macro(text)
    if type(text) ~= 'string' or text == '' then
        return
    end

    -- Start fresh each time; prevents leftovers from older macros.
    macro_queue = {}

    -- Normalize CRLF
    text = text:gsub('\r\n', '\n')

    local base = now_ms()
    local offset = 0

    for line in text:gmatch('([^\n]+)') do
        line = line:gsub('^%s+', ''):gsub('%s+$', '')
        if line ~= '' then
            -- Allow ; chaining like old addon
            for part in line:gmatch('([^;]+)') do
                local cmd = part:gsub('^%s+', ''):gsub('%s+$', '')
                if cmd ~= '' then
                    local wait_s = cmd:match('^/wait%s+([%d%.]+)%s*$')
                    if wait_s then
                        local s = tonumber(wait_s) or 0
                        if s < 0 then s = 0 end
                        offset = offset + math.floor((s * 1000) + 0.5)
                    else
                        macro_queue[#macro_queue + 1] = { cmd = cmd, at_ms = base + offset }
                    end
                end
            end
        end
    end
end

local function process_macro_queue()
    if #macro_queue == 0 then
        return
    end

    local now = now_ms()

    -- Prevent multiple sends inside the same ms (render_bar can be called multiple times)
    if now == macro_last_tick_ms then
        return
    end
    macro_last_tick_ms = now

    -- Send at most 1 command per tick
    local e = macro_queue[1]
    if not e or not e.at_ms or e.at_ms > now then
        return
    end

    table.remove(macro_queue, 1)
    dispatch_cmd(e.cmd or '')
end

local function ensure_macro_tick_registered()
    if macro_tick_registered then return end
    if not ashita then return end

    local function tick()
        process_macro_queue()
    end

    if ashita.events and type(ashita.events.register) == 'function' then
        pcall(function() ashita.events.register('d3d_present',   'gb_buttons_macro_tick_present', tick) end)
        pcall(function() ashita.events.register('d3d_end_scene', 'gb_buttons_macro_tick_end',     tick) end)
        pcall(function() ashita.events.register('d3d_begin_scene','gb_buttons_macro_tick_begin',  tick) end)
        macro_tick_registered = true
        return
    end

    if type(ashita.register_event) == 'function' then
        pcall(function() ashita.register_event('d3d_present',    'gb_buttons_macro_tick_present', tick) end)
        pcall(function() ashita.register_event('d3d_end_scene',  'gb_buttons_macro_tick_end',     tick) end)
        pcall(function() ashita.register_event('d3d_begin_scene','gb_buttons_macro_tick_begin',   tick) end)
        macro_tick_registered = true
        return
    end
end

-------------------------------------------------------------------------------
-- Colors / textures
-------------------------------------------------------------------------------
local function col32(r, g, b, a)
    r = bit.band(r or 255, 0xFF)
    g = bit.band(g or 255, 0xFF)
    b = bit.band(b or 255, 0xFF)
    a = bit.band(a or 255, 0xFF)
    return bit.bor(r, bit.lshift(g, 8), bit.lshift(b, 16), bit.lshift(a, 24))
end

local function col_from_tbl(t, fallback)
    if type(t) ~= 'table' then t = fallback end
    local r = tonumber(t[1] or 0) or 0
    local g = tonumber(t[2] or 0) or 0
    local b = tonumber(t[3] or 0) or 0
    local a = tonumber(t[4] or 0) or 0
    return col32(r, g, b, a)
end

local TEX      = {}
local ITEM_TEX = {} -- [item_id] = { handle=, tex= }

-- Spell icon cache (Index -> ROM -> texture handle)
local SPELL_ROM_BY_INDEX = nil -- [spell_index] = rom_number (or 0)
local SPELL_ASSET_TEX    = {}  -- [rom_number] = handle

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

    local out = ffi.new('IDirect3DTexture8*[1]')
    local hr = ffi.C.D3DXCreateTextureFromFileA(d3d8.get_device(), path, out)
    if hr ~= 0 or out[0] == nil then
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

-------------------------------------------------------------------------------
-- Spell assets directory helpers
-------------------------------------------------------------------------------
local function spells_assets_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then src = src:sub(2) end
    local base = src:match('^(.*[\\/])') or './'
    local sep = package.config:sub(1, 1)

    local p = base:gsub('[\\/]+$', '')
    p = p:gsub('[\\/]+plugins[\\/]+buttons$', '')
    return p .. sep .. 'assets' .. sep .. 'spells' .. sep
end

local SPELL_INFO_BY_ID = nil -- [spellId] = { index = <Index>, rom = <Icon/Rom> }

local function build_spell_info_cache()
    if SPELL_INFO_BY_ID ~= nil then
        return
    end

    SPELL_INFO_BY_ID = {}

    local resMgr = nil
    pcall(function()
        resMgr = AshitaCore:GetResourceManager()
    end)
    if resMgr == nil or resMgr.GetSpellById == nil then
        return
    end

    for spellId = 1, 0x400 do
        local res = nil
        pcall(function() res = resMgr:GetSpellById(spellId) end)
        if res ~= nil then
            local idx = tonumber(res.Index or 0) or 0

            local rom = 0
            rom = tonumber(res.IconId or 0) or rom
            rom = tonumber(res.IconID or 0) or rom
            rom = tonumber(res.RomId or 0) or rom
            rom = tonumber(res.ROMId or 0) or rom
            rom = tonumber(res.RomID or 0) or rom

            SPELL_INFO_BY_ID[spellId] = { index = idx, rom = tonumber(rom or 0) or 0 }
        end
    end
end

local function get_spell_info(spell_id)
    spell_id = tonumber(spell_id or 0) or 0
    if spell_id <= 0 then
        return 0, 0
    end

    build_spell_info_cache()

    local t = SPELL_INFO_BY_ID and SPELL_INFO_BY_ID[spell_id] or nil
    if type(t) ~= 'table' then
        return 0, 0
    end

    return tonumber(t.index or 0) or 0, tonumber(t.rom or 0) or 0
end

local function load_spell_asset_icon_handle_by_id(spell_id)
    spell_id = tonumber(spell_id or 0) or 0
    if spell_id <= 0 then
        return nil
    end

    local _, rom = get_spell_info(spell_id)

    -- 1) Prefer ROM/icon id -> assets/spells/<rom>.png
    if rom > 0 then
        local cached = SPELL_ASSET_TEX[rom]
        if cached ~= nil then
            return cached
        end

        local path = spells_assets_dir() .. tostring(rom) .. '.png'
        local h = load_texture_handle(path)
        if h ~= nil then
            SPELL_ASSET_TEX[rom] = h
            return h
        end
    end

    -- 2) Fallback -> assets/spells/<spellId>.png (only if you happen to have it)
    do
        local cached = SPELL_ASSET_TEX[spell_id]
        if cached ~= nil then
            return cached
        end

        local path = spells_assets_dir() .. tostring(spell_id) .. '.png'
        local h = load_texture_handle(path)
        if h ~= nil then
            SPELL_ASSET_TEX[spell_id] = h
            return h
        end
    end

    return nil
end

-------------------------------------------------------------------------------
-- Item icon handle (resource manager icon pointer)
-------------------------------------------------------------------------------
local function load_item_icon_handle(item_id)
    item_id = tonumber(item_id or 0) or 0
    if item_id <= 0 then return nil end

    local cached = ITEM_TEX[item_id]
    if type(cached) == 'table' and cached.handle ~= nil then
        return cached.handle
    end

    local res = nil
    pcall(function()
        res = AshitaCore:GetResourceManager()
    end)
    if not res then
        return nil
    end

    local tex = nil

    -- Try common Ashita resource icon accessors (varies by build/version).
    if tex == nil and res.GetItemIconById then
        pcall(function() tex = res:GetItemIconById(item_id) end)
    end
    if tex == nil and res.GetItemIcon then
        pcall(function() tex = res:GetItemIcon(item_id) end)
    end
    if tex == nil and res.GetIconByItemId then
        pcall(function() tex = res:GetIconByItemId(item_id) end)
    end

    if tex == nil then
        return nil
    end

    -- Important: treat as a raw pointer handle; do NOT gc_safe_release it.
    local handle = ptr_to_number(tex)
    if handle == nil or handle == 0 then
        return nil
    end

    ITEM_TEX[item_id] = { handle = handle }
    return handle
end

-------------------------------------------------------------------------------
-- Item recast (tHotBar-style: uses item.Extra timestamps)
-------------------------------------------------------------------------------
local vanaOffset  = 0x3C307D70
local timePointer = nil

local function gb_find_time_ptr()
    if timePointer ~= nil then return end
    if not ashita or not ashita.memory or not ashita.memory.find then return end
    -- Same signature style as tHotBar uses.
    timePointer = ashita.memory.find('FFXiMain.dll', 0, 'A1????????8B480C8B510C', 0, 0)
end

local function gb_get_time_utc()
    gb_find_time_ptr()
    if timePointer == nil then return 0 end
    local ptr = ashita.memory.read_uint32(timePointer + 0x01)
    if ptr == 0 then return 0 end
    ptr = ashita.memory.read_uint32(ptr)
    if ptr == 0 then return 0 end
    return ashita.memory.read_uint32(ptr + 0x0C) or 0
end

local function gb_recast_to_string(seconds)
    seconds = tonumber(seconds or 0) or 0
    if seconds <= 0 then return nil end

    local m = math.floor(seconds / 60)
    local s = seconds - (m * 60)

    if m > 0 then
        return string.format('%d:%02d', m, s)
    end
    return tostring(s)
end

-- tHotBar-style formatting for MemoryManager recast timers (frame-based).
local function gb_recast_to_string_thotbar(timer)
    timer = tonumber(timer or 0) or 0
    if timer == 0 then
        return nil
    end
    if timer >= 216000 then
        local h = math.floor(timer / 216000)
        local m = math.floor(math.fmod(timer, 216000) / 3600)
        return string.format('%i:%02i', h, m)
    elseif timer >= 3600 then
        local m = math.floor(timer / 3600)
        local s = math.floor(math.fmod(timer, 3600) / 60)
        return string.format('%i:%02i', m, s)
    else
        if timer < 60 then
            return '1'
        else
            return string.format('%i', math.floor(timer / 60))
        end
    end
end

local function gb_get_spell_recast_text(spell_id)
    spell_id = tonumber(spell_id or 0) or 0
    if spell_id <= 0 then
        return nil
    end

    local spell_index = 0
    do
        local idx = 0
        idx, _ = get_spell_info(spell_id)
        spell_index = tonumber(idx or 0) or 0
    end
    if spell_index <= 0 then
        return nil
    end

    local recast = nil
    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if mm and mm.GetRecast then
            recast = mm:GetRecast()
        end
    end)
    if recast == nil or recast.GetSpellTimer == nil then
        return nil
    end

    local timer = 0
    pcall(function()
        timer = recast:GetSpellTimer(spell_index) or 0
    end)

    return gb_recast_to_string_thotbar(timer)
end

local function gb_get_item_recast_seconds(item_id)
    item_id = tonumber(item_id or 0) or 0
    if item_id <= 0 then return 0 end

    local invmgr = nil
    local resMgr = nil
    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if mm then invmgr = mm:GetInventory() end
        resMgr = AshitaCore:GetResourceManager()
    end)
    if not invmgr or not resMgr then
        return 0
    end

    local res = nil
    pcall(function() res = resMgr:GetItemById(item_id) end)
    if not res then return 0 end

    local flags = tonumber(res.Flags or 0) or 0
    -- tHotBar only computes recast for "equippable" style items.
    if bit.band(flags, 0x800) ~= 0x800 then
        return 0
    end

    local now = gb_get_time_utc()
    if now <= 0 then return 0 end

    local lowest = 0

    -- Same bag set tHotBar uses for equippables.
    local bags = { 0, 8, 10, 11, 12, 13, 14, 15, 16 }

    for bi = 1, #bags do
        local bag = bags[bi]
        for s = 0, 80 do
            local it = invmgr:GetContainerItem(bag, s)
            local id = tonumber(it.Id or 0) or 0
            if id == item_id then
                local extra = it.Extra
                if type(extra) == 'string' and #extra >= 12 then
                    local useTime = 0
                    local equipTime = 0

                    -- useTime @ offset 5 (tHotBar)
                    local ok1, v1 = pcall(function() return struct.unpack('L', extra, 5) end)
                    if ok1 and v1 then
                        useTime = (tonumber(v1) or 0) + vanaOffset - now
                        if useTime < 0 then useTime = 0 end
                    end

                    -- equipTime: if it.Flags == 5 then @ offset 9 else CastDelay
                    if tonumber(it.Flags or 0) == 5 then
                        local ok2, v2 = pcall(function() return struct.unpack('L', extra, 9) end)
                        if ok2 and v2 then
                            equipTime = (tonumber(v2) or 0) + vanaOffset - now
                            if equipTime < 0 then equipTime = 0 end
                        end
                    else
                        equipTime = tonumber(res.CastDelay or 0) or 0
                    end

                    local v = (useTime > equipTime) and useTime or equipTime
                    v = math.floor(v + 0.5)

                    if v > 0 then
                        if lowest == 0 or v < lowest then
                            lowest = v
                        end
                    end
                end
            end
        end
    end

    return tonumber(lowest or 0) or 0
end

-------------------------------------------------------------------------------
-- Paths / state
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
    p = p:gsub('[\\/]+plugins[\\/]+buttons$', '')
    return p .. SEP
end

local function data_path()
    -- Build: <Ashita>\config\addons\gobbiebars\<Name_ID>\buttons.lua
    -- (No reliance on settings library path fields.)
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

        if name == nil or name == '' then
            local player = mm:GetPlayer()
            if player and player.GetName then
                name = player:GetName()
            end
            if id == nil and player and player.GetServerId then
                id = player:GetServerId()
            elseif id == nil and player and player.GetID then
                id = player:GetID()
            end
        end
    end)

    name = tostring(name or ''):gsub('%s+', '')
    id = tonumber(id or 0) or 0

    if name ~= '' and id > 0 then
        local root = gb_root_dir() -- ...\Ashita\addons\gobbiebars\
        root = root:gsub('[\\/]+$', '')
        root = root:gsub('[\\/]+addons[\\/]+gobbiebars$', '')

        return root .. SEP .. 'config' .. SEP .. 'addons' .. SEP .. 'gobbiebars'
            .. SEP .. name .. '_' .. tostring(id) .. SEP .. 'buttons.lua'
    end

    -- Fallback only if we cannot identify character yet (should be rare).
    return gb_root_dir() .. 'data' .. SEP .. 'gobbiebars_buttons.lua'
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

local function ensure_dir(path)
    pcall(function()
        local dir = path:gsub('[\\/][^\\/]+$', '')
        if ashita and ashita.fs and ashita.fs.create_dir then
            ashita.fs.create_dir(dir)
        end
    end)
end

local STATE = nil
local save_state = nil

local function default_state()
    return {
        version = 1,
        buttons = {}, -- { id, name, icon, cmd, bar, scope, job, x,y,w,h }
        ui = {
            icon_size = 35,
            pad = 4,
            gap = 4,
            bg   = { 20, 20, 20, 140 },
            hov  = { 37, 81, 237, 160 },
            down = { 37, 81, 237, 220 },
            border = { 255, 255, 255, 50 },

            -- Preview mode: force-draw overlays even when not available
            preview_active = false,



            -- Per-bar background texture (per-character, persisted).
            -- Applies ONLY to: top/bottom/left/right. Never to screen.
            bar_textures = {
                top    = nil,
                bottom = nil,
                left   = nil,
                right  = nil,
            },

            -- overlay master toggles
            active = true,
            preview_active = false,

            -- base font size for overlay scaling
            font_size = 14,

            -- per-element positions (offsets)
            pos = {
                label   = { x = 30,  y = 7  },   -- anchor: top-left of icon
                item    = { x = -30, y = 0  },   -- anchor: top-left of icon
                cd      = { x = -12, y = -15 },  -- anchor: bottom-right of icon
                counter = { x = -17, y = 7  },   -- anchor: bottom-right of icon
                keybind = { x = 3,  y = 3  },    -- anchor: top-left of icon
            },


            -- per-element text settings
            text = {
                label   = { enabled = true,  size = 14, shadow = 0, text = {255,255,255,255}, shadow_col = {0,0,0,200} },
                item    = { enabled = true,  size = 13, shadow = 1, text = {255,255,255,255}, shadow_col = {0,0,0,200} },
                cd      = { enabled = true,  size = 15, shadow = 1, text = {255,255,255,255}, shadow_col = {0,0,0,200} },
                counter = { enabled = true,  size = 10, shadow = 2, text = {255,255,255,245}, shadow_col = {0,0,0,210} },
                keybind = { enabled = true,  size = 10, shadow = 1, text = {255,255,255,255}, shadow_col = {0,0,0,200} },
                tooltip = { enabled = true,  size = 23, shadow = 0, text = {255,255,255,255}, shadow_col = {0,0,0,200} },
            },

            -- item count overlay (legacy fields kept for backwards compat)
            count_scale = 0.70, -- legacy font scale
            count_color = { 255, 255, 255, 245 },
            count_shadow_color = { 0, 0, 0, 210 },
            count_shadow_px = 2, -- legacy shadow strength (now treated as radius)


            -- Skillchain highlight (per-character)
            -- mode: 'off' | 'border' | 'crawler' | 'both'
            sc_mode  = 'crawler',
            -- crawler style folder under assets/ui, e.g. 'crawl_yellow'
            sc_style = 'crawl_yellow',
            -- RGBA 0-255 for border/glow (crawler images are not tinted)
            sc_color = { 255, 215, 0, 255 },

            -- WS element icon overlay (top-left). ON until disabled.
            ws_elem_overlay = true,

            -- Keybinds (Ashita /bind)
            kb_enabled    = true,  -- global on/off
            kb_modifier   = '@',   -- default modifier (Windows key)
            kb_auto_apply = true,  -- re-apply binds automatically

            -- Preview/test mode: force overlay drawing even when not available
            -- (moved to earlier preview_active)


        },





        _shipped_v1 = false,
    }
end

-------------------------------------------------------------------------------
-- Icon paths
-------------------------------------------------------------------------------
local function plugin_images_dir()
    return gb_root_dir() .. 'plugins' .. SEP .. 'buttons' .. SEP .. 'images' .. SEP
end

local function icon_path(rel)
    rel = tostring(rel or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if rel == '' then return nil end
    rel = rel:gsub('[\\/]+', SEP)
    return plugin_images_dir() .. rel
end

-- assets/ui icon helper (menu icons live here)
local function ui_icon_path(rel)
    rel = tostring(rel or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if rel == '' then return nil end
    rel = rel:gsub('[\\/]+', SEP)
    return gb_root_dir() .. 'assets' .. SEP .. 'ui' .. SEP .. rel
end

-------------------------------------------------------------------------------
-- Skillchain animated border (tHotBar-style crawl frames)
-- assets/ui/<style>/crawl1.png .. crawlN.png  (N detected per folder)
-------------------------------------------------------------------------------
local SC_CRAWL_FRAME_LEN  = 0.06 -- seconds per frame
local SC_CRAWL_MAX_FRAMES = 32   -- safety cap

-- Cache per-style:
-- SC_CRAWL_TEX[style][frame] = textureHandle
-- SC_CRAWL_COUNT[style]      = detected frame count
local SC_CRAWL_TEX   = {}
local SC_CRAWL_COUNT = {}
local SC_ANIM        = {} -- [buttonId] = { start_ms=<ms> }

local function sc_style_dir(style)
    style = tostring(style or ''):gsub('^%s+', ''):gsub('%s+$', '')
    if style == '' then style = 'crawl_yellow' end
    return style
end

local function sc_frame_path(style, frameIndex)
    style = sc_style_dir(style)
    frameIndex = tonumber(frameIndex or 0) or 0
    if frameIndex < 1 then return nil end
    return gb_root_dir() .. 'assets' .. SEP .. 'ui' .. SEP .. style .. SEP .. ('crawl' .. tostring(frameIndex) .. '.png')
end

local function sc_detect_frame_count(style)
    style = sc_style_dir(style)

    local cached = SC_CRAWL_COUNT[style]
    if cached ~= nil then
        return tonumber(cached or 0) or 0
    end

    local n = 0
    for i = 1, SC_CRAWL_MAX_FRAMES do
        local p = sc_frame_path(style, i)
        local f = nil
        if p ~= nil then
            f = io.open(p, 'rb')
        end
        if f ~= nil then
            f:close()
            n = i
        else
            -- Stop at first miss after at least one found
            if n > 0 then break end
        end
    end

    SC_CRAWL_COUNT[style] = n
    return n
end

local function sc_load_crawl_frame(style, i)
    style = sc_style_dir(style)
    i = tonumber(i or 0) or 0

    local n = sc_detect_frame_count(style)
    if n <= 0 then return nil end
    if i < 1 or i > n then return nil end

    SC_CRAWL_TEX[style] = SC_CRAWL_TEX[style] or {}
    local cached = SC_CRAWL_TEX[style][i]
    if cached ~= nil then return cached end

    local p = sc_frame_path(style, i)
    local h = (p ~= nil) and load_texture_handle(p) or nil
    if h ~= nil then
        SC_CRAWL_TEX[style][i] = h
    end
    return h
end

local function sc_get_crawl_handle(button_id, is_active, style)
    button_id = tonumber(button_id or 0) or 0
    if button_id <= 0 then return nil end

    style = sc_style_dir(style)

    if not is_active then
        SC_ANIM[button_id] = nil
        return nil
    end

    local n = sc_detect_frame_count(style)
    if n <= 0 then
        SC_ANIM[button_id] = nil
        return nil
    end

    local t = SC_ANIM[button_id]
    if t == nil then
        t = { start_ms = now_ms() }
        SC_ANIM[button_id] = t
    end

    local elapsed_s = (now_ms() - (tonumber(t.start_ms or 0) or 0)) / 1000.0
    if elapsed_s < 0 then elapsed_s = 0 end

    local fi = (math.floor(elapsed_s / SC_CRAWL_FRAME_LEN) % n) + 1
    return sc_load_crawl_frame(style, fi)
end





-------------------------------------------------------------------------------
-- WS icon map + WS element map
-- - WS icon map: plugins/buttons/wsmap.lua (tHotBar style, values like 'ITEM:16555')
-- - WS element map: assets/ui/elements/WS-ELEMENT.txt (tab-separated: Name <tab> Element <tab> Weapon)
-------------------------------------------------------------------------------
local WS_ICON_MAP = nil          -- [abilityId] = 'ITEM:16555'
local WS_ELEM_BY_NAME = nil      -- ['fast blade'] = 'light' etc.
local ELEM_TEX = {}              -- ['fire'] = texture handle

local function wsmap_path()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then src = src:sub(2) end
    local base = src:match('^(.*[\\/])') or './'
    return base .. 'wsmap.lua'
end

local function ensure_ws_icon_map()
    if WS_ICON_MAP ~= nil then return end
    WS_ICON_MAP = {}

    local p = wsmap_path()
    local ok, chunk = pcall(loadfile, p)
    if not ok or not chunk then return end

    local ok2, t = pcall(chunk)
    if not ok2 or type(t) ~= 'table' then return end

    for k, v in pairs(t) do
        local id = tonumber(k or 0) or 0
        local s = tostring(v or '')
        if id > 0 and s:upper():match('^ITEM:%d+$') then
            WS_ICON_MAP[id] = s:upper()
        end
    end
end

local function ws_elements_txt_path()
    return gb_root_dir() .. 'assets' .. SEP .. 'ui' .. SEP .. 'elements' .. SEP .. 'ws_elements.lua'
end


local function normalize_ws_name(s)
    s = tostring(s or ''):lower()
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    s = s:gsub('%s+', ' ')
    return s
end

local function ensure_ws_elem_map()
    if WS_ELEM_BY_NAME ~= nil then return end
    WS_ELEM_BY_NAME = {}

    local p = ws_elements_txt_path()
    local ok, chunk = pcall(loadfile, p)
    if (not ok) or (not chunk) then
        print('[GobbieBars][WS] ws_elements.lua loadfile FAILED: ' .. tostring(p))
        return
    end

    local ok2, t = pcall(chunk)
    if (not ok2) or (type(t) ~= 'table') then
        print('[GobbieBars][WS] ws_elements.lua returned non-table: ' .. tostring(p))
        return
    end

    local c = 0
    for k, v in pairs(t) do
        local name = normalize_ws_name(k)
        local elem = tostring(v or ''):lower():gsub('%s+', '')
        if name ~= '' and elem ~= '' and elem ~= 'none' then
            WS_ELEM_BY_NAME[name] = elem
            c = c + 1
        end
    end

    print('[GobbieBars][WS] ws_elements.lua loaded entries=' .. tostring(c))
end



local function ws_icon_spec_for_ability(ability_id)
    ensure_ws_icon_map()
    return (WS_ICON_MAP and WS_ICON_MAP[tonumber(ability_id or 0) or 0]) or nil
end

local function ws_element_for_name(ws_name)
    ensure_ws_elem_map()
    local k = normalize_ws_name(ws_name)
    local e = (WS_ELEM_BY_NAME and WS_ELEM_BY_NAME[k]) or nil
    if e == 'none' then
        return nil
    end
    return e
end


local function element_icon_handle(elem)
    elem = tostring(elem or ''):lower():gsub('%s+', '')
    if elem == '' then return nil end

    local cached = ELEM_TEX[elem]
    if cached ~= nil then return cached end

    local base = gb_root_dir() .. 'assets' .. SEP .. 'ui' .. SEP .. 'elements' .. SEP
    local h = load_texture_handle(base .. elem .. '.png')

    ELEM_TEX[elem] = h
    return h
end



local function trust_icon_path(spell_id)

    spell_id = tonumber(spell_id or 0) or 0
    if spell_id <= 0 then return nil end
    return gb_root_dir() .. 'assets' .. SEP .. 'trusts' .. SEP .. tostring(spell_id) .. '.png'
end

local function normalize_spell_name(name)
    name = tostring(name or '')
    name = name:lower()
    name = name:gsub("'", '')
    name = name:gsub('%.', '')
    name = name:gsub('%s+', '_')
    name = name:gsub('[^a-z0-9_]', '')
    name = name:gsub('_+', '_')
    name = name:gsub('^_', ''):gsub('_$', '')
    return name
end

local function spell_name_icon_path(spell_name)
    local n = normalize_spell_name(spell_name)
    if n == '' then return nil end
    return gb_root_dir() .. 'assets' .. SEP .. 'spells' .. SEP .. n .. '.png'
end


-------------------------------------------------------------------------------
-- Job Ability icon helpers (assets/ja/<ability_name>.png) - name-based like spells
-------------------------------------------------------------------------------
local JA_TEX = {} -- [normalized_name] = texture handle

local function normalize_ja_name(name)
    -- Same normalization rules as spell icons: lowercase, strip punctuation, spaces -> underscore.
    name = tostring(name or '')
    name = name:lower()
    name = name:gsub("'", '')
    name = name:gsub('%.', '')
    name = name:gsub('%s+', '_')
    name = name:gsub('[^a-z0-9_]', '')
    name = name:gsub('_+', '_')
    name = name:gsub('^_', ''):gsub('_$', '')
    return name
end

local function ja_name_icon_path(ability_name)
    local n = normalize_ja_name(ability_name)
    if n == '' then return nil end
    return gb_root_dir() .. 'assets' .. SEP .. 'ja' .. SEP .. n .. '.png'
end

local function load_ja_icon_handle_by_ability_id(ability_id)
    ability_id = tonumber(ability_id or 0) or 0
    if ability_id <= 0 then
        return nil
    end

    local resMgr = nil
    pcall(function()
        resMgr = AshitaCore:GetResourceManager()
    end)
    if resMgr == nil or resMgr.GetAbilityById == nil then
        return nil
    end

    local res = nil
    pcall(function() res = resMgr:GetAbilityById(ability_id) end)
    if res == nil or res.Name == nil then
        return nil
    end

    local nm = ''
    if type(res.Name) == 'string' then
        nm = res.Name
    elseif type(res.Name) == 'userdata' and res.Name[1] ~= nil then
        nm = tostring(res.Name[1])
    else
        nm = tostring(res.Name)
    end

    local key = normalize_ja_name(nm)
    if key == '' then
        return nil
    end

    local cached = JA_TEX[key]
    if cached ~= nil then
        return cached
    end

    local p = ja_name_icon_path(nm)
    if p ~= nil then
        local h = load_texture_handle(p)
        JA_TEX[key] = h
        return h
    end

    return nil
end

-------------------------------------------------------------------------------
-- Trust detection
-------------------------------------------------------------------------------
local function is_trust_spell_id(spell_id)
    spell_id = tonumber(spell_id or 0) or 0
    if spell_id <= 0 then return false end

    local resMgr = nil
    pcall(function()
        resMgr = AshitaCore:GetResourceManager()
    end)
    if resMgr == nil or resMgr.GetSpellById == nil then
        return false
    end

    local res = nil
    pcall(function() res = resMgr:GetSpellById(spell_id) end)
    if res == nil then
        return false
    end

    local lr = res.LevelRequired
    if lr == nil or lr[1] == nil then
        return false
    end

    return (tonumber(lr[2] or 0) or 0) == 1
end

-------------------------------------------------------------------------------
-- Shipped default buttons (one-time seeding)
-------------------------------------------------------------------------------
local function has_button(st, name, icon)
    if type(st) ~= 'table' or type(st.buttons) ~= 'table' then return false end
    for i = 1, #st.buttons do
        local b = st.buttons[i]
        if tostring(b.name or '') == tostring(name or '') and tostring(b.icon or '') == tostring(icon or '') then
            return true
        end
    end
    return false
end

local function add_shipped_buttons_if_needed(st)
    if type(st) ~= 'table' then return false end
    if st._shipped_v1 == true then return false end

    st.ui = st.ui or {}
    st.buttons = st.buttons or {}

    local isz = tonumber(st.ui.icon_size or 18) or 18
    local gap = tonumber(st.ui.gap or 4) or 4
    local step = isz + gap

    local function alloc_id()
        local mx = 0
        for i = 1, #st.buttons do
            local v = tonumber(st.buttons[i].id or 0) or 0
            if v > mx then mx = v end
        end
        return mx + 1
    end

    local shipped = {
        { name = 'Settings', icon = 'settings.png', cmd = '/gobbiebars ui', x = 0 * step },
        { name = 'Discord',  icon = 'discord.png',  cmd = 'discord:///', x = 1 * step },
        { name = 'Catseye',  icon = 'catseye.png',  cmd = 'https://www.catseyexi.com', x = 2 * step },
    }

    local changed = false
    for i = 1, #shipped do
        local s = shipped[i]
        local exists = false

        if s.name == 'Settings' then
            for j = 1, #st.buttons do
                if tostring(st.buttons[j].name or '') == 'Settings' then
                    exists = true
                    break
                end
            end
        else
            exists = has_button(st, s.name, s.icon)
        end

        if not exists then
            st.buttons[#st.buttons + 1] = {
                id = alloc_id(),
                name = s.name,
                icon = s.icon,
                cmd  = s.cmd,
                bar  = 'top',
                scope = 'all',
                x = tonumber(s.x) or 0,
                y = 0,
                w = isz,
                h = isz,
            }
            changed = true
        end
    end

    st._shipped_v1 = true
    return changed
end

-------------------------------------------------------------------------------
-- Per-character storage
-------------------------------------------------------------------------------
-- settings.plugin_settings.buttons._state
local CURRENT_PS = nil
local STATE_PATH = nil

local function load_state()
    local p_now = data_path()

    -- Reuse cache only if it was loaded for the same resolved path.
    if STATE ~= nil and STATE_PATH == p_now then
        return STATE
    end

    -- Path changed (common on first login): drop stale cached state.
    if STATE_PATH ~= p_now then
        STATE = nil
        STATE_PATH = p_now
    end

    -- 1) Prefer per-character buttons.lua if it exists and has buttons.
    do
        local ok, chunk = pcall(loadfile, p_now)
        if ok and chunk ~= nil then
            local ok2, t = pcall(chunk)
            if ok2 and type(t) == 'table' and type(t.buttons) == 'table' and #t.buttons > 0 then
                STATE = t
            end
        end
    end

    -- 2) Fallback: settings.lua cached state (_state) only if it has buttons.
    if STATE == nil then
        if type(CURRENT_PS) == 'table' and type(CURRENT_PS._state) == 'table' then
            local t = CURRENT_PS._state
            if type(t.buttons) == 'table' and #t.buttons > 0 then
                STATE = t
            end
        end
    end

    -- 3) Final fallback: built-in defaults
    if STATE == nil then
        STATE = default_state()
    end

    -- Ensure wrapper sees the state we are using
    if type(CURRENT_PS) == 'table' then
        CURRENT_PS._state = STATE
    end

    -- Seed shipped buttons once
    if add_shipped_buttons_if_needed(STATE) then
        if type(CURRENT_PS) == 'table' then
            CURRENT_PS._state = STATE
        end
    end

    return STATE
end

save_state = function()
    local st = load_state()
    local p = data_path()
    ensure_dir(p)
    local f = io.open(p, 'w')
    if not f then return end
    f:write('return ', dump(st, 0), '\n')
    f:close()
end

local function next_id(st)
    local mx = 0
    for i = 1, #st.buttons do
        local v = tonumber(st.buttons[i].id or 0) or 0
        if v > mx then mx = v end
    end
    return mx + 1
end

-------------------------------------------------------------------------------
-- Keybinds
-------------------------------------------------------------------------------
local KB_KEYS = { 'F1','F2','F3','F4','F5','F6','F7','F8','F9','F10','F11','F12' }
-- Persist applied-binds cache across any module reload/re-exec.
local KB_APPLIED = _G.__GB_BUTTONS_KB_APPLIED
if type(KB_APPLIED) ~= 'table' then
    KB_APPLIED = {} -- ['@F1']=buttonId etc (runtime only)
    _G.__GB_BUTTONS_KB_APPLIED = KB_APPLIED
end

local KB_CMD_REGISTERED = false

local function kb_norm_key(k)
    k = tostring(k or ''):upper()
    k = k:gsub('%s+', '')
    return k
end

local function kb_full(mod, k)
    mod = tostring(mod or '@')
    k = kb_norm_key(k)
    if k == '' then return '' end

    -- IMPORTANT: On this setup, Win modifier is '@' (tHotBar style).
    -- Do NOT convert to '?Win-' because Ashita rejects '?Win-F1' as invalid.
    return mod .. k
end



local function kb_collect_used(st, exclude_index)
    local used = {}
    if type(st) ~= 'table' or type(st.buttons) ~= 'table' then
        return used
    end
    exclude_index = tonumber(exclude_index or 0) or 0
    for i = 1, #st.buttons do
        if i ~= exclude_index then
            local b = st.buttons[i]
            local k = kb_norm_key(b and b.keybind or '')
            if k ~= '' then
                used[k] = true
            end
        end
    end
    return used
end

local function kb_find_button_by_id(st, id)
    id = tonumber(id or 0) or 0
    if id <= 0 or type(st) ~= 'table' or type(st.buttons) ~= 'table' then
        return nil
    end
    for i = 1, #st.buttons do
        local b = st.buttons[i]
        if tonumber(b.id or 0) == id then
            return b
        end
    end
    return nil
end

-- Public activation entry point (equivalent to tHotBar gDisplay:Activate)
function M.activate_button_by_id(id)
    local st = load_state()
    if not st then
        return false
    end

    local b = kb_find_button_by_id(st, id)
    if not b then
        return false
    end

    enqueue_macro(tostring(b.cmd or ''))
    return true
end


local KB_CMD_REGISTERED = false

local function kb_register_command_handler()
    if KB_CMD_REGISTERED then return end

    local function handler(e)
        local cmd = tostring(e and (e.command or e.Command) or '')
        if cmd == '' then return end

        local lower = cmd:lower()

        -- Match /gbbbuttons ... (allow leading/trailing spaces)
        if not lower:match('^%s*/gbbbuttons%s') and not lower:match('^%s*/gbbbuttons%s*$') then
            return
        end

        -- Tokenize
        local parts = {}
        for w in cmd:gmatch('%S+') do
            parts[#parts + 1] = w
        end

        -- /gbbbuttons activate <id>
        local sub = tostring(parts[2] or ''):lower()
        if sub == 'activate' then
            local id = tonumber(parts[3] or 0) or 0
            if id > 0 then
                M.activate_button_by_id(id)
            end
            if e then e.blocked = true end
            return
        end

        -- Eat unknown subcommands so binds don't spam chat
        if e then e.blocked = true end
    end

    if ashita and ashita.events and type(ashita.events.register) == 'function' then
        pcall(function() ashita.events.register('command', 'gb_buttons_cmd', handler) end)
        KB_CMD_REGISTERED = true
        return
    end

    if ashita and type(ashita.register_event) == 'function' then
        pcall(function() ashita.register_event('command', 'gb_buttons_cmd', handler) end)
        KB_CMD_REGISTERED = true
        return
    end
end



local function kb_apply_all(st)
    if type(st) ~= 'table' then return end
    st.ui = st.ui or {}

    -- Keybind system globally disabled: clear mapping and stop.
    if st.ui.kb_enabled == false then
        for fullk in pairs(KB_APPLIED) do
            KB_APPLIED[fullk] = nil
        end
        _G.__GB_BUTTONS_KB_APPLIED = KB_APPLIED
        return
    end

    local mod = tostring(st.ui.kb_modifier or '@')
    local desired = {}  -- fullKey -> buttonId (job-agnostic)

    if type(st.buttons) == 'table' then
        for i = 1, #st.buttons do
            local b = st.buttons[i]
            local k = kb_norm_key(b and b.keybind or '')
            if k ~= '' then
                local fullk = kb_full(mod, k)
                if fullk ~= '' then
                    desired[fullk] = tonumber(b.id or 0) or 0
                end
            end
        end
    end

    -- Drop keys that are no longer used at all.
    for fullk in pairs(KB_APPLIED) do
        if desired[fullk] == nil then
            KB_APPLIED[fullk] = nil
        end
    end

    -- Update current mapping.
    for fullk, id in pairs(desired) do
        KB_APPLIED[fullk] = id
    end

    _G.__GB_BUTTONS_KB_APPLIED = KB_APPLIED
end


-------------------------------------------------------------------------------
-- Internal key handler (Ashita key_state event)
-------------------------------------------------------------------------------

local KB_STATE_HANDLER_REGISTERED = false
local KB_PREV_STATE = {}

-- DirectInput scan codes we care about.
local KB_SCANCODES = {
    F1  = 0x3B,
    F2  = 0x3C,
    F3  = 0x3D,
    F4  = 0x3E,
    F5  = 0x3F,
    F6  = 0x40,
    F7  = 0x41,
    F8  = 0x42,
    F9  = 0x43,
    F10 = 0x44,
    F11 = 0x57,
    F12 = 0x58,
}

local DIK = {
    LCTRL  = 0x1D,
    RCTRL  = 0x9D,
    LALT   = 0x38,
    RALT   = 0xB8,
    LSHIFT = 0x2A,
    RSHIFT = 0x36,
    LWIN   = 0xDB,
    RWIN   = 0xDC,
    APPS   = 0xDD,
}

local function kb_is_modifier_down(ptr, mod)
    mod = tostring(mod or '@')
    if mod == '!' then
        return ptr[DIK.LALT] ~= 0 or ptr[DIK.RALT] ~= 0
    elseif mod == '^' then
        return ptr[DIK.LCTRL] ~= 0 or ptr[DIK.RCTRL] ~= 0
    elseif mod == '+' then
        return ptr[DIK.LSHIFT] ~= 0 or ptr[DIK.RSHIFT] ~= 0
    elseif mod == '@' then
        return ptr[DIK.LWIN] ~= 0 or ptr[DIK.RWIN] ~= 0
    elseif mod == '#' then
        return ptr[DIK.APPS] ~= 0
    end
    -- Unknown / empty modifier: treat as no modifier requirement.
    return true
end

local function kb_handle_key_state(e)
    if not e or not e.data_raw then
        return
    end

    -- If we have no active binds, nothing to do.
    local has_any = false
    for _ in pairs(KB_APPLIED) do
        has_any = true
        break
    end
    if not has_any then
        return
    end

    local st = load_state()
    if not st or st.ui == nil or st.ui.kb_enabled == false then
        return
    end

    local mod = tostring(st.ui.kb_modifier or '@')
    local ptr = ffi.cast('uint8_t*', e.data_raw)

    for fullk, id in pairs(KB_APPLIED) do
        id = tonumber(id or 0) or 0
        if id > 0 then
            local k = tostring(fullk or ''):upper():gsub('%s+', '')
            -- Expect stored as "<mod><key>" (eg. "@F1"); strip first char.
            if #k >= 2 then
                local key = k:sub(2)
                local sc = KB_SCANCODES[key]
                if sc then
                    local is_down = (ptr[sc] ~= 0) and kb_is_modifier_down(ptr, mod)
                    local was_down = (KB_PREV_STATE[sc] == true)
                    if is_down and not was_down then
                        M.activate_button_by_id(id)
                    end
                    KB_PREV_STATE[sc] = is_down
                end
            end
        end
    end
end

local function kb_ensure_key_state_handler()
    if KB_STATE_HANDLER_REGISTERED then
        return
    end

    -- Ensure the mapping table matches the current saved state once.
    local st = load_state()
    if st then
        kb_apply_all(st)
    end

    if not ashita then
        return
    end

    local ok = false

    if ashita.events and type(ashita.events.register) == 'function' then
        ok = pcall(function()
            ashita.events.register('key_state', 'gb_buttons_key_state', kb_handle_key_state)
        end)
    elseif type(ashita.register_event) == 'function' then
        ok = pcall(function()
            ashita.register_event('key_state', 'gb_buttons_key_state', kb_handle_key_state)
        end)
    end

    if ok then
        KB_STATE_HANDLER_REGISTERED = true
    end
end






-------------------------------------------------------------------------------
-- Misc helpers
-------------------------------------------------------------------------------


local function in_rect(mx, my, x1, y1, x2, y2)
    return mx >= x1 and mx <= x2 and my >= y1 and my <= y2
end

local JOB_ABBR = {
    [0]  = 'NONE', [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM',
    [5]  = 'RDM',  [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK', [9]  = 'BST',
    [10] = 'BRD',  [11] = 'RNG', [12] = 'SAM', [13] = 'NIN', [14] = 'DRG',
    [15] = 'SMN',  [16] = 'BLU', [17] = 'COR', [18] = 'PUP', [19] = 'DNC',
    [20] = 'SCH',  [21] = 'GEO', [22] = 'RUN',
}

local function get_main_job_id()
    local job = 0
    pcall(function()
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

local function get_main_job_level()
    local lvl = 0
    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if mm ~= nil then
            local party = mm:GetParty()
            if party ~= nil and party.GetMemberMainJobLevel ~= nil then
                lvl = party:GetMemberMainJobLevel(0) or 0
            end
        end
    end)
    return tonumber(lvl) or 0
end

local function get_player_tp()
    local tp = 0
    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if not mm then return end
        local party = mm:GetParty()
        if party and party.GetMemberTP then
            tp = party:GetMemberTP(0) or 0
        end
    end)
    return tonumber(tp) or 0
end

local function get_target_index()
    local idx = 0
    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if not mm then return end
        local t = mm:GetTarget()
        if not t then return end

        if t.GetTargetIndex then
            idx = t:GetTargetIndex(0) or t:GetTargetIndex() or 0
        elseif t.GetTargetIndex0 then
            idx = t:GetTargetIndex0() or 0
        end
    end)
    return tonumber(idx) or 0
end

local function is_ws_cmd(cmd)
    cmd = tostring(cmd or ''):lower()
    return cmd:match('^%s*/ws%s+') ~= nil
end

local function is_ja_cmd(cmd)
    cmd = tostring(cmd or ''):lower()
    return cmd:match('^%s*/ja%s+') ~= nil
end


local function get_sub_job_id()
    local job = 0
    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if mm ~= nil then
            local party = mm:GetParty()
            if party ~= nil and party.GetMemberSubJob ~= nil then
                job = party:GetMemberSubJob(0) or 0
            end
        end
    end)
    return tonumber(job) or 0
end

local function get_sub_job_level()
    local lvl = 0
    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if mm ~= nil then
            local party = mm:GetParty()
            if party ~= nil and party.GetMemberSubJobLevel ~= nil then
                lvl = party:GetMemberSubJobLevel(0) or 0
            end
        end
    end)
    return tonumber(lvl) or 0
end

local BAR_OPTS = { 'top', 'bottom', 'left', 'right', 'screen' }

-- UI display names (keep internal values above unchanged)
local BAR_UI = { 'Top Bar', 'Bottom Bar', 'Left Bar', 'Right Bar', 'Screen' }

-- List-view options (adds "All" without changing real bar values)
local VIEW_OPTS = { 'all', 'top', 'bottom', 'left', 'right', 'screen' }
local VIEW_UI   = { 'All', 'Top', 'Bottom', 'Left', 'Right', 'Screen' }

local function bar_ui_name(i)
    return BAR_UI[i] or BAR_OPTS[i] or 'Top Bar'
end

local function view_ui_name(i)
    return VIEW_UI[i] or VIEW_OPTS[i] or 'All'
end



-------------------------------------------------------------------------------
-- Game mode
-------------------------------------------------------------------------------
local function get_game_mode()
    -- 1) Prefer wrapper settings (always correct per character)
    if CURRENT_PS and CURRENT_PS.game_mode and type(CURRENT_PS.game_mode) == 'string' then
        local m = CURRENT_PS.game_mode:upper()
        if m == 'CW' or m == 'ACE' or m == 'WEW' then
            return m
        end
    end

    -- 2) Fallback to global settings (may not be initialized yet)
    if _G.gb_settings and _G.gb_settings.game_mode and type(_G.gb_settings.game_mode) == 'string' then
        local m = _G.gb_settings.game_mode:upper()
        if m == 'CW' or m == 'ACE' or m == 'WEW' then
            return m
        end
    end

    -- 3) Final fallback
    return 'CW'
end

-------------------------------------------------------------------------------
-- Inventory (simple cached scan)
-------------------------------------------------------------------------------
local INV = {
    next_ms = 0,
    counts = {}, -- [item_id] = total_count
    list = {},   -- { { id=, name=, count= } ... }
}

local function inv_refresh()
    local now = now_ms()
    if now < (INV.next_ms or 0) then
        return
    end
    INV.next_ms = now + 500

    INV.counts = {}
    INV.list = {}

    local invmgr = nil
    local resMgr = nil
    pcall(function()
        local mm = AshitaCore:GetMemoryManager()
        if mm then invmgr = mm:GetInventory() end
        resMgr = AshitaCore:GetResourceManager()
    end)
    if not invmgr or not resMgr then
        return
    end

    local function scan_bags(bags, flagmask)
        for bi = 1, #bags do
            local bag = bags[bi]
            for s = 0, 80 do
                local it = invmgr:GetContainerItem(bag, s)
                if it ~= nil then
                    local id = tonumber(it.Id or 0) or 0
                    local ct = tonumber(it.Count or 0) or 0
                    if id > 0 and ct > 0 then
                        local res = nil
                        pcall(function() res = resMgr:GetItemById(id) end)
                        local flags = tonumber(res and res.Flags or 0) or 0
                        if res ~= nil and bit.band(flags, flagmask) == flagmask then
                            INV.counts[id] = (INV.counts[id] or 0) + ct
                        end
                    end
                end
            end

        end
    end

    -- Match tHotBar:
    -- 0x200 items from inventory + temporary (0, 3)
    scan_bags({ 0, 3 }, 0x200)

    -- 0x400 items from wardrobes (8, 10..16)
    scan_bags({ 8, 10, 11, 12, 13, 14, 15, 16 }, 0x400)

    for id, count in pairs(INV.counts) do
        local r = nil
        pcall(function() r = resMgr:GetItemById(id) end)

        local name = nil
        if r and r.Name ~= nil then
            if type(r.Name) == 'string' then
                name = r.Name
            elseif type(r.Name) == 'userdata' and r.Name[1] ~= nil then
                name = tostring(r.Name[1])
            else
                name = tostring(r.Name)
            end
        end
        if name == nil or name == '' then
            name = 'Item ' .. tostring(id)
        end

        INV.list[#INV.list + 1] = { id = id, name = name, count = count }
    end

    table.sort(INV.list, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
end

local function inv_count(item_id)
    inv_refresh()
    return tonumber(INV.counts[tonumber(item_id or 0) or 0] or 0) or 0
end

-------------------------------------------------------------------------------
-- Macro box helper
-------------------------------------------------------------------------------
local function macrobox_append_line(s)
    s = tostring(s or '')
    s = s:gsub('\r\n', '\n'):gsub('\r', '\n')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return end

    local cur = tostring(EDIT.cmd[1] or '')
    cur = cur:gsub('\r\n', '\n'):gsub('\r', '\n')

    if cur == '' then
        EDIT.cmd[1] = s
        return
    end

    if not cur:match('\n$') then
        cur = cur .. '\n'
    end

    EDIT.cmd[1] = cur .. s
end

-------------------------------------------------------------------------------
-- Editor state
-------------------------------------------------------------------------------
EDIT = {
    _list_filter = { '' },
    selected = 0,
    name = { '' },
    icon = { '' },
    cmd  = { '' },

    -- Optional link to an inventory item for overlay count.
    item_id = { 0 },

    -- Optional link to a spell (spellId).
    spell_id = { 0 },

    -- Optional link to a job ability (abilityId).
    ability_id = { 0 },

    -- Optional WS element string: 'fire','ice','wind','earth','lightning','water','light','dark'
    ws_element = { '' },

    -- Optional keybind (suffix only, e.g. 'F1'..'F12'). Full bind is kb_modifier + key.
    keybind_on  = { false },
    keybind_key = { '' },



    -- Browse context (list filter)
    view_bar = 1,

    -- Editor fields (applied to selected button)
    bar  = 1,

    scope = 1, -- 1=global, 2=main, 3=sub
    job = { 0 },
    x = { 0 }, y = { 0 }, w = { 0 }, h = { 0 },
}

local DRAG = { active = false, id = 0, offx = 0, offy = 0 }

-------------------------------------------------------------------------------
-- Apply editor changes to selected button
-------------------------------------------------------------------------------
local function apply_editor_to_selected(st)
    if type(st) ~= 'table' or type(st.buttons) ~= 'table' then return false end
    if EDIT.selected == nil or EDIT.selected <= 0 then return false end

    local b = st.buttons[EDIT.selected]
    if b == nil then return false end

    b.name = tostring(EDIT.name[1] or '')
    b.icon = tostring(EDIT.icon[1] or '')
    b.cmd  = tostring(EDIT.cmd[1]  or '')
    b.bar  = BAR_OPTS[EDIT.bar] or 'top'

    if EDIT.scope == 2 then
        b.scope = 'main'
        b.job = tonumber(EDIT.job[1] or get_main_job_id()) or 0
    elseif EDIT.scope == 3 then
        b.scope = 'sub'
        b.job = tonumber(EDIT.job[1] or get_sub_job_id()) or 0
    else
        b.scope = 'all'
        b.job = nil
    end

    b.x = tonumber(EDIT.x[1] or 0) or 0
    b.y = tonumber(EDIT.y[1] or 0) or 0
    b.w = tonumber(EDIT.w[1] or 0) or 0
    b.h = tonumber(EDIT.h[1] or 0) or 0

    local iid = tonumber(EDIT.item_id[1] or 0) or 0
    b.item_id = (iid > 0) and iid or nil

    local sid = tonumber(EDIT.spell_id[1] or 0) or 0
    b.spell_id = (sid > 0) and sid or nil

    local aid = tonumber(EDIT.ability_id[1] or 0) or 0
    b.ability_id = (aid > 0) and aid or nil

    local we = tostring(EDIT.ws_element[1] or ''):lower():gsub('%s+', '')
    b.ws_element = (we ~= '') and we or nil

    -- Keybind
    local kb_on = (EDIT.keybind_on[1] == true)
    local kb_key = tostring(EDIT.keybind_key[1] or ''):upper():gsub('%s+', '')
    if kb_on and kb_key ~= '' then
        b.keybind = kb_key
    else
        b.keybind = nil
    end

    save_state()
    return true
end




-------------------------------------------------------------------------------
-- Load selected button into editor fields
-------------------------------------------------------------------------------
local function apply_selected_to_editor(st)
    local b = st.buttons[EDIT.selected]
    if not b then
        EDIT.name[1] = ''
        EDIT.icon[1] = ''
        EDIT.cmd[1]  = ''
        EDIT.bar = 1
        EDIT.scope = 1
        EDIT.job[1] = 0
        EDIT.x[1], EDIT.y[1], EDIT.w[1], EDIT.h[1] = 0, 0, 0, 0
        EDIT.item_id[1] = 0
        EDIT.spell_id[1] = 0
        EDIT.ability_id[1] = 0
        EDIT.keybind_on[1] = false
        EDIT.keybind_key[1] = ''
        return

    end

    EDIT.name[1] = tostring(b.name or '')
    EDIT.icon[1] = tostring(b.icon or '')
    EDIT.cmd[1]  = tostring(b.cmd or '')

    EDIT.item_id[1] = tonumber(b.item_id or 0) or 0
    EDIT.spell_id[1] = tonumber(b.spell_id or 0) or 0
    EDIT.ability_id[1] = tonumber(b.ability_id or 0) or 0
    EDIT.ws_element[1] = tostring(b.ws_element or '')

    -- Keybind
    local kb = tostring(b.keybind or ''):upper():gsub('%s+', '')
    EDIT.keybind_on[1] = (kb ~= '')
    EDIT.keybind_key[1] = kb



    EDIT.x[1] = tonumber(b.x or 0) or 0
    EDIT.y[1] = tonumber(b.y or 0) or 0
    EDIT.w[1] = tonumber(b.w or 0) or 0
    EDIT.h[1] = tonumber(b.h or 0) or 0

    local bar = tostring(b.bar or 'top')
    local bi = 1
    for i = 1, #BAR_OPTS do
        if BAR_OPTS[i] == bar then bi = i break end
    end
    EDIT.bar = bi

    local sc = tostring(b.scope or 'all')
    if sc == 'sub' then
        EDIT.scope = 3
    elseif sc == 'main' or sc == 'job' then
        EDIT.scope = 2
    else
        EDIT.scope = 1
    end
    EDIT.job[1] = tonumber(b.job or 0) or 0
end

-------------------------------------------------------------------------------
-- Settings UI
-------------------------------------------------------------------------------
function M.draw_settings_ui(_wrapper_settings)
    if CURRENT_PS ~= _wrapper_settings then
        CURRENT_PS = _wrapper_settings
        STATE = nil
    end
    local st = load_state()

    -- (description removed)






    ---------------------------------------------------------------------------
    -- Preview mode toggle (per plugin setting)
    ---------------------------------------------------------------------------
        do
        local v = { st.ui.preview_active == true }

        imgui.AlignTextToFramePadding()
        imgui.Text('Preview mode:')
        imgui.SameLine()

        if imgui.Checkbox('##gb_preview', v) then
            st.ui.preview_active = (v[1] == true)
            save_state()
        end

        imgui.SameLine()
        imgui.Dummy({ 10, 1 })
        imgui.SameLine()

        -- Font selection (plugin-wide, uses GobbieBars plugin fonts)
        local fam = 'default'
        if CURRENT_PS and type(CURRENT_PS.font_family) == 'string' then
            fam = CURRENT_PS.font_family
        end
        if not (FONT_FAMILIES and FONT_FAMILIES[fam]) then
            fam = 'default'
        end
        if CURRENT_PS then
            CURRENT_PS.font_family = fam
        end

        imgui.AlignTextToFramePadding()
        imgui.Text('Font:')
        imgui.SameLine()
        imgui.SetNextItemWidth(140)

        local preview = fam
        if imgui.BeginCombo('##gb_btn_font_family', preview, 0) then
            if FONT_FAMILIES then
                for family, _ in pairs(FONT_FAMILIES) do
                    local sel = (family == fam)
                    if imgui.Selectable(family, sel) then
                        fam = family
                        if CURRENT_PS then
                            CURRENT_PS.font_family = fam
                        end
                    end
                    if sel then
                        imgui.SetItemDefaultFocus()
                    end
                end
            end
            imgui.EndCombo()
        end
    end



    ---------------------------------------------------------------------------
    -- Label style (per-button)
    ---------------------------------------------------------------------------
    do
        local b = (EDIT.selected > 0) and st.buttons[EDIT.selected] or nil
        if b ~= nil then
            -- defaults
            b.label_shadow = tonumber(b.label_shadow) or 2
            b.label_text_color = (type(b.label_text_color) == 'table') and b.label_text_color or { 1, 1, 1, 1 }
            b.label_shadow_color = (type(b.label_shadow_color) == 'table') and b.label_shadow_color or { 0, 0, 0, 0.86 }

            imgui.AlignTextToFramePadding()
            imgui.Text('Shadow:')
            imgui.SameLine()
            imgui.SetNextItemWidth(40)
            local sh = { tostring(tonumber(b.label_shadow) or 2) }
            if imgui.InputText('##gb_btn_label_shadow', sh, 8) then
                local n = tonumber(sh[1]) or 0
                if n < 0 then n = 0 end
                if n > 5 then n = 5 end
                b.label_shadow = n
                save_state()
            end

            imgui.SameLine()
            imgui.AlignTextToFramePadding()
            imgui.Text('Text')
            imgui.SameLine()
            local tc = { b.label_text_color[1], b.label_text_color[2], b.label_text_color[3], b.label_text_color[4] }
            imgui.SetNextItemWidth(30)
            if imgui.ColorButton('##gb_btn_label_text_btn', tc, 0, { 18, 18 }) then
                imgui.OpenPopup('##gb_btn_label_text_popup')
            end
            if imgui.BeginPopup('##gb_btn_label_text_popup') then
                if imgui.ColorPicker4('##gb_btn_label_text_pick', tc, 0) then
                    b.label_text_color = { tc[1], tc[2], tc[3], tc[4] }
                    save_state()
                end
                imgui.EndPopup()
            end

            imgui.SameLine()
            imgui.AlignTextToFramePadding()
            imgui.Text('Shadow')
            imgui.SameLine()
            local sc = { b.label_shadow_color[1], b.label_shadow_color[2], b.label_shadow_color[3], b.label_shadow_color[4] }
            imgui.SetNextItemWidth(30)
            if imgui.ColorButton('##gb_btn_label_shadow_btn', sc, 0, { 18, 18 }) then
                imgui.OpenPopup('##gb_btn_label_shadow_popup')
            end
            if imgui.BeginPopup('##gb_btn_label_shadow_popup') then
                if imgui.ColorPicker4('##gb_btn_label_shadow_pick', sc, 0) then
                    b.label_shadow_color = { sc[1], sc[2], sc[3], sc[4] }
                    save_state()
                end
                imgui.EndPopup()
            end

        end
    end



    imgui.Separator()


    ---------------------------------------------------------------------------
    -- Global Button Defaults (collapsible)
    ---------------------------------------------------------------------------
    if imgui.CollapsingHeader('Button settings', imgui.TreeNodeFlags_DefaultOpen) then

        -- Apply To (scope selector)
        st.ui = st.ui or {}

        if st.ui.apply_to == nil then
            st.ui.apply_to = 'button'
        end

        local APPLY_TO = {
            { id = 'button', label = 'This Button' },
            { id = 'all',    label = 'All Buttons' },
            { id = 'top',    label = 'Top Bar' },
            { id = 'bottom', label = 'Bottom Bar' },
            { id = 'left',   label = 'Left Bar' },
            { id = 'right',  label = 'Right Bar' },
            { id = 'screen', label = 'Screen' },
        }

        local function apply_to_label(id)
            for i = 1, #APPLY_TO do
                if APPLY_TO[i].id == id then
                    return APPLY_TO[i].label
                end
            end
            return 'This Button'
        end

        imgui.AlignTextToFramePadding()
        imgui.Text('Apply To:')
        imgui.SameLine()
        imgui.SetNextItemWidth(180)

        local cur_apply = tostring(st.ui.apply_to or 'button')
        if imgui.BeginCombo('##gb_apply_to', apply_to_label(cur_apply), 0) then
            for i = 1, #APPLY_TO do
                local e = APPLY_TO[i]
                local sel = (cur_apply == e.id)
                if imgui.Selectable(e.label .. '##apply_' .. e.id, sel) then
                    st.ui.apply_to = e.id
                    save_state()
                end
            end
            imgui.EndCombo()
        end

        -- Selected button status (only for This Button)
        if cur_apply == 'button' then
            imgui.SameLine()
            imgui.Dummy({ 10, 1 })
            imgui.SameLine()

            local label = 'None'
            if EDIT.selected > 0 and st.buttons[EDIT.selected] ~= nil then
                label = tostring(st.buttons[EDIT.selected].name or 'Unnamed')
                if label == '' then label = 'Unnamed' end
            end

            imgui.Text('Selected Button:')
            imgui.SameLine()

            if label == 'None' then
                imgui.TextDisabled(label)
            else
                imgui.Text(label)
            end

            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.Text('Select a button by:')
                imgui.BulletText('Right-clicking a button on a bar')
                imgui.BulletText('Clicking a button in the list below')
                imgui.EndTooltip()
            end

        end






        -- Icon Size (respects Apply To)
        imgui.AlignTextToFramePadding()
        imgui.Text('Icon Size:')

        imgui.SameLine()
        imgui.SetNextItemWidth(260)

        local isz = { tonumber(st.ui.icon_size or 18) or 18 }
        if imgui.SliderInt('##gb_icon_size', isz, 12, 48) then
            st.ui.icon_size = isz[1]

            local mode = tostring(st.ui.apply_to or 'button')

            if mode == 'button' then
                if EDIT.selected > 0 and st.buttons[EDIT.selected] then
                    st.buttons[EDIT.selected].w = isz[1]
                    st.buttons[EDIT.selected].h = isz[1]
                    EDIT.w[1] = isz[1]
                    EDIT.h[1] = isz[1]
                end

            elseif mode == 'all' then
                for i = 1, #st.buttons do
                    st.buttons[i].w = isz[1]
                    st.buttons[i].h = isz[1]
                end

            else
                for i = 1, #st.buttons do
                    if tostring(st.buttons[i].bar or '') == mode then
                        st.buttons[i].w = isz[1]
                        st.buttons[i].h = isz[1]
                    end
                end
            end

            save_state()
        end


        -- Colors (compact row)
        st.ui.bg     = st.ui.bg     or { 20, 20, 20, 140 }
        st.ui.border = st.ui.border or { 255, 255, 255, 50 }
        st.ui.hov    = st.ui.hov    or { 37, 81, 237, 160 }
        st.ui.down   = st.ui.down   or { 37, 81, 237, 220 }

        -- Per-bar color defaults
        st.ui.bar = st.ui.bar or {}
        st.ui.bar.bg     = st.ui.bar.bg     or {}
        st.ui.bar.border = st.ui.bar.border or {}
        st.ui.bar.hov    = st.ui.bar.hov    or {}
        st.ui.bar.down   = st.ui.bar.down   or {}


        local function color_block(label, t, popup_id)
            -- base/global RGBA (0-255) from the argument
            local base = {
                tonumber(t[1] or 0)   or 0,
                tonumber(t[2] or 0)   or 0,
                tonumber(t[3] or 0)   or 0,
                tonumber(t[4] or 255) or 255,
            }

            local key  = popup_id:match('gb_btn_col_(.+)')
            local mode = tostring(st.ui.apply_to or 'button')

            -- resolve the *active* RGBA for current Apply To (button / all / bar)
            local function get_active_rgba()
                local src = base

                if key ~= nil then
                    if mode == 'button' then
                        if EDIT.selected > 0 and st.buttons[EDIT.selected]
                           and type(st.buttons[EDIT.selected][key]) == 'table' then
                            src = st.buttons[EDIT.selected][key]
                        end

                    elseif mode == 'all' then
                        if st.ui[key] and type(st.ui[key]) == 'table' then
            src = st.ui[key]
                        end

                    else
                        -- bar modes: first button on that bar with an override (if any)
                        for i = 1, #st.buttons do
                            local b = st.buttons[i]
                            if tostring(b.bar or '') == mode and type(b[key]) == 'table' then
                                src = b[key]
                                break
                            end
                        end
                    end
                end

                return {
                    tonumber(src[1] or 0)   or 0,
                    tonumber(src[2] or 0)   or 0,
                    tonumber(src[3] or 0)   or 0,
                    tonumber(src[4] or 255) or 255,
                }
            end

            -- preview square uses the resolved active color
            local active = get_active_rgba()
            local c = {
                active[1] / 255,
                active[2] / 255,
                active[3] / 255,
                active[4] / 255,
            }

            imgui.AlignTextToFramePadding()
            imgui.Text(label)
            imgui.SameLine()

            -- Color square with a gray border to make it stand out
            imgui.PushStyleColor(ImGuiCol_Border, { 0.5, 0.5, 0.5, 1.0 })
            if imgui.ColorButton('##' .. popup_id, c, 0, { 18, 18 }) then
                imgui.OpenPopup(popup_id)
            end
            imgui.PopStyleColor(1)


            if imgui.BeginPopup(popup_id) then
                imgui.Text(label)

                -- re-resolve in case Apply To changed while popup is open
                active = get_active_rgba()
                c[1] = active[1] / 255
                c[2] = active[2] / 255
                c[3] = active[3] / 255
                c[4] = active[4] / 255

                if imgui.ColorPicker4('##picker_' .. popup_id, c, imgui.ColorEditFlags_AlphaBar) then
                    local rgba = {
                        math.floor((c[1] or 0) * 255 + 0.5),
                        math.floor((c[2] or 0) * 255 + 0.5),
                        math.floor((c[3] or 0) * 255 + 0.5),
                        math.floor((c[4] or 0) * 255 + 0.5),
                    }

                    if key ~= nil then
                        if mode == 'button' then
                            if EDIT.selected > 0 and st.buttons[EDIT.selected] then
                                -- per-button override only
                                st.buttons[EDIT.selected][key] = rgba
                            end

                        elseif mode == 'all' then
                            -- global default + clear per-button overrides
                            for i = 1, #st.buttons do
                                st.buttons[i][key] = nil
                            end
                            st.ui[key] = rgba

                        else
                            -- bar-level overrides for that bar
                            for i = 1, #st.buttons do
                                if tostring(st.buttons[i].bar or '') == mode then
                                    st.buttons[i][key] = rgba
                                end
                            end
                        end
                    end

                    save_state()
                end

                imgui.EndPopup()
            end
        end






        imgui.AlignTextToFramePadding()
        imgui.Text('Button Colors:')
        imgui.SameLine()
        imgui.Dummy({ 10, 1 })
        imgui.SameLine()

        color_block('Background', st.ui.bg, 'gb_btn_col_bg'); imgui.SameLine()
        imgui.Dummy({ 10, 1 }); imgui.SameLine()
        color_block('Border', st.ui.border, 'gb_btn_col_border'); imgui.SameLine()
        imgui.Dummy({ 10, 1 }); imgui.SameLine()
        color_block('Hover', st.ui.hov, 'gb_btn_col_hov'); imgui.SameLine()
        imgui.Dummy({ 10, 1 }); imgui.SameLine()
        color_block('Click', st.ui.down, 'gb_btn_col_down')


        imgui.Separator()

         -----------------------------------------------------------------------
        -- Position (respects Apply To)
        -----------------------------------------------------------------------
        do
            local mode = tostring(st.ui.apply_to or 'button')

            -- iterate all buttons affected by current Apply To mode
            local function each_target(fn)
                if mode == 'button' then
                    if EDIT.selected > 0 and st.buttons[EDIT.selected] ~= nil then
                        fn(st.buttons[EDIT.selected])
                    end
                elseif mode == 'all' then
                    for i = 1, #st.buttons do
                        fn(st.buttons[i])
                    end
                else
                    -- bar / screen modes
                    for i = 1, #st.buttons do
                        local b = st.buttons[i]
                        if tostring(b.bar or '') == mode then
                            fn(b)
                        end
                    end
                end
            end

            -- pick one button as the "sample" to show values from
            local sample = nil
            each_target(function(b)
                if not sample then
                    sample = b
                end
            end)

            if not sample then
                imgui.Text('Position:')
                imgui.SameLine()
                imgui.TextDisabled('(no buttons in this scope)')
                imgui.Separator()
            else
                -- ensure pos table + defaults for all buttons in scope
                local function ensure_xy_one(b, key, dx, dy)
                    b.pos = (type(b.pos) == 'table') and b.pos or {}
                    b.pos[key] = (type(b.pos[key]) == 'table') and b.pos[key] or {}
                    b.pos[key].x = tonumber(b.pos[key].x) or dx
                    b.pos[key].y = tonumber(b.pos[key].y) or dy
                end

                each_target(function(b)
                    ensure_xy_one(b, 'label',    3,  -3)
                    ensure_xy_one(b, 'cd',      -4,  -4)
                    ensure_xy_one(b, 'counter', -2,  -2)
                    ensure_xy_one(b, 'keybind',  0,   0)
                end)

                imgui.Text('Position:')

                local function pos_group(title, key)
                    imgui.AlignTextToFramePadding()

                    -- X
                    imgui.Text(title .. ' X:')
                    imgui.SameLine()
                    imgui.SetNextItemWidth(120)
                    local vx = { tonumber(sample.pos[key].x or 0) or 0 }
                    if imgui.InputInt('##gb_pos_' .. key .. '_x', vx) then
                        local nx = tonumber(vx[1]) or 0
                        each_target(function(b)
                            ensure_xy_one(b, key, sample.pos[key].x or 0, sample.pos[key].y or 0)
                            b.pos[key].x = nx
                        end)
                        save_state()
                    end

                    -- Y
                    imgui.SameLine()
                    imgui.Text('Y:')
                    imgui.SameLine()
                    imgui.SetNextItemWidth(120)
                    local vy = { tonumber(sample.pos[key].y or 0) or 0 }
                    if imgui.InputInt('##gb_pos_' .. key .. '_y', vy) then
                        local ny = tonumber(vy[1]) or 0
                        each_target(function(b)
                            ensure_xy_one(b, key, sample.pos[key].x or 0, sample.pos[key].y or 0)
                            b.pos[key].y = ny
                        end)
                        save_state()
                    end
                end

                local base_x = imgui.GetCursorPosX()
                local right_x = base_x + 440

                imgui.SetCursorPosX(base_x)
                pos_group('Label',   'label')
                imgui.SameLine()
                imgui.SetCursorPosX(right_x)
                pos_group('Keybind ', 'keybind')

                imgui.Spacing()

                imgui.SetCursorPosX(base_x)
                pos_group('CD    ',      'cd')
                imgui.SameLine()
                imgui.SetCursorPosX(right_x)
                pos_group('Counter', 'counter')

                imgui.Separator()

            end
        end

        if imgui.CollapsingHeader('Text settings', imgui.TreeNodeFlags_DefaultOpen) then


            -------------------------------------------------------------------
            -- Text settings (global defaults)
            -------------------------------------------------------------------
            st.ui = st.ui or {}
            st.ui.text = st.ui.text or {}

            local function clamp(v, lo, hi)
                v = tonumber(v or 0) or 0
                if v < lo then v = lo end
                if v > hi then v = hi end
                return v
            end

            local function ensure_text_row(key, def_enabled, def_size, def_shadow, def_col, def_shcol)
                local t = st.ui.text
                t[key] = t[key] or {}
                local r = t[key]

                if r.enabled == nil then r.enabled = def_enabled end
                r.size   = clamp(r.size   or def_size,   8, 48)
                r.shadow = clamp(r.shadow or def_shadow, 0, 8)

                r.color  = r.color  or def_col
                r.scolor = r.scolor or def_shcol

                -- normalize color tables (RGBA 0-255)
                if type(r.color) ~= 'table' or #r.color < 4 then r.color = { def_col[1], def_col[2], def_col[3], def_col[4] } end
                if type(r.scolor) ~= 'table' or #r.scolor < 4 then r.scolor = { def_shcol[1], def_shcol[2], def_shcol[3], def_shcol[4] } end
                return r
            end

            local function edit_rgba_255(label, t, popup_id)
                local c = { (t[1] or 0) / 255, (t[2] or 0) / 255, (t[3] or 0) / 255, (t[4] or 255) / 255 }
                imgui.AlignTextToFramePadding()
                imgui.Text(label)
                imgui.SameLine()

                -- Color square with a gray border to make it stand out
                imgui.PushStyleColor(ImGuiCol_Border, { 0.5, 0.5, 0.5, 1.0 })
                if imgui.ColorButton('##' .. popup_id, c, 0, { 18, 18 }) then
                    imgui.OpenPopup(popup_id)
                end
                imgui.PopStyleColor(1)

                if imgui.BeginPopup(popup_id) then
                    if imgui.ColorPicker4('##picker_' .. popup_id, c, imgui.ColorEditFlags_AlphaBar) then
                        t[1] = math.floor((c[1] or 0) * 255 + 0.5)
                        t[2] = math.floor((c[2] or 0) * 255 + 0.5)
                        t[3] = math.floor((c[3] or 0) * 255 + 0.5)
                        t[4] = math.floor((c[4] or 0) * 255 + 0.5)
                        save_state()
                    end
                    imgui.EndPopup()
                end
            end


            local function text_row(title, key)
                local base = st.ui.text[key]
                local mode = tostring(st.ui.apply_to or 'button')

                -- target table we actually edit: global by default
                local target = base

                -- For "This Button" mode, use per-button overrides
                if mode == 'button' and EDIT.selected > 0 and st.buttons[EDIT.selected] then
                    local bsel = st.buttons[EDIT.selected]
                    bsel.text = bsel.text or {}
                    bsel.text[key] = bsel.text[key] or {}

                    local bt = bsel.text[key]

                    if bt.enabled == nil then bt.enabled = base.enabled end
                    bt.size   = tonumber(bt.size   or base.size)   or base.size
                    bt.shadow = tonumber(bt.shadow or base.shadow) or base.shadow

                    if type(bt.color) ~= 'table' or #bt.color < 4 then
                        bt.color = { base.color[1], base.color[2], base.color[3], base.color[4] }
                    end
                    if type(bt.scolor) ~= 'table' or #bt.scolor < 4 then
                        bt.scolor = { base.scolor[1], base.scolor[2], base.scolor[3], base.scolor[4] }
                    end

                    target = bt
                end

                local r = target

                local en = { r.enabled == true }
                if imgui.Checkbox('##gb_txt_en_' .. key, en) then
                    r.enabled = (en[1] == true)
                    save_state()
                end
                imgui.SameLine()
                imgui.AlignTextToFramePadding()
                imgui.Text(title)

                imgui.SameLine()
                imgui.SetNextItemWidth(120)
                local sz = { tonumber(r.size or 14) or 14 }
                if imgui.SliderInt('##gb_txt_sz_' .. key, sz, 8, 48) then
                    r.size = sz[1]
                    save_state()
                end

                imgui.SameLine()
                imgui.AlignTextToFramePadding()
                imgui.Text('Shadow')
                imgui.SameLine()
                imgui.SetNextItemWidth(90)
                local sh = { tonumber(r.shadow or 1) or 1 }
                if imgui.SliderInt('##gb_txt_sh_' .. key, sh, 0, 8) then
                    r.shadow = sh[1]
                    save_state()
                end

                imgui.SameLine()
                edit_rgba_255('Text', r.color,  'gb_txt_col_' .. key)
                imgui.SameLine()
                edit_rgba_255('Shadow', r.scolor, 'gb_txt_scol_' .. key)
            end


            -- Defaults (matches your current style where possible)
            ensure_text_row('label',   true,  14, 2, { 255, 255, 255, 255 }, { 0, 0, 0, 220 })
            ensure_text_row('item',    false, 14, 1, { 255, 255, 255, 255 }, { 0, 0, 0, 220 })
            ensure_text_row('cd',      true,  14, 1, { 255, 255, 255, 255 }, { 0, 0, 0, 220 })
            ensure_text_row('counter', true,  14, 1, { 255, 255, 255, 245 }, { 0, 0, 0, 210 })
            ensure_text_row('keybind', true,  12, 1, { 255, 255, 255, 255 }, { 0, 0, 0, 200 })
            ensure_text_row('tooltip', true,  14, 0, { 255, 255, 255, 255 }, { 0, 0, 0, 0 })

            -- Apply To (same as Button settings)
            imgui.AlignTextToFramePadding()
            imgui.Text('Apply To:')
            imgui.SameLine()
            imgui.SetNextItemWidth(180)

            local cur_apply = tostring(st.ui.apply_to or 'button')
            if imgui.BeginCombo('##gb_apply_to_text', apply_to_label(cur_apply), 0) then
                for i = 1, #APPLY_TO do
                    local e = APPLY_TO[i]
                    local sel = (cur_apply == e.id)
                    if imgui.Selectable(e.label .. '##apply_text_' .. tostring(i), sel) then
                        st.ui.apply_to = e.id
                        save_state()
                        cur_apply = e.id
                    end
                end
                imgui.EndCombo()
            end

            -- Selected button status (only for This Button)
            if cur_apply == 'button' then
                imgui.SameLine()
                imgui.Dummy({ 10, 1 })
                imgui.SameLine()

                local label = 'None'
                if EDIT.selected > 0 and st.buttons[EDIT.selected]
                    and st.buttons[EDIT.selected].name then
                    label = st.buttons[EDIT.selected].name
                end

                imgui.Text('Selected Button:')
                imgui.SameLine()

                if label == 'None' then
                    imgui.TextDisabled(label)
                else
                    imgui.Text(label)
                end

                if imgui.IsItemHovered() then
                    imgui.BeginTooltip()
                    imgui.Text('Select a button by:')
                    imgui.BulletText('Right-clicking a button on a bar')
                    imgui.BulletText('Clicking a button in the list below')
                    imgui.EndTooltip()
                end
            end

            imgui.Separator()

            text_row('Label      ',   'label');   imgui.Separator()
            text_row('CD          ',      'cd');      imgui.Separator()
            text_row('Counter', 'counter'); imgui.Separator()
            text_row('Keybind', 'keybind'); imgui.Separator()
            text_row('Tooltip  ', 'tooltip')

            imgui.Separator()
        end -- Text settings



        if imgui.CollapsingHeader('Weaponskill & Skillchain Settings', imgui.TreeNodeFlags_DefaultOpen) then

        -----------------------------------------------------------------------
        -- Skillchain Highlight / WS
        -----------------------------------------------------------------------


        do
            st.ui = st.ui or {}

            -- defaults (per-character)
            if st.ui.sc_mode == nil then st.ui.sc_mode = 'crawler' end
            if st.ui.sc_style == nil then st.ui.sc_style = 'crawl_yellow' end
            st.ui.sc_color = st.ui.sc_color or { 255, 215, 0, 255 }

            imgui.Text('Skillchain Highlight (WS):')

            -- WS element overlay (default ON)
if st.ui.ws_elem_overlay == nil then st.ui.ws_elem_overlay = true end

-- WS element icon size (default 12px; clamped)
if st.ui.ws_elem_size == nil then st.ui.ws_elem_size = 12 end
st.ui.ws_elem_size = tonumber(st.ui.ws_elem_size or 12) or 12
if st.ui.ws_elem_size < 8 then st.ui.ws_elem_size = 8 end
if st.ui.ws_elem_size > 24 then st.ui.ws_elem_size = 24 end

do
    local v = { (st.ui.ws_elem_overlay ~= false) }
    imgui.AlignTextToFramePadding()
    imgui.Text('WS Element Icon:')
    imgui.SameLine()
    if imgui.Checkbox('##gb_ws_elem_overlay', v) then
        st.ui.ws_elem_overlay = (v[1] == true)
        save_state()
    end

    -- Size slider on same row (only when enabled)
    if st.ui.ws_elem_overlay ~= false then
        imgui.SameLine()
        imgui.Dummy({ 10, 1 })
        imgui.SameLine()

        imgui.AlignTextToFramePadding()
        imgui.Text('Size:')
        imgui.SameLine()
        imgui.SetNextItemWidth(140)

        local sz = { tonumber(st.ui.ws_elem_size or 12) or 12 }
        if imgui.SliderInt('##gb_ws_elem_size', sz, 8, 24) then
            st.ui.ws_elem_size = sz[1]
            save_state()
        end
    end
end



            -- Effect (with optional Border Color button on same row)
            local cur_mode = tostring(st.ui.sc_mode or 'off')
            local show_crawl = (cur_mode == 'crawler')
local show_color = (cur_mode == 'border')


            local function sc_mode_label(m)
    m = tostring(m or 'off')
    if m == 'off' then return 'Off' end
    if m == 'border' then return 'Border' end
    if m == 'crawler' then return 'Crawler' end
    return m
end

            imgui.AlignTextToFramePadding()
            imgui.Text('Effect:')
            imgui.SameLine()
            imgui.SetNextItemWidth(220)

            if imgui.BeginCombo('##gb_sc_mode', sc_mode_label(cur_mode), 0) then
                local modes = {
    { id = 'off',     name = 'Off' },
    { id = 'border',  name = 'Border' },
    { id = 'crawler', name = 'Crawler' },
}

                for i = 1, #modes do
                    local m = modes[i]
                    local sel = (cur_mode == m.id)
                    if imgui.Selectable(m.name .. '##gb_sc_mode_' .. m.id, sel) then
                        st.ui.sc_mode = m.id
                        save_state()
                        cur_mode = m.id
                        show_crawl = (cur_mode == 'crawler')
show_color = (cur_mode == 'border')

                    end
                end
                imgui.EndCombo()
            end

            if show_color then
                local t = st.ui.sc_color
                local c = { (t[1] or 0) / 255, (t[2] or 0) / 255, (t[3] or 0) / 255, (t[4] or 255) / 255 }

                imgui.SameLine()
                imgui.Dummy({ 10, 1 })
                imgui.SameLine()

                imgui.AlignTextToFramePadding()
                imgui.Text('Border Color:')
                imgui.SameLine()

                if imgui.ColorButton('##gb_sc_color_btn', c, 0, { 18, 18 }) then
                    imgui.OpenPopup('gb_sc_color_popup')
                end


                if imgui.BeginPopup('gb_sc_color_popup') then
                    imgui.Text('Border Color')
                    if imgui.ColorPicker4('##gb_sc_color_pick', c, imgui.ColorEditFlags_AlphaBar) then
                        t[1] = math.floor((c[1] or 0) * 255 + 0.5)
                        t[2] = math.floor((c[2] or 0) * 255 + 0.5)
                        t[3] = math.floor((c[3] or 0) * 255 + 0.5)
                        t[4] = math.floor((c[4] or 0) * 255 + 0.5)
                        save_state()
                    end
                    imgui.EndPopup()
                end
            end

            -- Crawler Style (only when crawler is used)
            if show_crawl then
                imgui.AlignTextToFramePadding()
                imgui.Text('Effect Type:')

                imgui.SameLine()
                imgui.SetNextItemWidth(220)

                local function sc_list_styles()
                    local out = {}
                    local ui_dir = (gb_root_dir() .. 'assets' .. SEP .. 'ui' .. SEP):gsub('/', '\\')

                    local p = io.popen(('dir /b /ad "%s" 2>nul'):format(ui_dir))
                    if p ~= nil then
                        for line in p:lines() do
                            local fn = tostring(line or ''):gsub('^%s+', ''):gsub('%s+$', '')
					if fn ~= '' and not fn:match('^%.') then
						-- Show any folder that actually contains crawl frames.
						local test = ui_dir .. fn .. '\\crawl1.png'
						local fh = io.open(test, 'rb')
						if fh ~= nil then
							fh:close()
							out[#out + 1] = fn
						end
					end

                        end
                        p:close()
                    end

                    table.sort(out, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
                    return out
                end

                local style_label = tostring(st.ui.sc_style or 'crawl_yellow')
                if imgui.BeginCombo('##gb_sc_style', style_label, 0) then
                    local styles = sc_list_styles()
                    if #styles == 0 then
                        imgui.TextDisabled('No crawl_* folders found under assets/ui')
                    else
                        for i = 1, #styles do
                            local s = styles[i]
                            local sel = (tostring(st.ui.sc_style or '') == s)
                            if imgui.Selectable(s .. '##gb_sc_style_' .. tostring(i), sel) then
                                st.ui.sc_style = s
                                save_state()
                            end
                        end
                    end
                    imgui.EndCombo()
                end
            end

            imgui.Separator()
        end

        end -- Weaponskill & Skillchain Settings


    end

    ---------------------------------------------------------------------------
    -- Filters row: Bar / Search
    ---------------------------------------------------------------------------
    imgui.AlignTextToFramePadding()
    imgui.Text('Area:')
    imgui.SameLine()
    imgui.SetNextItemWidth(160)

    if EDIT.view_bar == nil or tonumber(EDIT.view_bar or 0) <= 0 then
        EDIT.view_bar = 1
    end

    local view_label = view_ui_name(EDIT.view_bar)
    if imgui.BeginCombo('##gb_btn_area_view', view_label, 0) then
        for i = 1, #VIEW_OPTS do
            local label = view_ui_name(i)
            if imgui.Selectable(label .. '##view_area_' .. tostring(i), i == EDIT.view_bar) then
                EDIT.view_bar = i
            end
        end
        imgui.EndCombo()
    end


    imgui.SameLine()
    imgui.AlignTextToFramePadding()
    imgui.Text('Search:')
    imgui.SameLine()
    imgui.SetNextItemWidth(260)
    imgui.InputText('##gb_btn_list_filter', EDIT._list_filter, 128)

    local want_bar = VIEW_OPTS[EDIT.view_bar] or 'all'

    local f = tostring(EDIT._list_filter[1] or ''):lower()

    local function matches_filter(b)
        if f == '' then return true end
        local n = tostring(b.name or ''):lower()
        local i = tostring(b.icon or ''):lower()
        local c = tostring(b.cmd  or ''):lower()
        return (n:find(f, 1, true) ~= nil) or (i:find(f, 1, true) ~= nil) or (c:find(f, 1, true) ~= nil)
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Button list
    ---------------------------------------------------------------------------
    if imgui.BeginChild('##gb_btn_list', { 0, 170 }, true) then
        local idx = {}
        for i = 1, #st.buttons do idx[#idx + 1] = i end
        table.sort(idx, function(a, b)
            return (st.buttons[a].id or 0) < (st.buttons[b].id or 0)
        end)

        for _, i in ipairs(idx) do
            local b = st.buttons[i]
            if (want_bar == 'all' or tostring(b.bar or '') == tostring(want_bar)) and matches_filter(b) then

                local sc = tostring(b.scope or 'all')
                local scope_tag = 'Global'
                if sc == 'main' or sc == 'job' then
                    local jid = tonumber(b.job or 0) or 0
                    local ab = JOB_ABBR[jid] or tostring(jid)
                    scope_tag = 'Main-' .. ab
                elseif sc == 'sub' then
                    local jid = tonumber(b.job or 0) or 0
                    local ab = JOB_ABBR[jid] or tostring(jid)
                    scope_tag = 'Sub-' .. ab
                end

                local name = tostring(b.name or '')
                local row_text = string.format('%s (%s)', name, scope_tag)

                local kb = tostring(b.keybind or ''):upper():gsub('%s+', '')
                if kb ~= '' then
                    local mod = tostring(st.ui and st.ui.kb_modifier or '@')
                    row_text = row_text .. '    Key bind: ' .. mod .. kb
                end


                -- icon (custom png override, else item icon)
                local icon_h = nil

                local custom_icon = tostring(b.icon or ''):gsub('^%s+', ''):gsub('%s+$', '')
                if custom_icon ~= '' then
                    local upper = custom_icon:upper()

                    -- Support: ITEM:<id> icon specs (tHotBar style)
                    if upper:match('^ITEM:%d+$') then
                        icon_h = gb_texcache:GetTexture(upper)
                    else
                        local ip = icon_path(custom_icon)
                        if ip ~= nil then icon_h = load_texture_handle(ip) end

                        -- fallback: assets/mounts/<file>.png
                        if icon_h == nil then
                            local mp = gb_root_dir() .. 'assets' .. SEP .. 'mounts' .. SEP .. custom_icon
                            icon_h = load_texture_handle(mp)
                        end
                    end
                else

                    local iid = tonumber(b.item_id or 0) or 0
                    if iid > 0 then
                        icon_h = gb_texcache:GetTexture('ITEM:' .. tostring(iid))
                    else

                        -- Job Abilities / WS icon auto-resolve when no custom icon and no item_id
                        local aid = tonumber(b.ability_id or 0) or 0
                        if aid > 0 then
                            if is_ws_cmd(b.cmd) then
                                local icon_spec = ws_icon_spec_for_ability(aid)
                                if icon_spec ~= nil then
                                    icon_h = gb_texcache:GetTexture(icon_spec)
                                end
                            elseif is_ja_cmd(b.cmd) then
                                icon_h = load_ja_icon_handle_by_ability_id(aid)
                            end
                        end

                        local sid = tonumber(b.spell_id or 0) or 0
                        if sid > 0 then
                            -- Trusts
                            if is_trust_spell_id(sid) then
                                local tp = trust_icon_path(sid)
                                if tp ~= nil then
                                    icon_h = load_texture_handle(tp)
                                end
                            end

                            -- Name-based spell icons (assets/spells/<name>.png)
                            if icon_h == nil then
                                local resMgr = nil
                                pcall(function()
                                    resMgr = AshitaCore:GetResourceManager()
                                end)

                                if resMgr ~= nil and resMgr.GetSpellById ~= nil then
                                    local res = nil
                                    pcall(function()
                                        res = resMgr:GetSpellById(sid)
                                    end)

                                    if res ~= nil and res.Name ~= nil then
                                        local spell_name = nil
                                        if type(res.Name) == 'string' then
                                            spell_name = res.Name
                                        elseif type(res.Name) == 'userdata' and res.Name[1] ~= nil then
                                            spell_name = tostring(res.Name[1])
                                        else
                                            spell_name = tostring(res.Name)
                                        end

                                        local p = spell_name_icon_path(spell_name)
                                        if p ~= nil then
                                            icon_h = load_texture_handle(p)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                if icon_h ~= nil then
                    imgui.Image(icon_h, { 22, 22 })
                else
                    imgui.Dummy({ 22, 22 })
                end

                imgui.SameLine()

                -- stable hidden id
                local id_suffix = '##gb_btn_row_' .. tostring(b.id or i)
                local sel = (EDIT.selected == i)
                if imgui.Selectable(row_text .. id_suffix, sel) then
                    EDIT.selected = i
                    apply_selected_to_editor(st)
                end
            end
        end
    end
    imgui.EndChild()

    if imgui.Button('Add Button') then
        local cur_main = get_main_job_id()
        local cur_sub  = get_sub_job_id()

        local b = {
            id = next_id(st),
            name = '',
            icon = '',
            cmd  = '',
            bar  = BAR_OPTS[EDIT.view_bar] or 'top',
            scope = 'all',
            job = nil,
            x = 0, y = 0,
            w = tonumber(st.ui.icon_size or 18) or 18,
            h = tonumber(st.ui.icon_size or 18) or 18,
        }

        if EDIT.scope == 2 then
            b.scope = 'main'
            b.job = cur_main
        elseif EDIT.scope == 3 then
            b.scope = 'sub'
            b.job = cur_sub
        end

        st.buttons[#st.buttons + 1] = b
        save_state()

        EDIT.selected = #st.buttons
        EDIT._force_show = true
        apply_selected_to_editor(st)
    end

    imgui.SameLine()

    imgui.PushStyleColor(ImGuiCol_Button,        { 0.75, 0.15, 0.15, 0.85 })
    imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.85, 0.20, 0.20, 0.95 })
    imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 0.65, 0.10, 0.10, 1.00 })
    if imgui.Button('Delete Button') then
        if EDIT.selected > 0 and st.buttons[EDIT.selected] ~= nil then
            table.remove(st.buttons, EDIT.selected)
            EDIT.selected = 0
            apply_selected_to_editor(st)
            save_state()
        end
    end
    imgui.PopStyleColor(3)

    imgui.Separator()

    if EDIT.selected == 0 and (EDIT._force_show ~= true) then
        imgui.TextDisabled('Select a button from the list, or click Add Button to create a new one.')
        return
    end

    ---------------------------------------------------------------------------
    -- Editor header
    ---------------------------------------------------------------------------
    do
        local hdr = 'Add New Button'
        if EDIT.selected > 0 and st.buttons[EDIT.selected] ~= nil then
            hdr = string.format('Edit Button: %s', tostring(EDIT.name[1] or ''))
        end
        pcall(imgui.SetWindowFontScale, 1.10)
        pcall(imgui.TextColored, { 1.00, 0.90, 0.20, 1.00 }, hdr)
        pcall(imgui.SetWindowFontScale, 1.00)
    end

    ---------------------------------------------------------------------------
    -- Identity + Placement (aligned)
    ---------------------------------------------------------------------------
    local field_x = 85
    local field_w = 320

    -- Label
    imgui.AlignTextToFramePadding()
    imgui.Text('Label:')
    imgui.SameLine()
    imgui.SetCursorPosX(field_x)
    imgui.SetNextItemWidth(field_w)
    if imgui.InputText('##gb_btn_label', EDIT.name, 64) then
        apply_editor_to_selected(st)
    end

    -- Icon
    imgui.AlignTextToFramePadding()
    imgui.Text('Icon:')
    imgui.SameLine()
    imgui.SetCursorPosX(field_x)
    imgui.SetNextItemWidth(field_w)
    if imgui.InputText('##gb_btn_image', EDIT.icon, 128) then
        apply_editor_to_selected(st)
    end

    imgui.SameLine()

    st.ui._img_filter = st.ui._img_filter or { '' }

    local browse_h = load_texture_handle(icon_path('browse.png') or '')
    local clicked = false
    if browse_h ~= nil then
        clicked = imgui.ImageButton(browse_h, { 18, 18 })
    else
        clicked = imgui.Button('...', { 18, 18 })
    end

    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
        imgui.Text('Browse images')
        imgui.EndTooltip()
    end

    if clicked then
        imgui.OpenPopup('##gb_img_picker')
    end

    ---------------------------------------------------------------------------
    -- Image picker popup
    ---------------------------------------------------------------------------
    if imgui.BeginPopup('##gb_img_picker') then
        if imgui.Button('Open Folder') then
            local dir = plugin_images_dir():gsub('/', '\\')
            pcall(function() os.execute('start "" "' .. dir .. '"') end)
        end

        imgui.SameLine()
        imgui.Text('filter')
        imgui.SameLine()
        imgui.SetNextItemWidth(220)
        imgui.InputText('##gb_img_filter', st.ui._img_filter, 128)

        imgui.Separator()

        local dir = plugin_images_dir()
        local filter = tostring(st.ui._img_filter[1] or ''):lower()

        if imgui.BeginChild('##gb_img_list', { 360, 260 }, true) then
            local cmd = ('dir /b "%s" 2>nul'):format(dir:gsub('/', '\\'))
            local p = io.popen(cmd)
            if p ~= nil then
                for line in p:lines() do
                    local fn = tostring(line or '')
                    local lfn = fn:lower()
                    if lfn:match('%.png$') and (filter == '' or lfn:find(filter, 1, true) ~= nil) then
                        local h = load_texture_handle(icon_path(fn) or '')
                        if h ~= nil then
                            local ok_img = pcall(function()
                                imgui.Image(h, { 26, 26 })
                            end)
                            if ok_img then imgui.SameLine() end
                        end
                        if imgui.Selectable(fn, false) then
                            EDIT.icon[1] = fn
                            apply_editor_to_selected(st)
                            imgui.CloseCurrentPopup()
                        end
                    end
                end
                p:close()
            end
        end
        imgui.EndChild()

        imgui.EndPopup()
    end

    -- Area (editor only)
    imgui.AlignTextToFramePadding()
    imgui.Text('Area:')
    imgui.SameLine()
    imgui.SetCursorPosX(field_x)
    imgui.SetNextItemWidth(field_w)

    local edit_area_label = bar_ui_name(EDIT.bar)
    if imgui.BeginCombo('##gb_btn_area_edit', edit_area_label, 0) then
        for i = 1, #BAR_OPTS do
            local label = bar_ui_name(i)
            if imgui.Selectable(label .. '##edit_area_' .. tostring(i), i == EDIT.bar) then
                EDIT.bar = i
                apply_editor_to_selected(st)
            end
        end
        imgui.EndCombo()
    end

    -- Scope (editor only)
    imgui.AlignTextToFramePadding()
    imgui.Text('Scope:')
    imgui.SameLine()
    imgui.SetCursorPosX(field_x)
    imgui.SetNextItemWidth(field_w)

    local main_id = get_main_job_id()
    local sub_id  = get_sub_job_id()
    local main_abbr = JOB_ABBR[main_id] or tostring(main_id)
    local sub_abbr  = JOB_ABBR[sub_id]  or tostring(sub_id)

    local scope_preview = 'Global'
    if EDIT.scope == 2 then scope_preview = 'Main (' .. main_abbr .. ')' end
    if EDIT.scope == 3 then scope_preview = 'Sub (' .. sub_abbr .. ')' end

    if imgui.BeginCombo('##gb_btn_scope_edit', scope_preview, 0) then
        if imgui.Selectable('Global##scope_global', EDIT.scope == 1) then
            EDIT.scope = 1
            EDIT.job[1] = 0
            apply_editor_to_selected(st)
        end
        if imgui.Selectable(('Main (%s)##scope_main'):format(main_abbr), EDIT.scope == 2) then
            EDIT.scope = 2
            EDIT.job[1] = main_id
            apply_editor_to_selected(st)
        end
        if imgui.Selectable(('Sub (%s)##scope_sub'):format(sub_abbr), EDIT.scope == 3) then
            EDIT.scope = 3
            EDIT.job[1] = sub_id
            apply_editor_to_selected(st)
        end
        imgui.EndCombo()
    end

    ---------------------------------------------------------------------------
    -- Keybind (per-button)
    ---------------------------------------------------------------------------
    st.ui = st.ui or {}
    if st.ui.kb_modifier == nil or tostring(st.ui.kb_modifier) == '' then
        st.ui.kb_modifier = '@'
    end
    if st.ui.kb_enabled == nil then st.ui.kb_enabled = true end
    if st.ui.kb_auto_apply == nil then st.ui.kb_auto_apply = false end

    -- Used keys excluding current selection (so the current key stays selectable)
    local used = {} -- kb_collect_used(st, EDIT.selected)  -- allow duplicate keys; resolved by job/scope
    local curk = tostring(EDIT.keybind_key[1] or ''):upper():gsub('%s+', '')
    if curk ~= '' then used[curk] = nil end

    imgui.AlignTextToFramePadding()
    imgui.Text('Keybind:')
    imgui.SameLine()
    imgui.SetCursorPosX(field_x)

    do
        imgui.TextDisabled(tostring(st.ui.kb_modifier or '@') .. ' +')

        imgui.SameLine()
        imgui.SetNextItemWidth(140)

        local cur = tostring(EDIT.keybind_key[1] or ''):upper():gsub('%s+', '')
        local preview = (cur ~= '' and cur) or 'Not bound'

        if imgui.BeginCombo('##gb_btn_keybind_key', preview, 0) then
            -- Not bound (first option)
            if imgui.Selectable('Not bound##gb_kb_none', (cur == '')) then
                EDIT.keybind_key[1] = ''
                EDIT.keybind_on[1] = false
                apply_editor_to_selected(st)
                kb_apply_all(st)
            end

            for i = 1, #KB_KEYS do
                local k = KB_KEYS[i]
                if not used[k] then
                    local sel = (cur == k)
                    if imgui.Selectable(k .. '##gb_kb_' .. k, sel) then
                        EDIT.keybind_key[1] = k
                        EDIT.keybind_on[1] = true
                        apply_editor_to_selected(st)
                        kb_apply_all(st)
                    end
                end
            end

            imgui.EndCombo()
        end
    end

    ---------------------------------------------------------------------------
    -- Action (macro editor + pickers)
    ---------------------------------------------------------------------------
    imgui.AlignTextToFramePadding()
    imgui.Text('Macro:')
    imgui.SameLine()
    imgui.SetCursorPosX(field_x)

    local btn_w = 20
local grid_gap = 6

-- Match other fields: full field_w, buttons sit to the right
imgui.SetNextItemWidth(field_w)
if imgui.InputTextMultiline('##gb_btn_cmd', EDIT.cmd, 2048, { field_w, 110 }, 0) then
    apply_editor_to_selected(st)
end

imgui.SameLine()

-- top-left of grid
local gx = imgui.GetCursorPosX()
local gy = imgui.GetCursorPosY()

-- icons from assets/ui (your new folder)
local macro_icon = load_texture_handle(ui_icon_path('macro.png') or '')
local item_icon  = load_texture_handle(ui_icon_path('item.png') or '')
local spell_icon = load_texture_handle(ui_icon_path('scroll.png') or '')
local ws_icon    = load_texture_handle(ui_icon_path('ws.png') or '')
local ja_icon    = load_texture_handle(ui_icon_path('ja.png') or '')        -- add this file
local trust_icon = load_texture_handle(ui_icon_path('trusts.png') or '')
local mount_icon = load_texture_handle(ui_icon_path('mounts.png') or '')    -- fixed: mounts.png

local function setpos(col, row)
    imgui.SetCursorPos({ gx + (col * (btn_w + grid_gap)), gy + (row * (btn_w + grid_gap)) })
end

local function icon_btn(tex, fallback, tip)
    local clicked = false
    if tex ~= nil then
        clicked = imgui.ImageButton(tex, { btn_w, btn_w })
    else
        clicked = imgui.Button(fallback, { btn_w, btn_w })
    end
    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
        imgui.Text(tip or '')
        imgui.EndTooltip()
    end
    return clicked
end

-- [macro] (row 0, col 0)
setpos(0, 0)
local clicked_macro = icon_btn(macro_icon, '.', 'Catseye Commands based on your set (General Tab) game mode')
if clicked_macro then
    imgui.OpenPopup('##gb_macro_picker')
end

-- [item] [spell] (row 1)
setpos(0, 1)
local clicked_item = icon_btn(item_icon, 'I', 'Pick an inventory item - sets macro and shows quantity overlay')
if clicked_item then
    imgui.OpenPopup('##gb_item_picker')
end

setpos(1, 1)
local clicked_spell = icon_btn(spell_icon, 'S', 'Pick an available spell - sets macro and shows cooldown overlay')
if clicked_spell then
    imgui.OpenPopup('##gb_spell_picker')
end

-- [ws] [ja] (row 2)
setpos(0, 2)
local clicked_ws = icon_btn(ws_icon, 'W', 'Pick a weaponskill')
if clicked_ws then
    imgui.OpenPopup('##gb_ws_picker')
end

setpos(1, 2)
local clicked_ja = icon_btn(ja_icon, 'JA', 'Pick a job ability')
if clicked_ja then
    imgui.OpenPopup('##gb_ja_picker')
end

-- [trust] [mount] (row 3)
setpos(0, 3)
local clicked_trust = icon_btn(trust_icon, 'T', 'Pick an available trust')
if clicked_trust then
    imgui.OpenPopup('##gb_trust_picker')
end

setpos(1, 3)
local clicked_mount = icon_btn(mount_icon, 'M', 'Pick a mount')
if clicked_mount then
    imgui.OpenPopup('##gb_mount_picker')
end

-- JA picker (Job Abilities)
st.ui = st.ui or {}
st.ui._ja_filter = st.ui._ja_filter or { '' }

if imgui.BeginPopup('##gb_ja_picker') then
    imgui.Text('Job Abilities')
    imgui.SameLine()
    imgui.Text('Search:')
    imgui.SameLine()
    imgui.SetNextItemWidth(220)
    imgui.InputText('##gb_ja_search', st.ui._ja_filter, 128)

    imgui.Separator()

    local filter = tostring(st.ui._ja_filter[1] or ''):lower()

    local resMgr = nil
    pcall(function()
        resMgr = AshitaCore:GetResourceManager()
    end)

    -- Match tHotBar range: 0x200..0x600
    -- Block "category headers" that are not real JAs.
    local BLOCKED_JA = {
        [567] = true, -- Pet Commands
        [603] = true, -- Blood Pact: Rage
        [609] = true, -- Phantom Roll
        [636] = true, -- Quick Draw
        [684] = true, -- Blood Pact: Ward
        [694] = true, -- Sambas
        [695] = true, -- Waltzes
        [710] = true, -- Jigs
        [711] = true, -- Steps
        [712] = true, -- Flourishes I
        [725] = true, -- Flourishes II
        [735] = true, -- Stratagems
        [763] = true, -- Ready
        [775] = true, -- Flourishes III
        [869] = true, -- Rune Enchantment
        [891] = true, -- Ward
        [892] = true, -- Effusion
    }

    if imgui.BeginChild('##gb_ja_list', { 360, 260 }, true) then
        if resMgr ~= nil and player_state ~= nil and type(player_state.KnowsAbility) == 'function' then
            for abilId = 0x200, 0x600 do
                if not BLOCKED_JA[abilId] then
                    local res = nil
                    pcall(function() res = resMgr:GetAbilityById(abilId) end)
                    if res ~= nil then
                        local okk, known = pcall(function()
                            return player_state:KnowsAbility(res.Id or abilId)
                        end)

                        if okk and known == true then
                            local nm = ''
                            if res.Name ~= nil then
                                if type(res.Name) == 'string' then
                                    nm = res.Name
                                elseif type(res.Name) == 'userdata' and res.Name[1] ~= nil then
                                    nm = tostring(res.Name[1])
                                else
                                    nm = tostring(res.Name)
                                end
                            end

                            if nm ~= '' then
                                if filter == '' or nm:lower():find(filter, 1, true) ~= nil then
                                    local rid = tonumber(res.Id or abilId) or abilId
                                    local label = string.format('%s##gb_ja_%d', nm, rid)
                                    if imgui.Selectable(label, false) then
                                        EDIT.item_id[1] = 0
                                        EDIT.spell_id[1] = 0
                                        EDIT.ability_id[1] = rid

                                        EDIT.name[1] = nm
                                        EDIT.cmd[1]  = string.format('/ja \"%s\" <me>', nm)

                                        apply_editor_to_selected(st)
                                        imgui.CloseCurrentPopup()
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    imgui.EndChild()

    imgui.Separator()
    if imgui.Button('Clear JA Link##gb_ja_clear') then
        EDIT.ability_id[1] = 0
        apply_editor_to_selected(st)
        imgui.CloseCurrentPopup()
    end

    imgui.EndPopup()
end



    ---------------------------------------------------------------------------
    -- Position & Size
    ---------------------------------------------------------------------------
    imgui.Text('Position & Size:')

    if EDIT.w[1] == 0 then EDIT.w[1] = tonumber(st.ui.icon_size or 18) or 18 end
    if EDIT.h[1] == 0 then EDIT.h[1] = tonumber(st.ui.icon_size or 18) or 18 end

    local f_w = 110
    local col1_w = 200
    local label_gap = 6
    local row_x = imgui.GetCursorPosX()

    imgui.AlignTextToFramePadding()
    imgui.Text('X: ')
    imgui.SameLine()
    imgui.Dummy({ label_gap, 1 })
    imgui.SameLine()
    imgui.SetNextItemWidth(f_w)
    if imgui.InputInt('##gb_btn_x', EDIT.x) then
        apply_editor_to_selected(st)
    end

    imgui.SameLine()
    imgui.SetCursorPosX(row_x + col1_w)

    imgui.AlignTextToFramePadding()
    imgui.Text('Y:')
    imgui.SameLine()
    imgui.Dummy({ label_gap, 1 })
    imgui.SameLine()
    imgui.SetNextItemWidth(f_w)
    if imgui.InputInt('##gb_btn_y', EDIT.y) then
        apply_editor_to_selected(st)
    end

    row_x = imgui.GetCursorPosX()

    imgui.AlignTextToFramePadding()
    imgui.Text('W:')
    imgui.SameLine()
    imgui.Dummy({ label_gap, 1 })
    imgui.SameLine()
    imgui.SetNextItemWidth(f_w)
    if imgui.InputInt('##gb_btn_w', EDIT.w) then
        apply_editor_to_selected(st)
    end

    imgui.SameLine()
    imgui.SetCursorPosX(row_x + col1_w)

    imgui.AlignTextToFramePadding()
    imgui.Text('H:')
    imgui.SameLine()
    imgui.Dummy({ label_gap, 1 })
    imgui.SameLine()
    imgui.SetNextItemWidth(f_w)
    if imgui.InputInt('##gb_btn_h', EDIT.h) then
        apply_editor_to_selected(st)
    end

    ---------------------------------------------------------------------------
    -- Macro picker
    ---------------------------------------------------------------------------
    if imgui.BeginPopup('##gb_macro_picker') then
        local mode = get_game_mode()

        local st2 = load_state()
        st2.ui = st2.ui or {}
        st2.ui._macro_filter = st2.ui._macro_filter or { '' }

        imgui.Text('Commands (' .. mode .. ')')
        imgui.SameLine()
        imgui.Text('Search:')
        imgui.SameLine()
        imgui.SetNextItemWidth(220)
        imgui.InputText('##gb_macro_search', st2.ui._macro_filter, 128)

        local filter = tostring(st2.ui._macro_filter[1] or ''):lower()
        imgui.Separator()

        local function entry_matches(e)
            if filter == '' then return true end
            local t = tostring(e.text or ''):lower()
            local c = tostring(e.command or ''):lower()
            local p = tostring(e.tooltip or ''):lower()
            return (t:find(filter, 1, true) ~= nil) or (c:find(filter, 1, true) ~= nil) or (p:find(filter, 1, true) ~= nil)
        end

        local function entry_allowed_for_mode(e)
            local em = e.mode
            if type(em) == 'string' then
                em = em:upper()
                return em == mode
            end

            local ms = e.modes
            if type(ms) == 'table' then
                return ms[mode] == true
            end

            return true
        end

        local list = COMMANDS[mode]
        local flat_fallback = false
        if type(list) ~= 'table' then
            list = COMMANDS
            flat_fallback = true
        end
        if type(list) ~= 'table' then list = {} end

        if imgui.BeginChild('##macro_list', { 360, 260 }, true) then
            if flat_fallback then
                for i = 1, #list do
                    local e = list[i]
                    if type(e) == 'table' and entry_allowed_for_mode(e) and entry_matches(e) then
                        local label = tostring(e.text or '')
                        if label == '' then label = tostring(e.command or '') end

                        if imgui.Selectable(label, false) then
                            macrobox_append_line(tostring(e.command or ''))
                            imgui.CloseCurrentPopup()
                        end

                        if imgui.IsItemHovered() then
                            local tip = tostring(e.tooltip or '')
                            if tip ~= '' then
                                imgui.BeginTooltip()
                                imgui.Text(tip)
                                imgui.EndTooltip()
                            end
                        end
                    end
                end
            else
                for i = 1, #list do
                    local e = list[i]
                    if type(e) == 'table' and entry_matches(e) then
                        local label = tostring(e.text or '')
                        if label == '' then label = tostring(e.command or '') end

                        if imgui.Selectable(label, false) then
                            macrobox_append_line(tostring(e.command or ''))
                            imgui.CloseCurrentPopup()
                        end

                        if imgui.IsItemHovered() then
                            local tip = tostring(e.tooltip or '')
                            if tip ~= '' then
                                imgui.BeginTooltip()
                                imgui.Text(tip)
                                imgui.EndTooltip()
                            end
                        end
                    end
                end
            end
        end
        imgui.EndChild()

        imgui.EndPopup()
    end

    ---------------------------------------------------------------------------
    -- Item picker (inventory)
    ---------------------------------------------------------------------------
    st.ui = st.ui or {}
    st.ui._item_filter = st.ui._item_filter or { '' }

    if imgui.BeginPopup('##gb_item_picker') then
        imgui.Text('Inventory Items')
        imgui.SameLine()
        imgui.Text('Search:')
        imgui.SameLine()
        imgui.SetNextItemWidth(220)
        imgui.InputText('##gb_item_search', st.ui._item_filter, 128)

        imgui.Separator()

        inv_refresh()
        local filter = tostring(st.ui._item_filter[1] or ''):lower()

        if imgui.BeginChild('##gb_item_list', { 360, 260 }, true) then
            for i = 1, #INV.list do
                local e = INV.list[i]
                local nm = ''
                if type(e.name) == 'string' then
                    nm = e.name
                elseif type(e.name) == 'userdata' and e.name[1] ~= nil then
                    nm = tostring(e.name[1])
                else
                    nm = tostring(e.name or '')
                end
                local ct = tonumber(e.count or 0) or 0

                if filter == '' or nm:lower():find(filter, 1, true) ~= nil then
                    local label = string.format('%s  x%d##gb_item_%d', nm, ct, tonumber(e.id or 0) or 0)
                    if imgui.Selectable(label, false) then
                        EDIT.item_id[1] = tonumber(e.id or 0) or 0
                        EDIT.spell_id[1] = 0

                        EDIT.name[1] = nm
                        EDIT.cmd[1]  = string.format('/item \"%s\" <me>', nm)

                        apply_editor_to_selected(st)
                        imgui.CloseCurrentPopup()
                    end
                end
            end
        end
        imgui.EndChild()

        imgui.Separator()
        if imgui.Button('Clear Spell Link##gb_spell_clear') then
            EDIT.item_id[1] = 0
            apply_editor_to_selected(st)
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    end

    ---------------------------------------------------------------------------
    -- Spell picker (available spells) - tHotBar-style usable filtering
    ---------------------------------------------------------------------------
    st.ui._spell_filter = st.ui._spell_filter or { '' }

    if imgui.BeginPopup('##gb_spell_picker') then
        imgui.Text('Available Spells')
        imgui.SameLine()
        imgui.Text('Search:')
        imgui.SameLine()
        imgui.SetNextItemWidth(220)
        imgui.InputText('##gb_spell_search', st.ui._spell_filter, 128)

        imgui.Separator()

        local filter = tostring(st.ui._spell_filter[1] or ''):lower()

        local resMgr = nil
        pcall(function()
            resMgr = AshitaCore:GetResourceManager()
        end)

        local mainJob      = tonumber(get_main_job_id() or 0) or 0
        local mainJobLevel = tonumber(get_main_job_level() or 0) or 0
        local subJob       = tonumber(get_sub_job_id() or 0) or 0
        local subJobLevel  = tonumber(get_sub_job_level() or 0) or 0

        -- Subjob cap: floor(main/2)
        do
            local cap = math.floor(mainJobLevel / 2)
            if cap < 0 then cap = 0 end
            if subJobLevel > cap then subJobLevel = cap end
        end

        local dbg_total_res = 0
        local dbg_owned     = 0
        local dbg_usable    = 0
        local dbg_shown     = 0

        if GB_DEBUG_SPELL_PICKER then
            imgui.TextDisabled(string.format(
                'DBG resMgr=%s player_state=%s HasSpell=%s main=%d/%d sub=%d/%d filter="%s"',
                tostring(resMgr ~= nil),
                tostring(player_state ~= nil),
                tostring(player_state ~= nil and type(player_state.HasSpell) == 'function'),
                mainJob, mainJobLevel, subJob, subJobLevel,
                tostring(st.ui._spell_filter[1] or '')
            ))
            imgui.Separator()
        end

        if imgui.BeginChild('##gb_spell_list', { 360, 260 }, true) then
            if resMgr ~= nil and player_state ~= nil and type(player_state.HasSpell) == 'function' then
                for spellId = 1, 0x400 do
                    local res = nil
                    pcall(function() res = resMgr:GetSpellById(spellId) end)
                    if res ~= nil then
                        dbg_total_res = dbg_total_res + 1

                        local owned = false
                        do
                            local ok_a, has_a = pcall(function() return player_state:HasSpell(res) end)
                            if ok_a and has_a == true then
                                owned = true
                            else
                                local ok_b, has_b = pcall(function() return player_state:HasSpell(spellId) end)
                                if ok_b and has_b == true then
                                    owned = true
                                end
                            end
                        end

                        if owned then
                            dbg_owned = dbg_owned + 1

                            local levelRequired = res.LevelRequired
                            local usable = false

                            -- IMPORTANT: Ashita commonly exposes LevelRequired as userdata (array-like), not a Lua table.
                            if levelRequired ~= nil and levelRequired[1] ~= nil then
                                local jpMask = tonumber(res.JobPointMask or 0) or 0

                                local function job_ok(job, lvl)
                                    job = tonumber(job or 0) or 0
                                    lvl = tonumber(lvl or 0) or 0
                                    if job < 0 or job > 22 then return false end

                                    local req = tonumber(levelRequired[job + 1] or -1) or -1
                                    if req == -1 then
                                        return false
                                    end

                                    -- tHotBar: if JP bit set for this job, require job 99 + enough job points
                                    if bit.band(bit.rshift(jpMask, job), 1) == 1 then
                                        if lvl ~= 99 then
                                            return false
                                        end
                                        if type(player_state.GetJobPointTotal) ~= 'function' then
                                            return false
                                        end
                                        local jp = tonumber(player_state:GetJobPointTotal(job) or 0) or 0
                                        return jp >= req
                                    end

                                    return lvl >= req
                                end

                                -- Trust handling matches tHotBar behavior.
                                local is_trust = (tonumber(levelRequired[2] or 0) or 0) == 1

                                -- Exclude Trusts from the Spell picker (tHotBar separates these).
                                if not is_trust then
                                    usable = job_ok(mainJob, mainJobLevel) or job_ok(subJob, subJobLevel)
                                end
                            end

                            if usable then
                                dbg_usable = dbg_usable + 1

                                local sid = tonumber(res.Index or 0) or 0
                                local nm = ''
                                if res.Name ~= nil then
                                    if type(res.Name) == 'string' then
                                        nm = res.Name
                                    elseif type(res.Name) == 'userdata' and res.Name[1] ~= nil then
                                        nm = tostring(res.Name[1])
                                    else
                                        nm = tostring(res.Name)
                                    end
                                end

                                if sid > 0 and nm ~= '' then
                                    if filter == '' or nm:lower():find(filter, 1, true) ~= nil then
                                        local label = string.format('%s##gb_spell_%d', nm, spellId)
                                        dbg_shown = dbg_shown + 1
                                        if imgui.Selectable(label, false) then
                                            EDIT.spell_id[1] = spellId
                                            EDIT.item_id[1] = 0

                                            EDIT.name[1] = nm
                                            EDIT.cmd[1]  = string.format('/ma \"%s\" <me>', nm)

                                            apply_editor_to_selected(st)
                                            imgui.CloseCurrentPopup()
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        imgui.EndChild()

        imgui.Separator()
        if imgui.Button('Clear Spell Link##gb_spell_clear') then
            EDIT.spell_id[1] = 0
            apply_editor_to_selected(st)
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    end

    ---------------------------------------------------------------------------
    -- Trust picker (available trusts only)
    ---------------------------------------------------------------------------
    st.ui._trust_filter = st.ui._trust_filter or { '' }

    if imgui.BeginPopup('##gb_trust_picker') then
        imgui.Text('Available Trusts')
        imgui.SameLine()
        imgui.Text('Search:')
        imgui.SameLine()
        imgui.SetNextItemWidth(220)
        imgui.InputText('##gb_trust_search', st.ui._trust_filter, 128)

        imgui.Separator()

        local filter = tostring(st.ui._trust_filter[1] or ''):lower()

        local resMgr = nil
        pcall(function()
            resMgr = AshitaCore:GetResourceManager()
        end)

        local mainJob      = tonumber(get_main_job_id() or 0) or 0
        local mainJobLevel = tonumber(get_main_job_level() or 0) or 0
        local subJob       = tonumber(get_sub_job_id() or 0) or 0
        local subJobLevel  = tonumber(get_sub_job_level() or 0) or 0

        -- Subjob cap: floor(main/2)
        do
            local cap = math.floor(mainJobLevel / 2)
            if cap < 0 then cap = 0 end
            if subJobLevel > cap then subJobLevel = cap end
        end

        if imgui.BeginChild('##gb_trust_list', { 360, 260 }, true) then
            if resMgr ~= nil and player_state ~= nil and type(player_state.HasSpell) == 'function' then
                for spellId = 1, 0x400 do
                    local res = nil
                    pcall(function() res = resMgr:GetSpellById(spellId) end)
                    if res ~= nil then
                        local levelRequired = res.LevelRequired
                        if levelRequired ~= nil and levelRequired[1] ~= nil then
                            local is_trust = (tonumber(levelRequired[2] or 0) or 0) == 1
                            if is_trust then
                                local owned = false
                                do
                                    local ok_a, has_a = pcall(function() return player_state:HasSpell(res) end)
                                    if ok_a and has_a == true then
                                        owned = true
                                    else
                                        local ok_b, has_b = pcall(function() return player_state:HasSpell(spellId) end)
                                        if ok_b and has_b == true then
                                            owned = true
                                        end
                                    end
                                end

                                if owned then
                                    local jpMask = tonumber(res.JobPointMask or 0) or 0

                                    local function job_ok(job, lvl)
                                        job = tonumber(job or 0) or 0
                                        lvl = tonumber(lvl or 0) or 0
                                        if job < 0 or job > 22 then return false end

                                        local req = tonumber(levelRequired[job + 1] or -1) or -1
                                        if req == -1 then
                                            return false
                                        end

                                        if bit.band(bit.rshift(jpMask, job), 1) == 1 then
                                            if lvl ~= 99 then
                                                return false
                                            end
                                            if type(player_state.GetJobPointTotal) ~= 'function' then
                                                return false
                                            end
                                            local jp = tonumber(player_state:GetJobPointTotal(job) or 0) or 0
                                            return jp >= req
                                        end

                                        return lvl >= req
                                    end

                                    local main_ok = job_ok(mainJob, mainJobLevel)

                                    local sub_ok = false
                                    -- If JP bit set for this job, do not allow subjob usage (matches your spell picker logic)
                                    if bit.band(bit.rshift(jpMask, subJob), 1) == 0 then
                                        sub_ok = job_ok(subJob, subJobLevel)
                                    end

                                    if main_ok or sub_ok then
                                        local sid = tonumber(res.Index or 0) or 0
                                        local nm = ''
                                        if res.Name ~= nil then
                                            if type(res.Name) == 'string' then
                                                nm = res.Name
                                            elseif type(res.Name) == 'userdata' and res.Name[1] ~= nil then
                                                nm = tostring(res.Name[1])
                                            else
                                                nm = tostring(res.Name)
                                            end
                                        end

                                        if sid > 0 and nm ~= '' then
                                            if filter == '' or nm:lower():find(filter, 1, true) ~= nil then
                                                local label = string.format('%s##gb_trust_%d', nm, spellId)
                                                if imgui.Selectable(label, false) then
                                                    EDIT.spell_id[1] = spellId
                                                    EDIT.item_id[1] = 0

                                                    EDIT.name[1] = nm
                                                    EDIT.cmd[1]  = string.format('/ma \"%s\" <me>', nm)

                                                    apply_editor_to_selected(st)
                                                    imgui.CloseCurrentPopup()
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        imgui.EndChild()

        imgui.Separator()
        if imgui.Button('Clear Trust Link##gb_trust_clear') then
            EDIT.spell_id[1] = 0
            apply_editor_to_selected(st)
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    end

    ---------------------------------------------------------------------------
    -- Weaponskill picker
    ---------------------------------------------------------------------------
    st.ui._ws_filter = st.ui._ws_filter or { '' }

    if imgui.BeginPopup('##gb_ws_picker') then
        imgui.Text('Weapon Skills')
        imgui.SameLine()
        imgui.Text('Search:')
        imgui.SameLine()
        imgui.SetNextItemWidth(220)
        imgui.InputText('##gb_ws_search', st.ui._ws_filter, 128)

        imgui.Separator()

        local filter = tostring(st.ui._ws_filter[1] or ''):lower()

        local resMgr = nil
        pcall(function()
            resMgr = AshitaCore:GetResourceManager()
        end)

        if imgui.BeginChild('##gb_ws_list', { 360, 260 }, true) then
            if resMgr ~= nil and player_state ~= nil and type(player_state.KnowsAbility) == 'function' then
                for abilId = 1, 0x200 do
                    local res = nil
                    pcall(function() res = resMgr:GetAbilityById(abilId) end)
                    if res ~= nil then
                        local okk, known = pcall(function() return player_state:KnowsAbility(res.Id or abilId) end)
                        if okk and known == true then
                            local nm = ''
                            if res.Name ~= nil then
                                if type(res.Name) == 'string' then
                                    nm = res.Name
                                elseif type(res.Name) == 'userdata' and res.Name[1] ~= nil then
                                    nm = tostring(res.Name[1])
                                else
                                    nm = tostring(res.Name)
                                end
                            end

                            if nm ~= '' then
                                if filter == '' or nm:lower():find(filter, 1, true) ~= nil then
                                    local label = string.format('%s##gb_ws_%d', nm, tonumber(res.Id or abilId) or abilId)
							if imgui.Selectable(label, false) then
								local rid = tonumber(res.Id or abilId) or abilId

								EDIT.item_id[1]  = 0
								EDIT.spell_id[1] = 0
								EDIT.ability_id[1] = rid

                                -- WS icon (tHotBar wsmap.lua: abilityId -> 'ITEM:####')
                                local icon_spec = ws_icon_spec_for_ability(rid)
                                if icon_spec ~= nil then
                                    EDIT.icon[1] = icon_spec
                                end

                                -- WS element (your WS-ELEMENT.txt: Name -> element)
                                local elem = ws_element_for_name(nm)
                                EDIT.ws_element[1] = tostring(elem or '')

								EDIT.name[1] = nm
								EDIT.cmd[1]  = string.format('/ws \"%s\" <t>', nm)

								apply_editor_to_selected(st)
								imgui.CloseCurrentPopup()
							end


                                end
                            end
                        end
                    end
                end
            end
        end
        imgui.EndChild()

        imgui.EndPopup()
    end

    ---------------------------------------------------------------------------
    -- Mount picker
    ---------------------------------------------------------------------------
    st.ui._mount_filter = st.ui._mount_filter or { '' }

    if imgui.BeginPopup('##gb_mount_picker') then
        imgui.Text('Mounts')
        imgui.SameLine()
        imgui.Text('Search:')
        imgui.SameLine()
        imgui.SetNextItemWidth(220)
        imgui.InputText('##gb_mount_search', st.ui._mount_filter, 128)

        imgui.Separator()

        local filter = tostring(st.ui._mount_filter[1] or ''):lower()

        local mounts = {
            'Adamantoise','Alicorn','Beetle','Bomb','Bubble Crab','Buffalo','Byakko','Chocobo',
            'Coeurl','Crab','Craklaw','Crawler','Dhalmel','Doll','Fenrir','Golden Bomb','Goobbue',
            'Hippogryph','Iron Giant','Levitus','Magic Pot','Moogle','Morbol','Noble Chocobo','Omega',
            'Phuabo','Raaz','Raptor','Red Crab','Red Raptor','Sheep','Spectral Chair','Spheroid',
            'Tiger','Tulfaire','Warmachine','Wivre','Wyvern','Xzomit'
        }

        if imgui.BeginChild('##gb_mount_list', { 360, 260 }, true) then
            for i = 1, #mounts do
                local nm = mounts[i]
                if filter == '' or nm:lower():find(filter, 1, true) ~= nil then
                    local label = string.format('%s##gb_mount_%d', nm, i)
                    if imgui.Selectable(label, false) then
                        EDIT.item_id[1]  = 0
                        EDIT.spell_id[1] = 0

                        EDIT.name[1] = nm
                        EDIT.cmd[1]  = string.format('/mount \"%s\"', nm)

                        -- icon naming: lowercase + underscores
                        local icon = nm:lower():gsub('%s+', '_') .. '.png'
                        EDIT.icon[1] = icon

                        apply_editor_to_selected(st)
                        imgui.CloseCurrentPopup()
                    end
                end
            end
        end
        imgui.EndChild()

        imgui.EndPopup()
    end
end -- M.draw_settings_ui


-------------------------------------------------------------------------------
-- Render
-------------------------------------------------------------------------------

local function gb_get_text_row(st, key, def_enabled, b)
    st.ui = st.ui or {}
    st.ui.text = st.ui.text or {}
    st.ui.text[key] = st.ui.text[key] or {}

    local base = st.ui.text[key]
    if base.enabled == nil then base.enabled = def_enabled end

    base.size = tonumber(base.size or 14) or 14
    if base.size < 8 then base.size = 8 end
    if base.size > 48 then base.size = 48 end

    base.shadow = tonumber(base.shadow or 0) or 0
    if base.shadow < 0 then base.shadow = 0 end
    if base.shadow > 8 then base.shadow = 8 end

    base.color  = (type(base.color)  == 'table' and #base.color  >= 4) and base.color  or { 255, 255, 255, 255 }
    base.scolor = (type(base.scolor) == 'table' and #base.scolor >= 4) and base.scolor or { 0, 0, 0, 220 }

    if b ~= nil and type(b) == 'table' and type(b.text) == 'table' and type(b.text[key]) == 'table' then
        local bt = b.text[key]
        local res = {}

        res.enabled = (bt.enabled ~= nil) and (bt.enabled == true) or (base.enabled == true)

        local sz = tonumber(bt.size or base.size) or base.size
        if sz < 8 then sz = 8 end
        if sz > 48 then sz = 48 end
        res.size = sz

        local sh = tonumber(bt.shadow or base.shadow) or base.shadow
        if sh < 0 then sh = 0 end
        if sh > 8 then sh = 8 end
        res.shadow = sh

        if type(bt.color) == 'table' and #bt.color >= 4 then
            res.color = bt.color
        else
            res.color = base.color
        end

        if type(bt.scolor) == 'table' and #bt.scolor >= 4 then
            res.scolor = bt.scolor
        else
            res.scolor = base.scolor
        end

        return res
    end

    return base
end


local function gb_col32_255(t)
    return col32(
        tonumber(t[1] or 255) or 255,
        tonumber(t[2] or 255) or 255,
        tonumber(t[3] or 255) or 255,
        tonumber(t[4] or 255) or 255
    )
end

local function resolve_btn_color(b, st, bar_name, key, fallback)
    -- 1) Per-button override
    if type(b[key]) == 'table' then
        return col_from_tbl(b[key], fallback)
    end

    -- 2) Global default
    if st.ui and st.ui[key] then
        return col_from_tbl(st.ui[key], fallback)
    end

    -- 3) Hard fallback
    return col_from_tbl(fallback, fallback)
end


local function gb_draw_text_dl(dl, x, y, text, shadow_px, col_t, scol_t, anchor_right, anchor_bottom, font_size)

    if text == nil then return end
    text = tostring(text)
    if text == '' then return end

    local scale = 1.0
    if type(font_size) == 'number' and font_size > 0 then
        scale = font_size / 14
    end


    if scale <= 0 then scale = 1.0 end

    pcall(imgui.SetWindowFontScale, scale)

    local tw, th = 0, 0
    do
        local ok, a, b2 = pcall(imgui.CalcTextSize, text)
        if ok then
            if type(a) == 'number' then
                tw = tonumber(a or 0) or 0
                th = tonumber(b2 or 0) or 0
            elseif type(a) == 'table' then
                tw = tonumber(a[1] or a.x or 0) or 0
                th = tonumber(a[2] or a.y or 0) or 0
            end
        end
    end

    local dx = 0
    local dy = 0
    if anchor_right then dx = -tw end
    if anchor_bottom then dy = -th end

    local tcol = gb_col32_255(col_t)
    local scol = gb_col32_255(scol_t)

    shadow_px = tonumber(shadow_px or 0) or 0
    if shadow_px > 0 then
        dl:AddText({ x + dx + shadow_px, y + dy + shadow_px }, scol, text)
    end
    dl:AddText({ x + dx, y + dy }, tcol, text)

    pcall(imgui.SetWindowFontScale, 1.0)
end


-------------------------------------------------------------------------------
-- Internal key handler (job-aware, no /bind)
-------------------------------------------------------------------------------

local KB_STATE_HANDLER_REGISTERED = false
local KB_PREV_STATE = {}

-- F1..F12 DirectInput scancodes.
local KB_SCANCODES = {
    F1  = 0x3B,
    F2  = 0x3C,
    F3  = 0x3D,
    F4  = 0x3E,
    F5  = 0x3F,
    F6  = 0x40,
    F7  = 0x41,
    F8  = 0x42,
    F9  = 0x43,
    F10 = 0x44,
    F11 = 0x57,
    F12 = 0x58,
}

local DIK = {
    LCTRL  = 0x1D,
    RCTRL  = 0x9D,
    LALT   = 0x38,
    RALT   = 0xB8,
    LSHIFT = 0x2A,
    RSHIFT = 0x36,
    LWIN   = 0xDB,
    RWIN   = 0xDC,
    APPS   = 0xDD,
}

local function kb_is_modifier_down(ptr, mod)
    mod = tostring(mod or '@')
    if mod == '!' then
        return ptr[DIK.LALT] ~= 0 or ptr[DIK.RALT] ~= 0
    elseif mod == '^' then
        return ptr[DIK.LCTRL] ~= 0 or ptr[DIK.RCTRL] ~= 0
    elseif mod == '+' then
        return ptr[DIK.LSHIFT] ~= 0 or ptr[DIK.RSHIFT] ~= 0
    elseif mod == '@' then
        -- Use Windows key as the '@' modifier (tHotBar style).
        return ptr[DIK.LWIN] ~= 0 or ptr[DIK.RWIN] ~= 0
    elseif mod == '#' then
        return ptr[DIK.APPS] ~= 0
    end
    -- Unknown / empty modifier: treat as always down.
    return true
end

-- Pick button for a key based on scope (global/main/sub) and current job.
local function kb_pick_button_for_key(st, key_name)
    if type(st) ~= 'table' or type(st.buttons) ~= 'table' then
        return nil
    end

    local main_id = get_main_job_id()
    local sub_id  = get_sub_job_id()

    local best_id  = nil
    local best_pri = 0  -- 1 = global, 2 = sub, 3 = main

    for i = 1, #st.buttons do
        local b = st.buttons[i]
        if b ~= nil then
            local k = kb_norm_key(b.keybind or '')
            if k == key_name then
                local scope = tostring(b.scope or 'all')
                local job   = tonumber(b.job or 0) or 0
                local pri   = 0
                local match = false

                -- Global: any job / subjob.
                if scope == 'all' then
                    pri = 1
                    match = true

                -- Subjob: any main, matching subjob.
                elseif scope == 'sub' and job == sub_id then
                    pri = 2
                    match = true

                -- Main job: matching main, any subjob.
                elseif (scope == 'main' or scope == 'job') and job == main_id then
                    pri = 3
                    match = true
                end

                if match and pri >= best_pri then
                    best_pri = pri
                    best_id  = tonumber(b.id or 0) or 0
                end
            end
        end
    end

    if (best_id or 0) <= 0 then
        return nil
    end
    return best_id
end

local function kb_handle_key_state(e)
    if not e or not e.data_raw then
        return
    end

    -- Load current state & settings.
    local st = load_state()
    if not st or not st.ui or st.ui.kb_enabled == false then
        return
    end

    local mod = tostring(st.ui.kb_modifier or '@')
    local ptr = ffi.cast('uint8_t*', e.data_raw)

    for _, key_name in ipairs(KB_KEYS) do
        local sc = KB_SCANCODES[key_name]
        if sc then
            local is_down  = (ptr[sc] ~= 0) and kb_is_modifier_down(ptr, mod)
            local was_down = (KB_PREV_STATE[sc] == true)

            -- Edge: just pressed.
            if is_down and not was_down then
                local id = kb_pick_button_for_key(st, key_name)
                if id then
                    M.activate_button_by_id(id)
                end
            end

            KB_PREV_STATE[sc] = is_down
        end
    end
end

local function kb_ensure_key_state_handler()
    if KB_STATE_HANDLER_REGISTERED then
        return
    end
    if not ashita then
        return
    end

    local ok = false

    if ashita.events and type(ashita.events.register) == 'function' then
        ok = pcall(function()
            ashita.events.register('key_state', 'gb_buttons_key_state', kb_handle_key_state)
        end)
    elseif type(ashita.register_event) == 'function' then
        ok = pcall(function()
            ashita.register_event('key_state', 'gb_buttons_key_state', kb_handle_key_state)
        end)
    end

    if ok then
        KB_STATE_HANDLER_REGISTERED = true
    end
end


function M.render_bar(dl, rect, _wrapper_settings, bar_name, layout_mode)

    if CURRENT_PS ~= _wrapper_settings then
        CURRENT_PS = _wrapper_settings
        STATE = nil
    end

    ensure_macro_tick_registered()
    process_macro_queue()
    kb_register_command_handler()
    kb_ensure_key_state_handler()

    local st = load_state()
    st._tooltip_done = false

    local preview_active = (not layout_mode) and (st.ui ~= nil) and (st.ui.preview_active == true)



    local cur_main = get_main_job_id()
    local cur_sub  = get_sub_job_id()

    local mx, my = 0, 0
    do
        local ok, a, b = pcall(imgui.GetMousePos)
        if ok then
            if type(a) == 'number' then
                mx = tonumber(a) or 0
                my = tonumber(b) or 0
            elseif type(a) == 'table' then
                mx = tonumber(a.x or a[1] or 0) or 0
                my = tonumber(a.y or a[2] or 0) or 0
            end
        end
    end

    -- Base rect (bar-local)
    local cx = rect.content_x
    local cy = rect.content_y
    local cw = rect.content_w
    local ch = rect.content_h

    -- Screen-space override for "screen" bar
    if tostring(bar_name or '') == 'screen' then
        local sw, sh = cw, ch
        pcall(function()
            local io = imgui.GetIO and imgui.GetIO() or nil
            if io and io.DisplaySize then
                sw = tonumber(io.DisplaySize.x or io.DisplaySize[1] or sw) or sw
                sh = tonumber(io.DisplaySize.y or io.DisplaySize[2] or sh) or sh
            end
        end)
        cx, cy, cw, ch = 0, 0, sw, sh
    end

    for i = 1, #st.buttons do
        local b = st.buttons[i]
        if tostring(b.bar or '') == tostring(bar_name or '') then
            -- Scope gate (Global/Main/Sub)
            local sc = tostring(b.scope or 'all')
            local want = tonumber(b.job or 0) or 0

            local allowed = true
            if sc == 'main' or sc == 'job' then
                allowed = (want == cur_main)
            elseif sc == 'sub' then
                allowed = (want == cur_sub)
            end

            if allowed then
                local bw = tonumber(b.w or st.ui.icon_size or 18) or 18
                local bh = tonumber(b.h or st.ui.icon_size or 18) or 18

                local ox = tonumber(b.x or 0) or 0
                local oy = tonumber(b.y or 0) or 0

                local maxx = (cw or 0) - bw
                local maxy = (ch or 0) - bh
                if maxx < 0 then maxx = 0 end
                if maxy < 0 then maxy = 0 end
                if ox < 0 then ox = 0 end
                if oy < 0 then oy = 0 end
                if ox > maxx then ox = maxx end
                if oy > maxy then oy = maxy end

                local bx1 = cx + ox
                local by1 = cy + oy
                local bx2 = bx1 + bw
                local by2 = by1 + bh

                if layout_mode and imgui.IsMouseClicked(0) and in_rect(mx, my, bx1, by1, bx2, by2) then
                    DRAG.active = true
                    DRAG.id = tonumber(b.id or 0) or 0
                    DRAG.offx = mx - bx1
                    DRAG.offy = my - by1
                end

                if layout_mode and DRAG.active and DRAG.id == (tonumber(b.id or 0) or 0) then
                    if imgui.IsMouseDown(0) then
                        local nx = (mx - cx) - DRAG.offx
                        local ny = (my - cy) - DRAG.offy

                        local maxx2 = cw - bw
                        local maxy2 = ch - bh
                        if maxx2 < 0 then maxx2 = 0 end
                        if maxy2 < 0 then maxy2 = 0 end

                        if nx < 0 then nx = 0 end
                        if ny < 0 then ny = 0 end
                        if nx > maxx2 then nx = maxx2 end
                        if ny > maxy2 then ny = maxy2 end

                        b.x = math.floor(nx + 0.5)
                        b.y = math.floor(ny + 0.5)
                        save_state()
                    else
                        DRAG.active = false
                        DRAG.id = 0
                    end
                end

                local hovered = in_rect(mx, my, bx1, by1, bx2, by2)

                if (not layout_mode) and hovered and (st._tooltip_done == false) then
                    st._tooltip_done = true

                    local text = tostring(b.name or '')
                    local r = gb_get_text_row(st, 'tooltip', true, b)


                    imgui.BeginTooltip()
                    if r ~= nil and type(r.color) == 'table' then
                        local col = {
                            (tonumber(r.color[1] or 255) or 255) / 255,
                            (tonumber(r.color[2] or 255) or 255) / 255,
                            (tonumber(r.color[3] or 255) or 255) / 255,
                            (tonumber(r.color[4] or 255) or 255) / 255,
                        }
                        local scale = (tonumber(r.size or 14) or 14) / 14
                        if scale < 0.5 then scale = 0.5 end
                        if scale > 2.0 then scale = 2.0 end

                        pcall(imgui.SetWindowFontScale, scale)
                        pcall(imgui.TextColored, col, text)
                        pcall(imgui.SetWindowFontScale, 1.0)
                    else
                        imgui.Text(text)
                    end
                    imgui.EndTooltip()
                end


                local down = hovered and imgui.IsMouseDown(0) and (not layout_mode)

                -- Skillchain highlight flag (WS buttons only)
                local sc_highlight = false
                do
                    local aid = tonumber(b.ability_id or 0) or 0
                    if (not layout_mode) and aid > 0 and is_ws_cmd(b.cmd) then
                        if preview_active then
                            sc_highlight = true
                        else
                            local tp = get_player_tp()
                            local tidx = get_target_index()

                            local has_mod = (skillchain ~= nil)
                            local has_fn  = (has_mod and (type(skillchain.GetSkillchain) == 'function' or type(skillchain.GetSkillchain) == 'userdata'))

                            if tp >= 1000 and tidx > 0 and has_fn then
                                local ok_call, sc = pcall(function()
                                    return skillchain:GetSkillchain(tidx, aid)
                                end)
                                if ok_call and sc ~= nil then
                                    sc_highlight = true
                                end
                            end
                        end
                    end
                end


                -- Base background
                local bg_col =
    down and resolve_btn_color(b, st, bar_name, 'down', { 37, 81, 237, 220 })
        or (hovered and resolve_btn_color(b, st, bar_name, 'hov', { 37, 81, 237, 160 })
            or resolve_btn_color(b, st, bar_name, 'bg', { 20, 20, 20, 140 }))


                dl:AddRectFilled({ bx1, by1 }, { bx2, by2 }, bg_col, 2)

                -- Border
                local border_col = resolve_btn_color(b, st, bar_name, 'border', { 255, 255, 255, 50 })
                dl:AddRect({ bx1, by1 }, { bx2, by2 }, border_col, 2)


                -- Skillchain highlight settings (per-character)
                local sc_mode  = tostring(st.ui.sc_mode or 'crawler')
                local sc_style = tostring(st.ui.sc_style or 'crawl_yellow')
                local sc_col_t = st.ui.sc_color or { 255, 215, 0, 255 }

                local sc_want_border = (not layout_mode) and sc_highlight and (sc_mode == 'border')
local sc_want_crawl  = (not layout_mode) and sc_highlight and (sc_mode == 'crawler')


                -- Border / glow uses sc_color (crawler is never tinted)
                if sc_want_border then
                    local p = pulse01(900) -- 0..1
                    local base_a = tonumber(sc_col_t[4] or 255) or 255
                    local a = math.floor(base_a * (0.35 + (0.65 * p)) + 0.5)
                    if a < 0 then a = 0 end
                    if a > 255 then a = 255 end

                    -- subtle glow fill (uses sc_color)
                    local fill_a = math.floor(a * 0.25 + 0.5)
                    if fill_a > 0 then
                        dl:AddRectFilled(
                            { bx1, by1 }, { bx2, by2 },
                            col32(tonumber(sc_col_t[1] or 255) or 255, tonumber(sc_col_t[2] or 215) or 215, tonumber(sc_col_t[3] or 0) or 0, fill_a),
                            2
                        )
                    end

                    -- pulsing border (uses sc_color)
                    dl:AddRect(
                        { bx1, by1 }, { bx2, by2 },
                        col32(tonumber(sc_col_t[1] or 255) or 255, tonumber(sc_col_t[2] or 215) or 215, tonumber(sc_col_t[3] or 0) or 0, a),
                        2
                    )
                end




                ----------------------------------------------------------------
                -- Icon resolve
				------------------------------------------------
                local h = nil

                local custom_icon = tostring(b.icon or ''):gsub('^%s+', ''):gsub('%s+$', '')
                if custom_icon ~= '' then
                    local upper = custom_icon:upper()

                    -- Support: ITEM:<id> icon specs (tHotBar style)
                    if upper:match('^ITEM:%d+$') then
                        h = gb_texcache:GetTexture(upper)
                    else
                        local p = icon_path(custom_icon)
                        if p ~= nil then h = load_texture_handle(p) end

                        -- fallback: assets/mounts/<file>.png
                        if h == nil then
                            local mp = gb_root_dir() .. 'assets' .. SEP .. 'mounts' .. SEP .. custom_icon
                            h = load_texture_handle(mp)
                        end
                    end
                else

                    local iid = tonumber(b.item_id or 0) or 0
                    if iid > 0 then
                        h = gb_texcache:GetTexture('ITEM:' .. tostring(iid))
                    else

                        -- Job Abilities / WS icon auto-resolve when no custom icon and no item_id
                        local aid = tonumber(b.ability_id or 0) or 0
                        if aid > 0 then
                            if is_ws_cmd(b.cmd) then
                                local icon_spec = ws_icon_spec_for_ability(aid)
                                if icon_spec ~= nil then
                                    h = gb_texcache:GetTexture(icon_spec)
                                end
                            elseif is_ja_cmd(b.cmd) then
                                h = load_ja_icon_handle_by_ability_id(aid)
                            end
                        end


                        local sid = tonumber(b.spell_id or 0) or 0
                        if sid > 0 then
                            if is_trust_spell_id(sid) then
                                local tp = trust_icon_path(sid)
                                if tp ~= nil then
                                    h = load_texture_handle(tp)
                                end
                            end

                            -- Spells: name-based icons using RESOURCE spell name (NOT button label)
                            if h == nil then
                                local resMgr = nil
                                pcall(function()
                                    resMgr = AshitaCore:GetResourceManager()
                                end)

                                if resMgr ~= nil and resMgr.GetSpellById ~= nil then
                                    local res = nil
                                    pcall(function()
                                        res = resMgr:GetSpellById(sid)
                                    end)

                                    if res ~= nil and res.Name ~= nil then
                                        local spell_name = nil
                                        if type(res.Name) == 'string' then
                                            spell_name = res.Name
                                        elseif type(res.Name) == 'userdata' and res.Name[1] ~= nil then
                                            spell_name = tostring(res.Name[1])
                                        else
                                            spell_name = tostring(res.Name)
                                        end

                                        local p = spell_name_icon_path(spell_name)
                                        if p ~= nil then
                                            h = load_texture_handle(p)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end

                if h ~= nil then
                    local pad = 2
                    dl:AddImage(h, { bx1 + pad, by1 + pad }, { bx2 - pad, by2 - pad })
                else
                    dl:AddRectFilled({ bx1, by1 }, { bx2, by2 }, col32(80, 80, 80, 200), 2)
                    dl:AddRect({ bx1, by1 }, { bx2, by2 }, col32(255, 255, 255, 60), 2)
                end

                 -- WS element overlay (top-left). Always show if enabled.
                -- Also self-heal old WS buttons: if icon/ws_element missing, derive from maps and save.
                do
                    if st.ui.ws_elem_overlay ~= false then
                        local aid = tonumber(b.ability_id or 0) or 0
                        if aid > 0 and is_ws_cmd(b.cmd) then

                            -- 1) Ensure WS icon spec exists (wsmap.lua) for older buttons
                            local cur_icon = tostring(b.icon or ''):gsub('^%s+', ''):gsub('%s+$', '')
                            if cur_icon == '' then
                                local icon_spec = ws_icon_spec_for_ability(aid)
                                if icon_spec ~= nil then
                                    b.icon = icon_spec
                                    save_state()
                                end
                            end

                            -- 2) Ensure ws_element exists (WS-ELEMENT mapping) for older buttons
                            local elem = tostring(b.ws_element or ''):lower():gsub('%s+', '')
                            if elem == '' then
                                local resMgr = nil
                                pcall(function() resMgr = AshitaCore:GetResourceManager() end)
                                if resMgr ~= nil and resMgr.GetAbilityById ~= nil then
                                    local res = nil
                                    pcall(function() res = resMgr:GetAbilityById(aid) end)
                                    if res ~= nil and res.Name ~= nil then
                                        local nm = ''
                                        if type(res.Name) == 'string' then
                                            nm = res.Name
                                        elseif type(res.Name) == 'userdata' and res.Name[1] ~= nil then
                                            nm = tostring(res.Name[1])
                                        else
                                            nm = tostring(res.Name)
                                        end
                                        if nm ~= '' then
                                            local e2 = ws_element_for_name(nm)
                                            if e2 ~= nil and tostring(e2) ~= '' then
                                                elem = tostring(e2):lower():gsub('%s+', '')
                                                b.ws_element = elem
                                                save_state()
                                            end
                                        end
                                    end
                                end
                            end

                            -- 3) Draw overlay
                            if preview_active and elem == '' then
                                elem = 'fire'
                            end
                            if elem ~= '' then
                                local eh = element_icon_handle(elem)
                                if eh ~= nil then
                                    local size = tonumber(st.ui.ws_elem_size or 12) or 12

                                    if size < 8 then size = 8 end
                                    dl:AddImage(eh, { bx1 + 2, by1 + 2 }, { bx1 + 2 + size, by1 + 2 + size })

                                end
                            end

                        end
                    end
                end



                -- Skillchain animated border overlay (crawl1..crawlN.png)
                if sc_want_crawl then
                    local crawl_h = sc_get_crawl_handle(tonumber(b.id or i) or i, true, sc_style)
                    if crawl_h ~= nil then
                        -- NOTE: crawler frames are drawn raw (no tint)
                        dl:AddImage(crawl_h, { bx1, by1 }, { bx2, by2 })
                    end
                else
                    -- stop animation state when not drawing crawler (including mode=off/border)
                    sc_get_crawl_handle(tonumber(b.id or i) or i, false, sc_style)
                end




                ----------------------------------------------------------------
                -- CD text (items)
                ----------------------------------------------------------------
                do
                    local r = gb_get_text_row(st, 'cd', true)
                    if r.enabled == true then
                        local iid = tonumber(b.item_id or 0) or 0

                        -- ALWAYS restore saved XY (even if no cooldown)
                        b.pos = (type(b.pos) == 'table') and b.pos or {}
                        b.pos.cd = (type(b.pos.cd) == 'table') and b.pos.cd or { x = -4, y = -4 }
                        local dx = tonumber(b.pos.cd.x or -4) or -4
                        local dy = tonumber(b.pos.cd.y or -4) or -4

                        if iid > 0 then
                            local cd = gb_get_item_recast_seconds(iid)
                            if cd > 0 then
                                local text = gb_recast_to_string(cd)

                                gb_draw_text_dl(
                                    dl,
                                    bx2 + dx,
                                    by2 + dy,
                                    text,
                                    r.shadow,
                                    r.color,
                                    r.scolor,
                                    true,
                                    true,
                                    r.size
                                )
                            end
                        end
                    end
                end


                ----------------------------------------------------------------
                -- Label text (uses Text settings + Position)
                ----------------------------------------------------------------
                do
                    local r = gb_get_text_row(st, 'label', true, b)
                    if r.enabled == true and b.show_label ~= false then
                        local label = tostring(b.name or ''):gsub('^%s+', ''):gsub('%s+$', '')
                        if label ~= '' then
                            if #label > 6 then
                                label = label:sub(1, 6)
                            end

                            b.pos = (type(b.pos) == 'table') and b.pos or {}
                            b.pos.label = (type(b.pos.label) == 'table') and b.pos.label or { x = 3, y = -3 }
                            local dx = tonumber(b.pos.label.x or 3) or 3
                            local dy = tonumber(b.pos.label.y or -3) or -3

                            gb_draw_text_dl(dl, bx1 + dx, by2 + dy, label, r.shadow, r.color, r.scolor, false, true, r.size)

                        end
                    end
                end

				----------------------------------------------------------------
				-- Item name text (uses Item Text settings + Position)
				----------------------------------------------------------------
				do
				local r = gb_get_text_row(st, 'item', false, b)
					if false and r.enabled == true then
						local iid = tonumber(b.item_id or 0) or 0
						if iid > 0 then
							local resMgr = nil
							pcall(function() resMgr = AshitaCore:GetResourceManager() end)
							local res = resMgr and resMgr:GetItemById(iid) or nil
							local name = res and res.Name or nil
							if type(name) == 'userdata' and name[1] then name = tostring(name[1]) end
							if type(name) == 'string' and name ~= '' then
								b.pos = (type(b.pos) == 'table') and b.pos or {}
								b.pos.item = (type(b.pos.item) == 'table') and b.pos.item or { x = 0, y = 0 }
								local dx = tonumber(b.pos.item.x or 0) or 0
								local dy = tonumber(b.pos.item.y or 0) or 0

								gb_draw_text_dl(
									dl,
									bx1 + dx,
									by1 + dy,
									name,
									r.shadow,
									r.color,
									r.scolor,
									false,
									false,
									r.size
								)
							end
						end
					end
				end

                ----------------------------------------------------------------
                -- CD text (spells)
                ----------------------------------------------------------------
                do
                    local r = gb_get_text_row(st, 'cd', true, b)

                    if r.enabled == true then
                        local sid = tonumber(b.spell_id or 0) or 0
                        if sid > 0 and (not layout_mode) then
                            local text = gb_get_spell_recast_text(sid)
                            if preview_active and (text == nil or text == '') then
                                text = '9'
                            end

                            b.pos = (type(b.pos) == 'table') and b.pos or {}
                            b.pos.cd = (type(b.pos.cd) == 'table') and b.pos.cd or { x = -4, y = -4 }
                            local dx = tonumber(b.pos.cd.x or -4) or -4
                            local dy = tonumber(b.pos.cd.y or -4) or -4

                            gb_draw_text_dl(dl, bx2 + dx, by2 + dy, text, r.shadow, r.color, r.scolor, true, true, r.size)

                        end
                    end
                end


----------------------------------------------------------------
-- Quantity overlay (items only) - uses item text settings
----------------------------------------------------------------
do
    local iid = tonumber(b.item_id or 0) or 0
    if iid > 0 and (not layout_mode) then
        local ct = inv_count(iid)
        if ct > 0 then
            local r = gb_get_text_row(st, 'counter', true, b)


            if r.enabled == true then
                local text = tostring(ct)

                b.pos = (type(b.pos) == 'table') and b.pos or {}
                b.pos.counter = (type(b.pos.counter) == 'table') and b.pos.counter or { x = -2, y = -2 }

                local dx = tonumber(b.pos.counter.x or -2) or -2
                local dy = tonumber(b.pos.counter.y or -2) or -2

                gb_draw_text_dl(
                    dl,
                    bx2 + dx,
                    by2 + dy,
                    text,
                    r.shadow,
                    r.color,
                    r.scolor,
                    true,
                    true,
                    r.size
                )
            end
        end
    end
end


                ----------------------------------------------------------------
                -- Keybind text (uses Text settings + Position)
                ----------------------------------------------------------------
                do
                    local kb = kb_norm_key(b and b.keybind or '')
                    if kb ~= '' then
                        local r = gb_get_text_row(st, 'keybind', true, b)
                        if r.enabled == true then
                            b.pos = (type(b.pos) == 'table') and b.pos or {}
                            b.pos.keybind = (type(b.pos.keybind) == 'table') and b.pos.keybind or { x = 3, y = 3 }

                            local kdx = tonumber(b.pos.keybind.x or 3) or 3
                            local kdy = tonumber(b.pos.keybind.y or 3) or 3

                            gb_draw_text_dl(
                                dl,
                                bx1 + kdx,
                                by1 + kdy,
                                kb,
                                r.shadow,
                                r.color,
                                r.scolor,
                                false,
                                false,
                                r.size
                            )
                        end
                    end
                end


                ----------------------------------------------------------------
                -- Click handling (queue macro)
                ----------------------------------------------------------------
                if (not layout_mode) and imgui.IsMouseClicked(0) and in_rect(mx, my, bx1, by1, bx2, by2) then
                    enqueue_macro(tostring(b.cmd or ''))
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Right click select (for editor)
-------------------------------------------------------------------------------
function M.on_right_click(rect, _wrapper_settings, layout_mode, mx, my)
    if CURRENT_PS ~= _wrapper_settings then
        CURRENT_PS = _wrapper_settings
        STATE = nil
    end
    local st = load_state()

    local bar_name = rect.bar

    for i = 1, #st.buttons do
        local b = st.buttons[i]
        if tostring(b.bar or '') == tostring(bar_name) then
            local sc = tostring(b.scope or 'all')
            local want = tonumber(b.job or -1) or -1

            if (sc == 'main' or sc == 'job') and want ~= get_main_job_id() then
                -- skip
            elseif sc == 'sub' and want ~= get_sub_job_id() then
                -- skip
            else
                local bx1 = rect.content_x + (tonumber(b.x or 0) or 0)
                local by1 = rect.content_y + (tonumber(b.y or 0) or 0)
                local bw = tonumber(b.w or st.ui.icon_size or 18) or 18
                local bh = tonumber(b.h or st.ui.icon_size or 18) or 18
                local bx2 = bx1 + bw
                local by2 = by1 + bh
                if in_rect(mx, my, bx1, by1, bx2, by2) then
                    EDIT.selected = i
                    apply_selected_to_editor(st)
                    return true
                end
            end
        end
    end

    return false
end

return M
