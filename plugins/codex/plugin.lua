-------------------------------------------------------------------------------
-- GobbieBars Plugin: Codex
-- File: Ashita/addons/gobbiebars/plugins/codex/plugin.lua
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
-- Load Windower spells.lua (must be a "return { ... }" table)
-------------------------------------------------------------------------------

local RAW_SPELLS = nil
local SPELLS_LOAD_ERR = nil

do
    local path = string.format('%s\\addons\\gobbiebars\\plugins\\codex\\spells.lua', AshitaCore:GetInstallPath())
    local ok, result = pcall(dofile, path)
    if ok then
        RAW_SPELLS = result
    else
        RAW_SPELLS = nil
        SPELLS_LOAD_ERR = tostring(result)
    end
end

-- Build name -> windower spell row (Windower keyed by spell name, not Ashita spell id)
local W_SPELLS_BY_NAME = {}
if type(RAW_SPELLS) == 'table' then
    for _, v in pairs(RAW_SPELLS) do
        if type(v) == 'table' and type(v.en) == 'string' then
            W_SPELLS_BY_NAME[v.en:lower()] = v
        end
    end
end

-------------------------------------------------------------------------------
-- Catseye overrides (optional file)
-------------------------------------------------------------------------------

local CATSEYE = { hide = {}, hide_by_mode = {}, levels = {}, geo_geocolure_main_only = false }
do
    local p = string.format('%s\\addons\\gobbiebars\\plugins\\codex\\catseye.lua', AshitaCore:GetInstallPath())
    local ok, t = pcall(dofile, p)
    if ok and type(t) == 'table' then
        CATSEYE.hide = (type(t.hide) == 'table') and t.hide or {}
        CATSEYE.hide_by_mode = (type(t.hide_by_mode) == 'table') and t.hide_by_mode or {}
        CATSEYE.levels = (type(t.levels) == 'table') and t.levels or {}
        CATSEYE.geo_geocolure_main_only = (t.geo_geocolure_main_only == true)
    end
end

-------------------------------------------------------------------------------
-- Texture loading (same as Emote)
-------------------------------------------------------------------------------

local TEX = {}

local CODEX_ICON = nil


local function codex_base_dir()
    local src = debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then src = src:sub(2) end
    return src:match('^(.*[\\/])') or './'
end

local BASE = codex_base_dir()
local SEP  = package.config:sub(1, 1)

local function ptr_to_number(p)
    if p == nil then return nil end
    return tonumber(ffi.cast('uintptr_t', p))
end

local function load_texture_handle(path)
    if type(path) ~= 'string' or path == '' then return nil end

    local cached = TEX[path]
    if cached and cached.handle then
        return cached.handle
    end

    if not d3d8 or not d3d8.get_device then return nil end
    local dev = d3d8.get_device()
    if not dev then return nil end

    local out = ffi.new('IDirect3DTexture8*[1]')
    local hr = ffi.C.D3DXCreateTextureFromFileA(dev, path, out)
    if hr ~= 0 or out[0] == nil then return nil end

    local tex = out[0]
    if d3d8.gc_safe_release then
        tex = d3d8.gc_safe_release(tex)
    end

    local handle = ptr_to_number(tex)
    if handle then
        TEX[path] = { handle = handle, tex = tex }
        return handle
    end

    return nil
end

local function codex_icon_path(spell)

    if type(spell) ~= 'string' then return nil end

    -- Match Windower scroll filenames exactly:
    -- "Banish III" -> "Banish_III_(Scroll)_icon.png"
    local s = spell
        :gsub('%s+', '_')     -- spaces -> underscores
        :gsub("'", '')       -- safety

    return BASE .. 'images' .. SEP .. s .. '_(Scroll)_icon.png'
end


-------------------------------------------------------------------------------
-- Plugin definition
-------------------------------------------------------------------------------


local M = {
    id   = 'codex',
    name = 'Codex',
    icon = 1129,

    default = { bar = 'top', x = 0, y = 0, w = 120, h = 34 },
    settings_defaults = {
    bar = 'top',
    x = 0,
    open = false,

    -- appearance
font_family = 'default',      -- bar label
font_size   = 14,

list_font_family = 'default',
list_font_size = 14,

show_label = true,
show_icon  = true,
show_list  = true,


    -- url source: 'bg' | 'fandom'
    url_source  = 'bg',
},


}

local JOB_SHORT = {
    [1]='WAR',[2]='MNK',[3]='WHM',[4]='BLM',[5]='RDM',[6]='THF',[7]='PLD',[8]='DRK',[9]='BST',[10]='BRD',[11]='RNG',
    [12]='SAM',[13]='NIN',[14]='DRG',[15]='SMN',[16]='BLU',[17]='COR',[18]='PUP',[19]='DNC',[20]='SCH',[21]='GEO',[22]='RUN',
}

local function job_short(jobId)
    return JOB_SHORT[jobId] or tostring(jobId or 0)
end

local BG_BASE = 'https://www.bg-wiki.com/ffxi/'
local FANDOM_BASE = 'https://ffxiclopedia.fandom.com/wiki/'

local function spell_url(name, source)
    if type(name) ~= 'string' then
        return (source == 'fandom') and FANDOM_BASE or BG_BASE
    end
    local s = name:gsub(' ', '_'):gsub("'", "%%27")
    if source == 'fandom' then
        return FANDOM_BASE .. s
    end
    return BG_BASE .. s
end

-------------------------------------------------------------------------------
-- Scroll icon loading (DISABLED - placeholder)
-------------------------------------------------------------------------------

local function get_game_mode(settings)
    -- 1) wrapper settings (preferred)
    if settings and settings.game_mode and type(settings.game_mode) == 'string' then
        local m = settings.game_mode:upper()
        if m == 'CW' or m == 'ACE' or m == 'WEW' then
            return m
        end
    end

    -- 2) global fallback (used by Buttons too)
    if _G.gb_settings and _G.gb_settings.game_mode and type(_G.gb_settings.game_mode) == 'string' then
        local m = _G.gb_settings.game_mode:upper()
        if m == 'CW' or m == 'ACE' or m == 'WEW' then
            return m
        end
    end

    return 'CW'
end

local function get_player_job_info()
    local mm = AshitaCore:GetMemoryManager()
    if mm == nil then return nil end

    local p = mm:GetPlayer()
    if p == nil then return nil end

    return p, p:GetMainJob(), p:GetMainJobLevel(), p:GetSubJob(), p:GetSubJobLevel()
end

-------------------------------------------------------------------------------
-- Windower required level lookup
-- Windower rows store job reqs in: row.levels[jobId] = requiredLevel
-------------------------------------------------------------------------------

local function required_level(spellName, jobId)
    if not spellName or not jobId then return nil end

    local row = W_SPELLS_BY_NAME[spellName:lower()]
    if type(row) ~= 'table' then return nil end

    local levels = row.levels
    if type(levels) ~= 'table' then return nil end

    -- Catseye override wins (if present)
	do
		local ov = CATSEYE.levels and CATSEYE.levels[spellName]
		if type(ov) == 'table' then
			local vv = ov[jobId]
			if type(vv) == 'number' and vv > 0 then
				return vv
			end
		end
	end

	local v = levels[jobId]

    if type(v) == 'number' and v > 0 then
        return v
    end

    return nil
end

-- HARD RULE:
-- If the spell has no required level for either of your jobs, it is NOT castable.
local function is_castable(spellName, mainJob, mainLvl, subJob, subLvl)
    local ml = required_level(spellName, mainJob)
    local sl = required_level(spellName, subJob)

    if (ml == nil and sl == nil) then
        return false
    end

    if (ml ~= nil and (mainLvl or 0) >= ml) then
        return true
    end

    if (sl ~= nil and (subLvl or 0) >= sl) then
        return true
    end

    return false
end

-------------------------------------------------------------------------------
-- State + list build
-------------------------------------------------------------------------------

local state = {
    built = false,

    lastMainJob = -1,
    lastSubJob  = -1,
    lastMainLvl = -1,
    lastSubLvl  = -1,

    list = T{},
    filter = '',
}

local function rebuild_list(settings)
    state.list = T{}
    state.built = true

    local rm = AshitaCore:GetResourceManager()
    if rm == nil then return end

    local player, mainJob, mainLvl, subJob, subLvl = get_player_job_info()
    if player == nil then return end

    state.lastMainJob = mainJob or -1
    state.lastSubJob  = subJob or -1
    state.lastMainLvl = mainLvl or -1
    state.lastSubLvl  = subLvl or -1

    -- If spells.lua failed to load, do nothing (UI will show error)
    if type(W_SPELLS_BY_NAME) ~= 'table' or next(W_SPELLS_BY_NAME) == nil then
        return
    end

    for i = 0, 2048 do
	    local mode = get_game_mode(settings)
		local hide_mode_tbl = CATSEYE.hide_by_mode and CATSEYE.hide_by_mode[mode] or nil
        local spell = rm:GetSpellById(i)
        if (spell ~= nil) then
            local name = (spell.Name and spell.Name[1]) and spell.Name[1] or nil
            if name ~= nil then
			
                if (not player:HasSpell(i)) then
                    if (is_castable(name, mainJob, mainLvl, subJob, subLvl)) then
                        local row = W_SPELLS_BY_NAME[name:lower()]
						local is_trust = (type(row) == 'table' and row.type == 'Trust')
						local is_unlearnable = (type(row) == 'table' and row.unlearnable == true)

												-- Always hide unlearnable spells (pet/NPC moves, etc.)
						if not is_unlearnable then

							-- Catseye global hide
							if CATSEYE.hide and CATSEYE.hide[name] == true then
								goto skip_spell
							end

							-- Catseye mode-specific hide
							if hide_mode_tbl and hide_mode_tbl[name] == true then
								goto skip_spell
							end

							if (not is_trust) or (settings and settings.include_trusts == true) then
								state.list:append(T{ id = i, name = name })
							end

							::skip_spell::
						end

                    end
                end
            end
        end
    end

    table.sort(state.list, function(a, b)
        return (a.name or '') < (b.name or '')
    end)
end

local function ensure_list_current(settings)
    local _, mainJob, mainLvl, subJob, subLvl = get_player_job_info()
    if mainJob == nil then return end

    if not state.built then
        rebuild_list(settings)
        return
    end

    if state.lastMainJob ~= (mainJob or -1) then rebuild_list(settings); return end
    if state.lastSubJob  ~= (subJob  or -1) then rebuild_list(settings); return end
    if state.lastMainLvl ~= (mainLvl or -1) then rebuild_list(settings); return end
    if state.lastSubLvl  ~= (subLvl  or -1) then rebuild_list(settings); return end
end


-------------------------------------------------------------------------------
-- Bar render (label + click toggles window)
-------------------------------------------------------------------------------

function M.render(dl, rect, settings)
    local st = settings or M.settings_defaults
    M._st = st
    if not dl or not rect then return end

    local font_sz = tonumber(st.font_size or 14)
    local scale   = font_sz / 14
    local icon_sz = math.floor(16 * scale)
    if icon_sz < 12 then icon_sz = 12 end

local x = rect.content_x + 8 + (st.x or 0)
local y = rect.content_y + 4 + (st.y or 0)

    local draw_x = x

    -- Icon (scaled, SAFE)
    if st.show_icon ~= false then
        local icon = CODEX_ICON
        if icon == nil then
            icon = load_texture_handle(BASE .. 'images' .. SEP .. 'codex.png')
            CODEX_ICON = icon
        end
        if icon then
            dl:AddImage(
                icon,
                { draw_x, y },
                { draw_x + icon_sz, y + icon_sz }
            )
            draw_x = draw_x + icon_sz + 4
        end
    end

    -- Label (SAFE DrawList text)
    if st.show_label ~= false then
        dl:AddText(
            { draw_x, y },
            0xFFFFFFFF,
            'Codex'
        )
    end

    local click_w = icon_sz + 80
    local click_h = icon_sz

    local mx, my = imgui.GetMousePos()
    if imgui.IsMouseClicked(0) then
        if mx >= x and mx <= (x + click_w) and my >= y and my <= (y + click_h) then
            st.open = not st.open
        end
    end
end




-------------------------------------------------------------------------------
-- Window
-------------------------------------------------------------------------------

function M.present(settings, font)

    local st = settings or M.settings_defaults
    if not st.open then return end

local function resolve_font_family_size(family, px, fallback)
    -- fallback should already be an ImFont (userdata/cdata) or nil
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

    -- exact match first
    local f = cache[px]
    if type(f) == 'userdata' or type(f) == 'cdata' then
        return f
    end

    -- nearest size (uses PLUGIN_FONT_SIZES if available, else scan keys)
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

-- Header font (top line + Refresh line)
    local fnt = resolve_font_family_size(st.font_family, 16, font)

-- List font (spell list)
local list_fnt = resolve_font_family_size(st.list_font_family, tonumber(st.list_font_size or 14) or 14, fnt)

    ensure_list_current(settings)

    imgui.SetNextWindowSize({ 420, 700 }, ImGuiCond_Once)

    -- Brown styling for title bar + Refresh button
    imgui.PushStyleColor(ImGuiCol_TitleBg,          { 0.62, 0.44, 0.20, 1.00 })
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,    { 0.62, 0.44, 0.20, 1.00 })
    imgui.PushStyleColor(ImGuiCol_TitleBgCollapsed, { 0.62, 0.44, 0.20, 1.00 })
    imgui.PushStyleColor(ImGuiCol_Button,           { 0.62, 0.44, 0.20, 1.00 })
    imgui.PushStyleColor(ImGuiCol_ButtonHovered,    { 0.70, 0.50, 0.22, 1.00 })
    imgui.PushStyleColor(ImGuiCol_ButtonActive,     { 0.76, 0.55, 0.24, 1.00 })

    local open = { true }

    if imgui.Begin(
        'Codex##gb_codex',
        open,
        bit.bor(
            ImGuiWindowFlags_NoScrollbar,
            ImGuiWindowFlags_NoScrollWithMouse
        )
    ) then

        -- Header font + size
        if fnt ~= nil then imgui.PushFont(fnt) end
        imgui.SetWindowFontScale(1.0)

        local _, mainJob, mainLvl, subJob, subLvl = get_player_job_info()
        imgui.Text(string.format('Main: %s Lv%d   Sub: %s Lv%d',
            job_short(mainJob), mainLvl or 0,
            job_short(subJob),  subLvl or 0
        ))

        if imgui.Button('Refresh##gb_codex_refresh') then
            rebuild_list(settings)
        end

        imgui.SameLine()
        imgui.Text(string.format('Missing castable: %d', #state.list))

        imgui.Separator()

        -- End header font
        imgui.SetWindowFontScale(1.0)
        if fnt ~= nil then imgui.PopFont() end

        -- List
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 14, 12 })

        if list_fnt ~= nil then imgui.PushFont(list_fnt) end
        imgui.SetWindowFontScale((tonumber(st.list_font_size or 14) or 14) / 14)

        imgui.BeginChild('##gb_codex_list', { 0, 0 }, true)

        -- Emote-style hover highlight colors
        imgui.PushStyleColor(ImGuiCol_Header,        { 0.62, 0.44, 0.20, 1.00 })
        imgui.PushStyleColor(ImGuiCol_HeaderHovered, { 0.70, 0.50, 0.22, 1.00 })
        imgui.PushStyleColor(ImGuiCol_HeaderActive,  { 0.76, 0.55, 0.24, 1.00 })

        for _, v in ipairs(state.list) do
            local name = tostring(v.name or '')

            local start_x = imgui.GetCursorPosX()
            local start_y = imgui.GetCursorPosY()
            local line_h  = imgui.GetTextLineHeight()
            local row_h   = math.max(18, line_h) + 6
            local avail_w = imgui.GetContentRegionAvail()

            if imgui.Selectable(
                '##codex_row_' .. name,
                false,
                0,
                { avail_w, row_h }
            ) then
                local url = spell_url(name, st.url_source)
                imgui.SetClipboardText(url)
                pcall(function()
                    os.execute('start "" "' .. url .. '"')
                end)
            end

            imgui.SetCursorPos({ start_x + 4, start_y + 3 })

            local icon = load_texture_handle(codex_icon_path(name))
            if icon then
                imgui.Image(icon, { 18, 18 })
                imgui.SameLine()
            else
                imgui.Dummy({ 18, 18 })
                imgui.SameLine()
            end

            imgui.TextUnformatted(name)

            imgui.SetCursorPosY(start_y + row_h)
        end

        imgui.PopStyleColor(3)
        imgui.EndChild()

        imgui.SetWindowFontScale(1.0)
        if list_fnt ~= nil then imgui.PopFont() end

        imgui.PopStyleVar(1)

        if SPELLS_LOAD_ERR ~= nil then
            imgui.Separator()
            imgui.Text('spells.lua load error:')
            imgui.TextWrapped(SPELLS_LOAD_ERR)
        end
    end

    imgui.End()
    imgui.PopStyleColor(6)

    -- X close works now
    if open[1] == false then
        st.open = false
    end
end

-------------------------------------------------------------------------------
-- Settings UI
-------------------------------------------------------------------------------

function M.draw_settings_ui(settings)
    local st = settings or M.settings_defaults

    if st.show_list == nil then st.show_list = true end

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

    local function draw_font_combo(label_id, current_value, set_value_fn, width)
        width = width or 180
        current_value = tostring(current_value or 'default')

        imgui.SetNextItemWidth(width)
        if imgui.BeginCombo(label_id, current_value) then
            if imgui.Selectable('default', current_value == 'default') then
                set_value_fn('default')
                current_value = 'default'
            end

            local names = build_sorted_font_names()
            for _, name in ipairs(names) do
                if imgui.Selectable(name, current_value == name) then
                    set_value_fn(name)
                    current_value = name
                end
            end

            imgui.EndCombo()
        end
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

    local cur_bar = tostring(st.bar or 'top')

    local function area_label(v)
        if v == 'top' then return 'Top Bar' end
        if v == 'bottom' then return 'Bottom Bar' end
        if v == 'left' then return 'Left Bar' end
        if v == 'right' then return 'Right Bar' end
        if v == 'screen' then return 'Screen' end
        return tostring(v)
    end

    if imgui.BeginCombo('##codex_area', area_label(cur_bar)) then
        for _, v in ipairs({ 'top','bottom','left','right','screen' }) do
            if imgui.Selectable(area_label(v), v == cur_bar) then
                st.bar = v
                cur_bar = v
            end
        end
        imgui.EndCombo()
    end

    -- Position (single line: X and Y)
    imgui.Text('Position')
    imgui.SameLine()

    imgui.SetNextItemWidth(110)
    local px = { tonumber(st.x or 0) or 0 }
    if imgui.InputInt('X##codex_pos_x', px) then
        st.x = tonumber(px[1] or 0) or 0
    end

    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local py = { tonumber(st.y or 0) or 0 }
    if imgui.InputInt('Y##codex_pos_y', py) then
        st.y = tonumber(py[1] or 0) or 0
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Label:
    ---------------------------------------------------------------------------
    header_yellow('Label:')
    imgui.Spacing()

    local show_label = { st.show_label ~= false }
    if imgui.Checkbox('Show Label##codex_show_label', show_label) then
        st.show_label = show_label[1]
    end

    imgui.Text('Font')
    imgui.SameLine()
    draw_font_combo('##codex_font_family', st.font_family, function(v) st.font_family = v end, 180)

    imgui.Text('Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(180)
    local fs = { tonumber(st.font_size or 14) or 14 }
    if imgui.SliderInt('##codex_font_size', fs, 10, 32) then
        st.font_size = tonumber(fs[1] or 14) or 14
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- List:
    ---------------------------------------------------------------------------
    header_yellow('List:')
    imgui.Spacing()

    local show_list = { st.show_list == true }
    if imgui.Checkbox('Show List##codex_show_list', show_list) then
        st.show_list = (show_list[1] == true)
    end

    imgui.Text('Font')
    imgui.SameLine()
    draw_font_combo('##codex_list_font_family', st.list_font_family, function(v) st.list_font_family = v end, 180)

    imgui.Text('Size')
    imgui.SameLine()
    imgui.SetNextItemWidth(180)
    local lfs = { tonumber(st.list_font_size or 14) or 14 }
    if imgui.SliderInt('##codex_list_font_size', lfs, 10, 32) then
        st.list_font_size = tonumber(lfs[1] or 14) or 14
    end

    imgui.Separator()

    ---------------------------------------------------------------------------
    -- Wiki Source:
    ---------------------------------------------------------------------------
    header_yellow('Wiki Source:')
    imgui.Spacing()

    if imgui.RadioButton('BG Wiki', st.url_source == 'bg') then
        st.url_source = 'bg'
    end
    imgui.SameLine()
    if imgui.RadioButton('Fandom', st.url_source == 'fandom') then
        st.url_source = 'fandom'
    end
end


function M.get_default(settings)
    local st = settings or {}
    return {
        bar = tostring(st.bar or M.default.bar),
        x   = tonumber(st.x or M.default.x) or M.default.x,
        y   = tonumber(st.y or M.default.y) or M.default.y,
        w   = M.default.w,
        h   = M.default.h,
    }
end

-- Command: /codex [open|close|toggle]
ashita.events.register('command', 'gb_codex_command', function(e)
    local args = e.command:args()
    if not args or #args == 0 then
        return
    end

    local cmd = tostring(args[1] or ''):lower()
    if cmd ~= '/codex' then
        return
    end

    e.blocked = true

    local st = M._st or M.settings_defaults
    local sub = tostring(args[2] or 'toggle'):lower()

    if sub == 'open' then
        st.open = true
    elseif sub == 'close' then
        st.open = false
    else
        st.open = not (st.open == true)
    end
end)

return M
