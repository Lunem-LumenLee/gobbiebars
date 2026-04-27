-------------------------------------------------------------------------------
-- GobbieBars - Weather helper
-- Owns: reading current weather id + human names
-------------------------------------------------------------------------------

require('common')

local M = {}

-- Weather pointer (same signature used in EC)
local pWeather = ashita.memory.find('FFXiMain.dll', 0, '66A1????????663D????72', 0, 0)

local weatherConstants = {
    [0]  = 'Clear',
    [1]  = 'Sunshine',
    [2]  = 'Clouds',
    [3]  = 'Fog',
    [4]  = 'Fire',
    [5]  = 'Fire x2',
    [6]  = 'Water',
    [7]  = 'Water x2',
    [8]  = 'Earth',
    [9]  = 'Earth x2',
    [10] = 'Wind',
    [11] = 'Wind x2',
    [12] = 'Ice',
    [13] = 'Ice x2',
    [14] = 'Thunder',
    [15] = 'Thunder x2',
    [16] = 'Light',
    [17] = 'Light x2',
    [18] = 'Dark',
    [19] = 'Dark x2',
}

local weatherTooltipNames = {
    [0]  = 'Clear Skys',
    [1]  = 'Sunny',
    [2]  = 'Cloudy',
    [3]  = 'Foggy',
    [4]  = 'Hot Spells',
    [5]  = 'Heat Wave',
    [6]  = 'Rain',
    [7]  = 'Squalls',
    [8]  = 'Dust Storm',
    [9]  = 'Sand Storm',
    [10] = 'Windy',
    [11] = 'Gales',
    [12] = 'Snow',
    [13] = 'Gales',
    [14] = 'Lightning',
    [15] = 'Thunderstorm',
    [16] = 'Aurora',
    [17] = 'Glare',
    [18] = 'Gloom',
    [19] = 'Miasma',
}

function M.get_weather_id()
    if not pWeather or pWeather == 0 then
        return nil
    end

    local ptr = ashita.memory.read_uint32(pWeather + 0x02)
    if not ptr or ptr == 0 then
        return nil
    end

    local id = ashita.memory.read_uint8(ptr + 0)
    if type(id) ~= 'number' then
        return nil
    end

    return id
end

function M.get_weather_text(id)
    if type(id) ~= 'number' then
        return 'Unknown'
    end
    return weatherConstants[id] or ('Unknown (' .. tostring(id) .. ')')
end

function M.get_weather_tooltip(id)
    if type(id) ~= 'number' then
        return nil
    end
    return weatherTooltipNames[id] or M.get_weather_text(id)
end

return M
