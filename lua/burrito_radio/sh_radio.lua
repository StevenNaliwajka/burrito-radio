--[[--------------------------------------------------------------------------
    burrito_radio/sh_radio.lua  -- shared bits: version, net names, helpers

    The pieces:
      sh_model.lua   the Crosley Cooper, as mesh + texture data
      sv_relay.lua   talks to the relay (relay/radio_relay.py): YouTube -> MP3
      sv_radio.lua   every radio's queue and clock; the menu's commands
      sv_persist.lua owner-pinned radios per map, saved playlists
      cl_model.lua   draws the radio
      cl_audio.lua   plays it, positioned, fading with distance
      cl_menu.lua    the menu you get pressing E on it

    A radio is a STATION (the queue, what is playing and since when) plus the
    entity that stands in the world. They are kept apart on purpose: TTT
    cleans the map up every round, which deletes every entity, and an owner's
    radio should come back mid-song rather than start over.
----------------------------------------------------------------------------]]

BRadio = BRadio or {}
BRadio.Version = "1.0.0"
BRadio.Class = "burrito_radio"

BRadio.Net = {
    State = "bradio_state",     -- S->C one station (compressed JSON)
    Gone = "bradio_gone",       -- S->C a station ended
    Open = "bradio_open",       -- S->C open the menu on a station
    Cmd = "bradio_cmd",         -- C->S a menu action (compressed JSON)
    Notice = "bradio_notice",   -- S->C a line for chat and the menu
    Hello = "bradio_hello",     -- C->S send me everything (after InitPostEntity)
    Library = "bradio_lib",     -- S->C the owner's library + saved playlists
}

-- how far a radio carries by default, and the menu's limits (Hammer units; 1 unit ~ 1 inch)
BRadio.DefaultRange = 3000
BRadio.MinRange, BRadio.MaxRange = 300, 12000
BRadio.DefaultVolume = 0.7
BRadio.LeadTime = 1.5   -- a new song starts this long after it is announced, so clients can buffer

function BRadio.FormatTime(s)
    s = math.max(0, math.floor(tonumber(s) or 0))
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = s % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
    return string.format("%d:%02d", m, sec)
end

-- a station's position in the current song, in seconds (shared: the server
-- decides when to move on, every client seeks to the same place)
function BRadio.Position(st, now)
    if not st or not st.current then return 0 end
    if st.state == "paused" then return st.pausedAt or 0 end
    if st.state ~= "playing" then return 0 end
    return (now or CurTime()) - (st.startedAt or 0)
end

-- bradio_owners: SteamID64s (space/comma separated) with full rights on every radio,
-- whatever the admin mod says: the server's owner, on a box with no ULX ranks.
function BRadio.IsOwner(ply)
    local cv = GetConVar and GetConVar("bradio_owners")
    if not cv or not IsValid(ply) then return false end
    local sid = ply:SteamID64() or ""
    for id in cv:GetString():gmatch("%d+") do if id == sid then return true end end
    return false
end

function BRadio.IsAdmin(ply)
    if not IsValid(ply) then return true end   -- the server console
    if BRadio.IsOwner(ply) then return true end
    if CAMI and CAMI.PlayerHasAccess then
        local ok = CAMI.PlayerHasAccess(ply, "bradio_admin", nil)
        if ok ~= nil then return ok end
    end
    return ply:IsAdmin()
end

if CAMI and CAMI.RegisterPrivilege then
    CAMI.RegisterPrivilege({ Name = "bradio_admin", MinAccess = "admin",
        Description = "Burrito Radio: control every radio, pin radios to the map, edit the library" })
end

function BRadio.SteamID(ply)
    if not IsValid(ply) then return "console" end
    return ply:SteamID64() or ply:SteamID() or tostring(ply:UserID())
end

--[[ DIRECTIVITY. The radio's one speaker is behind the grille on its front, so
     it is loud in front of it, softer to the sides and softest behind (a
     cardioid-ish pattern, like the real thing):
         front 1.0   side ~0.58   behind BRadio.BackGain (0.35)
     Up close the pattern relaxes (you hear a radio from any side when you are
     standing over it), fully directional from DIRECT_FULL units out.
     f = the radio's forward, d = radio -> listener, both unit vectors; numbers,
     not Vectors, so it runs in the offline tests. ]]
BRadio.BackGain = 0.35
local DIRECT_NEAR, DIRECT_FULL = 30, 250
function BRadio.Directivity(fx, fy, fz, dx, dy, dz, dist)
    local c = fx * dx + fy * dy + fz * dz
    if c > 1 then c = 1 elseif c < -1 then c = -1 end
    local g = BRadio.BackGain + (1 - BRadio.BackGain) * ((1 + c) / 2) ^ 1.5
    local w = ((dist or DIRECT_FULL) - DIRECT_NEAR) / (DIRECT_FULL - DIRECT_NEAR)
    if w < 0 then w = 0 elseif w > 1 then w = 1 end
    return 1 - (1 - g) * w
end

--[[ PAN: where the radio is from where you look. r/f = your view's right and
     forward, d = you -> radio (unit). Returns pan (-1 left .. 1 right) and a
     gain (0.85 when the radio is behind you: the ear's front/back cue). Right
     on top of it the pan centres, or turning your head would whip it about. ]]
function BRadio.Pan(rx, ry, rz, fx, fy, fz, dx, dy, dz, dist)
    local side = rx * dx + ry * dy + rz * dz
    local ahead = fx * dx + fy * dy + fz * dz
    local near = ((dist or 1000) - 10) / 70
    if near < 0 then near = 0 elseif near > 1 then near = 1 end
    local pan = side * 0.95 * near
    if pan > 1 then pan = 1 elseif pan < -1 then pan = -1 end
    local gain = 1
    if ahead < 0 then gain = 1 - 0.15 * (-ahead) * near end
    return pan, gain
end

--[[ FALLOFF: how loud at `dist` from the speaker, for a station of `range`.
     Real sound: half as loud at twice the distance ((REF/d)^0.8), so a few
     steps away is clearly quieter and the radio sounds like it is THERE, not
     around you; it still carries faintly far off ("music in the distance"),
     and fades to nothing over the last 40% of the range. ]]
BRadio.FalloffRef = 110
function BRadio.Falloff(dist, range)
    range = range or BRadio.DefaultRange
    local ref = BRadio.FalloffRef
    local v = dist <= ref and 1 or (ref / dist) ^ 0.8
    local t = dist / math.max(range, 1)
    if t >= 1 then return 0 end
    if t > 0.6 then
        local x = (t - 0.6) / 0.4
        v = v * (1 - x * x * (3 - 2 * x))
    end
    return v
end

-- the audio URL a client fetches
function BRadio.TrackURL(base, key)
    return (base or ""):gsub("/+$", "") .. "/a/" .. key .. ".mp3"
end
