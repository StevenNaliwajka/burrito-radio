--[[--------------------------------------------------------------------------
    burrito_radio/cl_model.lua  -- draws the Crosley Cooper

    sh_model.lua describes it (triangles + texture draw-ops); this turns that
    into render-target textures, UnlitGeneric materials and IMeshes once, and
    then every radio is a handful of mesh draws.

    LIGHT. A mesh has no lightmap and VertexLitGeneric does not light an IMesh,
    so the materials are unlit: the shape's shading is baked into vertex
    colours (sh_model.Shade) and the room's light is applied per radio, per
    frame, as the materials' $color from render.GetLightColor at the radio.
    A radio in a dark corridor is dark; one in the sun is bright.

    THE DISPLAY is drawn live over the black window with cam.Start3D2D: the
    song's elapsed time in big blue LED digits and the title scrolling under
    it; a clock (like the real one's 10:08) when nothing is playing.

    Render targets can lose their contents when the game's video device
    resets; `bradio_rebuild` redraws them (also done on a resolution change).
----------------------------------------------------------------------------]]

BRadio.Draw = BRadio.Draw or {}
local D = BRadio.Draw
local M = BRadio.Model

local cvDisplay = CreateClientConVar("bradio_display", "1", true, false, "Radio: draw the radio's live display (1/0)")

D.TexVersion = "v1"
D.mats = D.mats or {}
D.meshes = D.meshes or nil

-- --------------------------------------------------------------- textures
local fonts = {}
local function texFont(size)
    size = math.floor(size)
    local name = "BRadioTex" .. size
    if not fonts[name] then
        surface.CreateFont(name, { font = "Arial", size = size, weight = 900, antialias = true, extended = false })
        fonts[name] = true
    end
    return name
end

local function lcg(seed)
    local s = seed % 2147483647
    if s == 0 then s = 1 end
    return function()
        s = (s * 16807) % 2147483647
        return s / 2147483647
    end
end

local function setCol(c) surface.SetDrawColor(c[1], c[2], c[3], 255) end

-- DrawPoly wants clockwise on screen (y down); flip what is not
local function poly(pts)
    local v = {}
    for i = 1, #pts, 2 do v[#v + 1] = { x = pts[i], y = pts[i + 1] } end
    local area = 0
    for i = 1, #v do
        local a, b = v[i], v[i % #v + 1]
        area = area + (a.x * b.y - b.x * a.y)
    end
    if area < 0 then
        local r = {}
        for i = #v, 1, -1 do r[#r + 1] = v[i] end
        v = r
    end
    surface.DrawPoly(v)
end

local function ellipsePts(cx, cy, rx, ry, n)
    n = n or math.Clamp(math.floor(math.max(rx, ry) * 0.8), 10, 64)
    local pts = {}
    for i = 0, n - 1 do
        local a = 2 * math.pi * i / n
        pts[#pts + 1] = cx + math.cos(a) * rx
        pts[#pts + 1] = cy + math.sin(a) * ry
    end
    return pts
end

local function runOps(ops, w, h)
    draw.NoTexture()
    for _, op in ipairs(ops) do
        local k = op[1]
        if k == "fill" then
            setCol(op[2]) surface.DrawRect(0, 0, w, h)
        elseif k == "rect" then
            setCol(op[6]) surface.DrawRect(op[2], op[3], op[4], op[5])
        elseif k == "rrect" then
            local c = op[7]
            draw.RoundedBox(math.floor(op[6] / 2) * 2, op[2], op[3], op[4], op[5], Color(c[1], c[2], c[3]))
            draw.NoTexture()
        elseif k == "ellipse" then
            setCol(op[6]) poly(ellipsePts(op[2], op[3], op[4], op[5]))
        elseif k == "ring" then
            setCol(op[6])
            local cx, cy, r0, r1 = op[2], op[3], op[4], op[5]
            local n = 48
            for i = 0, n - 1 do
                local a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
                poly({ cx + math.cos(a0) * r0, cy + math.sin(a0) * r0, cx + math.cos(a0) * r1, cy + math.sin(a0) * r1,
                    cx + math.cos(a1) * r1, cy + math.sin(a1) * r1, cx + math.cos(a1) * r0, cy + math.sin(a1) * r0 })
            end
        elseif k == "poly" then
            setCol(op[3]) poly(op[2])
        elseif k == "speckle" then
            local rnd = lcg(op[2])
            local size, ca, cb = op[4], op[5], op[6]
            for _ = 1, op[3] do
                local x, y, t = rnd() * w, rnd() * h, rnd()
                surface.SetDrawColor(ca[1] + (cb[1] - ca[1]) * t, ca[2] + (cb[2] - ca[2]) * t, ca[3] + (cb[3] - ca[3]) * t, 255)
                surface.DrawRect(math.floor(x), math.floor(y), size, size)
            end
        elseif k == "dots" then
            local x, y, ww, hh, pitch, r, c = op[2], op[3], op[4], op[5], op[6], op[7], op[8]
            setCol(c)
            local row, yy = 0, y + r
            while yy <= y + hh - r do
                local xx = x + r + ((row % 2 == 1) and pitch / 2 or 0)
                while xx <= x + ww - r do
                    poly(ellipsePts(xx, yy, r, r, 8))
                    xx = xx + pitch
                end
                yy = yy + pitch * 0.866
                row = row + 1
            end
        elseif k == "text" then
            local str, x, y, size, c, align, sp = op[2], op[3], op[4], op[5], op[6], op[7], op[8] or 0
            local f = texFont(size)
            surface.SetFont(f)
            surface.SetTextColor(c[1], c[2], c[3], 255)
            local widths, total = {}, 0
            for i = 1, #str do
                local cw = surface.GetTextSize(str:sub(i, i))
                widths[i] = cw
                total = total + cw + (i > 1 and sp or 0)
            end
            local _, th = surface.GetTextSize(str)
            local cx = (align == 1) and (x - total / 2) or x
            for i = 1, #str do
                surface.SetTextPos(math.floor(cx), math.floor(y - th / 2))
                surface.DrawText(str:sub(i, i))
                cx = cx + widths[i] + sp
            end
            draw.NoTexture()
        elseif k == "vgrad" then
            local x, y, ww, hh, ct, cb = op[2], op[3], op[4], op[5], op[6], op[7]
            for i = 0, hh - 1 do
                local t = i / math.max(1, hh - 1)
                surface.SetDrawColor(ct[1] + (cb[1] - ct[1]) * t, ct[2] + (cb[2] - ct[2]) * t, ct[3] + (cb[3] - ct[3]) * t, 255)
                surface.DrawRect(x, y + i, ww, 1)
            end
        end
    end
end

function D.BuildTextures()
    for name, spec in pairs(M.Textures) do
        local w, h, ops = spec[1], spec[2], spec[3]
        local rt = GetRenderTargetEx("bradio_" .. name .. "_" .. D.TexVersion, w, h,
            RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGB888)
        render.PushRenderTarget(rt)
        render.Clear(0, 0, 0, 255, true, true)
        cam.Start2D()
        local ok, err = pcall(runOps, ops, w, h)
        cam.End2D()
        render.PopRenderTarget()
        if not ok then ErrorNoHalt("[Radio] texture " .. name .. ": " .. tostring(err) .. "\n") end
        local mat = D.mats[name]
        if not mat then
            mat = CreateMaterial("bradio_" .. name .. "_" .. D.TexVersion, "UnlitGeneric", {
                ["$basetexture"] = rt:GetName(),
                ["$vertexcolor"] = "1",
                ["$nocull"] = "1",
            })
            D.mats[name] = mat
        else
            mat:SetTexture("$basetexture", rt)
        end
    end
    D.texturesBuilt = true
end

-- --------------------------------------------------------------- meshes
function D.BuildMeshes()
    local parts = M.Build()
    D.meshes = {}
    local mn = Vector(1e9, 1e9, 1e9)
    local mx = Vector(-1e9, -1e9, -1e9)
    for mat, tris in pairs(parts) do
        local im = Mesh()
        mesh.Begin(im, MATERIAL_TRIANGLES, #tris)
        for _, t in ipairs(tris) do
            for i = 1, 3 do
                local v = t[i]
                local p = Vector(v[1], v[2], v[3])
                mn.x, mn.y, mn.z = math.min(mn.x, p.x), math.min(mn.y, p.y), math.min(mn.z, p.z)
                mx.x, mx.y, mx.z = math.max(mx.x, p.x), math.max(mx.y, p.y), math.max(mx.z, p.z)
                local s = math.Clamp(math.floor(v[6] * 255 + 0.5), 0, 255)
                mesh.Position(p)
                mesh.TexCoord(0, v[4], v[5])
                mesh.Color(s, s, s, 255)
                mesh.AdvanceVertex()
            end
        end
        mesh.End()
        D.meshes[#D.meshes + 1] = { mat = mat, mesh = im }
    end
    table.sort(D.meshes, function(a, b) return a.mat < b.mat end)
    D.bounds = { mn, mx }
end

function D.RenderBounds()
    if not D.bounds then D.BuildMeshes() end
    return D.bounds[1] - Vector(2, 2, 2), D.bounds[2] + Vector(2, 2, 2)
end

function D.Rebuild()
    D.texturesBuilt = false
    D.BuildMeshes()
end
concommand.Add("bradio_rebuild", function() D.Rebuild() end)
hook.Add("OnScreenSizeChanged", "bradio_rebuild", function() D.texturesBuilt = false end)

-- textures are drawn outside any other render pass: before the frame, once
hook.Add("PreRender", "bradio_textures", function()
    if not D.texturesBuilt and #ents.FindByClass(BRadio.Class) > 0 then D.BuildTextures() end
end)

-- --------------------------------------------------------------- display
surface.CreateFont("BRadioLED", { font = "Consolas", size = 120, weight = 700, antialias = true })
surface.CreateFont("BRadioLEDSmall", { font = "Consolas", size = 30, weight = 600, antialias = true, extended = true })

-- split a UTF-8 string into characters (titles are full of accents and emoji)
function D.Chars(s)
    local out = {}
    for ch in tostring(s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
    return out
end

local LED = Color(150, 178, 255)
local LEDDim = Color(40, 48, 80)
local LEDGlow = Color(90, 120, 255, 40)

local function drawDisplay(ent, st)
    local r = M.DisplayRect()
    local w, h = (r.y1 - r.y0), (r.z1 - r.z0)
    local scale = 0.01
    local pw, ph = w / scale, h / scale
    -- the 3D2D plane: x runs with +Y (the viewer's right), y down with -Z
    local origin = ent:LocalToWorld(Vector(r.x + 0.02, r.y0, r.z1))
    local ang = ent:LocalToWorldAngles(Angle(0, 90, 90))
    cam.Start3D2D(origin, ang, scale)
    local now = CurTime()
    local big, small, blink = nil, nil, false
    if not st or not st.cur then
        big = os.date("%H:%M")
        small = st and st.state == "loading" and "LOADING..." or "RADIO"
    elseif st.state == "loading" then
        big, small, blink = "--:--", "LOADING  " .. (st.cur.t or ""), true
    else
        local pos = BRadio.Position(st, now)
        if pos < 0 then pos = 0 end
        big = BRadio.FormatTime(pos)
        if #big < 5 then big = "0" .. big end
        small = st.cur.t or ""
        blink = st.state == "paused"
    end
    draw.SimpleText("88:88", "BRadioLED", pw / 2, ph * 0.40, LEDDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    if not blink or math.floor(now * 2) % 2 == 0 then
        draw.SimpleText(big, "BRadioLED", pw / 2 + 1, ph * 0.40 + 1, LEDGlow, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        draw.SimpleText(big, "BRadioLED", pw / 2, ph * 0.40, LED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    -- the title: a fixed-width font, so a marquee is just a window of characters
    surface.SetFont("BRadioLEDSmall")
    local cw = surface.GetTextSize("M")
    local fit = math.max(4, math.floor((pw - 16) / cw))
    local chars = D.Chars(small)
    local line
    if #chars <= fit then
        line = small
    else
        local loop = {}
        for _, c in ipairs(chars) do loop[#loop + 1] = c end
        for _ = 1, 4 do loop[#loop + 1] = " " end
        local off = math.floor(now * 5) % #loop
        local out = {}
        for i = 1, fit do out[i] = loop[(off + i - 1) % #loop + 1] end
        line = table.concat(out)
    end
    draw.SimpleText(line, "BRadioLEDSmall", pw / 2, ph * 0.82, LED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    cam.End3D2D()
end

-- --------------------------------------------------------------- drawing
local lightVec = Vector(1, 1, 1)
function D.Radio(ent)
    if not D.meshes then D.BuildMeshes() end
    if not D.texturesBuilt then return end   -- PreRender draws them, next frame

    -- the room's light at the radio, lifted a little so it never goes pitch black
    local lc = render.GetLightColor(ent:WorldSpaceCenter())
    local function lift(x) return math.Clamp(math.sqrt(math.max(x, 0)) * 1.25 + 0.10, 0.18, 1.15) end
    lightVec.x, lightVec.y, lightVec.z = lift(lc.x), lift(lc.y), lift(lc.z)

    cam.PushModelMatrix(ent:GetWorldTransformMatrix())
    for _, m in ipairs(D.meshes) do
        local mat = D.mats[m.mat]
        if mat then
            mat:SetVector("$color", lightVec)
            render.SetMaterial(mat)
            m.mesh:Draw()
        end
    end
    cam.PopModelMatrix()

    if cvDisplay:GetBool() and EyePos():DistToSqr(ent:GetPos()) < 700 * 700 then
        local st = BRadio.CL and BRadio.CL.Stations[ent:GetStationId()]
        drawDisplay(ent, st)
    end
end
