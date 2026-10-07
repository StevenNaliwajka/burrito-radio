-- Dump the radio model (sh_model.lua) as JSON for tools/preview/render.py.
-- Plain Lua 5.1, no GMod: run from the repo root, `lua tools/preview/export.lua > model.json`
dofile("lua/burrito_radio/sh_model.lua")
local M = BRadio.Model

local function enc(v)
    local t = type(v)
    if t == "number" then
        if v ~= v then return "0" end
        return string.format("%.5g", v)
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    elseif t == "boolean" then return tostring(v)
    elseif t == "table" then
        if #v > 0 or next(v) == nil then
            local o = {}
            for i = 1, #v do o[i] = enc(v[i]) end
            return "[" .. table.concat(o, ",") .. "]"
        end
        local o = {}
        for k, x in pairs(v) do
            if type(k) == "string" and k ~= "scaled" then o[#o + 1] = enc(k) .. ":" .. enc(x) end
        end
        table.sort(o)
        return "{" .. table.concat(o, ",") .. "}"
    end
    return "null"
end

local parts = M.Build(1)
local out = {}
for mat, tris in pairs(parts) do
    local flat = {}
    for _, t in ipairs(tris) do
        for i = 1, 3 do
            local v = t[i]
            flat[#flat + 1] = { v[1], v[2], v[3], v[4], v[5], v[6] }
        end
    end
    out[mat] = flat
end
local ntri = 0
for _, f in pairs(out) do ntri = ntri + #f / 3 end
io.stderr:write("triangles: " .. ntri .. "\n")
io.write(enc({ parts = out, textures = M.Textures, display = M.DisplayRect(1) }))
