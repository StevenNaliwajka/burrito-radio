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

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
