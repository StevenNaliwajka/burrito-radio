-- Client-side smoke test: cl_model / cl_audio / cl_menu run against permissive mocks of
-- the GMod client API (any unknown call returns another mock), so the radio's own logic
-- -- texture ops, mesh building, the display, the audio manager, the menu build and
-- refresh -- executes end to end and a nil index or a typo in OUR code fails here.
-- It cannot tell whether it LOOKS right; that is what tools/preview and a real client are for.
local shim = dofile("tests/shim.lua")

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

-- a value that answers every call and index with another such value
local calls = {}
local function mock(name)
    local m = {}
    return setmetatable(m, {
        __index = function(_, k)
            if k == "IsValid" then return function() return true end end
            local child = mock(name .. "." .. tostring(k))
            rawset(m, k, child)
            return child
        end,
        __call = function(_, ...)
            calls[name] = (calls[name] or 0) + 1
            return mock(name .. "()")
        end,
        __add = function(a) return a end, __sub = function(a) return a end,
        __mul = function(a) return a end, __div = function(a) return a end,
        __concat = function(a, b) return tostring(a) .. tostring(b) end,
        __tostring = function() return name end,
    })
end

local W = shim.new()
local G = _G
G.SERVER, G.CLIENT = false, true
G.BRadio = nil

-- the client API the radio uses, with real return types where the code computes on them
G.surface = mock("surface")
G.surface.GetTextSize = function(s) return #tostring(s) * 10, 20 end
G.surface.DrawPoly = function(v)
    calls.poly = (calls.poly or 0) + 1
    assert(type(v) == "table" and #v >= 3 and v[1].x and v[1].y, "DrawPoly wants {x,y} vertices")
end
G.surface.DrawRect = function(x, y, w, h)
    calls.rect = (calls.rect or 0) + 1
    assert(type(x) == "number" and type(w) == "number", "DrawRect args")
end
G.draw = mock("draw")
G.render = mock("render")
G.render.GetLightColor = function() return shim.Vector(0.2, 0.2, 0.2) end
G.cam = mock("cam")
G.Color = function(r, g, b, a) return { r = r, g = g, b = b, a = a or 255 } end
G.GetRenderTargetEx = function(name, w, h)
    assert(type(name) == "string" and w > 0 and h > 0)
    return setmetatable({ GetName = function() return name end }, { __index = function() return function() end end })
end
local mats = {}
G.CreateMaterial = function(name, shader, params)
    assert(shader == "UnlitGeneric" and params["$basetexture"], "material params")
    local m = { name = name, SetVector = function(self, k, v) self[k] = v end, SetTexture = function() end }
    mats[name] = m
    return m
end
local meshes = 0
G.Mesh = function() meshes = meshes + 1 return { Draw = function() calls.meshdraw = (calls.meshdraw or 0) + 1 end } end
local verts = 0
G.mesh = { Begin = function() end, End = function() end, Position = function(p) assert(p.x) end,
    TexCoord = function(_, u, v) assert(u and v) end, Color = function() end, AdvanceVertex = function() verts = verts + 1 end }
G.MATERIAL_TRIANGLES, G.RT_SIZE_LITERAL, G.MATERIAL_RT_DEPTH_NONE, G.IMAGE_FORMAT_RGB888 = 1, 1, 1, 1
G.TEXT_ALIGN_CENTER, G.TEXT_ALIGN_LEFT = 1, 0
G.GMOD_CHANNEL_PLAYING, G.GMOD_CHANNEL_PAUSED, G.GMOD_CHANNEL_STOPPED = 1, 2, 0
G.MASK_SOLID_BRUSHONLY = 1
local cv = {}
G.CreateClientConVar = function(name, def)
    if cv[name] == nil then cv[name] = def end
    return { GetBool = function() return tostring(cv[name]) ~= "0" end, GetFloat = function() return tonumber(cv[name]) or 0 end }
end
G.concommand = { Add = function() end }
G.chat = mock("chat")
G.Lerp = function(t, a, b) return a + (b - a) * t end
G.FrameTime = function() return 0.016 end
G.os.date = function() return "10:08" end
G.EyePos = function() return shim.Vector(100, 0, 0) end
-- you look along -X (at the radio's front from +X): your right is +Y... in Source,
-- right = forward x up, so looking along -X your right is +Y
local view = { fwd = shim.Vector(-1, 0, 0), right = shim.Vector(0, 1, 0) }
G.EyeAngles = function()
    return { Forward = function() return view.fwd end, Right = function() return view.right end }
end
G.RealTime = function() return W.now end
local function settle() for _ = 1, 120 do W:run("Think") end end
local wall = false
G.util.TraceLine = function() return { Hit = wall } end
G.ScrW, G.ScrH = function() return 1920 end, function() return 1080 end
-- panels remember what they were Set*, so the menu's greyed-out buttons can be checked
local function panel(class)
    local p = {}
    return setmetatable(p, { __index = function(_, k)
        -- like a real panel: a field nobody set (self.quiet, self.lastSend) is nil
        if type(k) == "string" and k:sub(1, 1):match("%l") then return nil end
        if type(k) == "string" and k:sub(1, 3) == "Set" then
            return function(self, v) rawset(self, "_" .. k:sub(4), v) end
        elseif type(k) == "string" and k:sub(1, 3) == "Get" and k ~= "GetSelected" and k ~= "GetValue" then
            return function(self)
                local v = rawget(self, "_" .. k:sub(4))
                if v == nil then return mock("vgui:" .. class .. "." .. k .. "()") end
                return v
            end
        end
        return mock("vgui:" .. class .. "." .. tostring(k))
    end })
end
G.vgui = { Create = function(class) return panel(class) end }
G.DermaMenu = function() return mock("DermaMenu") end
G.Derma_Query = function() end
G.SetClipboardText = function() end
G.LocalPlayer = function()
    return { SteamID64 = function() return "7656me" end, GetPos = function() return shim.Vector(0, 0, 0) end }
end
G.math.Round = function(v) return math.floor(v + 0.5) end

-- entities: one radio for station "r1"
local radio = {
    IsValid = function() return true end, GetClass = function() return "burrito_radio" end,
    GetStationId = function() return "r1" end, GetPos = function() return shim.Vector(0, 0, 0) end,
    WorldSpaceCenter = function() return shim.Vector(0, 0, 10) end,
    GetWorldTransformMatrix = function() return {} end,
    LocalToWorld = function(_, v) return v end, LocalToWorldAngles = function(_, a) return a end,
    GetForward = function() return shim.Vector(1, 0, 0) end,
}
local radios = { [7] = radio }
local function makeRadio(idx, sid, pos)
    local r = {}
    for k, v in pairs(radio) do r[k] = v end
    r.GetStationId = function() return sid end
    r.GetPos = function() return pos end
    r.WorldSpaceCenter = function() return pos end
    r.LocalToWorld = function(_, v) return pos + v end
    radios[idx] = r
    return r
end
G.Entity = function(i) return radios[i] or { IsValid = function() return false end } end
G.ents = { FindByClass = function() local out = {} for _, r in pairs(radios) do out[#out + 1] = r end return out end }
G.IsValid = function(x) return type(x) == "table" and x.IsValid ~= nil and x:IsValid() end

-- sound.PlayURL hands back a channel that records what it was told
local chan
local chans, failURL = {}, nil
G.sound = { PlayURL = function(url, flags, cb)
    calls.playurl = url
    calls.opens = (calls.opens or 0) + 1
    if failURL and url:find(failURL, 1, true) then return cb(nil, 2, "BASS_ERROR_FILEOPEN") end
    assert(not flags:find("3d", 1, true), "a plain stream: we pan it ourselves")
    chan = { t = 0, vol = -1, state = 0, IsValid = function() return true end }
    function chan:GetTime() return self.t end
    function chan:SetTime(t) self.t = t end
    function chan:GetLength() return 213 end
    function chan:GetState() return self.state end
    function chan:Play() self.state = 1 end
    function chan:Pause() self.state = 2 end
    function chan:Stop() self.state = 0 self.stopped = true end
    function chan:SetVolume(v) self.vol = v end
    function chan:GetVolume() return self.vol end
    function chan:SetPos(p, d) self.pos = p self.dir = d end
    function chan:SetPan(p) self.pan = p end
    function chan:Set3DFadeDistance(a, b) self.fade = { a, b } end
    chans[#chans + 1] = chan
    chan.url = url
    cb(chan)
end }

dofile("lua/autorun/burrito_radio.lua")

-- a station arriving over the net, as sv_radio sends it
local function receiveState(t)
    local data = shim.encode(t)
    W.reading, W.ri = { data }, 1
    W.net["bradio_state"]()
end

test("textures: every draw op runs", function()
    BRadio.Draw.BuildTextures()
    truthy(BRadio.Draw.texturesBuilt)
    truthy((calls.poly or 0) > 1000, "grille holes drawn as polys: " .. tostring(calls.poly))
    for name in pairs(BRadio.Model.Textures) do truthy(BRadio.Draw.mats[name], "material " .. name) end
end)

test("meshes build, one per material, with every vertex", function()
    BRadio.Draw.BuildMeshes()
    truthy(#BRadio.Draw.meshes >= 8, "meshes: " .. #BRadio.Draw.meshes)
    truthy(verts > 3000, "vertices: " .. verts)
    local mn, mx = BRadio.Draw.RenderBounds()
    truthy(mx.z > 13, "render bounds reach the antenna tip (" .. mx.z .. ")")
end)

test("the radio draws (idle clock) and lights its materials", function()
    BRadio.Draw.Radio(radio)
    truthy((calls.meshdraw or 0) >= 8)
    local body = BRadio.Draw.mats.body
    truthy(body["$color"] and body["$color"].x > 0.1, "lit")
end)

test("a playing station opens a channel at the station's clock", function()
    receiveState({ id = "r1", ent = 7, state = "playing", cur = { k = "yt-dQw4w9WgXcQ", t = "Never Gonna Give You Up", d = 213, b = "Burrito" },
        at = CurTime() - 42, vol = 0.7, range = 3000, base = "https://www.naliwajka.com/radio", q = {} })
    timer.Create = timer.Create  -- (manage runs on a timer; drive it)
    W:advance(0.3)
    truthy(calls.playurl == "https://www.naliwajka.com/radio/a/yt-dQw4w9WgXcQ.mp3", "url " .. tostring(calls.playurl))
    truthy(math.abs(chan.t - 42) < 0.5, "seeked to 42s, got " .. chan.t)
    truthy(chan.state == 1, "playing")
    settle()
    truthy(chan.vol > 0.3 and chan.vol < 0.8, "volume near it: " .. chan.vol)
end)

test("the speaker is directional: same distance, louder in front than behind", function()
    G.EyePos = function() return shim.Vector(600, 0, 10) end
    settle()
    local front = chan.vol
    truthy(math.abs(chan.pan) < 0.2, "facing it: centred (" .. chan.pan .. ")")
    G.EyePos = function() return shim.Vector(-600, 0, 10) end
    view.fwd, view.right = shim.Vector(1, 0, 0), shim.Vector(0, -1, 0)
    settle()
    local back = chan.vol
    view.fwd, view.right = shim.Vector(-1, 0, 0), shim.Vector(0, 1, 0)
    truthy(front > 0 and back > 0, "both audible")
    truthy(back / front < 0.4, string.format("behind %.3f vs front %.3f", back, front))
    G.EyePos = function() return shim.Vector(100, 0, 0) end
end)

test("pan: the radio on your right is in your right ear, and follows your head", function()
    G.EyePos = function() return shim.Vector(600, 0, 10) end
    view.fwd, view.right = shim.Vector(0, 1, 0), shim.Vector(1, 0, 0)    -- facing +Y: radio (at -X) on your LEFT
    settle()
    truthy(chan.pan < -0.8, "left: " .. chan.pan)
    view.fwd, view.right = shim.Vector(0, -1, 0), shim.Vector(-1, 0, 0)  -- turn round: now on your RIGHT
    settle()
    truthy(chan.pan > 0.8, "right: " .. chan.pan)
    view.fwd, view.right = shim.Vector(-1, 0, 0), shim.Vector(0, 1, 0)  -- face it: centred
    settle()
    truthy(math.abs(chan.pan) < 0.1, "ahead: " .. chan.pan)
    local ahead = chan.vol
    view.fwd, view.right = shim.Vector(1, 0, 0), shim.Vector(0, -1, 0)  -- back to it: centred, a little softer
    settle()
    truthy(math.abs(chan.pan) < 0.1 and chan.vol < ahead, "behind you")
    view.fwd, view.right = shim.Vector(-1, 0, 0), shim.Vector(0, 1, 0)
    G.EyePos = function() return shim.Vector(100, 0, 0) end
    settle()
end)

test("the volume slider is heard at once, louder and softer, still directional", function()
    BRadio.Menu.Open("r1", true, true, true)
    local before = chan.vol
    BRadio.CL.Stations.r1.vol = 0.2
    settle()
    local low = chan.vol
    BRadio.CL.Stations.r1.vol = 1.0
    for _ = 1, 12 do W:run("Think") end    -- ~0.2 s of frames
    truthy(chan.vol > low * 3, string.format("rose quickly: %.3f -> %.3f", low, chan.vol))
    settle()
    local front = chan.vol
    G.EyePos = function() return shim.Vector(-100, 0, 10) end   -- same distance, behind the radio
    settle()
    truthy(chan.vol < front * 0.9, "the knob does not undo the direction")
    -- an older value echoed by the server mid-drag does not yank it back
    BRadio.CL.LocalVol.r1 = { v = 0.9, untilT = CurTime() + 1 }
    local data = shim.encode({ id = "r1", ent = 7, state = "playing", cur = { k = "yt-dQw4w9WgXcQ", t = "x", d = 213 },
        at = CurTime() - 42, vol = 0.3, range = 3000, base = "https://www.naliwajka.com/radio", q = {} })
    W.reading, W.ri = { data }, 1
    W.net["bradio_state"]()
    truthy(BRadio.CL.Stations.r1.vol == 0.9, "kept the dragged value")
    G.EyePos = function() return shim.Vector(100, 0, 0) end
    settle()
end)

test("volume fades with distance and stops past the range", function()
    G.EyePos = function() return shim.Vector(2000, 0, 0) end
    settle()
    local far = chan.vol
    truthy(far > 0 and far < 0.1, "faint at 2000: " .. far)
    G.EyePos = function() return shim.Vector(5000, 0, 0) end
    W:advance(0.3)
    truthy(chan.stopped, "closed out of range")
    G.EyePos = function() return shim.Vector(100, 0, 0) end
    W:advance(0.3)
end)

test("the display draws while playing, paused and loading", function()
    BRadio.Draw.Radio(radio)
    BRadio.CL.Stations.r1.state = "paused"
    BRadio.CL.Stations.r1.pausedAt = 50
    BRadio.Draw.Radio(radio)
    BRadio.CL.Stations.r1.state = "loading"
    BRadio.Draw.Radio(radio)
    truthy(#BRadio.Draw.Chars("héllo 🎵") == 7, "utf-8 aware")
end)

test("the menu builds and refreshes for a guest and an admin", function()
    receiveState({ id = "r1", ent = 7, state = "playing", cur = { k = "yt-a", t = "Song", d = 100, b = "x", s = "7656me" },
        at = CurTime(), vol = 0.5, range = 3000, base = "https://www.naliwajka.com/radio",
        q = { { k = "yt-b", t = "Next", d = 90, b = "me", s = "7656me" }, { k = "yt-c", t = "Later", d = 0, b = "x", s = "x" } } })
    BRadio.Menu.Open("r1", false, false, true)
    BRadio.Menu.Refresh()
    BRadio.Menu.Open("r1", true, true, true)
    BRadio.CL.Library = { tracks = { { key = "lib-1", title = "Owner Song", duration = 100, album = "Chill" } },
        playlists = { { name = "Party", n = 3 } } }
    BRadio.Menu.RefreshLibrary()
    W:run("BRadioNotice", "hello")
end)

test("a station going away stops its channel", function()
    W.reading, W.ri = { "r1" }, 1
    W.net["bradio_gone"]()
    W:advance(0.3)
    truthy(BRadio.CL.Stations.r1 == nil)
end)

-- ------------------------------------------------------------------ playback states
local function playing(extra)
    local t = { id = "r1", ent = 7, state = "playing", cur = { k = "yt-dQw4w9WgXcQ", t = "Song", d = 213, b = "x" },
        at = CurTime() - 42, vol = 0.7, range = 3000, base = "https://www.naliwajka.com/radio", q = {} }
    for k, v in pairs(extra or {}) do t[k] = v end
    receiveState(t)
end
local function openOn(id)
    for _, c in ipairs(chans) do if not c.stopped and c.url:find(id, 1, true) then return c end end
end

test("pause pauses the channel where it is; resume plays from the station's clock", function()
    playing() W:advance(0.3) settle()
    local c = openOn("dQw4w9WgXcQ")
    truthy(c and c.state == 1, "playing")
    playing({ state = "paused", pa = 50 }) settle()
    eq(c.state, 2, "paused")
    playing({ state = "playing", at = CurTime() - 50 }) settle()
    eq(c.state, 1, "playing again")
    truthy(math.abs(c.t - 50) < 1.5, "from 50s (" .. c.t .. ")")
end)

test("a seek by the owner moves every listener's channel", function()
    local c = openOn("dQw4w9WgXcQ")
    playing({ at = CurTime() - 150 }) settle()
    truthy(math.abs(c.t - 150) < 1.5, "jumped to 150 (" .. c.t .. ")")
end)

test("a new song closes the old channel and opens the new one at 0", function()
    local old = openOn("dQw4w9WgXcQ")
    playing({ cur = { k = "yt-NEWSONG0001", t = "Next", d = 100, b = "x" }, at = CurTime() + 1.5 })
    W:advance(0.3)
    truthy(old.stopped, "old channel closed")
    local c = openOn("NEWSONG0001")
    truthy(c, "new channel opened")
    truthy(c.state ~= 1, "held until the announced start")
    W:advance(2) settle()
    eq(c.state, 1, "starts on time")
    truthy(c.t < 1, "from the top")
end)

test("a wall between you and the radio muffles it", function()
    local c = openOn("NEWSONG0001")
    settle()
    local open = c.vol
    wall = true
    W:advance(0.4) settle()
    truthy(c.vol < open * 0.6, string.format("behind a wall %.3f vs %.3f", c.vol, open))
    wall = false
    W:advance(0.4) settle()
    truthy(c.vol > open * 0.9, "clear again")
end)

test("mute for me closes it for you only; unmute brings it back", function()
    local c = openOn("NEWSONG0001")
    BRadio.CL.Muted.r1 = true
    W:advance(0.3)
    truthy(c.stopped, "muted: channel closed (no download for you)")
    BRadio.CL.Muted.r1 = nil
    W:advance(0.3) settle()
    truthy(openOn("NEWSONG0001"), "back")
end)

test("bradio_enabled 0 turns every radio off for you; bradio_volume scales them", function()
    settle()
    local c = openOn("NEWSONG0001")
    local full = c.vol
    cv.bradio_volume = "0.4"
    settle()
    truthy(math.abs(c.vol - full * 0.5) < 0.02, string.format("0.4/0.8 of it: %.3f vs %.3f", c.vol, full))
    cv.bradio_volume = "0.8"
    cv.bradio_enabled = "0"
    W:advance(0.3)
    truthy(c.stopped, "off")
    cv.bradio_enabled = "1"
    W:advance(0.3) settle()
    truthy(openOn("NEWSONG0001"), "on again")
end)

test("only the 4 nearest radios play at once", function()
    for i = 1, 5 do
        local sid = "far" .. i
        makeRadio(20 + i, sid, shim.Vector(0, 300 * i, 0))
        receiveState({ id = sid, ent = 20 + i, state = "playing", cur = { k = "yt-FAR000000" .. i, t = "F", d = 213, b = "x" },
            at = CurTime() - 5, vol = 0.7, range = 3000, base = "https://www.naliwajka.com/radio", q = {} })
    end
    W:advance(0.3)
    local open = 0
    for _, c in ipairs(chans) do if not c.stopped then open = open + 1 end end
    eq(open, 4, "four channels")
    truthy(openOn("NEWSONG0001"), "the nearest (r1) is one of them")
    truthy(not openOn("FAR0000005"), "the farthest is not")
    for i = 1, 5 do
        W.reading, W.ri = { "far" .. i }, 1
        W.net["bradio_gone"]()
        radios[20 + i] = nil
    end
    W:advance(0.3)
end)

test("a stream that fails to open is retried, not hammered", function()
    failURL = "BROKEN00001"
    local before = calls.opens or 0
    playing({ cur = { k = "yt-BROKEN00001", t = "Broken", d = 100, b = "x" }, at = CurTime() - 1 })
    W:advance(5)
    eq((calls.opens or 0) - before, 1, "one try in the first 5 s")
    W:advance(15)
    truthy((calls.opens or 0) - before >= 2, "retried after ~15 s")
    failURL = nil
    W:advance(16)
    truthy(openOn("BROKEN00001"), "plays once the file is there")
end)

-- ------------------------------------------------------------------ the menu
local function sentOps()
    local ops = {}
    for _, m in ipairs(W.sent) do
        if m.name == "bradio_cmd" and m.to == "server" then ops[#ops + 1] = shim.decode(m.fields[2]) end
    end
    W.sent = {}
    return ops
end

test("menu buttons send the right commands", function()
    playing({ q = { { k = "yt-b", t = "Next", d = 90, b = "me", s = "7656me" } } })
    local M = BRadio.Menu
    M.Open("r1", true, true, true)
    W.sent = {}
    M.entry.GetValue = function() return "  https://youtu.be/dQw4w9WgXcQ  " end
    M.bAdd.DoClick()
    M.bNext.DoClick()
    M.bSkip.DoClick()
    M.bPlay.DoClick()
    M.bStop.DoClick()
    M.bClear.DoClick()
    local ops = sentOps()
    local names = {}
    for i, o in ipairs(ops) do names[i] = o.op eq(o.id, "r1", "addressed to the radio") end
    eq(table.concat(names, ","), "add,add,skip,pause,stop,clear")
    eq(ops[1].q, "https://youtu.be/dQw4w9WgXcQ", "trimmed link")
    eq(ops[2].next, true, "Play next")
    M.queue.GetSelected = function() return { { idx = 1, key = "yt-b" } } end
    M.bRemove.DoClick()
    M.bTop.DoClick()
    ops = sentOps()
    eq(ops[1].op .. ":" .. ops[1].i .. ":" .. ops[1].k, "remove:1:yt-b")
    eq(ops[2].op .. ":" .. ops[2].to, "move:1")
    M.lib.GetSelected = function() return { { key = "lib-1" } } end
    M.bLibAdd.DoClick()
    M.bLibAll.DoClick()
    ops = sentOps()
    eq(ops[1].op .. ":" .. ops[1].keys[1], "libadd:lib-1")
    eq(ops[2].all, true)
end)

test("the volume slider sends quickly while dragging and always sends where you let go", function()
    local M = BRadio.Menu
    W.sent = {}
    for v = 10, 60, 5 do M.vol.OnValueChanged(M.vol, v) W:advance(0.03) end
    local during = #sentOps()
    truthy(during >= 2 and during <= 5, "throttled to ~10/s while dragging (" .. during .. ")")
    W:advance(0.2)
    local ops = sentOps()
    truthy(#ops == 1 and math.abs(ops[1].v - 0.6) < 1e-6, "the final 60% went out (" .. #ops .. ")")
    eq(BRadio.CL.Stations.r1.vol, 0.6, "and you already hear it")
end)

test("a guest sees control buttons greyed out; an admin does not", function()
    local M = BRadio.Menu
    M.Open("r1", false, false, true)
    M.Refresh()
    eq(M.bPlay:GetDisabled(), true, "pause")
    eq(M.bStop:GetDisabled(), true, "stop")
    eq(M.bNext:GetDisabled(), true, "play next")
    eq(M.bClear:GetDisabled(), true, "clear")
    eq(M.bAdd:GetDisabled(), false, "add is open to guests")
    eq(M.bSkip:GetText(), "Vote skip")
    eq(M.bSaveNow:GetVisible(), false, "no library saving")
    M.Open("r1", true, true, true)
    M.Refresh()
    eq(M.bPlay:GetDisabled(), false)
    eq(M.bSkip:GetText(), "Skip")
    eq(M.bSaveNow:GetVisible(), true)
end)

test("a guest's own song shows Skip (they may skip what they added)", function()
    playing({ cur = { k = "yt-mine", t = "Mine", d = 100, b = "me", s = "7656me" } })
    local M = BRadio.Menu
    M.Open("r1", false, false, true)
    M.Refresh()
    eq(M.bSkip:GetText(), "Skip")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
