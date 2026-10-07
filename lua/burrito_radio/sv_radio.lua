--[[--------------------------------------------------------------------------
    burrito_radio/sv_radio.lua  -- every radio's queue and clock

    THE CLOCK IS THE SERVER'S. A song "plays" here as two numbers: when it
    started (CurTime, which every client shares) and how long it is. Clients
    open the MP3 and seek to CurTime() - startedAt, so everyone in earshot
    hears the same bar of the same song, and someone who walks up halfway
    through hears it from halfway. The server never touches audio.

    A new song is announced LeadTime seconds before it starts so clients have
    the first second buffered when it does.

    WHO MAY DO WHAT (convar bradio_add picks whether strangers may queue):
      add            anyone (bradio_add 0, the default) or controllers only (1)
      remove         your own tracks; controllers remove any
      skip           controllers skip at once; anyone else votes, and the skip
                     passes at bradio_vote_ratio of the players in earshot
      pause, clear, volume, range, loop, shuffle, autoplay   controllers
      library, saved playlists, pin to map                    admins
    A controller is an admin (CAMI privilege bradio_admin, else IsAdmin) or
    the player who spawned the radio. Pinned radios belong to the admins.
----------------------------------------------------------------------------]]

BRadio.Stations = BRadio.Stations or {}
local S = BRadio.Stations
local R = BRadio.Relay
local NET = BRadio.Net

for _, n in pairs(NET) do util.AddNetworkString(n) end

local cvAdd = CreateConVar("bradio_add", "0", FCVAR_ARCHIVE, "Radio: 0 = anyone may queue songs, 1 = only the radio's owner and admins")
local cvUserTracks = CreateConVar("bradio_user_tracks", "25", FCVAR_ARCHIVE, "Radio: most songs one non-admin may have queued on a radio")
local cvMaxQueue = CreateConVar("bradio_max_queue", "300", FCVAR_ARCHIVE, "Radio: most songs in one radio's queue")
local cvSpawn = CreateConVar("bradio_spawn", "0", FCVAR_ARCHIVE, "Radio: 0 = anyone may spawn a radio (sandbox), 1 = admins only")
local cvPerPlayer = CreateConVar("bradio_max_per_player", "1", FCVAR_ARCHIVE, "Radio: radios one non-admin may have out")
local cvVote = CreateConVar("bradio_vote_ratio", "0.5", FCVAR_ARCHIVE, "Radio: share of the players in earshot whose skip votes skip the song")

BRadio.Library = BRadio.Library or { tracks = {}, fetched = -1e9 }
BRadio.Playlists = BRadio.Playlists or {}
BRadio.Seq = BRadio.Seq or 0

-- ------------------------------------------------------------- helpers
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

function BRadio.Tell(ply, msg)
    if not IsValid(ply) then print("[Radio] " .. msg) return end
    net.Start(NET.Notice)
    net.WriteString(msg)
    net.Send(ply)
end

local function playerBySid(sid)
    for _, p in ipairs(player.GetAll()) do
        if BRadio.SteamID(p) == sid then return p end
    end
end

function BRadio.CanControl(ply, st)
    if BRadio.IsAdmin(ply) then return true end
    return not st.permanent and st.owner ~= nil and st.owner == BRadio.SteamID(ply)
end

function BRadio.CanAdd(ply, st)
    return cvAdd:GetInt() == 0 or BRadio.CanControl(ply, st)
end

function BRadio.Listeners(st)
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
        bySid = IsValid(ply) and BRadio.SteamID(ply) or t.bySid,
    }
end

-- ------------------------------------------------------------- stations
function BRadio.NewStation(opts)
    opts = opts or {}
    BRadio.Seq = BRadio.Seq + 1
    local st = {
        id = opts.id or ("r" .. BRadio.Seq .. "-" .. os.time() % 100000),
        owner = opts.owner and BRadio.SteamID(opts.owner) or nil,
        ownerName = IsValid(opts.owner) and opts.owner:Nick() or (opts.permanent and "the server" or "nobody"),
        permanent = opts.permanent or false,
        queue = {}, current = nil, state = "idle",
        startedAt = nil, pausedAt = nil,
        volume = opts.volume or BRadio.DefaultVolume,
        range = opts.range or BRadio.DefaultRange,
        loop = opts.loop or false, shuffle = opts.shuffle or false,
        autoplay = opts.autoplay == nil and true or opts.autoplay,
        skipVotes = {}, history = {}, failStreak = 0,
    }
    S[st.id] = st
    return st
end

function BRadio.StationOf(ent)
    if not IsValid(ent) then return nil end
    return S[ent:GetStationId()]
end

function BRadio.Snapshot(st)
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
BRadio.WriteTable = writeTable

function BRadio.SendState(st, target)
    net.Start(NET.State)
    writeTable(BRadio.Snapshot(st))
    if target then net.Send(target) else net.Broadcast() end
end

-- changes are flushed once per tick, however many happened
BRadio.DirtySet = BRadio.DirtySet or {}
function BRadio.Dirty(st)
    BRadio.DirtySet[st.id] = true
    if BRadio.OnChanged then BRadio.OnChanged(st) end
    timer.Create("bradio_flush", 0, 1, function()
        for id in pairs(BRadio.DirtySet) do
            local s = S[id]
            if s then BRadio.SendState(s) end
        end
        BRadio.DirtySet = {}
    end)
end

function BRadio.RemoveStation(st)
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
    if IsValid(who) then BRadio.Tell(who, line) else print("[Radio] " .. line) end
    st.lastError = line
    st.current = nil
    if st.failStreak >= 6 then
        st.state = "idle"
        st.failStreak = 0
        BRadio.Dirty(st)
        print("[Radio] " .. st.id .. ": six failures in a row, stopping")
        return
    end
    BRadio.Advance(st, "failed")
end

function BRadio.Load(st)
    local tr = st.current
    if not tr then return end
    st.loadToken = (st.loadToken or 0) + 1
    local token = st.loadToken
    st.state = "loading"
    st.startedAt, st.pausedAt = nil, nil
    st.loadStarted = CurTime()
    BRadio.Dirty(st)
    local function stale() return S[st.id] ~= st or st.loadToken ~= token or st.current ~= tr end
    local function try()
        if stale() then return end
        R.Fetch(tr.key, function(ok, res)
            if stale() then return end
            -- the relay forgot this song (its cache clears after 30 min, its notes
            -- after a week): a pinned radio coming back finds it again, once
            if not ok and tostring(res):find("resolve it first", 1, true) and not tr.reresolved then
                local src = BRadio.SourceOf(tr.key)
                if src then
                    tr.reresolved = true
                    return R.Resolve(src, function() if not stale() then try() end end)
                end
            end
            if not ok then return failTrack(st, tr, res) end
            if res.state == "ready" then
                if (tonumber(res.duration) or 0) > 0 then tr.duration = tonumber(res.duration) end
                st.state = "playing"
                st.startedAt = CurTime() + BRadio.LeadTime - (tr.resumeAt or 0)
                tr.resumeAt = nil
                st.skipVotes = {}
                st.failStreak = 0
                st.lastError = nil
                BRadio.Dirty(st)
                BRadio.Prefetch(st)
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
function BRadio.Prefetch(st)
    for i = 1, math.min(2, #st.queue) do
        local t = st.queue[i]
        if not t.prefetched then
            t.prefetched = true
            R.Fetch(t.key, function() end)
        end
    end
end

function BRadio.PickLibrary(st)
    local lib = BRadio.Library.tracks or {}
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

function BRadio.Advance(st, reason)
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
    if not nxt and st.autoplay then nxt = BRadio.PickLibrary(st) end
    if not nxt then
        st.state = "idle"
        st.startedAt, st.pausedAt = nil, nil
        BRadio.Dirty(st)
        return
    end
    st.current = nxt
    BRadio.Load(st)
end

-- where a track came from, to find it again (nil for library files)
function BRadio.SourceOf(key)
    local yt = tostring(key):match("^yt%-([%w_-]+)$")
    if yt then return "https://www.youtube.com/watch?v=" .. yt end
    local sp = tostring(key):match("^sp%-(%w+)$")
    if sp then return "spotify:track:" .. sp end
end

-- keep-alive: the relay clears songs nobody used for 30 minutes; a long song that
-- is still playing (or paused) is "used", so it is not cleared under the players
function BRadio.KeepAlive()
    for _, st in pairs(S) do
        if st.current and (st.state == "playing" or st.state == "paused") then R.Fetch(st.current.key, function() end) end
    end
end
timer.Create("bradio_keepalive", 300, 0, function() BRadio.KeepAlive() end)

-- the one timer: songs that ran out move on
function BRadio.Tick()
    local now = CurTime()
    for _, st in pairs(S) do
        if st.state == "playing" and st.current then
            local d = st.current.duration or 0
            if d > 0 and now >= (st.startedAt or now) + d + 0.75 then BRadio.Advance(st, "ended") end
        elseif st.state == "idle" and st.autoplay and #BRadio.Library.tracks > 0 and IsValid(st.ent)
            and (st.idleSince or 0) + 5 < now then
            st.idleSince = now
            BRadio.Advance(st, "autoplay")
        end
        if st.state ~= "idle" then st.idleSince = now end
    end
end
timer.Create("bradio_tick", 1, 0, function() BRadio.Tick() end)

-- ------------------------------------------------------------- the library
function BRadio.RefreshLibrary(cb)
    R.Library(function(ok, res)
        if ok and type(res.tracks) == "table" then
            local out = {}
            for _, t in ipairs(res.tracks) do
                if t.key then out[#out + 1] = { key = t.key, title = t.title, duration = tonumber(t.duration) or 0, album = t.album or "" } end
            end
            BRadio.Library = { tracks = out, fetched = CurTime() }
        end
        if cb then cb(ok, res) end
    end)
end
timer.Create("bradio_library", 300, 0, function() BRadio.RefreshLibrary() end)
hook.Add("InitPostEntity", "bradio_library", function() BRadio.RefreshLibrary() end)

function BRadio.SendLibrary(ply)
    net.Start(NET.Library)
    local pls = {}
    for name, p in pairs(BRadio.Playlists) do pls[#pls + 1] = { name = name, n = #(p.tracks or {}) } end
    table.sort(pls, function(a, b) return a.name:lower() < b.name:lower() end)
    writeTable({ tracks = BRadio.Library.tracks, playlists = pls, problem = BRadio.IsAdmin(ply) and R.Problem or nil })
    net.Send(ply)
end

-- ------------------------------------------------------------- queueing
local function userCount(st, sid)
    local n = 0
    for _, t in ipairs(st.queue) do if t.bySid == sid then n = n + 1 end end
    return n
end

-- add tracks (already resolved) to a station; returns how many went in
function BRadio.Enqueue(st, ply, tracks, playNext)
    local admin = BRadio.CanControl(ply, st)
    local sid = BRadio.SteamID(ply)
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
    if st.state == "idle" then BRadio.Advance(st, "added") else BRadio.Dirty(st); BRadio.Prefetch(st) end
    return #added, #tracks - #added
end

function BRadio.AddQuery(st, ply, q, playNext)
    q = string.Trim(string.sub(tostring(q or ""), 1, 500))
    if q == "" then return BRadio.Tell(ply, "Paste a YouTube link or type a song name.") end
    BRadio.Tell(ply, "Looking up " .. (#q > 60 and (q:sub(1, 57) .. "...") or q) .. " ...")
    R.Resolve(q, function(ok, res)
        if not S[st.id] then return end
        if not ok then return BRadio.Tell(ply, "Couldn't add that: " .. tostring(res)) end
        local tracks = res.tracks or {}
        local n, dropped = BRadio.Enqueue(st, ply, tracks, playNext)
        if n == 0 then
            return BRadio.Tell(ply, #tracks == 0 and "Nothing playable there." or "The queue is full (or you have too many songs in it).")
        end
        local what = (#tracks == 1) and ("\"" .. tostring(tracks[1].title) .. "\"") or (n .. " songs from \"" .. tostring(res.title) .. "\"")
        BRadio.Tell(ply, "Added " .. what .. ((dropped or 0) > 0 and (" (" .. dropped .. " didn't fit)") or "") .. ".")
    end)
end

-- ------------------------------------------------------------- commands
BRadio.Commands = BRadio.Commands or {}
local C = BRadio.Commands

local function need(check, ply, st)
    if check == "control" and not BRadio.CanControl(ply, st) then
        BRadio.Tell(ply, "Only " .. (st.permanent and "admins" or (st.ownerName .. " or an admin")) .. " can do that on this radio.")
        return false
    end
    if check == "admin" and not BRadio.IsAdmin(ply) then
        BRadio.Tell(ply, "Only admins can do that.")
        return false
    end
    if check == "add" and not BRadio.CanAdd(ply, st) then
        BRadio.Tell(ply, "Only " .. st.ownerName .. " or an admin can add songs to this radio.")
        return false
    end
    return true
end

C.add = function(ply, st, a)
    if not need("add", ply, st) then return end
    BRadio.AddQuery(st, ply, a.q, a.next and BRadio.CanControl(ply, st))
end

C.skip = function(ply, st)
    if not st.current then return end
    local mine = st.current.bySid == BRadio.SteamID(ply)
    if BRadio.CanControl(ply, st) or mine then
        BRadio.Advance(st, "skipped")
        return
    end
    st.skipVotes[BRadio.SteamID(ply)] = true
    local listeners = BRadio.Listeners(st)
    local votes = 0
    for _, p in ipairs(listeners) do if st.skipVotes[BRadio.SteamID(p)] then votes = votes + 1 end end
    local needed = math.max(1, math.ceil(#listeners * cvVote:GetFloat()))
    if votes >= needed then
        BRadio.Advance(st, "skipped")
    else
        BRadio.Tell(ply, "Skip vote counted: " .. votes .. "/" .. needed .. " of the people in earshot.")
        BRadio.Dirty(st)
    end
end

C.remove = function(ply, st, a)
    local i = tonumber(a.i)
    local t = i and st.queue[i]
    if not t or t.key ~= a.k then return BRadio.Tell(ply, "That song already moved; try again.") end
    if not (BRadio.CanControl(ply, st) or t.bySid == BRadio.SteamID(ply)) then
        return BRadio.Tell(ply, "You can only remove songs you added.")
    end
    table.remove(st.queue, i)
    BRadio.Dirty(st)
end

C.move = function(ply, st, a)
    if not need("control", ply, st) then return end
    local i, j = tonumber(a.i), tonumber(a.to)
    local t = i and st.queue[i]
    if not t or t.key ~= a.k or not j then return end
    j = math.Clamp(j, 1, #st.queue)
    table.remove(st.queue, i)
    table.insert(st.queue, j, t)
    BRadio.Dirty(st)
    BRadio.Prefetch(st)
end

C.clear = function(ply, st)
    if not need("control", ply, st) then return end
    st.queue = {}
    BRadio.Dirty(st)
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
    BRadio.Dirty(st)
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
        BRadio.Advance(st, "play")
        return
    end
    BRadio.Dirty(st)
end

C.seek = function(ply, st, a)
    if not need("control", ply, st) then return end
    local t = tonumber(a.t)
    if not t or not st.current or st.state ~= "playing" then return end
    t = math.Clamp(t, 0, math.max(0, (st.current.duration or 0) - 1))
    st.startedAt = CurTime() + 0.3 - t
    BRadio.Dirty(st)
end

C.volume = function(ply, st, a)
    if not need("control", ply, st) then return end
    st.volume = math.Clamp(tonumber(a.v) or st.volume, 0, 1)
    BRadio.Dirty(st)
end

C.range = function(ply, st, a)
    if not need("control", ply, st) then return end
    st.range = math.Clamp(math.floor(tonumber(a.v) or st.range), BRadio.MinRange, BRadio.MaxRange)
    BRadio.Dirty(st)
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
        BRadio.Dirty(st)
    end
end

-- the owner's library: anyone who may add can queue from it
C.libadd = function(ply, st, a)
    if not need("add", ply, st) then return end
    local want = {}
    if a.all then
        for _, t in ipairs(BRadio.Library.tracks) do want[#want + 1] = t end
        for i = #want, 2, -1 do local j = math.random(i) want[i], want[j] = want[j], want[i] end
    else
        local set = {}
        for _, k in ipairs(type(a.keys) == "table" and a.keys or {}) do set[k] = true end
        for _, t in ipairs(BRadio.Library.tracks) do if set[t.key] then want[#want + 1] = t end end
    end
    local n = BRadio.Enqueue(st, ply, want, false)
    BRadio.Tell(ply, n > 0 and ("Added " .. n .. " from the library.") or "Nothing added (the queue is full?).")
end

C.libsave = function(ply, st, a)
    if not need("admin", ply, st) then return end
    local key = a.k or (st.current and st.current.key)
    if not key then return end
    R.Save(key, function(ok, res)
        if not ok then return BRadio.Tell(ply, "Couldn't save: " .. tostring(res)) end
        BRadio.RefreshLibrary(function() BRadio.SendLibrary(ply) end)
        BRadio.Tell(ply, "Saved to the library. It stays on the server and autoplay can pick it.")
    end)
end

C.libremove = function(ply, st, a)
    if not need("admin", ply, st) then return end
    R.Unsave(tostring(a.k or ""), function(ok, res)
        if not ok then return BRadio.Tell(ply, "Couldn't remove: " .. tostring(res)) end
        BRadio.RefreshLibrary(function() BRadio.SendLibrary(ply) end)
    end)
end

C.libimport = function(ply, st, a)   -- a YouTube playlist straight into the library
    if not need("admin", ply, st) then return end
    local q = string.Trim(tostring(a.q or ""))
    if q == "" then return end
    BRadio.Tell(ply, "Importing into the library (this downloads every song; it takes a while) ...")
    R.Resolve(q, function(ok, res)
        if not ok then return BRadio.Tell(ply, "Couldn't import: " .. tostring(res)) end
        local tracks = res.tracks or {}
        local i = 0
        local function nextOne()
            i = i + 1
            local t = tracks[i]
            if not t then
                BRadio.RefreshLibrary(function() if IsValid(ply) then BRadio.SendLibrary(ply) end end)
                return BRadio.Tell(ply, "Library import queued: " .. #tracks .. " songs. They show up as they finish downloading.")
            end
            R.Save(t.key, function() timer.Simple(0.2, nextOne) end)
        end
        nextOne()
    end)
end

C.librescan = function(ply, st)
    if not need("admin", ply, st) then return end
    R.Rescan(function(ok, res)
        if not ok then return BRadio.Tell(ply, "Rescan failed: " .. tostring(res)) end
        BRadio.RefreshLibrary(function() BRadio.SendLibrary(ply) end)
        BRadio.Tell(ply, "Library rescanned.")
    end)
end

C.library = function(ply, st)
    if CurTime() - (BRadio.Library.fetched or -1e9) > 30 then
        BRadio.RefreshLibrary(function() if IsValid(ply) then BRadio.SendLibrary(ply) end end)
    else
        BRadio.SendLibrary(ply)
    end
end

-- saved playlists (sv_persist stores them)
C.plsave = function(ply, st, a)
    if not need("admin", ply, st) then return end
    local name = string.Trim(string.sub(tostring(a.name or ""), 1, 60))
    if name == "" then return BRadio.Tell(ply, "Give the playlist a name.") end
    local tracks = {}
    if st.current then tracks[1] = st.current end
    for _, t in ipairs(st.queue) do tracks[#tracks + 1] = t end
    if #tracks == 0 then return BRadio.Tell(ply, "The queue is empty; add songs first.") end
    local list = {}
    for _, t in ipairs(tracks) do list[#list + 1] = { key = t.key, title = t.title, duration = t.duration } end
    BRadio.Playlists[name] = { tracks = list }
    BRadio.SavePlaylists()
    BRadio.SendLibrary(ply)
    BRadio.Tell(ply, "Saved \"" .. name .. "\" (" .. #list .. " songs).")
end

C.plload = function(ply, st, a)
    if not need("add", ply, st) then return end
    local p = BRadio.Playlists[tostring(a.name or "")]
    if not p then return BRadio.Tell(ply, "No playlist by that name.") end
    local n = BRadio.Enqueue(st, ply, p.tracks or {}, false)
    BRadio.Tell(ply, "Added " .. n .. " songs from \"" .. a.name .. "\".")
end

C.pldelete = function(ply, st, a)
    if not need("admin", ply, st) then return end
    BRadio.Playlists[tostring(a.name or "")] = nil
    BRadio.SavePlaylists()
    BRadio.SendLibrary(ply)
end

C.pin = function(ply, st, a)
    if not need("admin", ply, st) then return end
    BRadio.SetPinned(st, a.on and true or false)
    -- pinning renames the station, which closes the client's menu: reopen it
    if IsValid(st.ent) then timer.Simple(0.2, function() if IsValid(ply) and IsValid(st.ent) then BRadio.OpenMenu(ply, st.ent) end end) end
    BRadio.Tell(ply, a.on and "Pinned: this radio comes back here after every round and restart, still playing."
        or "Unpinned: this radio goes away with the next cleanup.")
end

-- ------------------------------------------------------------- net
local rate = {}
net.Receive(NET.Cmd, function(_, ply)
    local sid = BRadio.SteamID(ply)
    local now = CurTime()
    local len = net.ReadUInt(32)
    if len <= 0 or len > 16384 then return end
    local a = util.JSONToTable(util.Decompress(net.ReadData(len)) or "")
    if type(a) ~= "table" then return end
    -- sliders (volume, range, seek) send ~10 a second while dragged: their own,
    -- roomier bucket, so a drag is never cut off and never starves the buttons
    local bucket = (a.op == "volume" or a.op == "range" or a.op == "seek") and "slide" or "cmd"
    rate[sid] = rate[sid] or {}
    local r = rate[sid][bucket] or { t = now, n = 0 }
    if now - r.t > 2 then r.t, r.n = now, 0 end
    r.n = r.n + 1
    rate[sid][bucket] = r
    if r.n > (bucket == "slide" and 40 or 12) then return end
    local st = S[tostring(a.id or "")]
    local fn = C[tostring(a.op or "")]
    if not st or not fn then return end
    -- you have to be near the radio (or an admin) to work it
    if not BRadio.IsAdmin(ply) and IsValid(st.ent) and ply:GetPos():Distance(st.ent:GetPos()) > 400 then
        return BRadio.Tell(ply, "Walk over to the radio to use it.")
    end
    if a.op == "add" then
        local rr = rate[sid]
        if rr.lastAdd and now - rr.lastAdd < 2 then return BRadio.Tell(ply, "Slow down a little.") end
        rr.lastAdd = now
    end
    fn(ply, st, a)
end)

net.Receive(NET.Hello, function(_, ply)
    if ply.bradioHello then return end
    ply.bradioHello = true
    for _, st in pairs(S) do BRadio.SendState(st, ply) end
end)

function BRadio.OpenMenu(ply, ent)
    local st = BRadio.StationOf(ent)
    if not st then return end
    BRadio.SendState(st, ply)
    net.Start(NET.Open)
    net.WriteString(st.id)
    net.WriteBool(BRadio.CanControl(ply, st))
    net.WriteBool(BRadio.IsAdmin(ply))
    net.WriteBool(BRadio.CanAdd(ply, st))
    net.Send(ply)
    C.library(ply, st)
end

-- ------------------------------------------------------------- spawning
hook.Add("PlayerSpawnSENT", "bradio_limit", function(ply, class)
    if class ~= BRadio.Class then return end
    if BRadio.IsAdmin(ply) then return end
    if cvSpawn:GetInt() == 1 then
        BRadio.Tell(ply, "Only admins can spawn radios here.")
        return false
    end
    local sid, n = BRadio.SteamID(ply), 0
    for _, st in pairs(S) do if st.owner == sid and not st.permanent and IsValid(st.ent) then n = n + 1 end end
    if n >= cvPerPlayer:GetInt() then
        BRadio.Tell(ply, "You already have " .. n .. " radio" .. (n == 1 and "" or "s") .. " out.")
        return false
    end
end)

-- an entity left: its station goes too, unless it is pinned (then TTT's
-- round cleanup is what removed it, and PostCleanupMap puts it back)
function BRadio.EntityRemoved(ent)
    local st = S[ent:GetStationId()]
    if not st or st.ent ~= ent then return end
    if st.permanent then st.pos, st.ang = ent:GetPos(), ent:GetAngles() end
    st.ent = nil
    -- a pinned radio outlives its entity: the round cleanup, a map change and
    -- a stray remover all bring it back. The menu's "Remove radio" deletes it.
    if st.permanent then return end
    BRadio.RemoveStation(st)
end

C.delete = function(ply, st)
    if not need("control", ply, st) then return end
    if st.permanent then BRadio.SetPinned(st, false) end
    local ent = st.ent
    BRadio.RemoveStation(st)
    if st.permanent == false then BRadio.SavePinned() end
    if IsValid(ent) then ent:Remove() end
end

-- admins console: spawn a radio where you look (for TTT, which has no spawn menu)
concommand.Add("bradio_place", function(ply, _, args)
    if not BRadio.IsAdmin(ply) or not IsValid(ply) then return end
    local tr = ply:GetEyeTrace()
    -- created unpinned, then pinned: SetPinned gives it the stable p<n> id the map file keys on
    local ent = BRadio.SpawnRadio(tr.HitPos + tr.HitNormal * 2, Angle(0, ply:EyeAngles().y + 180, 0), nil, {})
    if args[1] ~= "0" then BRadio.SetPinned(BRadio.StationOf(ent), true) end
    BRadio.Tell(ply, args[1] ~= "0" and "Placed a pinned radio. Press E on it to load music." or "Placed a radio.")
end)

-- spawn an entity for a station (new or existing)
function BRadio.SpawnRadio(pos, ang, st, opts)
    st = st or BRadio.NewStation(opts)
    local ent = ents.Create(BRadio.Class)
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
    BRadio.Dirty(st)
    return ent, st
end

concommand.Add("bradio_status", function(ply)
    if IsValid(ply) and not BRadio.IsAdmin(ply) then return end
    local out = {}
    for id, st in pairs(S) do
        out[#out + 1] = string.format("%s %s%s %s q=%d %s", id, st.state, st.permanent and " pinned" or "",
            st.current and ("\"" .. st.current.title .. "\" " .. BRadio.FormatTime(BRadio.Position(st)) .. "/" .. BRadio.FormatTime(st.current.duration)) or "-",
            #st.queue, IsValid(st.ent) and tostring(st.ent:GetPos()) or "no entity")
    end
    out[#out + 1] = "library: " .. #BRadio.Library.tracks .. " tracks" .. (R.Problem and ("; relay problem: " .. R.Problem) or "")
    local text = table.concat(out, "\n")
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, text) else print(text) end
end)

-- console / rcon: queue something on every radio, or one (bradio_play <query> [stationId])
concommand.Add("bradio_play", function(ply, _, args)
    if IsValid(ply) and not BRadio.IsAdmin(ply) then return end
    local q, id = args[1], args[2]
    for sid, st in pairs(S) do
        if not id or id == sid then BRadio.AddQuery(st, ply, q, false) end
    end
end)
