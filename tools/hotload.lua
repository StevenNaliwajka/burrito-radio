--[[ Reload Burrito Radio on a RUNNING server and every connected player, without a
     restart. tools/hotload.py copies this to garrysmod/lua/ and runs it with
     lua_openscript. For when GMod's autorefresh cannot see the files (the addon
     folder was swapped under a running server). Safe to run more than once. ]]
local D = "burrito_radio/"
for _, f in ipairs({ "sh_radio", "sh_model", "sv_relay", "sv_radio", "sv_persist" }) do include(D .. f .. ".lua") end

-- the entity (Use = menu / Shift+E carry, physics): re-registered, so radios already
-- in the world pick up the new code too
do
    local base = "addons/burrito_radio/lua/entities/burrito_radio/"
    local inc, cs = include, AddCSLuaFile
    ENT = { Folder = "entities/burrito_radio", ClassName = "burrito_radio" }
    include = function(f) RunString(file.Read(base .. f, "GAME") or "", "entities/burrito_radio/" .. f) end
    AddCSLuaFile = function() end
    include("init.lua")
    include, AddCSLuaFile = inc, cs
    scripted_ents.Register(ENT, "burrito_radio")
    ENT = nil
end

util.AddNetworkString("bradio_hot")
-- the client side: one receiver (sent with SendLua, <255 bytes) that runs each file;
-- before cl_audio it stops the old channels so nothing plays twice
local boot = [[net.Receive("bradio_hot",function()local n,d=net.ReadString(),util.Decompress(net.ReadData(net.ReadUInt(32)))if n=="cl_audio"then for k,a in pairs(BRadio.CL.Audio)do if IsValid(a.ch)then a.ch:Stop()end BRadio.CL.Audio[k]=nil end end RunString(d,n)end)]]
local files = { "sh_radio", "sh_model", "cl_model", "cl_audio", "cl_menu" }
for _, ply in ipairs(player.GetHumans()) do ply:SendLua(boot) end
timer.Simple(1.5, function()
    for i, f in ipairs(files) do
        timer.Simple(i * 0.3, function()
            local data = util.Compress(file.Read("addons/burrito_radio/lua/" .. D .. f .. ".lua", "GAME") or "")
            net.Start("bradio_hot")
            net.WriteString(f)
            net.WriteUInt(#data, 32)
            net.WriteData(data, #data)
            net.Broadcast()
        end)
    end
    timer.Simple(#files * 0.3 + 1, function()
        for _, st in pairs(BRadio.Stations) do BRadio.SendState(st) end
        print("[Radio] hot-loaded " .. #files .. " client files to " .. #player.GetHumans() .. " player(s)")
    end)
end)
print("[Radio] hot-loaded the server side")
