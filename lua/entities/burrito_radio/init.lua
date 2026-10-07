AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

-- any small stock model: it is never drawn (cl_init draws the mesh), it only
-- gives the engine something to hang the entity on
ENT.HostModel = "models/props_junk/PopCan01a.mdl"

function ENT:SpawnFunction(ply, tr, class)
    if not tr.Hit then return end
    local ang = Angle(0, ply:EyeAngles().y + 180, 0)
    local ent = BRadio.SpawnRadio(tr.HitPos + tr.HitNormal * 1, ang, nil, { owner = ply })
    return ent
end

function ENT:Initialize()
    self:SetModel(self.HostModel)
    self:DrawShadow(false)
    self:InitBox()
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetUseType(SIMPLE_USE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetMass(6)
        phys:SetMaterial("plastic")
        phys:Wake()
    end
    -- spawned some other way (a dupe, ents.Create): give it a station of its own
    if self:GetStationId() == "" or not BRadio.Stations[self:GetStationId()] then
        local st = BRadio.NewStation({})
        st.ent = self
        self:SetStationId(st.id)
        BRadio.Dirty(st)
    end
end

function ENT:Use(activator)
    if IsValid(activator) and activator:IsPlayer() then BRadio.OpenMenu(activator, self) end
end

function ENT:OnTakeDamage(dmg)
    self:TakePhysicsDamage(dmg)   -- it gets knocked about, never broken
end

function ENT:OnRemove()
    BRadio.EntityRemoved(self)
end
