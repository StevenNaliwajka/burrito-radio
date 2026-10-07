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
G.NRadio = nil

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
G.CreateClientConVar = function(name, def)
    return { GetBool = function() return def ~= "0" end, GetFloat = function() return tonumber(def) or 0 end }
end
G.concommand = { Add = function() end }
G.chat = mock("chat")
G.Lerp = function(t, a, b) return a + (b - a) * t end
G.FrameTime = function() return 0.016 end
G.os.date = function() return "10:08" end
G.EyePos = function() return shim.Vector(100, 0, 0) end
G.util.TraceLine = function() return { Hit = false } end
G.ScrW, G.ScrH = function() return 1920 end, function() return 1080 end
G.vgui = { Create = function(class) return mock("vgui:" .. class) end }
G.DermaMenu = function() return mock("DermaMenu") end
G.Derma_Query = function() end
G.SetClipboardText = function() end
G.LocalPlayer = function()
    return { SteamID64 = function() return "7656me" end, GetPos = function() return shim.Vector(0, 0, 0) end }
end
G.math.Round = function(v) return math.floor(v + 0.5) end

-- entities: one radio for station "r1"
local radio = {
    IsValid = function() return true end, GetClass = function() return "naliwajka_radio" end,
    GetStationId = function() return "r1" end, GetPos = function() return shim.Vector(0, 0, 0) end,
    WorldSpaceCenter = function() return shim.Vector(0, 0, 10) end,
    GetWorldTransformMatrix = function() return {} end,
    LocalToWorld = function(_, v) return v end, LocalToWorldAngles = function(_, a) return a end,
}
G.Entity = function(i) if i == 7 then return radio end return { IsValid = function() return false end } end
G.ents = { FindByClass = function() return { radio } end }
G.IsValid = function(x) return type(x) == "table" and x.IsValid ~= nil and x:IsValid() end

-- sound.PlayURL hands back a channel that records what it was told
local chan
G.sound = { PlayURL = function(url, flags, cb)
    calls.playurl = url
    assert(flags:find("3d", 1, true), "positional")
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
    function chan:SetPos(p) self.pos = p end
    function chan:Set3DFadeDistance(a, b) self.fade = { a, b } end
    cb(chan)
end }

dofile("lua/autorun/naliwajka_radio.lua")

-- a station arriving over the net, as sv_radio sends it
local function receiveState(t)
    local data = shim.encode(t)
    W.reading, W.ri = { data }, 1
    W.net["nradio_state"]()
end

test("textures: every draw op runs", function()
    NRadio.Draw.BuildTextures()
    truthy(NRadio.Draw.texturesBuilt)
    truthy((calls.poly or 0) > 1000, "grille holes drawn as polys: " .. tostring(calls.poly))
    for name in pairs(NRadio.Model.Textures) do truthy(NRadio.Draw.mats[name], "material " .. name) end
end)

test("meshes build, one per material, with every vertex", function()
    NRadio.Draw.BuildMeshes()
    truthy(#NRadio.Draw.meshes >= 8, "meshes: " .. #NRadio.Draw.meshes)
    truthy(verts > 3000, "vertices: " .. verts)
    local mn, mx = NRadio.Draw.RenderBounds()
    truthy(mx.z > 13, "render bounds reach the antenna tip (" .. mx.z .. ")")
end)

test("the radio draws (idle clock) and lights its materials", function()
    NRadio.Draw.Radio(radio)
    truthy((calls.meshdraw or 0) >= 8)
    local body = NRadio.Draw.mats.body
    truthy(body["$color"] and body["$color"].x > 0.1, "lit")
end)

test("a playing station opens a 3D channel at the station's clock", function()
    receiveState({ id = "r1", ent = 7, state = "playing", cur = { k = "yt-dQw4w9WgXcQ", t = "Never Gonna Give You Up", d = 213, b = "Burrito" },
        at = CurTime() - 42, vol = 0.7, range = 3000, base = "https://www.naliwajka.com/radio", q = {} })
    timer.Create = timer.Create  -- (manage runs on a timer; drive it)
    W:advance(0.3)
    truthy(calls.playurl == "https://www.naliwajka.com/radio/a/yt-dQw4w9WgXcQ.mp3", "url " .. tostring(calls.playurl))
    truthy(math.abs(chan.t - 42) < 0.5, "seeked to 42s, got " .. chan.t)
    truthy(chan.state == 1, "playing")
    W:run("Think")
    truthy(chan.vol > 0.3 and chan.vol < 0.8, "volume near it: " .. chan.vol)
    truthy(chan.fade[1] >= 6000, "BASS roll-off pushed out past the range")
end)

test("volume fades with distance and stops past the range", function()
    G.EyePos = function() return shim.Vector(2000, 0, 0) end
    W:run("Think")
    local far = chan.vol
    truthy(far > 0 and far < 0.1, "faint at 2000: " .. far)
    G.EyePos = function() return shim.Vector(5000, 0, 0) end
    W:advance(0.3)
    truthy(chan.stopped, "closed out of range")
    G.EyePos = function() return shim.Vector(100, 0, 0) end
    W:advance(0.3)
end)

test("the display draws while playing, paused and loading", function()
    NRadio.Draw.Radio(radio)
    NRadio.CL.Stations.r1.state = "paused"
    NRadio.CL.Stations.r1.pausedAt = 50
    NRadio.Draw.Radio(radio)
    NRadio.CL.Stations.r1.state = "loading"
    NRadio.Draw.Radio(radio)
    truthy(#NRadio.Draw.Chars("héllo 🎵") == 7, "utf-8 aware")
end)

test("the menu builds and refreshes for a guest and an admin", function()
    receiveState({ id = "r1", ent = 7, state = "playing", cur = { k = "yt-a", t = "Song", d = 100, b = "x", s = "7656me" },
        at = CurTime(), vol = 0.5, range = 3000, base = "https://www.naliwajka.com/radio",
        q = { { k = "yt-b", t = "Next", d = 90, b = "me", s = "7656me" }, { k = "yt-c", t = "Later", d = 0, b = "x", s = "x" } } })
    NRadio.Menu.Open("r1", false, false, true)
    NRadio.Menu.Refresh()
    NRadio.Menu.Open("r1", true, true, true)
    NRadio.CL.Library = { tracks = { { key = "lib-1", title = "Owner Song", duration = 100, album = "Chill" } },
        playlists = { { name = "Party", n = 3 } } }
    NRadio.Menu.RefreshLibrary()
    W:run("NRadioNotice", "hello")
end)

test("a station going away stops its channel", function()
    W.reading, W.ri = { "r1" }, 1
    W.net["nradio_gone"]()
    W:advance(0.3)
    truthy(NRadio.CL.Stations.r1 == nil)
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
