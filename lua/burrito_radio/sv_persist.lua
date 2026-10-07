--[[--------------------------------------------------------------------------
    burrito_radio/sv_persist.lua  -- what the server owner sets up stays put

      data/burrito_radio/maps/<map>.json   pinned radios on that map: where,
                                             settings, and the queue (with the
                                             song that was playing and how far in)
      data/burrito_radio/playlists.json    saved playlists (menu: Library tab)

    A pinned radio is frozen in place, comes back after TTT's round cleanup
    still playing, and comes back after a restart or map change at the song
    it was on. Only admins can move (physgun), tool or remove it.
----------------------------------------------------------------------------]]

local S = BRadio.Stations
local DIR = "burrito_radio"

local function mapFile() return DIR .. "/maps/" .. game.GetMap() .. ".json" end

local function ensureDirs()
    if not file.IsDir(DIR, "DATA") then file.CreateDir(DIR) end
    if not file.IsDir(DIR .. "/maps", "DATA") then file.CreateDir(DIR .. "/maps") end
end

-- ------------------------------------------------------------- playlists
function BRadio.SavePlaylists()
    ensureDirs()
    file.Write(DIR .. "/playlists.json", util.TableToJSON(BRadio.Playlists, true))
end

function BRadio.LoadPlaylists()
    local t = util.JSONToTable(file.Read(DIR .. "/playlists.json", "DATA") or "") or {}
    BRadio.Playlists = type(t) == "table" and t or {}
end

-- ------------------------------------------------------------- pinned radios
local function trackRow(t, pos)
    return { key = t.key, title = t.title, duration = t.duration, by = t.by, bySid = t.bySid, at = pos }
end

function BRadio.SavePinned()
    ensureDirs()
    local rows = {}
    for _, st in pairs(S) do
        if st.permanent then
            local pos, ang = st.pos, st.ang
            if IsValid(st.ent) then pos, ang = st.ent:GetPos(), st.ent:GetAngles() end
            if pos then
                local q = {}
                if st.current then
                    q[1] = trackRow(st.current, (st.state == "playing" or st.state == "paused") and math.floor(BRadio.Position(st)) or 0)
                end
                for _, t in ipairs(st.queue) do q[#q + 1] = trackRow(t) end
                rows[#rows + 1] = {
                    id = st.id, pos = { pos.x, pos.y, pos.z }, ang = { ang.p, ang.y, ang.r },
                    volume = st.volume, range = st.range, loop = st.loop, shuffle = st.shuffle,
                    autoplay = st.autoplay, queue = q, stopped = st.state == "idle" and #q == 0 or nil,
                }
            end
        end
    end
    table.sort(rows, function(a, b) return a.id < b.id end)
    file.Write(mapFile(), util.TableToJSON({ map = game.GetMap(), radios = rows }, true))
end

-- coalesce saves: at most one every few seconds
local function saveSoon()
    if timer.Exists("bradio_save") then return end
    timer.Create("bradio_save", 3, 1, function() BRadio.SavePinned() end)
end

function BRadio.OnChanged(st)
    if st.permanent then saveSoon() end
end

function BRadio.SetPinned(st, on)
    if not st then return end
    if on and not st.permanent then
        -- pinned stations get a stable id so the file lines up across restarts
        local n = 1
        while S["p" .. n] do n = n + 1 end
        local old = st.id
        S[old] = nil
        st.id = "p" .. n
        S[st.id] = st
        if IsValid(st.ent) then st.ent:SetStationId(st.id) end
        net.Start(BRadio.Net.Gone) net.WriteString(old) net.Broadcast()
    end
    st.permanent = on
    if on then
        st.owner, st.ownerName = nil, "the server"
        if IsValid(st.ent) then
            local phys = st.ent:GetPhysicsObject()
            if IsValid(phys) then phys:EnableMotion(false) end
        end
    end
    BRadio.Dirty(st)
    BRadio.SavePinned()
end

function BRadio.LoadPinned()
    local t = util.JSONToTable(file.Read(mapFile(), "DATA") or "")
    if type(t) ~= "table" or type(t.radios) ~= "table" then return 0 end
    local n = 0
    for _, row in ipairs(t.radios) do
        if not S[row.id] and type(row.pos) == "table" then
            local st = BRadio.NewStation({ id = row.id, permanent = true, volume = row.volume, range = row.range,
                loop = row.loop, shuffle = row.shuffle, autoplay = row.autoplay })
            st.pos = Vector(row.pos[1], row.pos[2], row.pos[3])
            st.ang = Angle(row.ang[1], row.ang[2], row.ang[3])
            for _, q in ipairs(row.queue or {}) do
                st.queue[#st.queue + 1] = { key = q.key, title = q.title, duration = tonumber(q.duration) or 0,
                    by = q.by, bySid = q.bySid, resumeAt = tonumber(q.at) }
            end
            BRadio.SpawnRadio(st.pos, st.ang, st)
            if #st.queue > 0 then
                BRadio.Advance(st, "restore")
            elseif row.stopped then
                st.idleSince = CurTime() + 1e9
            end
            n = n + 1
        end
    end
    return n
end

hook.Add("InitPostEntity", "bradio_persist", function()
    BRadio.LoadPlaylists()
    -- give the relay's library a moment so autoplay has something to pick
    timer.Simple(3, function()
        local n = BRadio.LoadPinned()
        if n > 0 then print("[Radio] " .. n .. " pinned radio(s) on " .. game.GetMap()) end
    end)
end)

hook.Add("ShutDown", "bradio_persist", function() BRadio.SavePinned() end)

-- TTT (and admins' cleanup button) remove every entity; pinned radios come straight back
hook.Add("PreCleanupMap", "bradio_persist", function()
    BRadio.CleaningUp = true
    for _, st in pairs(S) do
        if st.permanent and IsValid(st.ent) then st.pos, st.ang = st.ent:GetPos(), st.ent:GetAngles() end
    end
end)

hook.Add("PostCleanupMap", "bradio_persist", function()
    BRadio.CleaningUp = false
    for id, st in pairs(S) do
        if st.permanent then
            if not IsValid(st.ent) and st.pos then BRadio.SpawnRadio(st.pos, st.ang, st) end
        elseif not IsValid(st.ent) then
            BRadio.RemoveStation(st)
        end
    end
end)

-- admins move pinned radios; everyone else leaves them alone
local function pinned(ent)
    if not IsValid(ent) or ent:GetClass() ~= BRadio.Class then return false end
    local st = BRadio.StationOf(ent)
    return st and st.permanent
end

hook.Add("PhysgunPickup", "bradio_protect", function(ply, ent)
    if pinned(ent) and not BRadio.IsAdmin(ply) then return false end
end)
hook.Add("CanTool", "bradio_protect", function(ply, tr)
    if pinned(tr.Entity) and not BRadio.IsAdmin(ply) then return false end
end)
hook.Add("CanProperty", "bradio_protect", function(ply, _, ent)
    if pinned(ent) and not BRadio.IsAdmin(ply) then return false end
end)
hook.Add("GravGunPickupAllowed", "bradio_protect", function(ply, ent)
    if pinned(ent) and not BRadio.IsAdmin(ply) then return false end
end)
hook.Add("PhysgunDrop", "bradio_persist", function(_, ent)
    if pinned(ent) then
        local st = BRadio.StationOf(ent)
        local phys = ent:GetPhysicsObject()
        if IsValid(phys) then phys:EnableMotion(false) end
        st.pos, st.ang = ent:GetPos(), ent:GetAngles()
        BRadio.SavePinned()
    end
end)
