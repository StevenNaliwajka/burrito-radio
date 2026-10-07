-- The radio you see: a Crosley Cooper (naliwajka_radio/sh_model.lua). Everything it
-- plays lives in its station (sv_radio.lua); this is the box, its physics and E.
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Radio (Crosley Cooper)"
ENT.Author = "naliwajka.com"
ENT.Category = "Naliwajka"
ENT.Purpose = "Plays YouTube links, playlists and the server's music. Press E to use it."
ENT.Instructions = "Press E to open the radio"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.DisableDuplicator = true
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "StationId")
end

function ENT:InitBox()
    local mins, maxs = NRadio.Model.Bounds()
    self.BoxMins, self.BoxMaxs = Vector(mins[1], mins[2], mins[3]), Vector(maxs[1], maxs[2], maxs[3])
    self:PhysicsInitBox(self.BoxMins, self.BoxMaxs)
    self:SetCollisionBounds(self.BoxMins, self.BoxMaxs)
    self:EnableCustomCollisions(true)
end
