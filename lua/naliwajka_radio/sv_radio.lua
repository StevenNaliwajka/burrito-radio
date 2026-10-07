--[[--------------------------------------------------------------------------
    naliwajka_radio/sv_radio.lua  -- every radio's queue and clock

    THE CLOCK IS THE SERVER'S. A song "plays" here as two numbers: when it
    started (CurTime, which every client shares) and how long it is. Clients
    open the MP3 and seek to CurTime() - startedAt, so everyone in earshot
    hears the same bar of the same song, and someone who walks up halfway
    through hears it from halfway. The server never touches audio.

    A new song is announced LeadTime seconds before it starts so clients have
    the first second buffered when it does.

    WHO MAY DO WHAT (convar nradio_add picks whether strangers may queue):
      add            anyone (nradio_add 0, the default) or controllers only (1)
      remove         your own tracks; controllers remove any
      skip           controllers skip at once; anyone else votes, and the skip
                     passes at nradio_vote_ratio of the players in earshot
      pause, clear, volume, range, loop, shuffle, autoplay   controllers
      library, saved playlists, pin to map                    admins
    A controller is an admin (CAMI privilege nradio_admin, else IsAdmin) or
    the player who spawned the radio. Pinned radios belong to the admins.
----------------------------------------------------------------------------]]

NRadio.Stations = NRadio.Stations or {}
local S = NRadio.Stations
local R = NRadio.Relay
local NET = NRadio.Net

for _, n in pairs(NET) do util.AddNetworkString(n) end

local cvAdd = CreateConVar("nradio_add", "0", FCVAR_ARCHIVE, "Radio: 0 = anyone may queue songs, 1 = only the radio's owner and admins")
local cvUserTracks = CreateConVar("nradio_user_tracks", "25", FCVAR_ARCHIVE, "Radio: most songs one non-admin may have queued on a radio")
local cvMaxQueue = CreateConVar("nradio_max_queue", "300", FCVAR_ARCHIVE, "Radio: most songs in one radio's queue")
local cvSpawn = CreateConVar("nradio_spawn", "0", FCVAR_ARCHIVE, "Radio: 0 = anyone may spawn a radio (sandbox), 1 = admins only")
local cvPerPlayer = CreateConVar("nradio_max_per_player", "1", FCVAR_ARCHIVE, "Radio: radios one non-admin may have out")
local cvVote = CreateConVar("nradio_vote_ratio", "0.5", FCVAR_ARCHIVE, "Radio: share of the players in earshot whose skip votes skip the song")

NRadio.Library = NRadio.Library or { tracks = {}, fetched = -1e9 }
NRadio.Playlists = NRadio.Playlists or {}
NRadio.Seq = NRadio.Seq or 0

-- ------------------------------------------------------------- helpers
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

function NRadio.Tell(ply, msg)
    if not IsValid(ply) then print("[Radio] " .. msg) return end
    net.Start(NET.Notice)
    net.WriteString(msg)
    net.Send(ply)
end

local function playerBySid(sid)
    for _, p in ipairs(player.GetAll()) do
        if NRadio.SteamID(p) == sid then return p end
    end
end

function NRadio.CanControl(ply, st)
    if NRadio.IsAdmin(ply) then return true end
    return not st.permanent and st.owner ~= nil and st.owner == NRadio.SteamID(ply)
end

function NRadio.CanAdd(ply, st)
    return cvAdd:GetInt() == 0 or NRadio.CanControl(ply, st)
end

function NRadio.Listeners(st)
    local out = {}
    local ent = st.ent
    if not IsValid(ent) then return out end
    local pos = ent:GetPos()
    for _, p in ipairs(player.GetAll()) do
        if not p:IsBot() and p:GetPos():Distance(pos) <= st.range then out[#out + 1] = p end
    end
    return out
end

local function trackFrom(t, ply)
    return {
        key = t.key, title = t.title or t.key, duration = tonumber(t.duration) or 0,
        by = IsValid(ply) and ply:Nick() or (t.by or "Library"),
        bySid = IsValid(ply) and NRadio.SteamID(ply) or t.bySid,
    }
end

-- ------------------------------------------------------------- stations
function NRadio.NewStation(opts)
    opts = opts or {}
    NRadio.Seq = NRadio.Seq + 1
    local st = {
        id = opts.id or ("r" .. NRadio.Seq .. "-" .. os.time() % 100000),
        owner = opts.owner and NRadio.SteamID(opts.owner) or nil,
        ownerName = IsValid(opts.owner) and opts.owner:Nick() or (opts.permanent and "the server" or "nobody"),
        permanent = opts.permanent or false,
        queue = {}, current = nil, state = "idle",
        startedAt = nil, pausedAt = nil,
        volume = opts.volume or NRadio.DefaultVolume,
        range = opts.range or NRadio.DefaultRange,
        loop = opts.loop or false, shuffle = opts.shuffle or false,
        autoplay = opts.autoplay == nil and true or opts.autoplay,
        skipVotes = {}, history = {}, failStreak = 0,
    }
    S[st.id] = st
    return st
end

function NRadio.StationOf(ent)
    if not IsValid(ent) then return nil end
    return S[ent:GetStationId()]
end

function NRadio.Snapshot(st)
    local function tr(t)
        if not t then return nil end
        return { k = t.key, t = t.title, d = t.duration, b = t.by, s = t.bySid }
    end
    local q = {}
    for i, t in ipairs(st.queue) do q[i] = tr(t) end
    return {
        id = st.id, ent = IsValid(st.ent) and st.ent:EntIndex() or 0,
        state = st.state, cur = tr(st.current), at = st.startedAt, pa = st.pausedAt,
        vol = st.volume, range = st.range, loop = st.loop, shuffle = st.shuffle,
        auto = st.autoplay, pinned = st.permanent, owner = st.ownerName, ownerSid = st.owner,
        base = R.PublicURL(), votes = count(st.skipVotes), q = q,
    }
end

local function writeTable(t)
    local data = util.Compress(util.TableToJSON(t)) or ""
    net.WriteUInt(#data, 32)
    net.WriteData(data, #data)
end
NRadio.WriteTable = writeTable

function NRadio.SendState(st, target)
    net.Start(NET.State)
    writeTable(NRadio.Snapshot(st))
    if target then net.Send(target) else net.Broadcast() end
end

-- changes are flushed once per tick, however many happened
NRadio.DirtySet = NRadio.DirtySet or {}
function NRadio.Dirty(st)
    NRadio.DirtySet[st.id] = true
    if NRadio.OnChanged then NRadio.OnChanged(st) end
    timer.Create("nradio_flush", 0, 1, function()
        for id in pairs(NRadio.DirtySet) do
            local s = S[id]
            if s then NRadio.SendState(s) end
        end
        NRadio.DirtySet = {}
    end)
end

function NRadio.RemoveStation(st)
    S[st.id] = nil
    st.loadToken = (st.loadToken or 0) + 1
    net.Start(NET.Gone)
    net.WriteString(st.id)
    net.Broadcast()
end

-- ------------------------------------------------------------- playback
local function failTrack(st, tr, msg)
    st.failStreak = (st.failStreak or 0) + 1
    local who = tr.bySid and playerBySid(tr.bySid)
    local line = "Couldn't play \"" .. tostring(tr.title) .. "\": " .. tostring(msg)
    if IsValid(who) then NRadio.Tell(who, line) else print("[Radio] " .. line) end
    st.lastError = line
    st.current = nil
    if st.failStreak >= 6 then
        st.state = "idle"
        st.failStreak = 0
        NRadio.Dirty(st)
        print("[Radio] " .. st.id .. ": six failures in a row, stopping")
        return
    end
    NRadio.Advance(st, "failed")
end

function NRadio.Load(st)
    local tr = st.current
    if not tr then return end
    st.loadToken = (st.loadToken or 0) + 1
    local token = st.loadToken
    st.state = "loading"
    st.startedAt, st.pausedAt = nil, nil
    st.loadStarted = CurTime()
    NRadio.Dirty(st)
    local function stale() return S[st.id] ~= st or st.loadToken ~= token or st.current ~= tr end
    local function try()
        if stale() then return end
        R.Fetch(tr.key, function(ok, res)
            if stale() then return end
            if not ok then return failTrack(st, tr, res) end
            if res.state == "ready" then
                if (tonumber(res.duration) or 0) > 0 then tr.duration = tonumber(res.duration) end
                st.state = "playing"
                st.startedAt = CurTime() + NRadio.LeadTime - (tr.resumeAt or 0)
                tr.resumeAt = nil
                st.skipVotes = {}
                st.failStreak = 0
                st.lastError = nil
                NRadio.Dirty(st)
                NRadio.Prefetch(st)
            elseif res.state == "error" then
                failTrack(st, tr, res.error or "error")
            elseif CurTime() - st.loadStarted > 900 then
                failTrack(st, tr, "it took too long to download")
            else
                timer.Simple(2, try)
            end
        end)
    end
    try()
end

-- warm the relay's cache for what is up next, so the switch is instant
function NRadio.Prefetch(st)
    for i = 1, math.min(2, #st.queue) do
        local t = st.queue[i]
        if not t.prefetched then
            t.prefetched = true
            R.Fetch(t.key, function() end)
        end
    end
end

function NRadio.PickLibrary(st)
    local lib = NRadio.Library.tracks or {}
    if #lib == 0 then return nil end
    local recent = {}
    for i = #st.history, math.max(1, #st.history - math.min(#lib - 1, 25)) + 0, -1 do
        if st.history[i] then recent[st.history[i]] = true end
    end
    local pool = {}
    for _, t in ipairs(lib) do if not recent[t.key] then pool[#pool + 1] = t end end
    if #pool == 0 then pool = lib end
    local t = pool[math.random(#pool)]
    return trackFrom({ key = t.key, title = t.title, duration = t.duration, by = "Library" })
end

function NRadio.Advance(st, reason)
    local prev = st.current
    if prev then
        st.history[#st.history + 1] = prev.key
        if #st.history > 50 then table.remove(st.history, 1) end
        if st.loop and reason ~= "removed" and reason ~= "failed" and reason ~= "cleared" then
            local again = trackFrom(prev)
            again.by, again.bySid = prev.by, prev.bySid
            st.queue[#st.queue + 1] = again
        end
    end
    st.current = nil
    st.skipVotes = {}
    local nxt = table.remove(st.queue, 1)
    if not nxt and st.autoplay then nxt = NRadio.PickLibrary(st) end
    if not nxt then
        st.state = "idle"
        st.startedAt, st.pausedAt = nil, nil
        NRadio.Dirty(st)
        return
    end
    st.current = nxt
    NRadio.Load(st)
end

-- the one timer: songs that ran out move on
function NRadio.Tick()
    local now = CurTime()
    for _, st in pairs(S) do
        if st.state == "playing" and st.current then
            local d = st.current.duration or 0
            if d > 0 and now >= (st.startedAt or now) + d + 0.75 then NRadio.Advance(st, "ended") end
        elseif st.state == "idle" and st.autoplay and #NRadio.Library.tracks > 0 and IsValid(st.ent)
            and (st.idleSince or 0) + 5 < now then
            st.idleSince = now
            NRadio.Advance(st, "autoplay")
        end
        if st.state ~= "idle" then st.idleSince = now end
    end
end
timer.Create("nradio_tick", 1, 0, function() NRadio.Tick() end)

-- ------------------------------------------------------------- the library
function NRadio.RefreshLibrary(cb)
    R.Library(function(ok, res)
        if ok and type(res.tracks) == "table" then
            local out = {}
            for _, t in ipairs(res.tracks) do
                if t.key then out[#out + 1] = { key = t.key, title = t.title, duration = tonumber(t.duration) or 0, album = t.album or "" } end
            end
            NRadio.Library = { tracks = out, fetched = CurTime() }
        end
        if cb then cb(ok, res) end
    end)
end
timer.Create("nradio_library", 300, 0, function() NRadio.RefreshLibrary() end)
hook.Add("InitPostEntity", "nradio_library", function() NRadio.RefreshLibrary() end)

function NRadio.SendLibrary(ply)
    net.Start(NET.Library)
    local pls = {}
    for name, p in pairs(NRadio.Playlists) do pls[#pls + 1] = { name = name, n = #(p.tracks or {}) } end
    table.sort(pls, function(a, b) return a.name:lower() < b.name:lower() end)
    writeTable({ tracks = NRadio.Library.tracks, playlists = pls, problem = NRadio.IsAdmin(ply) and R.Problem or nil })
    net.Send(ply)
end

-- ------------------------------------------------------------- queueing
local function userCount(st, sid)
    local n = 0
    for _, t in ipairs(st.queue) do if t.bySid == sid then n = n + 1 end end
    return n
end

-- add tracks (already resolved) to a station; returns how many went in
function NRadio.Enqueue(st, ply, tracks, playNext)
    local admin = NRadio.CanControl(ply, st)
    local sid = NRadio.SteamID(ply)
    local room = cvMaxQueue:GetInt() - #st.queue
    if not admin then room = math.min(room, cvUserTracks:GetInt() - userCount(st, sid)) end
    local added = {}
    for _, t in ipairs(tracks) do
        if #added >= room then break end
        if t.key then added[#added + 1] = trackFrom(t, ply) end
    end
    if #added == 0 then return 0 end
    if st.shuffle and not playNext then
        for _, t in ipairs(added) do table.insert(st.queue, math.random(1, #st.queue + 1), t) end
    elseif playNext then
        for i = #added, 1, -1 do table.insert(st.queue, 1, added[i]) end
    else
        for _, t in ipairs(added) do st.queue[#st.queue + 1] = t end
    end
    if st.state == "idle" then NRadio.Advance(st, "added") else NRadio.Dirty(st); NRadio.Prefetch(st) end
    return #added, #tracks - #added
end

function NRadio.AddQuery(st, ply, q, playNext)
    q = string.Trim(string.sub(tostring(q or ""), 1, 500))
    if q == "" then return NRadio.Tell(ply, "Paste a YouTube link or type a song name.") end
    NRadio.Tell(ply, "Looking up " .. (#q > 60 and (q:sub(1, 57) .. "...") or q) .. " ...")
    R.Resolve(q, function(ok, res)
        if not S[st.id] then return end
        if not ok then return NRadio.Tell(ply, "Couldn't add that: " .. tostring(res)) end
        local tracks = res.tracks or {}
        local n, dropped = NRadio.Enqueue(st, ply, tracks, playNext)
        if n == 0 then
            return NRadio.Tell(ply, #tracks == 0 and "Nothing playable there." or "The queue is full (or you have too many songs in it).")
        end
        local what = (#tracks == 1) and ("\"" .. tostring(tracks[1].title) .. "\"") or (n .. " songs from \"" .. tostring(res.title) .. "\"")
        NRadio.Tell(ply, "Added " .. what .. ((dropped or 0) > 0 and (" (" .. dropped .. " didn't fit)") or "") .. ".")
    end)
end

-- ------------------------------------------------------------- commands
NRadio.Commands = NRadio.Commands or {}
local C = NRadio.Commands

local function need(check, ply, st)
    if check == "control" and not NRadio.CanControl(ply, st) then
        NRadio.Tell(ply, "Only " .. (st.permanent and "admins" or (st.ownerName .. " or an admin")) .. " can do that on this radio.")
        return false
    end
    if check == "admin" and not NRadio.IsAdmin(ply) then
        NRadio.Tell(ply, "Only admins can do that.")
        return false
    end
    if check == "add" and not NRadio.CanAdd(ply, st) then
        NRadio.Tell(ply, "Only " .. st.ownerName .. " or an admin can add songs to this radio.")
        return false
    end
    return true
end

C.add = function(ply, st, a)
    if not need("add", ply, st) then return end
    NRadio.AddQuery(st, ply, a.q, a.next and NRadio.CanControl(ply, st))
end

C.skip = function(ply, st)
    if not st.current then return end
    local mine = st.current.bySid == NRadio.SteamID(ply)
    if NRadio.CanControl(ply, st) or mine then
        NRadio.Advance(st, "skipped")
        return
    end
    st.skipVotes[NRadio.SteamID(ply)] = true
    local listeners = NRadio.Listeners(st)
    local votes = 0
    for _, p in ipairs(listeners) do if st.skipVotes[NRadio.SteamID(p)] then votes = votes + 1 end end
    local needed = math.max(1, math.ceil(#listeners * cvVote:GetFloat()))
    if votes >= needed then
        NRadio.Advance(st, "skipped")
    else
        NRadio.Tell(ply, "Skip vote counted: " .. votes .. "/" .. needed .. " of the people in earshot.")
        NRadio.Dirty(st)
    end
end

C.remove = function(ply, st, a)
    local i = tonumber(a.i)
    local t = i and st.queue[i]
    if not t or t.key ~= a.k then return NRadio.Tell(ply, "That song already moved; try again.") end
    if not (NRadio.CanControl(ply, st) or t.bySid == NRadio.SteamID(ply)) then
        return NRadio.Tell(ply, "You can only remove songs you added.")
    end
    table.remove(st.queue, i)
    NRadio.Dirty(st)
end

C.move = function(ply, st, a)
    if not need("control", ply, st) then return end
    local i, j = tonumber(a.i), tonumber(a.to)
    local t = i and st.queue[i]
    if not t or t.key ~= a.k or not j then return end
    j = math.Clamp(j, 1, #st.queue)
    table.remove(st.queue, i)
    table.insert(st.queue, j, t)
    NRadio.Dirty(st)
    NRadio.Prefetch(st)
end

C.clear = function(ply, st)
    if not need("control", ply, st) then return end
    st.queue = {}
    NRadio.Dirty(st)
end

C.stop = function(ply, st)
    if not need("control", ply, st) then return end
    st.queue = {}
    st.autoplayWas = st.autoplay
    st.current = nil
    st.loadToken = (st.loadToken or 0) + 1
    st.state = "idle"
    st.startedAt, st.pausedAt = nil, nil
    st.idleSince = CurTime() + 1e9   -- autoplay waits until something is added
    NRadio.Dirty(st)
end

C.pause = function(ply, st)
    if not need("control", ply, st) then return end
    if st.state == "playing" then
        st.pausedAt = math.max(0, CurTime() - st.startedAt)
        st.state = "paused"
    elseif st.state == "paused" then
        st.startedAt = CurTime() + 0.5 - (st.pausedAt or 0)
        st.pausedAt = nil
        st.state = "playing"
    elseif st.state == "idle" then
        st.idleSince = 0
        NRadio.Advance(st, "play")
        return
    end
    NRadio.Dirty(st)
end

C.seek = function(ply, st, a)
    if not need("control", ply, st) then return end
    local t = tonumber(a.t)
    if not t or not st.current or st.state ~= "playing" then return end
    t = math.Clamp(t, 0, math.max(0, (st.current.duration or 0) - 1))
    st.startedAt = CurTime() + 0.3 - t
    NRadio.Dirty(st)
end

C.volume = function(ply, st, a)
    if not need("control", ply, st) then return end
    st.volume = math.Clamp(tonumber(a.v) or st.volume, 0, 1)
    NRadio.Dirty(st)
end

C.range = function(ply, st, a)
    if not need("control", ply, st) then return end
    st.range = math.Clamp(math.floor(tonumber(a.v) or st.range), NRadio.MinRange, NRadio.MaxRange)
    NRadio.Dirty(st)
end

for _, flag in ipairs({ "loop", "shuffle", "autoplay" }) do
    C[flag] = function(ply, st, a)
        if not need("control", ply, st) then return end
        st[flag] = a.on and true or false
        if flag == "shuffle" and st.shuffle then
            for i = #st.queue, 2, -1 do
                local j = math.random(i)
                st.queue[i], st.queue[j] = st.queue[j], st.queue[i]
            end
        end
        if flag == "autoplay" and st.autoplay then st.idleSince = 0 end
        NRadio.Dirty(st)
    end
end

-- the owner's library: anyone who may add can queue from it
C.libadd = function(ply, st, a)
    if not need("add", ply, st) then return end
    local want = {}
    if a.all then
        for _, t in ipairs(NRadio.Library.tracks) do want[#want + 1] = t end
        for i = #want, 2, -1 do local j = math.random(i) want[i], want[j] = want[j], want[i] end
    else
        local set = {}
        for _, k in ipairs(type(a.keys) == "table" and a.keys or {}) do set[k] = true end
        for _, t in ipairs(NRadio.Library.tracks) do if set[t.key] then want[#want + 1] = t end end
    end
    local n = NRadio.Enqueue(st, ply, want, false)
    NRadio.Tell(ply, n > 0 and ("Added " .. n .. " from the library.") or "Nothing added (the queue is full?).")
end

C.libsave = function(ply, st, a)
    if not need("admin", ply, st) then return end
    local key = a.k or (st.current and st.current.key)
    if not key then return end
    R.Save(key, function(ok, res)
        if not ok then return NRadio.Tell(ply, "Couldn't save: " .. tostring(res)) end
        NRadio.RefreshLibrary(function() NRadio.SendLibrary(ply) end)
        NRadio.Tell(ply, "Saved to the library. It stays on the server and autoplay can pick it.")
    end)
end

C.libremove = function(ply, st, a)
    if not need("admin", ply, st) then return end
    R.Unsave(tostring(a.k or ""), function(ok, res)
        if not ok then return NRadio.Tell(ply, "Couldn't remove: " .. tostring(res)) end
        NRadio.RefreshLibrary(function() NRadio.SendLibrary(ply) end)
    end)
end

C.libimport = function(ply, st, a)   -- a YouTube playlist straight into the library
    if not need("admin", ply, st) then return end
    local q = string.Trim(tostring(a.q or ""))
    if q == "" then return end
    NRadio.Tell(ply, "Importing into the library (this downloads every song; it takes a while) ...")
    R.Resolve(q, function(ok, res)
        if not ok then return NRadio.Tell(ply, "Couldn't import: " .. tostring(res)) end
        local tracks = res.tracks or {}
        local i = 0
        local function nextOne()
            i = i + 1
            local t = tracks[i]
            if not t then
                NRadio.RefreshLibrary(function() if IsValid(ply) then NRadio.SendLibrary(ply) end end)
                return NRadio.Tell(ply, "Library import queued: " .. #tracks .. " songs. They show up as they finish downloading.")
            end
            R.Save(t.key, function() timer.Simple(0.2, nextOne) end)
        end
        nextOne()
    end)
end

C.librescan = function(ply, st)
    if not need("admin", ply, st) then return end
    R.Rescan(function(ok, res)
        if not ok then return NRadio.Tell(ply, "Rescan failed: " .. tostring(res)) end
        NRadio.RefreshLibrary(function() NRadio.SendLibrary(ply) end)
        NRadio.Tell(ply, "Library rescanned.")
    end)
end

C.library = function(ply, st)
    if CurTime() - (NRadio.Library.fetched or -1e9) > 30 then
        NRadio.RefreshLibrary(function() if IsValid(ply) then NRadio.SendLibrary(ply) end end)
    else
        NRadio.SendLibrary(ply)
    end
end

-- saved playlists (sv_persist stores them)
C.plsave = function(ply, st, a)
    if not need("admin", ply, st) then return end
    local name = string.Trim(string.sub(tostring(a.name or ""), 1, 60))
    if name == "" then return NRadio.Tell(ply, "Give the playlist a name.") end
    local tracks = {}
    if st.current then tracks[1] = st.current end
    for _, t in ipairs(st.queue) do tracks[#tracks + 1] = t end
    if #tracks == 0 then return NRadio.Tell(ply, "The queue is empty; add songs first.") end
    local list = {}
    for _, t in ipairs(tracks) do list[#list + 1] = { key = t.key, title = t.title, duration = t.duration } end
    NRadio.Playlists[name] = { tracks = list }
    NRadio.SavePlaylists()
    NRadio.SendLibrary(ply)
    NRadio.Tell(ply, "Saved \"" .. name .. "\" (" .. #list .. " songs).")
end

C.plload = function(ply, st, a)
    if not need("add", ply, st) then return end
    local p = NRadio.Playlists[tostring(a.name or "")]
    if not p then return NRadio.Tell(ply, "No playlist by that name.") end
    local n = NRadio.Enqueue(st, ply, p.tracks or {}, false)
    NRadio.Tell(ply, "Added " .. n .. " songs from \"" .. a.name .. "\".")
end

C.pldelete = function(ply, st, a)
    if not need("admin", ply, st) then return end
    NRadio.Playlists[tostring(a.name or "")] = nil
    NRadio.SavePlaylists()
    NRadio.SendLibrary(ply)
end

C.pin = function(ply, st, a)
    if not need("admin", ply, st) then return end
    NRadio.SetPinned(st, a.on and true or false)
    -- pinning renames the station, which closes the client's menu: reopen it
    if IsValid(st.ent) then timer.Simple(0.2, function() if IsValid(ply) and IsValid(st.ent) then NRadio.OpenMenu(ply, st.ent) end end) end
    NRadio.Tell(ply, a.on and "Pinned: this radio comes back here after every round and restart, still playing."
        or "Unpinned: this radio goes away with the next cleanup.")
end

-- ------------------------------------------------------------- net
local rate = {}
net.Receive(NET.Cmd, function(_, ply)
    local sid = NRadio.SteamID(ply)
    local now = CurTime()
    local r = rate[sid] or { t = now, n = 0 }
    if now - r.t > 2 then r.t, r.n = now, 0 end
    r.n = r.n + 1
    rate[sid] = r
    if r.n > 12 then return end
    local len = net.ReadUInt(32)
    if len <= 0 or len > 16384 then return end
    local a = util.JSONToTable(util.Decompress(net.ReadData(len)) or "")
    if type(a) ~= "table" then return end
    local st = S[tostring(a.id or "")]
    local fn = C[tostring(a.op or "")]
    if not st or not fn then return end
    -- you have to be near the radio (or an admin) to work it
    if not NRadio.IsAdmin(ply) and IsValid(st.ent) and ply:GetPos():Distance(st.ent:GetPos()) > 400 then
        return NRadio.Tell(ply, "Walk over to the radio to use it.")
    end
    if a.op == "add" then
        if r.lastAdd and now - r.lastAdd < 2 then return NRadio.Tell(ply, "Slow down a little.") end
        r.lastAdd = now
    end
    fn(ply, st, a)
end)

net.Receive(NET.Hello, function(_, ply)
    if ply.nradioHello then return end
    ply.nradioHello = true
    for _, st in pairs(S) do NRadio.SendState(st, ply) end
end)

function NRadio.OpenMenu(ply, ent)
    local st = NRadio.StationOf(ent)
    if not st then return end
    NRadio.SendState(st, ply)
    net.Start(NET.Open)
    net.WriteString(st.id)
    net.WriteBool(NRadio.CanControl(ply, st))
    net.WriteBool(NRadio.IsAdmin(ply))
    net.WriteBool(NRadio.CanAdd(ply, st))
    net.Send(ply)
    C.library(ply, st)
end

-- ------------------------------------------------------------- spawning
hook.Add("PlayerSpawnSENT", "nradio_limit", function(ply, class)
    if class ~= NRadio.Class then return end
    if NRadio.IsAdmin(ply) then return end
    if cvSpawn:GetInt() == 1 then
        NRadio.Tell(ply, "Only admins can spawn radios here.")
        return false
    end
    local sid, n = NRadio.SteamID(ply), 0
    for _, st in pairs(S) do if st.owner == sid and not st.permanent and IsValid(st.ent) then n = n + 1 end end
    if n >= cvPerPlayer:GetInt() then
        NRadio.Tell(ply, "You already have " .. n .. " radio" .. (n == 1 and "" or "s") .. " out.")
        return false
    end
end)

-- an entity left: its station goes too, unless it is pinned (then TTT's
-- round cleanup is what removed it, and PostCleanupMap puts it back)
function NRadio.EntityRemoved(ent)
    local st = S[ent:GetStationId()]
    if not st or st.ent ~= ent then return end
    if st.permanent then st.pos, st.ang = ent:GetPos(), ent:GetAngles() end
    st.ent = nil
    -- a pinned radio outlives its entity: the round cleanup, a map change and
    -- a stray remover all bring it back. The menu's "Remove radio" deletes it.
    if st.permanent then return end
    NRadio.RemoveStation(st)
end

C.delete = function(ply, st)
    if not need("control", ply, st) then return end
    if st.permanent then NRadio.SetPinned(st, false) end
    local ent = st.ent
    NRadio.RemoveStation(st)
    if st.permanent == false then NRadio.SavePinned() end
    if IsValid(ent) then ent:Remove() end
end

-- admins console: spawn a radio where you look (for TTT, which has no spawn menu)
concommand.Add("nradio_place", function(ply, _, args)
    if not NRadio.IsAdmin(ply) or not IsValid(ply) then return end
    local tr = ply:GetEyeTrace()
    local ent = NRadio.SpawnRadio(tr.HitPos + tr.HitNormal * 2, Angle(0, ply:EyeAngles().y + 180, 0), nil,
        { owner = nil, permanent = args[1] ~= "0" })
    if args[1] ~= "0" then NRadio.SetPinned(NRadio.StationOf(ent), true) end
    NRadio.Tell(ply, args[1] ~= "0" and "Placed a pinned radio. Press E on it to load music." or "Placed a radio.")
end)

-- spawn an entity for a station (new or existing)
function NRadio.SpawnRadio(pos, ang, st, opts)
    st = st or NRadio.NewStation(opts)
    local ent = ents.Create(NRadio.Class)
    ent:SetStationId(st.id)
    ent:SetPos(pos)
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()
    st.ent = ent
    if st.permanent then
        local phys = ent:GetPhysicsObject()
        if IsValid(phys) then phys:EnableMotion(false) end
    end
    NRadio.Dirty(st)
    return ent, st
end

concommand.Add("nradio_status", function(ply)
    if IsValid(ply) and not NRadio.IsAdmin(ply) then return end
    local out = {}
    for id, st in pairs(S) do
        out[#out + 1] = string.format("%s %s%s %s q=%d %s", id, st.state, st.permanent and " pinned" or "",
            st.current and ("\"" .. st.current.title .. "\" " .. NRadio.FormatTime(NRadio.Position(st)) .. "/" .. NRadio.FormatTime(st.current.duration)) or "-",
            #st.queue, IsValid(st.ent) and tostring(st.ent:GetPos()) or "no entity")
    end
    out[#out + 1] = "library: " .. #NRadio.Library.tracks .. " tracks" .. (R.Problem and ("; relay problem: " .. R.Problem) or "")
    local text = table.concat(out, "\n")
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, text) else print(text) end
end)

-- console / rcon: queue something on every radio, or one (nradio_play <query> [stationId])
concommand.Add("nradio_play", function(ply, _, args)
    if IsValid(ply) and not NRadio.IsAdmin(ply) then return end
    local q, id = args[1], args[2]
    for sid, st in pairs(S) do
        if not id or id == sid then NRadio.AddQuery(st, ply, q, false) end
    end
end)
