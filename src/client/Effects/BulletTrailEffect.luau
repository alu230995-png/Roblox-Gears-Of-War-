--[[
	BulletTrailEffect.luau
	═══════════════════════════════════════════════════════════════
	Tracer line desde muzzle hasta cada punto de impacto.
	═══════════════════════════════════════════════════════════════
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConfig = require(Shared:WaitForChild("EffectsConfig"))

local BulletTrailEffect = {}
BulletTrailEffect.__index = BulletTrailEffect

function BulletTrailEffect.new(trailPool)
	local self = setmetatable({}, BulletTrailEffect)
	self._trailPool = trailPool
	return self
end

function BulletTrailEffect:Destroy() end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function BulletTrailEffect:Fire(origin: Vector3, hitPositions: { [string]: Vector3 }, weaponName: string)
	if not self._trailPool then
		return
	end

	local weaponConfig = EffectsConfig.WEAPONS[weaponName]
	if not weaponConfig or not weaponConfig.BulletTrail then
		return
	end

	local trailConfig = weaponConfig.BulletTrail

	for _, hitPos in hitPositions do
		self._trailPool:Fire(origin, hitPos, trailConfig)
	end
end

return BulletTrailEffect
