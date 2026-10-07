--[[--------------------------------------------------------------------------
    burrito_radio/sh_model.lua

    The radio's look: a Crosley Cooper (CR1121A-EB, "Elemental Blue"), built
    as plain data so the same code feeds the game and the offline preview
    (tools/preview). Nothing in here touches a GMod API.

    WHY NOT AN .MDL. A compiled model needs studiomdl, a Windows tool from the
    GMod client, plus Blender time per change. The radio is a rounded box
    with a few parts on it, which is exactly what a mesh does well, and the
    textures are drawn at load (BRadio.Model.Textures are draw ops, run by
    cl_model.lua with surface.* and by tools/preview/render.py with PIL), so
    the addon ships no binary assets at all and every player already has it.

    Measured off the product photos (crosleyradio.com, CR1121A-EB-W2/W4):
    5.25" wide, 3.25" tall to the top of the case, 3.25" deep, scaled up by
    BRadio.Scale so it reads as a radio from across a room.

    Local frame: +X is the FRONT (the grille faces where the entity faces),
    +Y is to the left of someone facing the radio... so the viewer's right is
    +Y. Z is up, the origin is the centre of the feet's footprint on the floor.
    All model numbers below are in INCHES; Build() applies the scale.
----------------------------------------------------------------------------]]

BRadio = BRadio or {}
local M = {}
BRadio.Model = M

BRadio.Scale = BRadio.Scale or 2.5

-- case
local HX, HY = 1.625, 2.625         -- half depth, half width
local FOOT = 0.10                   -- feet lift the case off the floor
local H = 3.25                      -- case height
local R = 0.30                      -- edge rounding
M.Inches = { hx = HX, hy = HY, foot = FOOT, h = H }

-- The front and back "decals" cover the flat part of each face, 2:1 so the
-- 1024x512 texture has square pixels: 4.81" x 2.405".
local DEC = { y0 = -(HY - R), y1 = HY - R, z0 = FOOT + R, z1 = FOOT + R + 2.405 }
local DPX = 1024 / (DEC.y1 - DEC.y0)          -- texture px per inch
M.Decal = DEC

-- colours (sRGB 0-255), sampled off the photos and nudged for an unlit look
local C = {
    body    = { 121, 153, 194 },
    bodyLo  = { 104, 134, 172 },
    bodyHi  = { 138, 170, 209 },
    grille  = { 112, 141, 176 },
    hole    = { 22, 30, 44 },
    display = { 6, 7, 10 },
    button  = { 128, 164, 204 },
    icon    = { 236, 242, 250 },
    brass   = { 214, 178, 112 },
    brassHi = { 246, 222, 164 },
    brassLo = { 158, 118, 62 },
    dark    = { 30, 34, 42 },
    chrome  = { 200, 204, 210 },
    seam    = { 92, 118, 152 },
}
M.Colors = C

-- ---------------------------------------------------------------- geometry
local sqrt, sin, cos, tan, pi, max, min, abs =
    math.sqrt, math.sin, math.cos, math.tan, math.pi, math.max, math.min, math.abs

local function norm(x, y, z)
    local l = sqrt(x * x + y * y + z * z)
    if l < 1e-9 then return 0, 0, 1 end
    return x / l, y / l, z / l
end

-- the light baked into vertex colours: up, a little in front, a little left
local LX, LY, LZ = norm(0.45, 0.30, 0.85)
local function shade(nx, ny, nz)
    local d = nx * LX + ny * LY + nz * LZ
    return 0.68 + 0.32 * max(0, d)
end
M.Shade = shade

-- parts[material] = list of triangles; each vertex = { x, y, z, u, v, s }
local function newParts() return {} end

local function vert(x, y, z, u, v, nx, ny, nz)
    return { x, y, z, u, v, shade(nx, ny, nz) }
end

local function tri(parts, mat, a, b, c)
    local t = parts[mat]
    if not t then t = {}; parts[mat] = t end
    t[#t + 1] = { a, b, c }
end

local function quad(parts, mat, a, b, c, d)   -- a b c d counter-clockwise seen from outside
    tri(parts, mat, a, b, c)
    tri(parts, mat, a, c, d)
end

-- corner-weighted coordinates along one axis of a rounded box face (see roundedBox)
local function axisSteps(h, r, n)
    local out = {}
    for k = 0, n do  -- -h .. -(h-r): tan spacing so the projection lands evenly on the arc
        local phi = (pi / 4) * (n - k) / n
        out[#out + 1] = -(h - r) - r * tan(phi)
    end
    for k = n, 0, -1 do
        local phi = (pi / 4) * (n - k) / n
        out[#out + 1] = (h - r) + r * tan(phi)
    end
    return out
end

--[[ A box with every edge rounded to radius r. Each face is a grid on the
     sharp box; every grid point is pushed onto the rounded surface by
     clamping it to the inner box (half extents minus r) and stepping r out
     along the direction it was clamped. A face covers its half of each edge
     arc (0..45 degrees), its neighbour the other half, so the seams meet
     exactly without sharing vertices. ]]
local function roundedBox(parts, mat, cx, cy, cz, hx, hy, hz, r, n, uvScale)
    local ix, iy, iz = hx - r, hy - r, hz - r
    local function project(x, y, z)
        local qx = max(-ix, min(ix, x))
        local qy = max(-iy, min(iy, y))
        local qz = max(-iz, min(iz, z))
        local dx, dy, dz = x - qx, y - qy, z - qz
        local l = sqrt(dx * dx + dy * dy + dz * dz)
        if l < 1e-9 then return x, y, z, nil end
        dx, dy, dz = dx / l, dy / l, dz / l
        return qx + dx * r, qy + dy * r, qz + dz * r, dx, dy, dz
    end
    local sx, sy, sz = axisSteps(hx, r, n), axisSteps(hy, r, n), axisSteps(hz, r, n)
    -- face: fixed axis + sign, and the two running axes (a, b) in right-handed order
    local faces = {
        { "x", 1, sy, sz }, { "x", -1, sz, sy },
        { "y", 1, sz, sx }, { "y", -1, sx, sz },
        { "z", 1, sx, sy }, { "z", -1, sy, sx },
    }
    for _, f in ipairs(faces) do
        local axis, sg, A, B = f[1], f[2], f[3], f[4]
        local function at(a, b)
            local x, y, z
            if axis == "x" then
                x = sg * hx
                if sg > 0 then y, z = a, b else z, y = a, b end
            elseif axis == "y" then
                y = sg * hy
                if sg > 0 then z, x = a, b else x, z = a, b end
            else
                z = sg * hz
                if sg > 0 then x, y = a, b else y, x = a, b end
            end
            local px, py, pz, nx, ny, nz = project(x, y, z)
            if not nx then
                if axis == "x" then nx, ny, nz = sg, 0, 0
                elseif axis == "y" then nx, ny, nz = 0, sg, 0
                else nx, ny, nz = 0, 0, sg end
            end
            -- planar UVs off the face's own axes, in inches * uvScale
            local u, v
            if axis == "x" then u, v = py, -pz
            elseif axis == "y" then u, v = px, -pz
            else u, v = px, py end
            return vert(cx + px, cy + py, cz + pz, u * uvScale, v * uvScale, nx, ny, nz)
        end
        for i = 1, #A - 1 do
            for j = 1, #B - 1 do
                local a0, a1, b0, b1 = A[i], A[i + 1], B[j], B[j + 1]
                if a1 - a0 > 1e-6 and b1 - b0 > 1e-6 then
                    quad(parts, mat, at(a0, b0), at(a1, b0), at(a1, b1), at(a0, b1))
                end
            end
        end
    end
end

-- an axis-aligned box (sharp), with UVs 0..1 on every face
local function box(parts, mat, x0, y0, z0, x1, y1, z1, frontMat, frontUV)
    local function V(x, y, z, u, v, nx, ny, nz) return vert(x, y, z, u, v, nx, ny, nz) end
    -- +X (front): viewer's right is +Y, so u runs with y and v down with z
    local fu0, fv0, fu1, fv1 = 0, 0, 1, 1
    if frontUV then fu0, fv0, fu1, fv1 = frontUV[1], frontUV[2], frontUV[3], frontUV[4] end
    quad(parts, frontMat or mat,
        V(x1, y0, z0, fu0, fv1, 1, 0, 0), V(x1, y1, z0, fu1, fv1, 1, 0, 0),
        V(x1, y1, z1, fu1, fv0, 1, 0, 0), V(x1, y0, z1, fu0, fv0, 1, 0, 0))
    quad(parts, mat,
        V(x0, y1, z0, 0, 1, -1, 0, 0), V(x0, y0, z0, 1, 1, -1, 0, 0),
        V(x0, y0, z1, 1, 0, -1, 0, 0), V(x0, y1, z1, 0, 0, -1, 0, 0))
    quad(parts, mat,
        V(x1, y1, z0, 0, 1, 0, 1, 0), V(x0, y1, z0, 1, 1, 0, 1, 0),
        V(x0, y1, z1, 1, 0, 0, 1, 0), V(x1, y1, z1, 0, 0, 0, 1, 0))
    quad(parts, mat,
        V(x0, y0, z0, 0, 1, 0, -1, 0), V(x1, y0, z0, 1, 1, 0, -1, 0),
        V(x1, y0, z1, 1, 0, 0, -1, 0), V(x0, y0, z1, 0, 0, 0, -1, 0))
    quad(parts, mat,
        V(x0, y0, z1, 0, 0, 0, 0, 1), V(x1, y0, z1, 1, 0, 0, 0, 1),
        V(x1, y1, z1, 1, 1, 0, 0, 1), V(x0, y1, z1, 0, 1, 0, 0, 1))
    quad(parts, mat,
        V(x0, y1, z0, 0, 0, 0, 0, -1), V(x1, y1, z0, 1, 0, 0, 0, -1),
        V(x1, y0, z0, 1, 1, 0, 0, -1), V(x0, y0, z0, 0, 1, 0, 0, -1))
end

-- an orthonormal frame around a direction
local function basis(dx, dy, dz)
    dx, dy, dz = norm(dx, dy, dz)
    local ax, ay, az = 0, 0, 1
    if abs(dz) > 0.9 then ax, ay, az = 1, 0, 0 end
    -- e1 = a x d, e2 = d x e1
    local e1x, e1y, e1z = norm(ay * dz - az * dy, az * dx - ax * dz, ax * dy - ay * dx)
    local e2x, e2y, e2z = dy * e1z - dz * e1y, dz * e1x - dx * e1z, dx * e1y - dy * e1x
    return dx, dy, dz, e1x, e1y, e1z, e2x, e2y, e2z
end

--[[ A cylinder from p along d, `len` long. radiusAt(k) lets the knob have
     ridges. capMat (optional) closes the far end with a disc whose UVs map
     the unit square onto it (so a round texture lands round). ]]
local function cylinder(parts, mat, px, py, pz, ddx, ddy, ddz, len, radius, sides, capMat, capR, nearCap)
    local dx, dy, dz, e1x, e1y, e1z, e2x, e2y, e2z = basis(ddx, ddy, ddz)
    local function rim(k, t)
        local a = 2 * pi * k / sides
        local c, s = cos(a), sin(a)
        local r = type(radius) == "function" and radius(k) or radius
        local nx, ny, nz = c * e1x + s * e2x, c * e1y + s * e2y, c * e1z + s * e2z
        return px + dx * t + nx * r, py + dy * t + ny * r, pz + dz * t + nz * r, nx, ny, nz, c, s
    end
    for k = 0, sides - 1 do
        local x0, y0, z0, n0x, n0y, n0z = rim(k, 0)
        local x1, y1, z1, n1x, n1y, n1z = rim(k + 1, 0)
        local x2, y2, z2 = rim(k + 1, len)
        local x3, y3, z3 = rim(k, len)
        local u0, u1 = k / sides, (k + 1) / sides
        quad(parts, mat,
            vert(x0, y0, z0, u0, 1, n0x, n0y, n0z), vert(x1, y1, z1, u1, 1, n1x, n1y, n1z),
            vert(x2, y2, z2, u1, 0, n1x, n1y, n1z), vert(x3, y3, z3, u0, 0, n0x, n0y, n0z))
    end
    local function cap(t, m, rr, sign)
        local cx, cy, cz = px + dx * t, py + dy * t, pz + dz * t
        local nx, ny, nz = dx * sign, dy * sign, dz * sign
        local ctr = vert(cx, cy, cz, 0.5, 0.5, nx, ny, nz)
        for k = 0, sides - 1 do
            local a0, a1 = 2 * pi * k / sides, 2 * pi * (k + 1) / sides
            local function rv(a)
                local c, s = cos(a), sin(a)
                return vert(cx + (c * e1x + s * e2x) * rr, cy + (c * e1y + s * e2y) * rr,
                    cz + (c * e1z + s * e2z) * rr, 0.5 + 0.5 * c, 0.5 - 0.5 * s, nx, ny, nz)
            end
            if sign > 0 then tri(parts, m, ctr, rv(a0), rv(a1)) else tri(parts, m, ctr, rv(a1), rv(a0)) end
        end
    end
    if capMat then cap(len, capMat, capR or (type(radius) == "number" and radius or 0), 1) end
    if nearCap then cap(0, nearCap, type(radius) == "number" and radius or 0, -1) end
end

M.Layout = {
    -- front, measured from the viewer's left edge (u) and the case bottom (zb), inches
    buttons = {
        { u0 = 2.52, u1 = 3.10, zb0 = 0.87, zb1 = 1.41, icon = 1 },  -- play/pause
        { u0 = 3.13, u1 = 3.71, zb0 = 0.87, zb1 = 1.41, icon = 2 },  -- +
        { u0 = 2.52, u1 = 3.10, zb0 = 0.31, zb1 = 0.85, icon = 3 },  -- settings
        { u0 = 3.13, u1 = 3.71, zb0 = 0.31, zb1 = 0.85, icon = 4 },  -- -
    },
    knob = { u = 4.32, zb = 0.88, r = 0.45, depth = 0.34, cap = 0.27 },
    display = { u0 = 2.50, u1 = 4.88, zb0 = 1.45, zb1 = 2.55 },
    antenna = { y = 2.065, z = FOOT + 2.26, dir = { -0.30, -0.80, 0.52 },
                seg = { { 1.15, 0.085 }, { 1.12, 0.071 }, { 1.10, 0.058 }, { 1.05, 0.047 } } },
}

function M.Build(scale)
    scale = scale or BRadio.Scale
    local parts = newParts()
    local L = M.Layout

    -- case, with every edge softened
    roundedBox(parts, "body", 0, 0, FOOT + H / 2, HX, HY, H / 2, R, 4, 0.5)

    -- front decal (grille, display, badge), a hair proud of the flat face
    local fx = HX + 0.004
    quad(parts, "front",
        vert(fx, DEC.y0, DEC.z0, 0, 1, 1, 0, 0), vert(fx, DEC.y1, DEC.z0, 1, 1, 1, 0, 0),
        vert(fx, DEC.y1, DEC.z1, 1, 0, 1, 0, 0), vert(fx, DEC.y0, DEC.z1, 0, 0, 1, 0, 0))
    -- back decal: the viewer behind it has +Y on their left
    local bx = -HX - 0.004
    quad(parts, "back",
        vert(bx, DEC.y1, DEC.z0, 0, 1, -1, 0, 0), vert(bx, DEC.y0, DEC.z0, 1, 1, -1, 0, 0),
        vert(bx, DEC.y0, DEC.z1, 1, 0, -1, 0, 0), vert(bx, DEC.y1, DEC.z1, 0, 0, -1, 0, 0))

    -- the four square buttons (2x2 icon atlas)
    for _, b in ipairs(L.buttons) do
        local col, row = (b.icon - 1) % 2, math.floor((b.icon - 1) / 2)
        local uv = { col * 0.5 + 0.02, row * 0.5 + 0.02, col * 0.5 + 0.48, row * 0.5 + 0.48 }
        box(parts, "buttonside", HX - 0.02, -HY + b.u0, FOOT + b.zb0, HX + 0.06, -HY + b.u1, FOOT + b.zb1,
            "button", uv)
    end

    -- the volume knob: ridged blue barrel, flat face, brass cap
    local k = L.knob
    local ky, kz = -HY + k.u, FOOT + k.zb
    cylinder(parts, "knob", HX - 0.02, ky, kz, 1, 0, 0, k.depth, function(i) return (i % 2 == 0) and k.r or k.r - 0.025 end,
        48, "knob", k.r - 0.012)
    cylinder(parts, "brass", HX + k.depth - 0.02, ky, kz, 1, 0, 0, 0.025, k.cap, 40, "brasscap", k.cap)

    -- telescopic antenna on the back, swung up and over to the left
    local a = L.antenna
    local ddx, ddy, ddz = norm(a.dir[1], a.dir[2], a.dir[3])
    local px, py, pz = -HX - 0.10, a.y, a.z
    -- the swivel: a short stub out of the case, then the hinge barrel
    cylinder(parts, "chrome", -HX + 0.02, py, pz, -1, 0, 0, 0.14, 0.10, 12, "chrome")
    cylinder(parts, "chrome", px, py - 0.12, pz, 0, 1, 0, 0.24, 0.07, 12, "chrome", nil, "chrome")
    local t = 0
    for _, s in ipairs(a.seg) do
        cylinder(parts, "chrome", px + ddx * t, py + ddy * t, pz + ddz * t, ddx, ddy, ddz, s[1], s[2], 10,
            "chrome")
        t = t + s[1] - 0.06
    end
    cylinder(parts, "chrome", px + ddx * t, py + ddy * t, pz + ddz * t, ddx, ddy, ddz, 0.14, 0.075, 10, "chrome")

    -- feet
    for _, sx in ipairs({ -1, 1 }) do
        for _, sy in ipairs({ -1, 1 }) do
            local x, y = sx * (HX - 0.55), sy * (HY - 0.75)
            box(parts, "dark", x - 0.14, y - 0.22, 0, x + 0.14, y + 0.22, FOOT + 0.05)
        end
    end

    -- scale positions (UVs and shading stay)
    if scale ~= 1 then
        for _, tris in pairs(parts) do
            for _, t3 in ipairs(tris) do
                for i = 1, 3 do
                    local v = t3[i]
                    if not v.scaled then
                        v[1], v[2], v[3] = v[1] * scale, v[2] * scale, v[3] * scale
                        v.scaled = true
                    end
                end
            end
        end
    end
    return parts
end

-- the collision / render box (scaled), and where a 3D2D panel sits on the display
function M.Bounds(scale)
    scale = scale or BRadio.Scale
    local ax = M.Layout.antenna
    return { -HX * scale, -HY * scale, 0 }, { (HX + M.Layout.knob.depth) * scale, HY * scale, (FOOT + H) * scale }
end

function M.DisplayRect(scale)
    scale = scale or BRadio.Scale
    local d = M.Layout.display
    return {
        x = (HX + 0.006) * scale,
        y0 = (-HY + d.u0 + 0.06) * scale, y1 = (-HY + d.u1 - 0.06) * scale,
        z0 = (FOOT + d.zb0 + 0.06) * scale, z1 = (FOOT + d.zb1 - 0.06) * scale,
    }
end

-- ---------------------------------------------------------------- textures
--[[ Each texture is { w, h, ops }. Coordinates are texture pixels.
     ops:
       { "fill", col }
       { "rect", x, y, w, h, col }
       { "rrect", x, y, w, h, r, col }
       { "ellipse", cx, cy, rx, ry, col }
       { "ring", cx, cy, r0, r1, col }               annulus r0 < r1
       { "poly", { x1, y1, x2, y2, ... }, col }       convex
       { "speckle", seed, count, size, colA, colB }   deterministic noise
       { "dots", x, y, w, h, pitch, r, col }          staggered holes
       { "text", str, x, y, size, col, align, spacing }  align: 0 left, 1 centre; spacing px between letters
       { "vgrad", x, y, w, h, colTop, colBottom }
     A colour is { r, g, b }. ]]

local function rgb(c, k)
    k = k or 1
    return { min(255, math.floor(c[1] * k + 0.5)), min(255, math.floor(c[2] * k + 0.5)), min(255, math.floor(c[3] * k + 0.5)) }
end

-- inches on the front/back decal -> texture px (u from the case's left edge, zb from its bottom)
local function dx(u) return (u - (HY - (HY - R))) * DPX end
local function dy(zb) return (DEC.z1 - (FOOT + zb)) * DPX end

local function gearPoly(cx, cy, r0, r1, teeth)
    local pts = {}
    local n = teeth * 4
    for i = 0, n - 1 do
        local a = 2 * pi * (i + 0.5) / n
        local r = (math.floor(i / 2) % 2 == 0) and r1 or r0
        pts[#pts + 1] = cx + cos(a) * r
        pts[#pts + 1] = cy + sin(a) * r
    end
    return pts
end

local function textures()
    local T = {}

    -- leatherette: the case, pebbled
    T.body = { 256, 256, {
        { "fill", C.body },
        { "speckle", 11, 2600, 3, rgb(C.body, 0.90), rgb(C.body, 1.06) },
        { "speckle", 12, 900, 2, rgb(C.body, 0.84), rgb(C.body, 1.10) },
    } }

    -- the front panel
    local f = { { "fill", C.body }, { "speckle", 21, 9000, 3, rgb(C.body, 0.90), rgb(C.body, 1.06) } }
    local function add(op) f[#f + 1] = op end
    -- grille: a perforated plate with a rounded outer corner
    local gx0, gx1, gy0, gy1 = dx(0.31), dx(2.50), dy(2.55), dy(0.31)
    add({ "rrect", gx0, gy0, gx1 - gx0, gy1 - gy0, 26, C.grille })
    add({ "dots", gx0 + 10, gy0 + 10, gx1 - gx0 - 20, gy1 - gy0 - 20, 12.5, 3.6, C.hole })
    -- the badge: light-blue plate, brass rim, brass letters
    local bx0, bx1, by0, by1 = dx(0.78), dx(2.06), dy(0.80), dy(0.54)
    add({ "rrect", bx0 - 4, by0 - 4, bx1 - bx0 + 8, by1 - by0 + 8, 12, C.brassLo })
    add({ "rrect", bx0, by0, bx1 - bx0, by1 - by0, 9, rgb(C.button, 1.05) })
    add({ "text", "CROSLEY", (bx0 + bx1) / 2 + 2, (by0 + by1) / 2 + 2, 40, C.brassLo, 1, 9 })
    add({ "text", "CROSLEY", (bx0 + bx1) / 2, (by0 + by1) / 2, 40, C.brassHi, 1, 9 })
    -- display window (the live read-out is drawn over it in game)
    local d = M.Layout.display
    local wx0, wx1, wy0, wy1 = dx(d.u0), dx(d.u1), dy(d.zb1), dy(d.zb0)
    add({ "rrect", wx0, wy0, wx1 - wx0, wy1 - wy0, 6, rgb(C.seam, 0.8) })
    add({ "rect", wx0 + 4, wy0 + 4, wx1 - wx0 - 8, wy1 - wy0 - 8, C.display })
    add({ "vgrad", wx0 + 4, wy0 + 4, wx1 - wx0 - 8, (wy1 - wy0) * 0.45, { 26, 28, 34 }, C.display })
    -- the well the buttons sit in
    add({ "rect", dx(2.50), dy(1.43), dx(3.73) - dx(2.50), dy(0.29) - dy(1.43), C.seam })
    -- knob surround and the two small symbols under it
    local kx, ky = dx(M.Layout.knob.u), dy(M.Layout.knob.zb)
    add({ "ellipse", kx, ky, M.Layout.knob.r * DPX + 10, M.Layout.knob.r * DPX + 10, rgb(C.body, 0.86) })
    local px, py = dx(3.90), dy(0.40)
    add({ "ring", px, py, 9, 13, C.icon })
    add({ "rect", px - 5, py - 18, 10, 9, C.body })
    add({ "rect", px - 2, py - 17, 4, 13, C.icon })
    local ix, iy = dx(4.73), dy(0.40)
    add({ "rrect", ix - 14, iy - 10, 28, 20, 3, C.icon })
    add({ "rrect", ix - 11, iy - 7, 22, 14, 2, C.body })
    add({ "poly", { ix - 9, iy - 3, ix + 2, iy - 3, ix + 2, iy - 7, ix + 9, iy, ix + 2, iy + 7, ix + 2, iy + 3, ix - 9, iy + 3 }, C.icon })
    T.front = { 1024, 512, f }

    -- the back: bass port, screws, the jack panel
    local b = { { "fill", C.body }, { "speckle", 31, 9000, 3, rgb(C.body, 0.90), rgb(C.body, 1.06) } }
    local function addb(op) b[#b + 1] = op end
    local portx, porty = dx(2.62), dy(1.34)
    addb({ "ellipse", portx, porty, 0.66 * DPX, 0.66 * DPX, rgb(C.body, 1.06) })
    addb({ "ring", portx, porty, 0.60 * DPX, 0.66 * DPX, rgb(C.body, 0.85) })
    addb({ "ellipse", portx, porty, 0.36 * DPX, 0.36 * DPX, rgb(C.body, 0.70) })
    addb({ "ellipse", portx, porty + 6, 0.30 * DPX, 0.30 * DPX, rgb(C.hole, 1.4) })
    for _, s in ipairs({ { 0.33, 2.50 }, { 2.62, 2.50 }, { 4.92, 2.50 }, { 0.33, 0.42 }, { 2.62, 0.42 }, { 4.92, 0.42 } }) do
        addb({ "ellipse", dx(s[1]), dy(s[2]), 13, 13, C.hole })
    end
    local jx0, jx1, jy0, jy1 = dx(0.50), dx(1.12), dy(1.72), dy(0.48)
    addb({ "rrect", jx0, jy0, jx1 - jx0, jy1 - jy0, 8, rgb(C.body, 1.08) })
    addb({ "ellipse", (jx0 + jx1) / 2, jy0 + 50, 16, 16, C.hole })
    addb({ "text", "AUX IN", (jx0 + jx1) / 2, jy0 + 92, 17, C.icon, 1 })
    addb({ "rrect", (jx0 + jx1) / 2 - 10, jy0 + 130, 20, 52, 9, C.hole })
    addb({ "text", "DC IN 5V 1A", (jx0 + jx1) / 2, jy0 + 210, 15, C.icon, 1 })
    -- the antenna's parking clip
    addb({ "rrect", dx(3.95) - 18, dy(2.25) - 22, 36, 44, 10, rgb(C.body, 1.08) })
    addb({ "rect", dx(3.95) - 6, dy(2.25) - 10, 12, 20, C.hole })
    T.back = { 1024, 512, b }

    -- buttons: a 2x2 atlas: play/pause, +, settings, -
    local btn = { { "fill", C.button }, { "speckle", 41, 2500, 2, rgb(C.button, 0.95), rgb(C.button, 1.05) } }
    local function cell(i) return (i % 2) * 128 + 64, math.floor(i / 2) * 128 + 64 end
    local c1x, c1y = cell(0)
    btn[#btn + 1] = { "poly", { c1x - 22, c1y - 18, c1x - 2, c1y, c1x - 22, c1y + 18 }, C.icon }
    btn[#btn + 1] = { "rect", c1x + 6, c1y - 17, 6, 34, C.icon }
    btn[#btn + 1] = { "rect", c1x + 17, c1y - 17, 6, 34, C.icon }
    local c2x, c2y = cell(1)
    btn[#btn + 1] = { "rect", c2x - 18, c2y - 3, 36, 6, C.icon }
    btn[#btn + 1] = { "rect", c2x - 3, c2y - 18, 6, 36, C.icon }
    local c3x, c3y = cell(2)
    btn[#btn + 1] = { "poly", gearPoly(c3x, c3y, 15, 21, 8), C.icon }
    btn[#btn + 1] = { "ellipse", c3x, c3y, 7, 7, C.button }
    local c4x, c4y = cell(3)
    btn[#btn + 1] = { "rect", c4x - 18, c4y - 3, 36, 6, C.icon }
    T.button = { 256, 256, btn }
    T.buttonside = { 16, 16, { { "fill", rgb(C.button, 0.82) } } }

    T.knob = { 128, 128, { { "fill", rgb(C.button, 1.02) }, { "speckle", 51, 500, 2, rgb(C.button, 0.94), rgb(C.button, 1.06) } } }

    -- brass cap: brushed concentric rings
    local br = { { "fill", C.brass } }
    for i = 60, 1, -1 do
        local k = 0.86 + 0.22 * ((i * 37) % 11) / 10
        br[#br + 1] = { "ellipse", 64, 64, i * 64 / 60, i * 64 / 60, rgb(C.brass, k) }
    end
    br[#br + 1] = { "poly", { 64, 64, 10, 20, 30, 6 }, rgb(C.brassHi, 1) }
    T.brasscap = { 128, 128, br }
    T.brass = { 16, 16, { { "fill", C.brassLo } } }

    -- chrome: bright streak down the middle of the strip (the cylinder's u wraps around)
    local ch = {}
    for i = 0, 31 do
        local a = i / 32 * 2 * pi
        local k = 0.55 + 0.45 * max(0, cos(a - 0.6)) + 0.25 * max(0, cos(a + 2.2))
        ch[#ch + 1] = { "rect", i * 2, 0, 2, 64, rgb(C.chrome, k) }
    end
    T.chrome = { 64, 64, ch }
    T.dark = { 16, 16, { { "fill", C.dark } } }
    return T
end

M.Textures = textures()

return M
