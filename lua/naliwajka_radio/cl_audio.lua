--[[--------------------------------------------------------------------------
    naliwajka_radio/cl_audio.lua  -- hearing the radios

    Each radio within earshot gets one BASS channel (sound.PlayURL with "3d"),
    opened on the relay's MP3 and seeked to the station's clock, so it lines
    up with everyone else's. The channel sits on the radio: the engine pans
    it to the side it is on.

    LOUDNESS IS OURS, not BASS's. BASS's own 3D roll-off is pushed out past
    the station's range (Set3DFadeDistance) and the volume is set every frame:
        full within NEAR units, then (1 - t)^2 out to the station's range,
        x0.45 when a wall is between you and the radio (smoothed),
        x the station's volume (the knob), x your nradio_volume.
    That is what makes it "music going off in the distance": loud on top of
    it, faint across the map, gone past its range, softer round a corner.

    Only the MAX_CHANNELS nearest radios play at once; a radio out of range
    is closed, not muted, so nobody downloads music they cannot hear.

    Client convars:
        nradio_volume   0.8   your volume for every radio (0-1)
        nradio_enabled  1     hear radios at all
----------------------------------------------------------------------------]]

NRadio.CL = NRadio.CL or { Stations = {}, Library = { tracks = {}, playlists = {} }, Muted = {} }
local CL = NRadio.CL
local NET = NRadio.Net

local cvVolume = CreateClientConVar("nradio_volume", "0.8", true, false, "Radio: your volume for every radio (0-1)", 0, 1)
local cvEnabled = CreateClientConVar("nradio_enabled", "1", true, false, "Radio: hear radios at all (1/0)")

local NEAR = 140
local MAX_CHANNELS = 4
local WALL = 0.45

CL.Audio = CL.Audio or {}
local A = CL.Audio

-- --------------------------------------------------------------- net
local function readTable()
    local len = net.ReadUInt(32)
    if len <= 0 then return nil end
    return util.JSONToTable(util.Decompress(net.ReadData(len)) or "")
end

net.Receive(NET.State, function()
    local t = readTable()
    if not t or not t.id then return end
    t.received = CurTime()
    -- the wire uses short names; NRadio.Position (shared) reads the server's
    t.current, t.startedAt, t.pausedAt = t.cur, t.at, t.pa
    CL.Stations[t.id] = t
    hook.Run("NRadioState", t.id, t)
end)

net.Receive(NET.Gone, function()
    local id = net.ReadString()
    CL.Stations[id] = nil
    hook.Run("NRadioState", id, nil)
end)

net.Receive(NET.Library, function()
    local t = readTable()
    if not t then return end
    CL.Library = t
    hook.Run("NRadioLibrary", t)
end)

net.Receive(NET.Notice, function()
    local msg = net.ReadString()
    chat.AddText(Color(120, 170, 255), "[Radio] ", Color(235, 235, 235), msg)
    hook.Run("NRadioNotice", msg)
end)

hook.Add("InitPostEntity", "nradio_hello", function()
    net.Start(NET.Hello)
    net.SendToServer()
end)

function NRadio.Send(op, args)
    args = args or {}
    args.op = op
    local data = util.Compress(util.TableToJSON(args)) or ""
    net.Start(NET.Cmd)
    net.WriteUInt(#data, 32)
    net.WriteData(data, #data)
    net.SendToServer()
end

-- --------------------------------------------------------------- entity lookup
function NRadio.EntityFor(st)
    if not st then return nil end
    local e = Entity(st.ent or 0)
    if IsValid(e) and e:GetClass() == NRadio.Class and e:GetStationId() == st.id then return e end
    for _, x in ipairs(ents.FindByClass(NRadio.Class)) do
        if x:GetStationId() == st.id then return x end
    end
    return nil
end

-- --------------------------------------------------------------- channels
local function stop(a)
    if a and IsValid(a.ch) then a.ch:Stop() end
end

local function volumeAt(st, a, dist)
    local v
    if dist <= NEAR then
        v = 1
    else
        local t = math.Clamp((dist - NEAR) / math.max(1, (st.range or NRadio.DefaultRange) - NEAR), 0, 1)
        v = (1 - t) * (1 - t)
    end
    return v * (a.occ or 1) * (st.vol or NRadio.DefaultVolume) * cvVolume:GetFloat()
end

local function sync(a, st, force)
    local ch = a.ch
    if not IsValid(ch) then return end
    if st.state == "paused" then
        if ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() end
        return
    end
    local pos = NRadio.Position(st, CurTime())
    if pos < 0 then   -- announced, not started yet
        if ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() end
        return
    end
    local len = ch:GetLength()
    if len > 0 and pos >= len then return end
    if force or math.abs(ch:GetTime() - pos) > 1.2 then
        if pos > 0.25 then ch:SetTime(pos, true) end
    end
    if ch:GetState() ~= GMOD_CHANNEL_PLAYING then ch:Play() end
end

local function start(id, st)
    local a = { key = st.cur.k, born = CurTime(), occ = 1, nextSync = 0, nextTrace = 0 }
    A[id] = a
    local url = NRadio.TrackURL(st.base, st.cur.k)
    sound.PlayURL(url, "3d noplay", function(ch, errId, errName)
        if A[id] ~= a then
            if IsValid(ch) then ch:Stop() end
            return
        end
        if not IsValid(ch) then
            a.failed = CurTime()
            a.err = tostring(errName or errId)
            print("[Radio] couldn't open " .. url .. ": " .. a.err)
            return
        end
        a.ch = ch
        local r = st.range or NRadio.DefaultRange
        ch:Set3DFadeDistance(r * 2, r * 4)
        ch:SetVolume(0)
        local s = CL.Stations[id]
        if s then sync(a, s, true) end
    end)
    return a
end

-- every quarter second: which radios should be open
local function manage()
    local enabled = cvEnabled:GetBool()
    local eye = EyePos()
    local want = {}
    if enabled then
        for id, st in pairs(CL.Stations) do
            if st.cur and (st.state == "playing" or st.state == "paused") and not CL.Muted[id] then
                local ent = NRadio.EntityFor(st)
                if IsValid(ent) then
                    local d = eye:Distance(ent:WorldSpaceCenter())
                    if d < (st.range or NRadio.DefaultRange) * 1.05 then want[#want + 1] = { id = id, d = d } end
                end
            end
        end
        table.sort(want, function(x, y) return x.d < y.d end)
    end
    local keep = {}
    for i = 1, math.min(#want, MAX_CHANNELS) do keep[want[i].id] = true end
    for id, a in pairs(A) do
        local st = CL.Stations[id]
        if not keep[id] or not st or not st.cur or st.cur.k ~= a.key
            or (a.failed and CurTime() - a.failed > 15) then
            stop(a)
            A[id] = nil
        end
    end
    for id in pairs(keep) do
        if not A[id] then start(id, CL.Stations[id]) end
    end
end
timer.Create("nradio_manage", 0.25, 0, manage)

-- every frame: follow the radio, set the loudness, keep in time
hook.Add("Think", "nradio_audio", function()
    local now = CurTime()
    local eye = EyePos()
    for id, a in pairs(A) do
        local st = CL.Stations[id]
        local ch = a.ch
        if st and IsValid(ch) then
            local ent = NRadio.EntityFor(st)
            if IsValid(ent) then
                local p = ent:WorldSpaceCenter()
                ch:SetPos(p)
                if now >= a.nextTrace then
                    a.nextTrace = now + 0.3
                    local tr = util.TraceLine({ start = eye, endpos = p, mask = MASK_SOLID_BRUSHONLY })
                    a.occTarget = tr.Hit and WALL or 1
                end
                a.occ = Lerp(math.min(1, FrameTime() * 4), a.occ, a.occTarget or 1)
                ch:SetVolume(volumeAt(st, a, eye:Distance(p)))
            end
            if now >= a.nextSync then
                a.nextSync = now + 2
                sync(a, st, false)
            elseif st.state == "playing" and ch:GetState() ~= GMOD_CHANNEL_PLAYING and NRadio.Position(st, now) >= 0
                and now >= (a.nextKick or 0) then
                a.nextKick = now + 0.5
                sync(a, st, true)   -- the song was announced and its start time came
            elseif st.state == "paused" and ch:GetState() == GMOD_CHANNEL_PLAYING then
                ch:Pause()
            end
        end
    end
end)

-- a station changed: resync at once (seek, pause, resume)
hook.Add("NRadioState", "nradio_audio", function(id)
    local a = A[id]
    if a then a.nextSync = 0 end
end)

concommand.Add("nradio_debug", function()
    for id, a in pairs(A) do
        local st = CL.Stations[id]
        print(id, a.key, IsValid(a.ch) and string.format("t=%.1f len=%.1f vol=%.2f state=%d",
            a.ch:GetTime(), a.ch:GetLength(), a.ch:GetVolume(), a.ch:GetState()) or ("no channel " .. tostring(a.err)),
            st and string.format("expected %.1f", NRadio.Position(st)) or "")
    end
end)
