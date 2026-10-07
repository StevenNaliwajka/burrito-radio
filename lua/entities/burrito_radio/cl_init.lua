include("shared.lua")

function ENT:Initialize()
    self:InitBox()
    local mn, mx = BRadio.Draw.RenderBounds()
    self:SetRenderBounds(mn, mx)
end

function ENT:Draw()
    BRadio.Draw.Radio(self)
end

-- the hint when you look at it
function ENT:GetOverlayText() return "" end
