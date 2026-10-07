-- The radio you see: a Crosley Cooper (burrito_radio/sh_model.lua). Everything it
-- plays lives in its station (sv_radio.lua); this is the box, its physics and E.
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Radio (Crosley Cooper)"
ENT.Author = "Burrito"
ENT.Category = "Burrito"
ENT.Purpose = "Plays YouTube links, playlists and the server's music. Press E to use it."
ENT.Instructions = "E: open the radio. Shift+E: pick it up and carry it."
ENT.Spawnable = true
ENT.IconOverride = "entities/burrito_radio.png"   -- rendered from the model: tools/preview/render.py --icon
ENT.AdminOnly = false
ENT.DisableDuplicator = true
ENT.RenderGroup = RENDERGROUP_OPAQUE

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "StationId")
end

function ENT:InitBox()
    local mins, maxs = BRadio.Model.Bounds()
    self.BoxMins, self.BoxMaxs = Vector(mins[1], mins[2], mins[3]), Vector(maxs[1], maxs[2], maxs[3])
    self:PhysicsInitBox(self.BoxMins, self.BoxMaxs)
    self:SetCollisionBounds(self.BoxMins, self.BoxMaxs)
    self:EnableCustomCollisions(true)
end
