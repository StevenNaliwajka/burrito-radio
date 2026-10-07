-- Burrito Radio: a Crosley Cooper you can put anywhere that plays YouTube links,
-- playlists and the server's own music, out loud, to everyone near it.
-- By Burrito.  (lua/burrito_radio/sh_radio.lua has the map of the files)
local D = "burrito_radio/"

if SERVER then
    -- the spawn-menu picture: players only get an addon's materials if told to
    resource.AddFile("materials/entities/burrito_radio.png")
    AddCSLuaFile(D .. "sh_radio.lua")
    AddCSLuaFile(D .. "sh_model.lua")
    AddCSLuaFile(D .. "cl_model.lua")
    AddCSLuaFile(D .. "cl_audio.lua")
    AddCSLuaFile(D .. "cl_menu.lua")
end

include(D .. "sh_radio.lua")
include(D .. "sh_model.lua")

if SERVER then
    include(D .. "sv_relay.lua")
    include(D .. "sv_radio.lua")
    include(D .. "sv_persist.lua")
    print("[Radio] " .. BRadio.Version .. " loaded (server)")
else
    include(D .. "cl_model.lua")
    include(D .. "cl_audio.lua")
    include(D .. "cl_menu.lua")
end
