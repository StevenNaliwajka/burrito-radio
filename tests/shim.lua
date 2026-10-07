-- A Garry's Mod SERVER in plain Lua 5.1, just enough to run the radio's server side
-- for real: hooks, timers on a fake clock, convars, net (captured), entities, the
-- DATA folder, and HTTP() answered by a fake relay (tests set relay.* behaviour).
local M = {}

-- ------------------------------------------------------------------ JSON
local function encode(v)
    local t = type(v)
    if v == nil then return "null" end
    if t == "boolean" then return tostring(v) end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.14g", v)
    end
    if t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c)
            return ({ ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n" })[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    if t == "table" then
        local n = #v
        local isArr = n > 0 or next(v) == nil
        if isArr then
            for k in pairs(v) do if type(k) ~= "number" or k > n or k < 1 then isArr = false break end end
        end
        local out = {}
        if isArr then
            for i = 1, n do out[i] = encode(v[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            if type(v[k]) ~= "function" then out[#out + 1] = encode(tostring(k)) .. ":" .. encode(v[k]) end
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    return "null"
end
M.encode = encode

local function decode(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or (#s + 1) end
    local val
    local function str()
        local out = {}
        i = i + 1
        while true do
            local c = s:sub(i, i)
            if c == "" then error("unterminated string") end
            if c == '"' then i = i + 1 break end
            if c == "\\" then
                local e = s:sub(i + 1, i + 1)
                if e == "u" then
                    local code = tonumber(s:sub(i + 2, i + 5), 16)
                    out[#out + 1] = code < 128 and string.char(code) or "?"
                    i = i + 6
                else
                    out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[e] or e
                    i = i + 2
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
        return table.concat(out)
    end
    function val()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            local t = {}
            i = i + 1 ws()
            if s:sub(i, i) == "}" then i = i + 1 return t end
            while true do
                ws()
                local k = str()
                ws() i = i + 1  -- :
                t[k] = val()
                ws()
                local d = s:sub(i, i) i = i + 1
                if d == "}" then return t end
            end
        elseif c == "[" then
            local t = {}
            i = i + 1 ws()
            if s:sub(i, i) == "]" then i = i + 1 return t end
            while true do
                t[#t + 1] = val()
                ws()
                local d = s:sub(i, i) i = i + 1
                if d == "]" then return t end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
        elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
        elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
            i = i + #num
            return tonumber(num)
        end
    end
    return val()
end
M.decode = decode

-- ------------------------------------------------------------------ vectors
local Vec = {}
Vec.__index = Vec
local function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, Vec) end
function Vec:Distance(o) return math.sqrt((self.x - o.x) ^ 2 + (self.y - o.y) ^ 2 + (self.z - o.z) ^ 2) end
Vec.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
Vec.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
function Vec:DistToSqr(o) return self:Distance(o) ^ 2 end
function Vec:Length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
Vec.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    return Vector(a.x * b, a.y * b, a.z * b)
end
Vec.__tostring = function(v) return string.format("%.1f %.1f %.1f", v.x, v.y, v.z) end
local AngM = {}
AngM.__index = AngM
local function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, AngM) end

-- ------------------------------------------------------------------ world
function M.new()
    local W = { now = 0, hooks = {}, timers = {}, cvars = {}, cmds = {}, net = {}, sent = {}, data = {},
        players = {}, ents = {}, nextEnt = 1, printed = {}, map = "gm_test", relay = {}, httpLog = {} }
    local G = _G
    G.SERVER, G.CLIENT = true, false
    G.FCVAR_ARCHIVE, G.FCVAR_PROTECTED, G.FCVAR_DONTRECORD = 128, 32, 131072
    G.HUD_PRINTCONSOLE = 2
    G.BRadio = nil
    G.CAMI = nil
    G.Vector, G.Angle = Vector, Angle
    G.CurTime = function() return W.now end
    G.print = function(...)
        local p = {}
        for i = 1, select("#", ...) do p[#p + 1] = tostring((select(i, ...))) end
        W.printed[#W.printed + 1] = table.concat(p, " ")
    end
    G.IsValid = function(x) return type(x) == "table" and x.IsValid ~= nil and x:IsValid() end
    G.bit = { bor = function(a, b, c) return (a or 0) + (b or 0) + (c or 0) end }
    G.math.Clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
    G.math.Round = function(v) return math.floor(v + 0.5) end
    G.string.Trim = function(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
    G.AddCSLuaFile = function() end
    W.resources = {}
    G.resource = { AddFile = function(p) W.resources[#W.resources + 1] = p end }
    G.include = function(p) return dofile("lua/" .. p) end
    G.ErrorNoHalt = function(m) W.printed[#W.printed + 1] = "ERROR " .. m end
    G.os.time = function() return 1000 end
    local seed = 1
    G.math.random = function(a, b)   -- deterministic
        seed = (seed * 16807) % 2147483647
        local r = seed / 2147483647
        if not a then return r end
        if not b then a, b = 1, a end
        return a + math.floor(r * (b - a + 1))
    end

    G.hook = {
        Add = function(ev, id, fn)
            W.hooks[ev] = W.hooks[ev] or {}
            W.hooks[ev][id] = fn
        end,
        Remove = function(ev, id) if W.hooks[ev] then W.hooks[ev][id] = nil end end,
        Run = function(ev, ...) return W:run(ev, ...) end,
    }
    function W:run(ev, ...)
        for _, fn in pairs(self.hooks[ev] or {}) do
            local r = fn(...)
            if r ~= nil then return r end
        end
    end

    local seq = 0
    G.timer = {
        Create = function(id, delay, reps, fn)
            seq = seq + 1
            W.timers[id] = { at = W.now + delay, delay = delay, reps = reps, fn = fn, seq = seq }
        end,
        Simple = function(delay, fn)
            seq = seq + 1
            W.timers[{}] = { at = W.now + delay, delay = delay, reps = 1, fn = fn, seq = seq }
        end,
        Remove = function(id) W.timers[id] = nil end,
        Exists = function(id) return W.timers[id] ~= nil end,
    }

    G.CreateConVar = function(name, def)
        if W.cvars[name] == nil then W.cvars[name] = def end
        return {
            GetString = function() return tostring(W.cvars[name]) end,
            GetInt = function() return math.floor(tonumber(W.cvars[name]) or 0) end,
            GetFloat = function() return tonumber(W.cvars[name]) or 0 end,
            GetBool = function() return (tonumber(W.cvars[name]) or 0) ~= 0 end,
        }
    end
    G.concommand = { Add = function(n, fn) W.cmds[n] = fn end }
    G.GetConVar = function(name)
        if W.cvars[name] == nil then return nil end
        return { SetString = function(_, v) W.cvars[name] = v end }
    end
    G.RunConsoleCommand = function(name, v) W.cvars[name] = v end

    -- net: every message is captured as { name, fields..., to }
    local cur
    G.util = {
        AddNetworkString = function() end,
        TableToJSON = function(t) return encode(t) end,
        JSONToTable = function(s)
            local ok, r = pcall(decode, s or "")
            if ok and type(r) == "table" then return r end
            return nil
        end,
        Compress = function(s) return s end,
        Decompress = function(s) return s end,
    }
    G.net = {
        Start = function(name) cur = { name = name, fields = {} } end,
        WriteString = function(s) cur.fields[#cur.fields + 1] = s end,
        WriteBool = function(b) cur.fields[#cur.fields + 1] = b end,
        WriteUInt = function(n) cur.fields[#cur.fields + 1] = n end,
        WriteData = function(d) cur.fields[#cur.fields + 1] = d end,
        Send = function(ply) cur.to = ply W.sent[#W.sent + 1] = cur end,
        Broadcast = function() cur.to = "all" W.sent[#W.sent + 1] = cur end,
        SendToServer = function() cur.to = "server" W.sent[#W.sent + 1] = cur end,
        Receive = function(name, fn) W.net[name] = fn end,
        ReadUInt = function() return W.reading[W.ri] and #W.reading[W.ri] or 0 end,
        ReadData = function() local d = W.reading[W.ri] W.ri = W.ri + 1 return d end,
        ReadString = function() local d = W.reading[W.ri] W.ri = W.ri + 1 return d end,
    }

    G.file = {
        IsDir = function(p) return W.data[p .. "/"] ~= nil end,
        CreateDir = function(p) W.data[p .. "/"] = true end,
        Write = function(p, s) W.data[p] = s end,
        Read = function(p) return W.data[p] end,
    }
    G.game = { GetMap = function() return W.map end }

    -- entities
    local Ent = {}
    Ent.__index = Ent
    function Ent:IsValid() return not self.removed end
    function Ent:GetPos() return self.pos end
    function Ent:SetPos(p) self.pos = p end
    function Ent:GetAngles() return self.ang end
    function Ent:SetAngles(a) self.ang = a end
    function Ent:EntIndex() return self.idx end
    function Ent:GetClass() return self.class end
    function Ent:GetStationId() return self.sid or "" end
    function Ent:SetStationId(s) self.sid = s end
    function Ent:GetPhysicsObject() return self.phys end
    function Ent:Spawn() self.spawned = true end
    function Ent:Activate() end
    function Ent:Remove()
        if self.removed then return end
        self.removed = true
        if self.OnRemove then self:OnRemove() end
    end
    local Phys = {}
    Phys.__index = Phys
    function Phys:IsValid() return true end
    function Phys:EnableMotion(b) self.motion = b end
    G.ents = {
        Create = function(class)
            local e = setmetatable({ class = class, idx = W.nextEnt, pos = Vector(), ang = Angle(),
                phys = setmetatable({ motion = true }, Phys) }, Ent)
            W.nextEnt = W.nextEnt + 1
            e.OnRemove = function(self) BRadio.EntityRemoved(self) end
            W.ents[#W.ents + 1] = e
            return e
        end,
    }
    function W:cleanup()
        self:run("PreCleanupMap")
        for _, e in ipairs(self.ents) do e:Remove() end
        self:run("PostCleanupMap")
    end

    -- players
    local Ply = {}
    Ply.__index = Ply
    function Ply:IsValid() return self.connected end
    function Ply:Nick() return self.name end
    function Ply:SteamID64() return self.sid end
    function Ply:SteamID() return self.sid end
    function Ply:UserID() return self.uid end
    function Ply:IsAdmin() return self.admin or false end
    function Ply:IsBot() return false end
    function Ply:GetPos() return self.pos end
    function Ply:PrintMessage(_, text) self.console = (self.console or "") .. tostring(text) .. "\n" end
    function Ply:GetEyeTrace() return { HitPos = Vector(200, 0, 0), HitNormal = Vector(0, 0, 1) } end
    function Ply:EyeAngles() return Angle(0, 90, 0) end
    function W:player(name, opts)
        opts = opts or {}
        local p = setmetatable({ name = name, sid = "7656" .. name, uid = #self.players + 1, connected = true,
            admin = opts.admin, pos = opts.pos or Vector(0, 0, 0) }, Ply)
        self.players[#self.players + 1] = p
        return p
    end
    G.player = { GetAll = function()
        local out = {}
        for _, p in ipairs(W.players) do if p.connected then out[#out + 1] = p end end
        return out
    end }

    -- HTTP -> the fake relay. relay.resolve[q] = {title, tracks}, relay.fetch[key] = list of
    -- states returned on successive calls (the last one repeats)
    W.relay = { resolve = {}, fetch = {}, library = { tracks = {} }, saved = {}, down = false }
    G.HTTP = function(req)
        W.httpLog[#W.httpLog + 1] = req.url
        local path, query = req.url:match("^http://[^/]+/radio(/[^?]*)%??(.*)$")
        local q = {}
        for k, v in (query or ""):gmatch("([^&=]+)=([^&]*)") do
            q[k] = v:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
        end
        local R = W.relay
        local code, body
        if R.down then
            G.timer.Simple(0, function() req.failed("unsuccessful") end)
            return true
        end
        if path == "/resolve" then
            local r = R.resolve[q.q]
            if r then code, body = 200, r else code, body = 400, { error = "could not read that video" } end
        elseif path == "/fetch" then
            local seqs = R.fetch[q.key] or { { state = "ready", duration = 200 } }
            local i = math.min(#seqs, (R.fetchCalls or {})[q.key] or 1)
            R.fetchCalls = R.fetchCalls or {}
            R.fetchCalls[q.key] = i + 1
            code, body = 200, seqs[i]
        elseif path == "/library" then
            code, body = 200, R.library
        elseif path == "/library/save" then
            R.saved[q.key] = true
            code, body = 200, { state = "ready" }
        elseif path == "/library/remove" then
            R.saved[q.key] = nil
            code, body = 200, { state = "ready" }
        else
            code, body = 404, { error = "not found" }
        end
        G.timer.Simple(0, function() req.success(code, encode(body), {}) end)
        return true
    end

    -- advance the fake clock, firing timers in order
    function W:advance(dt)
        local target = self.now + dt
        while true do
            local best, bid
            for id, t in pairs(self.timers) do
                if t.at <= target and (not best or t.at < best.at or (t.at == best.at and t.seq < best.seq)) then best, bid = t, id end
            end
            if not best then break end
            self.now = math.max(self.now, best.at)
            if best.reps == 1 then
                self.timers[bid] = nil
            else
                best.at = best.at + math.max(best.delay, 0.001)
                if best.reps and best.reps > 1 then best.reps = best.reps - 1 end
            end
            best.fn()
        end
        self.now = target
    end

    -- a menu command, through the real net receiver
    function W:cmd(ply, op, args)
        args = args or {}
        args.op = op
        local data = encode(args)
        self.reading, self.ri = { data }, 1
        self.net["bradio_cmd"](#data, ply)
    end

    -- raw bytes through the command receiver (malformed payloads)
    function W:raw(ply, data)
        self.reading, self.ri = { data }, 1
        self.net["bradio_cmd"](#data, ply)
    end

    function W:sentTo(ply, name)
        local out = {}
        for _, m in ipairs(self.sent) do
            if m.name == name and (m.to == ply or m.to == "all") then out[#out + 1] = m end
        end
        return out
    end

    function W:notices(ply)
        local out = {}
        for _, m in ipairs(self.sent) do
            if m.name == "bradio_notice" and m.to == ply then out[#out + 1] = m.fields[1] end
        end
        return out
    end
    function W:lastNotice(ply) local n = self:notices(ply) return n[#n] end

    function W:boot()
        dofile("lua/autorun/burrito_radio.lua")
        self:run("InitPostEntity")
    end
    return W
end

M.Vector, M.Angle = Vector, Angle
return M
