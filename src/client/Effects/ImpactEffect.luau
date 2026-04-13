--[[
	ImpactEffect.luau
	═══════════════════════════════════════════════════════════════
	Partículas de impacto de bala contra superficies del mundo.
	═══════════════════════════════════════════════════════════════

	Resuelve material → tipo de impacto y emite partículas del pool.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConfig = require(Shared:WaitForChild("EffectsConfig"))
local EffectsConstants = require(Shared:WaitForChild("EffectsConstants"))

local ImpactEffect = {}
ImpactEffect.__index = ImpactEffect

function ImpactEffect.new(particlePool)
	local self = setmetatable({}, ImpactEffect)
	self._particlePool = particlePool
	self._activeCount = 0
	return self
end

function ImpactEffect:Destroy() end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function ImpactEffect:Fire(position: Vector3, normal: Vector3?, material: Enum.Material?)
	if self._activeCount >= EffectsConstants.MAX_ACTIVE_IMPACTS then
		return
	end

	-- Resolver tipo de impacto por material
	local impactType = "Default"
	if material then
		impactType = EffectsConstants.MATERIAL_TO_IMPACT_TYPE[material] or "Default"
	end

	local config = EffectsConfig.IMPACTS[impactType]
	if not config then
		config = EffectsConfig.IMPACTS.Default
	end

	if not config then
		return
	end

	self._activeCount += 1

	local part = self._particlePool:Acquire(position, normal, config)
	if part then
		-- Auto-decrement cuando se libere
		local lifetime = config.Lifetime or 0.6
		task.delay(lifetime + 0.2, function()
			self._activeCount = math.max(self._activeCount - 1, 0)
		end)
	else
		self._activeCount = math.max(self._activeCount - 1, 0)
	end
end

return ImpactEffect
