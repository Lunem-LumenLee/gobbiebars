-- GobbieBars - texturecache.lua
-- Minimal texture cache for D3D8 textures (Ashita)

require('common')

local ffi  = require('ffi')
local d3d8 = require('d3d8')

ffi.cdef[[
typedef void*               LPVOID;
typedef const char*         LPCSTR;
typedef const void*         LPCVOID;
typedef unsigned int        UINT;
typedef unsigned long       DWORD;

typedef struct IDirect3DTexture8 IDirect3DTexture8;
typedef long                HRESULT;

HRESULT D3DXCreateTextureFromFileA(
    LPVOID pDevice, LPCSTR pSrcFile, IDirect3DTexture8** ppTexture
);

HRESULT D3DXCreateTextureFromFileInMemoryEx(
    LPVOID pDevice,
    LPCVOID pSrcData,
    UINT SrcDataSize,
    UINT Width,
    UINT Height,
    UINT MipLevels,
    DWORD Usage,
    DWORD Format,
    DWORD Pool,
    DWORD Filter,
    DWORD MipFilter,
    DWORD ColorKey,
    LPVOID pSrcInfo,
    LPVOID pPalette,
    IDirect3DTexture8** ppTexture
);
]]


local M = {}
local TEX = {}

local function ptr_to_number(p)
    if p == nil then return nil end
    return tonumber(ffi.cast('uintptr_t', p))
end

function M.load(path)
    if type(path) ~= 'string' or path == '' then return nil end

    local cached = TEX[path]
    if type(cached) == 'table' and cached.handle ~= nil and cached.tex ~= nil then
        return cached.handle
    end

    -- ITEM:<id> -> in-game icon bitmap (tHotBar-style)
    if path:sub(1, 5) == 'ITEM:' then
        local item_id = tonumber(path:sub(6))
        if type(item_id) ~= 'number' then return nil end

        local item = nil
        pcall(function()
            item = AshitaCore:GetResourceManager():GetItemById(item_id)
        end)
        if item == nil or item.Bitmap == nil then
            return nil
        end

        local out = ffi.new('IDirect3DTexture8*[1]')
        local size = -1
        if ashita and ashita.interface_version == nil then
            size = item.ImageSize
        end

        -- Constants (avoid relying on ffi.C enums existing):
        local D3DX_DEFAULT       = 0xFFFFFFFF
        local D3DFMT_A8R8G8B8    = 21
        local D3DPOOL_MANAGED    = 1
        local S_OK               = 0

        local hr = ffi.C.D3DXCreateTextureFromFileInMemoryEx(
            d3d8.get_device(),
            item.Bitmap,
            size,
            D3DX_DEFAULT, D3DX_DEFAULT,
            1,
            0,
            D3DFMT_A8R8G8B8,
            D3DPOOL_MANAGED,
            D3DX_DEFAULT, D3DX_DEFAULT,
            0xFF000000,
            nil, nil,
            out
        )

        if hr ~= S_OK or out[0] == nil then
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

    -- Default: file path on disk
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


-- colon-call compatibility: texturecache:GetTexture(path)
function M:GetTexture(path)
    return M.load(path)
end

function M.clear()
    TEX = {}
end

return M
