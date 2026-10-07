-- The radio's server side, offline: queueing, the clock, skip/remove rules, the
-- library, pinned radios across TTT cleanups and restarts. Run: tests/run.sh
local shim = dofile("tests/shim.lua")
local V = shim.Vector

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1 io.write("  ok   ", name, "\n")
    else fail = fail + 1 io.write("  FAIL ", name, "\n       ", tostring(err), "\n") end
end
local function eq(a, b, what)
    if a ~= b then error((what or "value") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function truthy(v, what) if not v then error((what or "condition") .. " was false", 2) end end

local function track(id, title, dur) return { key = "yt-" .. id, title = title, duration = dur or 200, ready = false } end

-- a booted server with one radio spawned by `owner`
local function world(opts)
    opts = opts or {}
    local W = shim.new()
    W.relay.resolve["song a"] = { title = "A", tracks = { track("aaaaaaaaaaa", "Song A", 180) } }
    W.relay.resolve["song b"] = { title = "B", tracks = { track("bbbbbbbbbbb", "Song B", 120) } }
    W.relay.resolve["song c"] = { title = "C", tracks = { track("ccccccccccc", "Song C", 90) } }
    W.relay.resolve["playlist"] = { title = "Mix", tracks = {
        track("p1p1p1p1p1p", "P1", 100), track("p2p2p2p2p2p", "P2", 100), track("p3p3p3p3p3p", "P3", 100) } }
    W:boot()
    W.owner = W:player("owner")
    W.guest = W:player("guest", { pos = V(50, 0, 0) })
    W.admin = W:player("admin", { admin = true, pos = V(9000, 0, 0) })
    if not opts.noRadio then
        local ent, st = BRadio.SpawnRadio(V(0, 0, 0), shim.Angle(), nil, { owner = W.owner })
        W.ent, W.st = ent, st
        W.id = st.id
    end
    W:advance(0.1)
    return W
end

local function state(W) return BRadio.Stations[W.id] end

test("adding a link plays it after the relay has it", function()
    local W = world()
    W.relay.fetch["yt-aaaaaaaaaaa"] = { { state = "loading" }, { state = "loading" }, { state = "ready", duration = 181 } }
    W:cmd(W.guest, "add", { id = W.id, q = "song a" })
    W:advance(0.1)
    eq(state(W).state, "loading", "state while downloading")
    eq(state(W).current.title, "Song A")
    W:advance(5)
    eq(state(W).state, "playing")
    eq(state(W).current.duration, 181, "duration from the relay")
    eq(state(W).current.by, "guest")
    truthy(state(W).startedAt > W.now, "start is announced ahead (lead time)")
    truthy(W:lastNotice(W.guest):find("Added \"Song A\"", 1, true), "told the guest")
end)

test("songs play in order and the clock moves the queue on", function()
    local W = world()
    W:cmd(W.guest, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.guest, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    eq(state(W).current.key, "yt-aaaaaaaaaaa")
    eq(#state(W).queue, 1)
    W:advance(200 + 3)
    eq(state(W).current.key, "yt-bbbbbbbbbbb", "moved to B when A ran out")
    W:advance(200 + 3)
    eq(state(W).state, "idle", "nothing left, library empty")
end)

test("a playlist link queues every song; the next ones are prefetched", function()
    local W = world()
    W:cmd(W.guest, "add", { id = W.id, q = "playlist" }) W:advance(3)
    eq(state(W).current.key, "yt-p1p1p1p1p1p")
    eq(#state(W).queue, 2)
    local fetched = {}
    for _, u in ipairs(W.httpLog) do local k = u:match("fetch%?key=(.+)$") if k then fetched[k] = true end end
    truthy(fetched["yt-p2p2p2p2p2p"] and fetched["yt-p3p3p3p3p3p"], "P2 and P3 warmed in the relay")
end)

test("a guest cannot skip someone else's song directly; enough votes do", function()
    local W = world()
    W.st.range = 1000
    local g2 = W:player("guest2", { pos = V(10, 0, 0) })
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.owner, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    -- in earshot: owner, guest, guest2 (admin is 9000 away) -> needs ceil(3*0.5) = 2
    W:cmd(W.guest, "skip", { id = W.id }) W:advance(0.1)
    eq(state(W).current.key, "yt-aaaaaaaaaaa", "one vote is not enough")
    truthy(W:lastNotice(W.guest):find("1/2", 1, true), "told the vote count")
    W:advance(2.1)
    W:cmd(g2, "skip", { id = W.id }) W:advance(2.5)
    eq(state(W).current.key, "yt-bbbbbbbbbbb", "two votes skip")
end)

test("the owner and admins skip at once; so does whoever added the song", function()
    local W = world()
    W:cmd(W.guest, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.guest, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    W:cmd(W.guest, "add", { id = W.id, q = "song c" }) W:advance(2.1)
    W:cmd(W.guest, "skip", { id = W.id }) W:advance(2.1)
    eq(state(W).current.key, "yt-bbbbbbbbbbb", "the guest skips their own song")
    W:cmd(W.owner, "skip", { id = W.id }) W:advance(2.1)
    eq(state(W).current.key, "yt-ccccccccccc", "the owner skips")
end)

test("remove: your own songs, or any if you run the radio", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.owner, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    W:cmd(W.guest, "add", { id = W.id, q = "song c" }) W:advance(2.1)
    eq(#state(W).queue, 2)
    W:cmd(W.guest, "remove", { id = W.id, i = 1, k = "yt-bbbbbbbbbbb" }) W:advance(0.1)
    eq(#state(W).queue, 2, "guest may not remove the owner's song")
    W:cmd(W.guest, "remove", { id = W.id, i = 2, k = "yt-ccccccccccc" }) W:advance(0.1)
    eq(#state(W).queue, 1, "guest removes their own")
    W:cmd(W.owner, "add", { id = W.id, q = "song c" }) W:advance(2.1)
    W:cmd(W.owner, "remove", { id = W.id, i = 2, k = "wrong-key" }) W:advance(0.1)
    eq(#state(W).queue, 2, "a stale index/key pair is refused")
    W:cmd(W.owner, "remove", { id = W.id, i = 1, k = "yt-bbbbbbbbbbb" }) W:advance(0.1)
    eq(#state(W).queue, 1)
    eq(state(W).queue[1].key, "yt-ccccccccccc")
end)

test("pause holds the position and resume carries on from it", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:advance(30)
    local pos = BRadio.Position(state(W))
    W:cmd(W.guest, "pause", { id = W.id }) W:advance(0.1)
    eq(state(W).state, "playing", "a guest cannot pause")
    W:cmd(W.owner, "pause", { id = W.id })
    eq(state(W).state, "paused")
    W:advance(500)
    eq(state(W).state, "paused", "the song did not run out while paused")
    W:cmd(W.owner, "pause", { id = W.id })
    eq(state(W).state, "playing")
    truthy(math.abs(BRadio.Position(state(W)) - pos) < 1.5, "resumed where it was")
end)

test("loop puts finished songs back at the end", function()
    local W = world()
    W:cmd(W.owner, "loop", { id = W.id, on = true })
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.owner, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    W:advance(203)
    eq(state(W).current.key, "yt-bbbbbbbbbbb")
    eq(state(W).queue[1].key, "yt-aaaaaaaaaaa", "A went back in")
end)

test("autoplay picks from the owner's library when the queue is empty", function()
    local W = world()
    W.relay.library = { tracks = { { key = "lib-0123456789ab", title = "Owner Song", duration = 150, album = "" } } }
    BRadio.RefreshLibrary() W:advance(0.1)
    W:advance(7)
    eq(state(W).state, "playing")
    eq(state(W).current.key, "lib-0123456789ab")
    eq(state(W).current.by, "Library")
end)

test("a song that fails to download is skipped and the adder is told", function()
    local W = world()
    W.relay.fetch["yt-aaaaaaaaaaa"] = { { state = "error", error = "Video unavailable" } }
    W:cmd(W.guest, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.guest, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    eq(state(W).current.key, "yt-bbbbbbbbbbb")
    local found = false
    for _, n in ipairs(W:notices(W.guest)) do if n:find("Video unavailable", 1, true) then found = true end end
    truthy(found, "the guest heard why")
end)

test("bradio_add 1 keeps strangers from queueing", function()
    local W = world()
    W.cvars.bradio_add = "1"
    W:cmd(W.guest, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    eq(state(W).state, "idle")
    truthy(W:lastNotice(W.guest):find("Only owner", 1, true))
end)

test("a guest's share of the queue is capped", function()
    local W = world()
    W.cvars.bradio_user_tracks = "2"
    W:cmd(W.guest, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.guest, "add", { id = W.id, q = "playlist" }) W:advance(2.1)
    eq(#state(W).queue, 2, "A plays, two of the playlist queue, one doesn't fit")
    truthy(W:lastNotice(W.guest):find("didn't fit", 1, true))
end)

test("players far away (not admins) cannot work the radio", function()
    local W = world()
    local far = W:player("far", { pos = V(5000, 0, 0) })
    W:cmd(far, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    eq(state(W).state, "idle")
    W:cmd(W.admin, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    eq(state(W).state, "playing", "an admin can from anywhere")
end)

test("unpinned radios go with the round cleanup; pinned ones come back mid-song", function()
    local W = world()
    local _, st2 = BRadio.SpawnRadio(V(100, 0, 0), shim.Angle(), nil, { owner = W.owner })
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.admin, "pin", { id = W.id, on = true }) W:advance(0.5)
    local st = BRadio.StationOf(W.ent)
    truthy(st.permanent, "pinned")
    eq(st.id, "p1", "pinned radios get a stable id")
    eq(W.ent.phys.motion, false, "frozen")
    W:advance(40)
    local before = BRadio.Position(st)
    W:cleanup()
    truthy(BRadio.Stations["p1"], "pinned station survived")
    truthy(IsValid(BRadio.Stations["p1"].ent), "and got a new entity")
    truthy(BRadio.Stations["p1"].ent ~= W.ent, "a new one")
    eq(BRadio.Stations["p1"].state, "playing")
    truthy(math.abs(BRadio.Position(BRadio.Stations["p1"]) - before) < 0.01, "same place in the song")
    eq(BRadio.Stations[st2.id], nil, "the unpinned radio went away")
end)

test("pinned radios and their queue survive a restart", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.owner, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    W:cmd(W.admin, "pin", { id = W.id, on = true }) W:advance(0.5)
    W:cmd(W.admin, "volume", { id = "p1", v = 0.33 }) W:advance(0.1)
    W:advance(60)
    W:run("ShutDown")
    local saved = W.data["burrito_radio/maps/gm_test.json"]
    truthy(saved and saved:find("Song B", 1, true), "queue written to data/")
    -- a new server process on the same data folder
    local W2 = shim.new()
    W2.data = W.data
    W2:boot()
    W2:player("someone")
    W2:advance(5)
    local st = BRadio.Stations["p1"]
    truthy(st, "the pinned radio is back")
    eq(st.volume, 0.33)
    eq(st.current.key, "yt-aaaaaaaaaaa", "the song it was on")
    truthy(BRadio.Position(st) > 55, "from about where it was (" .. BRadio.Position(st) .. ")")
    eq(#st.queue, 1)
end)

test("removing a pinned radio from the menu deletes it for good", function()
    local W = world()
    W:cmd(W.admin, "pin", { id = W.id, on = true }) W:advance(0.5)
    W:cmd(W.admin, "delete", { id = "p1" }) W:advance(0.1)
    eq(BRadio.Stations["p1"], nil)
    W:run("ShutDown")
    truthy(not W.data["burrito_radio/maps/gm_test.json"]:find("p1", 1, true), "not in the file")
end)

test("a stray remover on a pinned radio does not lose it", function()
    local W = world()
    W:cmd(W.admin, "pin", { id = W.id, on = true }) W:advance(0.5)
    W.ent:Remove()
    truthy(BRadio.Stations["p1"], "still a station")
    W:cleanup()
    truthy(IsValid(BRadio.Stations["p1"].ent), "back after the next cleanup")
end)

test("saved playlists: an admin saves the queue, anyone loads it", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "playlist" }) W:advance(3)
    W:cmd(W.guest, "plsave", { id = W.id, name = "Mine" }) W:advance(0.1)
    eq(BRadio.Playlists["Mine"], nil, "guests can't save")
    W:cmd(W.admin, "plsave", { id = W.id, name = "Party" }) W:advance(0.1)
    eq(#BRadio.Playlists["Party"].tracks, 3)
    W:cmd(W.owner, "clear", { id = W.id }) W:advance(0.1)
    W:cmd(W.guest, "plload", { id = W.id, name = "Party" }) W:advance(2.1)
    eq(#state(W).queue, 3)
    truthy(W.data["burrito_radio/playlists.json"]:find("Party", 1, true), "written to data/")
end)

test("library: save the playing song, import a playlist (admins only)", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.guest, "libsave", { id = W.id }) W:advance(0.1)
    eq(W.relay.saved["yt-aaaaaaaaaaa"], nil, "guest refused")
    W:cmd(W.admin, "libsave", { id = W.id }) W:advance(0.1)
    eq(W.relay.saved["yt-aaaaaaaaaaa"], true)
    W:cmd(W.admin, "libimport", { id = W.id, q = "playlist" }) W:advance(3)
    truthy(W.relay.saved["yt-p1p1p1p1p1p"] and W.relay.saved["yt-p3p3p3p3p3p"], "every playlist song saved")
end)

test("the relay being down is reported, not fatal", function()
    local W = world()
    W.relay.down = true
    W:cmd(W.guest, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    truthy(W:lastNotice(W.guest):find("not answering", 1, true))
    truthy(BRadio.Relay.Problem and BRadio.Relay.Problem:find("can't reach", 1, true))
end)

test("the state sent to clients carries the queue and the public URL", function()
    local W = world()
    W:cmd(W.guest, "add", { id = W.id, q = "playlist" }) W:advance(3)
    local last
    for _, m in ipairs(W.sent) do if m.name == "bradio_state" then last = m end end
    local t = shim.decode(last.fields[2])
    eq(t.id, W.id)
    eq(t.cur.k, "yt-p1p1p1p1p1p")
    eq(#t.q, 2)
    eq(t.base, "https://www.naliwajka.com/radio")
    eq(BRadio.TrackURL(t.base, t.cur.k), "https://www.naliwajka.com/radio/a/yt-p1p1p1p1p1p.mp3")
end)

test("spawn limit: one radio per player unless admin", function()
    local W = world()
    eq(W:run("PlayerSpawnSENT", W.owner, "burrito_radio"), false, "owner already has one")
    eq(W:run("PlayerSpawnSENT", W.guest, "burrito_radio"), nil, "guest may")
    eq(W:run("PlayerSpawnSENT", W.admin, "burrito_radio"), nil, "admins always may")
end)

test("the model builds and its bounds fit the case", function()
    local parts = BRadio.Model.Build()
    local n = 0
    for _, tris in pairs(parts) do n = n + #tris end
    truthy(n > 500, "triangles: " .. n)
    local mn, mx = BRadio.Model.Bounds()
    truthy(mx[2] - mn[2] > 12 and mx[2] - mn[2] < 14, "about 13 units wide at scale 2.5")
end)

test("directivity: loud in front of the grille, soft behind, relaxed up close", function()
    local D = BRadio.Directivity
    local front = D(1, 0, 0, 1, 0, 0, 1000)
    local side = D(1, 0, 0, 0, 1, 0, 1000)
    local back = D(1, 0, 0, -1, 0, 0, 1000)
    eq(front, 1, "front")
    truthy(side > 0.5 and side < 0.65, "side ~0.58: " .. side)
    eq(back, BRadio.BackGain, "behind")
    truthy(D(1, 0, 0, -1, 0, 0, 20) == 1, "standing on it: no direction")
    local mid = D(1, 0, 0, -1, 0, 0, 140)
    truthy(mid > back and mid < 1, "fades in between: " .. mid)
    local diag = D(1, 0, 0, 0.7071, 0.7071, 0, 1000)
    truthy(diag > side and diag < front, "45 degrees between front and side")
end)

test("dragging the volume: every step lands, and the buttons still work", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    for i = 1, 20 do W:cmd(W.owner, "volume", { id = W.id, v = i / 20 }) W:advance(0.1) end
    eq(state(W).volume, 1, "the last value of a 2-second drag")
    local sent = 0
    for _, m in ipairs(W.sent) do if m.name == "bradio_state" then sent = sent + 1 end end
    truthy(sent >= 20, "every step went out to the players (" .. sent .. ")")
    W:cmd(W.owner, "pause", { id = W.id })
    eq(state(W).state, "paused", "a button right after the drag is not rate-limited")
end)

test("falloff: real-sound drop close up, faint far away, silent past the range", function()
    local F = BRadio.Falloff
    eq(F(50, 3000), 1, "standing at it")
    local r1, r2 = F(220, 3000), F(440, 3000)
    truthy(r1 < 0.65, "a few steps away is clearly quieter (" .. r1 .. ")")
    truthy(math.abs(r2 / r1 - 0.574) < 0.01, "twice as far: ~0.57x")
    local far = F(1700, 3000)
    truthy(far > 0.05 and far < 0.2, "still faintly there across the map (" .. far .. ")")
    truthy(F(2900, 3000) < F(1700, 3000) * 0.2, "fading out near the edge")
    eq(F(3000, 3000), 0)
    eq(F(5000, 3000), 0)
    truthy(F(6000, 12000) > 0, "a bigger range carries further")
end)

test("pan: left/right from your view, centred up close, softer behind you", function()
    -- you look along +X, your right is -Y
    local p, g = BRadio.Pan(0, -1, 0, 1, 0, 0, 0, -1, 0, 500)
    truthy(p > 0.9 and g == 1, "radio on your right")
    p = BRadio.Pan(0, -1, 0, 1, 0, 0, 0, 1, 0, 500)
    truthy(p < -0.9, "on your left")
    p, g = BRadio.Pan(0, -1, 0, 1, 0, 0, -1, 0, 0, 500)
    truthy(math.abs(p) < 1e-9 and g < 0.9, "behind you")
    p = BRadio.Pan(0, -1, 0, 1, 0, 0, 0, -1, 0, 5)
    eq(p, 0, "standing on it")
end)

test("per-box settings come from cfg/burrito_radio.cfg", function()
    local W = world({ noRadio = true })
    W.data["cfg/burrito_radio.cfg"] = '// comment\nbradio_relay_url "http://10.9.1.13:8090/radio"\nbradio_relay_key abc123\nsv_cheats 1\n'
    eq(BRadio.LoadLocalCfg(), 2)
    eq(W.cvars.bradio_relay_url, "http://10.9.1.13:8090/radio")
    eq(W.cvars.bradio_relay_key, "abc123")
    eq(W.cvars.sv_cheats, nil, "only the radio's own convars")
end)

-- ------------------------------------------------------------------ queue controls
local function queued(W) local out = {} for i, t in ipairs(state(W).queue) do out[i] = t.key end return table.concat(out, ",") end

test("play next: controllers jump the queue, guests' 'next' is just an add", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.owner, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    W:cmd(W.owner, "add", { id = W.id, q = "song c", next = true }) W:advance(2.1)
    eq(queued(W), "yt-ccccccccccc,yt-bbbbbbbbbbb", "C jumped ahead of B")
    W:cmd(W.guest, "add", { id = W.id, q = "playlist", next = true }) W:advance(2.1)
    eq(state(W).queue[1].key, "yt-ccccccccccc", "a guest's 'next' went to the end")
end)

test("move to top (controllers only)", function()
    local W = world()
    for _, q in ipairs({ "song a", "song b", "song c" }) do W:cmd(W.owner, "add", { id = W.id, q = q }) W:advance(2.1) end
    W:cmd(W.guest, "move", { id = W.id, i = 2, k = "yt-ccccccccccc", to = 1 }) W:advance(0.1)
    eq(queued(W), "yt-bbbbbbbbbbb,yt-ccccccccccc", "guest refused")
    W:cmd(W.owner, "move", { id = W.id, i = 2, k = "yt-ccccccccccc", to = 1 }) W:advance(0.1)
    eq(queued(W), "yt-ccccccccccc,yt-bbbbbbbbbbb")
end)

test("clear empties the queue but the song plays on; stop ends it and autoplay waits", function()
    local W = world()
    W.relay.library = { tracks = { { key = "lib-0123456789ab", title = "Owner Song", duration = 150, album = "" } } }
    BRadio.RefreshLibrary() W:advance(0.1)
    W:cmd(W.owner, "add", { id = W.id, q = "playlist" }) W:advance(3)
    W:cmd(W.guest, "clear", { id = W.id }) W:advance(0.1)
    eq(#state(W).queue, 2, "guest cannot clear")
    W:cmd(W.owner, "clear", { id = W.id }) W:advance(0.1)
    eq(#state(W).queue, 0)
    eq(state(W).state, "playing", "the current song carries on")
    W:cmd(W.owner, "stop", { id = W.id }) W:advance(30)
    eq(state(W).state, "idle")
    eq(state(W).current, nil)
    W:advance(60)
    eq(state(W).state, "idle", "autoplay does not restart a stopped radio")
    W:cmd(W.owner, "pause", { id = W.id }) W:advance(2.1)
    eq(state(W).state, "playing", "Play on an idle radio starts the library again")
end)

test("seek moves everyone to the same place, clamped to the song", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.guest, "seek", { id = W.id, t = 100 }) W:advance(0.1)
    truthy(BRadio.Position(state(W)) < 5, "guest cannot seek")
    W:cmd(W.owner, "seek", { id = W.id, t = 100 }) W:advance(0.5)
    truthy(math.abs(BRadio.Position(state(W)) - 100) < 1, "at 100s")
    W:cmd(W.owner, "seek", { id = W.id, t = 99999 }) W:advance(0.5)
    truthy(BRadio.Position(state(W)) <= 200, "clamped before the end")
end)

test("range and volume are clamped and controller-only", function()
    local W = world()
    W:cmd(W.guest, "range", { id = W.id, v = 9000 }) W:advance(0.1)
    eq(state(W).range, BRadio.DefaultRange, "guest refused")
    W:cmd(W.owner, "range", { id = W.id, v = 50 }) W:advance(0.1)
    eq(state(W).range, BRadio.MinRange)
    W:cmd(W.owner, "range", { id = W.id, v = 1e9 }) W:advance(0.1)
    eq(state(W).range, BRadio.MaxRange)
    W:cmd(W.owner, "volume", { id = W.id, v = 7 }) W:advance(0.1)
    eq(state(W).volume, 1)
    W:cmd(W.guest, "volume", { id = W.id, v = 0 }) W:advance(0.1)
    eq(state(W).volume, 1, "guest refused")
end)

test("shuffle reorders the queue; new songs land at random places", function()
    local W = world()
    W.relay.resolve["big"] = { title = "Big", tracks = {} }
    for i = 1, 12 do W.relay.resolve["big"].tracks[i] = track(string.format("s%010d", i), "S" .. i, 100) end
    W:cmd(W.owner, "add", { id = W.id, q = "big" }) W:advance(3)
    local before = queued(W)
    W:cmd(W.owner, "shuffle", { id = W.id, on = true }) W:advance(0.1)
    truthy(state(W).shuffle)
    truthy(queued(W) ~= before, "order changed")
    eq(#state(W).queue, 11, "nothing lost")
    W:cmd(W.guest, "shuffle", { id = W.id, on = false }) W:advance(0.1)
    truthy(state(W).shuffle, "guest cannot toggle")
end)

test("autoplay off: an empty queue stays quiet", function()
    local W = world()
    W.relay.library = { tracks = { { key = "lib-0123456789ab", title = "Owner Song", duration = 150, album = "" } } }
    BRadio.RefreshLibrary() W:advance(0.1)
    W:cmd(W.owner, "autoplay", { id = W.id, on = false }) W:advance(30)
    eq(state(W).state, "idle")
end)

test("autoplay does not repeat a library song while others are unplayed", function()
    local W = world()
    local lib = {}
    for i = 1, 5 do
        lib[i] = { key = string.format("lib-%012d", i), title = "L" .. i, duration = 10, album = "" }
        W.relay.fetch[lib[i].key] = { { state = "ready", duration = 10 } }
    end
    W.relay.library = { tracks = lib }
    BRadio.RefreshLibrary() W:advance(0.1)
    W:advance(120)
    local h = state(W).history
    truthy(#h >= 6, "played several (" .. #h .. ")")
    local seen = {}
    for i = 1, 5 do
        truthy(not seen[h[i]], "repeat of " .. tostring(h[i]) .. " before the other four played")
        seen[h[i]] = true
    end
end)

test("the queue has a hard cap, even for admins", function()
    local W = world()
    W.cvars.bradio_max_queue = "4"
    W:cmd(W.admin, "add", { id = W.id, q = "playlist" }) W:advance(3)
    W:cmd(W.admin, "add", { id = W.id, q = "playlist" }) W:advance(3)
    eq(#state(W).queue, 4)
end)

-- ------------------------------------------------------------------ library
test("library: queue selected or all of it; admins remove and rescan", function()
    local W = world()
    local lib = {}
    for i = 1, 4 do lib[i] = { key = string.format("lib-%012d", i), title = "L" .. i, duration = 100, album = "A" } end
    W.relay.library = { tracks = lib }
    BRadio.RefreshLibrary() W:advance(0.1)
    W:cmd(W.owner, "autoplay", { id = W.id, on = false }) W:advance(0.1)
    W:cmd(W.guest, "libadd", { id = W.id, keys = { "lib-000000000002", "not-in-library" } }) W:advance(2.1)
    eq(state(W).current.key, "lib-000000000002", "only real library keys")
    eq(#state(W).queue, 0)
    W:cmd(W.guest, "libadd", { id = W.id, all = true }) W:advance(0.1)
    eq(#state(W).queue, 4, "all of it")
    W:cmd(W.guest, "libremove", { id = W.id, k = "lib-000000000001" }) W:advance(0.1)
    W:cmd(W.guest, "librescan", { id = W.id }) W:advance(0.1)
    local rescans = 0
    for _, u in ipairs(W.httpLog) do if u:find("/library/remove", 1, true) or u:find("/library/rescan", 1, true) then rescans = rescans + 1 end end
    eq(rescans, 0, "guests reach neither")
    W:cmd(W.admin, "libremove", { id = W.id, k = "yt-aaaaaaaaaaa" }) W:advance(0.1)
    W:cmd(W.admin, "librescan", { id = W.id }) W:advance(0.1)
    local hits = 0
    for _, u in ipairs(W.httpLog) do if u:find("/library/remove", 1, true) or u:find("/library/rescan", 1, true) then hits = hits + 1 end end
    eq(hits, 2, "admin reached both")
end)

test("saved playlists: only admins delete", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "playlist" }) W:advance(3)
    W:cmd(W.admin, "plsave", { id = W.id, name = "Keep" }) W:advance(0.1)
    W:cmd(W.guest, "pldelete", { id = W.id, name = "Keep" }) W:advance(0.1)
    truthy(BRadio.Playlists.Keep, "guest refused")
    W:cmd(W.admin, "pldelete", { id = W.id, name = "Keep" }) W:advance(0.1)
    eq(BRadio.Playlists.Keep, nil)
end)

-- ------------------------------------------------------------------ pinned radios
test("pinned radios: only admins physgun, tool, edit or gravgun them; drops save the spot", function()
    local W = world()
    W:cmd(W.admin, "pin", { id = W.id, on = true }) W:advance(0.5)
    local ent = BRadio.Stations.p1.ent
    ent.GetClass = function() return "burrito_radio" end
    for _, h in ipairs({ "PhysgunPickup", "GravGunPickupAllowed" }) do
        eq(W:run(h, W.owner, ent), false, h .. " refused for the old owner")
        eq(W:run(h, W.admin, ent), nil, h .. " allowed for admins")
    end
    eq(W:run("CanTool", W.guest, { Entity = ent }), false)
    eq(W:run("CanProperty", W.guest, "remover", ent), false)
    ent:SetPos(V(321, 0, 0))
    W:run("PhysgunDrop", W.admin, ent)
    eq(ent.phys.motion, false, "frozen again")
    truthy(W.data["burrito_radio/maps/gm_test.json"]:find("321", 1, true), "new spot saved")
end)

test("an unpinned radio's station goes when its entity is removed", function()
    local W = world()
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W.ent:Remove()
    eq(BRadio.Stations[W.id], nil)
    local gone = W:sentTo("all", "bradio_gone")
    truthy(#gone > 0 and gone[#gone].fields[1] == W.id, "players told it is gone")
end)

test("the delete command: owner removes their own radio, a guest cannot", function()
    local W = world()
    W:cmd(W.guest, "delete", { id = W.id }) W:advance(0.1)
    truthy(BRadio.Stations[W.id], "guest refused")
    W:cmd(W.owner, "delete", { id = W.id }) W:advance(0.1)
    eq(BRadio.Stations[W.id], nil)
    truthy(W.ent.removed)
end)

-- ------------------------------------------------------------------ spawning + console
test("bradio_spawn 1: only admins spawn radios", function()
    local W = world({ noRadio = true })
    W.cvars.bradio_spawn = "1"
    eq(W:run("PlayerSpawnSENT", W.guest, "burrito_radio"), false)
    eq(W:run("PlayerSpawnSENT", W.admin, "burrito_radio"), nil)
    eq(W:run("PlayerSpawnSENT", W.guest, "prop_physics"), nil, "other classes untouched")
end)

test("bradio_place: admins place a pinned radio where they look", function()
    local W = world({ noRadio = true })
    W.cmds.bradio_place(W.guest, "bradio_place", {})
    eq(next(BRadio.Stations), nil, "guest refused")
    W.cmds.bradio_place(W.admin, "bradio_place", {})
    local st = BRadio.Stations.p1
    truthy(st and st.permanent and IsValid(st.ent), "pinned radio placed")
    eq(st.ent:GetPos().x, 200, "at the eye trace")
    W.cmds.bradio_place(W.admin, "bradio_place", { "0" })
    local plain = 0
    for _, s in pairs(BRadio.Stations) do if not s.permanent then plain = plain + 1 end end
    eq(plain, 1, "'bradio_place 0' places an unpinned one")
end)

test("bradio_play and bradio_status from the console", function()
    local W = world()
    W.cmds.bradio_play(nil, "bradio_play", { "song a" }) W:advance(2.1)
    eq(state(W).current.key, "yt-aaaaaaaaaaa")
    W.cmds.bradio_play(W.guest, "bradio_play", { "song b" }) W:advance(2.1)
    eq(#state(W).queue, 0, "guests cannot use the console command")
    W.cmds.bradio_status(nil)
    local found = false
    for _, l in ipairs(W.printed) do if l:find("Song A", 1, true) and l:find("playing", 1, true) then found = true end end
    truthy(found, "status lists the playing song")
    W.cmds.bradio_status(W.admin)
    truthy(W.admin.console and W.admin.console:find("Song A", 1, true), "admins get it in their console")
end)

-- ------------------------------------------------------------------ net + robustness
test("a player joining gets every radio's state once", function()
    local W = world()
    local _, st2 = BRadio.SpawnRadio(V(100, 0, 0), shim.Angle(), nil, {})
    local late = W:player("late")
    W.sent = {}
    W.net["bradio_hello"](0, late)
    W.net["bradio_hello"](0, late)
    local got = W:sentTo(late, "bradio_state")
    eq(#got, 2, "two radios, sent once")
end)

test("pressing E opens the menu with that player's permissions and the library", function()
    local W = world()
    W.sent = {}
    BRadio.OpenMenu(W.guest, W.ent) W:advance(0.1)
    local open = W:sentTo(W.guest, "bradio_open")[1]
    truthy(open, "opened")
    eq(open.fields[1], W.id)
    eq(open.fields[2], false, "guest: no control")
    eq(open.fields[3], false, "guest: not admin")
    eq(open.fields[4], true, "guest: may add")
    truthy(#W:sentTo(W.guest, "bradio_lib") > 0, "library sent")
    W.sent = {}
    BRadio.OpenMenu(W.owner, W.ent)
    eq(W:sentTo(W.owner, "bradio_open")[1].fields[2], true, "owner controls")
end)

test("malformed or hostile commands are ignored", function()
    local W = world()
    W:raw(W.guest, "not json at all")
    W:raw(W.guest, "")
    W:cmd(W.guest, "nonexistent_op", { id = W.id })
    W:cmd(W.guest, "add", { id = "no-such-radio", q = "song a" })
    W:cmd(W.guest, "remove", { id = W.id, i = "x", k = 5 })
    W:cmd(W.guest, "add", { id = W.id, q = string.rep("a", 5000) }) W:advance(2.1)
    eq(state(W).state, "idle", "nothing happened")
end)

test("spam: adds are spaced out and a command flood is cut off", function()
    local W = world()
    W:cmd(W.guest, "add", { id = W.id, q = "song a" })
    W:cmd(W.guest, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    truthy(W:lastNotice(W.guest) ~= nil)
    local slow = false
    for _, n in ipairs(W:notices(W.guest)) do if n:find("Slow down", 1, true) then slow = true end end
    truthy(slow, "second add within 2s refused")
    W.sent = {}
    for _ = 1, 30 do W:cmd(W.guest, "skip", { id = W.id }) end
    local counted = #W:notices(W.guest)
    truthy(counted <= 12, "flood capped (" .. counted .. " answered)")
end)

test("six broken songs in a row stop the radio instead of looping forever", function()
    local W = world()
    W.relay.resolve["broken"] = { title = "Broken", tracks = {} }
    for i = 1, 8 do
        local k = string.format("b%010d", i)
        W.relay.resolve["broken"].tracks[i] = track(k, "B" .. i, 100)
        W.relay.fetch["yt-" .. k] = { { state = "error", error = "gone" } }
    end
    W:cmd(W.owner, "add", { id = W.id, q = "broken" }) W:advance(10)
    eq(state(W).state, "idle")
    eq(#state(W).queue, 2, "stopped after six, two left")
end)

test("a download that never finishes gives up after 15 minutes", function()
    local W = world()
    W.relay.fetch["yt-aaaaaaaaaaa"] = { { state = "loading" } }
    W:cmd(W.owner, "add", { id = W.id, q = "song a" }) W:advance(2.1)
    W:cmd(W.owner, "add", { id = W.id, q = "song b" }) W:advance(2.1)
    eq(state(W).current.key, "yt-aaaaaaaaaaa")
    W:advance(905)
    eq(state(W).current.key, "yt-bbbbbbbbbbb", "moved on")
end)

-- ------------------------------------------------------------------ the model
test("model: every part has a texture, no NaN, meshes within the engine's vertex limit", function()
    local M = BRadio.Model
    local parts = M.Build()
    for mat, tris in pairs(parts) do
        truthy(M.Textures[mat], "texture for " .. mat)
        truthy(#tris * 3 < 32768, mat .. " fits one IMesh (" .. #tris * 3 .. " verts)")
        for _, t in ipairs(tris) do
            for i = 1, 3 do
                for j = 1, 6 do
                    local x = t[i][j]
                    truthy(type(x) == "number" and x == x and x > -1e6 and x < 1e6, mat .. " has a bad number")
                end
            end
        end
    end
    for _, need in ipairs({ "body", "front", "back", "button", "knob", "brasscap", "chrome", "dark" }) do
        truthy(parts[need], "the model has its " .. need)
    end
end)

test("model: Crosley proportions (5.25 x 3.25 x 3.25 in at 2.5x), front faces +X", function()
    local M = BRadio.Model
    local s = BRadio.Scale
    local mn, mx = M.Bounds()
    truthy(math.abs((mx[2] - mn[2]) - 5.25 * s) < 0.01, "width")
    truthy(math.abs(mx[3] - (3.25 + M.Inches.foot) * s) < 0.01, "height to the top of the case")
    local front = M.Build().front
    for _, t in ipairs(front) do for i = 1, 3 do truthy(t[i][1] > 0, "the grille side is +X") end end
    local sx, sy, sz = M.SpeakerPos()
    truthy(sx > 0 and sy < 0 and sz > 0, "the speaker is on the front, on the left as you face it (grille side)")
    local d = M.DisplayRect()
    truthy(d.y0 > sy and d.y1 < mx[2] and d.z1 < mx[3], "display to the right of the grille, inside the case")
end)

test("model: every texture draw-op is one the game knows how to draw", function()
    local known = { fill = 1, rect = 1, rrect = 1, ellipse = 1, ring = 1, poly = 1, speckle = 1, dots = 1, text = 1, vgrad = 1 }
    for name, spec in pairs(BRadio.Model.Textures) do
        truthy(spec[1] > 0 and spec[2] > 0, name .. " size")
        for _, op in ipairs(spec[3]) do truthy(known[op[1]], name .. ": unknown op " .. tostring(op[1])) end
    end
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
