--[[--------------------------------------------------------------------------
    naliwajka_radio/sh_radio.lua  -- shared bits: version, net names, helpers

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

NRadio = NRadio or {}
NRadio.Version = "1.0.0"
NRadio.Class = "naliwajka_radio"

NRadio.Net = {
    State = "nradio_state",     -- S->C one station (compressed JSON)
    Gone = "nradio_gone",       -- S->C a station ended
    Open = "nradio_open",       -- S->C open the menu on a station
    Cmd = "nradio_cmd",         -- C->S a menu action (compressed JSON)
    Notice = "nradio_notice",   -- S->C a line for chat and the menu
    Hello = "nradio_hello",     -- C->S send me everything (after InitPostEntity)
    Library = "nradio_lib",     -- S->C the owner's library + saved playlists
}

-- how far a radio carries by default, and the menu's limits (Hammer units; 1 unit ~ 1 inch)
NRadio.DefaultRange = 3000
NRadio.MinRange, NRadio.MaxRange = 300, 12000
NRadio.DefaultVolume = 0.7
NRadio.LeadTime = 1.5   -- a new song starts this long after it is announced, so clients can buffer

function NRadio.FormatTime(s)
    s = math.max(0, math.floor(tonumber(s) or 0))
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = s % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
    return string.format("%d:%02d", m, sec)
end

-- a station's position in the current song, in seconds (shared: the server
-- decides when to move on, every client seeks to the same place)
function NRadio.Position(st, now)
    if not st or not st.current then return 0 end
    if st.state == "paused" then return st.pausedAt or 0 end
    if st.state ~= "playing" then return 0 end
    return (now or CurTime()) - (st.startedAt or 0)
end

function NRadio.IsAdmin(ply)
    if not IsValid(ply) then return true end   -- the server console
    if CAMI and CAMI.PlayerHasAccess then
        local ok = CAMI.PlayerHasAccess(ply, "nradio_admin", nil)
        if ok ~= nil then return ok end
    end
    return ply:IsAdmin()
end

if CAMI and CAMI.RegisterPrivilege then
    CAMI.RegisterPrivilege({ Name = "nradio_admin", MinAccess = "admin",
        Description = "Naliwajka Radio: control every radio, pin radios to the map, edit the library" })
end

function NRadio.SteamID(ply)
    if not IsValid(ply) then return "console" end
    return ply:SteamID64() or ply:SteamID() or tostring(ply:UserID())
end

-- the audio URL a client fetches
function NRadio.TrackURL(base, key)
    return (base or ""):gsub("/+$", "") .. "/a/" .. key .. ".mp3"
end
