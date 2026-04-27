return {
    -- Always hide (not on Catseye)
    hide = {
        ['Inundation'] = true,
        ['Odin'] = true,
        ['Siren'] = true,
        ['Atomos'] = true,
    },

    -- Mode-specific hides (CW/ACE hide Cait Sith; WEW allows it)
    hide_by_mode = {
        CW  = { ['Cait Sith'] = true },
        ACE = { ['Cait Sith'] = true },
        WEW = { },
    },

    -- Per-spell per-job level overrides (Catseye)
    -- Job IDs: WHM=3, BLM=4, RDM=5, DRK=8, GEO=21, RUN=22
    levels = {
        ['Baramnesia'] = { [5] = 65, [3] = 65, [22] = 63 },
        ['Enlight']    = { [3] = 75 },
        ['Arise']      = { [3] = 75 },

        ['Flash']      = { [22] = 38 },
        ['Crusade']    = { [22] = 56 },

        ['Absorb-Attri'] = { [8] = 75 },

        ['Stone V']    = { [4] = 75 },
        ['Water V']    = { [4] = 75 },
        ['Aero V']     = { [4] = 75 },
        ['Fire V']     = { [4] = 75 },
        ['Blizzard V'] = { [4] = 75 },
        ['Thunder V']  = { [4] = 75 },
    },

    -- GEO: Geocolure main-only (spell name starts with "Geo-")
    geo_geocolure_main_only = true,
}
