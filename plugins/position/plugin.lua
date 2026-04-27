-------------------------------------------------------------------------------
-- GobbieBars Plugin: Position
-- File: Ashita/addons/gobbiebars/plugins/position/plugin.lua
-- Author: Lunem
-- Version: 0.1.0
-------------------------------------------------------------------------------

require('common')
local imgui = require('imgui')

local M = {
    id   = 'position',
    name = 'Position',
    icon = 0,

    -- bar geometry (host uses this)
    default = { bar = 'top', x = 0, y = 0, w = 120, h = 34 },

    -- SETTINGS: these are the keys your UI shows
    settings_defaults = {
        bar         = 'top',                 -- Area
        x           = 0,                     -- Position X offset
        y           = 0,                     -- Position Y offset

        font_family = 'calibri',            -- Font name text
        font_size   = 32,                   -- Font Size

        -- Font Color (stored as 0..255 or 0..1; we handle both)
        font_color  = { 255, 255, 255, 255 },

        precision   = 2,                    -- decimals shown
    },
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function clampi(v, lo, hi)
    v = tonumber(v) or lo
    if v < lo then return lo end
    if v > hi then return hi end
    return math.floor(v)
end

local function color_to_u32_any(c)
    -- Accepts either {255,255,255,255} or {1,1,1,1}
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

local function fmt_num(v, prec)
    if type(v) ~= 'number' then return nil end
    prec = tonumber(prec) or 2
    if prec < 0 then prec = 0 end
    if prec > 6 then prec = 6 end
    return string.format('%0.' .. tostring(prec) .. 'f', v)
end

-- Exact same pattern MobDB uses (from tokens.lua):
--   local myIndex = partyMgr:GetMemberTargetIndex(0)
--   entMgr:GetLocalPositionX/Y(myIndex)
local function get_player_xy()
    if not AshitaCore then return nil end

    local memMgr   = AshitaCore:GetMemoryManager()
    if not memMgr then return nil end

    local entMgr   = memMgr:GetEntity()
    local partyMgr = memMgr:GetParty()
    if not entMgr or not partyMgr then return nil end

    local myIndex = partyMgr:GetMemberTargetIndex(0)
    if not myIndex or myIndex < 0 then
        return nil
    end

    local x = entMgr:GetLocalPositionX(myIndex)
    local y = entMgr:GetLocalPositionY(myIndex)

    if type(x) ~= 'number' or type(y) ~= 'number' then
        return nil
    end

    return x, y
end

local function area_label(v)
    if v == 'top'    then return 'Top Bar'    end
    if v == 'bottom' then return 'Bottom Bar' end
    if v == 'left'   then return 'Left Bar'   end
    if v == 'right'  then return 'Right Bar'  end
    if v == 'screen' then return 'Screen'     end
    return tostring(v)
end

-------------------------------------------------------------------------------
-- Bar render
-------------------------------------------------------------------------------

function M.render(dl, rect, settings)
    local st = settings or M.settings_defaults
    if not dl or not rect then return end

    local xw, yw = get_player_xy()

    local text
    if xw == nil then
        text = 'pos: n/a'
    else
        local a = fmt_num(xw, st.precision)
        local b = fmt_num(yw, st.precision)
        if not a or not b then
            text = 'pos: n/a'
        else
            text = a .. ',' .. b
        end
    end

    local draw_x = rect.content_x + 8 + (tonumber(st.x) or 0)
    local draw_y = rect.content_y + 4 + (tonumber(st.y) or 0)

    local color = color_to_u32_any(st.font_color or { 255, 255, 255, 255 })

    -- Scale using font_size (no PushFont; avoids crashes)
    local base  = 14
    local fs    = tonumber(st.font_size) or base
    local scale = fs / base
    if scale < 0.5 then scale = 0.5 end
    if scale > 3.0 then scale = 3.0 end

    imgui.SetWindowFontScale(scale)
    dl:AddText({ draw_x, draw_y }, color, text)
    imgui.SetWindowFontScale(1.0)
end

-------------------------------------------------------------------------------
-- Settings UI
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
    if imgui.BeginCombo('##position_area', area_label(cur_area)) then
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
    if imgui.InputInt('X##position_pos_x', px) then
        st.x = tonumber(px[1] or 0) or 0
    end
    imgui.SameLine()
    imgui.SetNextItemWidth(110)
    local py = { tonumber(st.y or 0) or 0 }
    if imgui.InputInt('Y##position_pos_y', py) then
        st.y = tonumber(py[1] or 0) or 0
    end

    -- Precision
    imgui.Text('Precision')
    imgui.SameLine()
    imgui.SetNextItemWidth(120)
    local p = { tonumber(st.precision or 2) or 2 }
    if imgui.SliderInt('##position_precision', p, 0, 4) then
        st.precision = tonumber(p[1] or 2) or 2
    end

    imgui.Separator()

    ------------------------------------------------------------------------
    -- Font:
    ------------------------------------------------------------------------
    header_yellow('Font:')
    imgui.Spacing()

    -- Font family (sorted, no dup default)
    imgui.Text('Font')
    imgui.SameLine()
    imgui.SetNextItemWidth(180)

    local cur_font = tostring(st.font_family or 'default')
    if imgui.BeginCombo('##position_font_family', cur_font) then
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
    if imgui.SliderInt('##position_font_size', fs, 10, 64) then
        st.font_size = tonumber(fs[1] or 32) or 32
    end

    -- Font Color (picker only; no value boxes)
    st.font_color = st.font_color or { 255, 255, 255, 255 }

    local c = {
        st.font_color[1],
        st.font_color[2],
        st.font_color[3],
        st.font_color[4],
    }
    if c[1] > 1 or c[2] > 1 or c[3] > 1 or c[4] > 1 then
        c[1] = c[1] / 255
        c[2] = c[2] / 255
        c[3] = c[3] / 255
        c[4] = c[4] / 255
    end

    imgui.Text('Font Color')
    imgui.SameLine()
    imgui.SetNextItemWidth(240)

    if imgui.ColorEdit4('##position_font_color', c, ImGuiColorEditFlags_NoInputs) then
        st.font_color[1] = c[1]
        st.font_color[2] = c[2]
        st.font_color[3] = c[3]
        st.font_color[4] = c[4]
    end
end

return M