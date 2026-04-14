--[[
	BloodEffect.luau
	═══════════════════════════════════════════════════════════════
	Partículas de sangre para impactos de bala y muertes.
	═══════════════════════════════════════════════════════════════
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConfig = require(Shared:WaitForChild("EffectsConfig"))
local EffectsConstants = require(Shared:WaitForChild("EffectsConstants"))

local BloodEffect = {}
BloodEffect.__index = BloodEffect

function BloodEffect.new(particlePool)
	local self = setmetatable({}, BloodEffect)
	self._particlePool = particlePool
	self._activeCount = 0
	return self
end

function BloodEffect:Destroy() end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function BloodEffect:FireHit(position: Vector3, direction: Vector3?, damage: number?)
	if self._activeCount >= EffectsConstants.MAX_ACTIVE_BLOOD then
		return
	end

	local baseConfig = EffectsConfig.IMPACTS.Flesh
	if not baseConfig then
		return
	end

	local intensity = math.clamp((damage or 50) / 100, 0.3, 3.0)

	local config = {
		Path = baseConfig.Path,
		ParticleCount = math.clamp(math.floor(baseConfig.ParticleCount * intensity), 3, 30),
		Spread = baseConfig.Spread * math.clamp(intensity, 0.5, 2.0),
		Lifetime = baseConfig.Lifetime * math.clamp(intensity, 0.7, 1.5),
		Speed = baseConfig.Speed * math.clamp(intensity, 0.6, 2.0),
		Color = baseConfig.Color,
		DecalLifetime = baseConfig.DecalLifetime,
	}

	self._activeCount += 1

	local normal = direction and direction.Unit or Vector3.yAxis
	self._particlePool:Acquire(position, normal, config)

	local lifetime = config.Lifetime or 0.8
	task.delay(lifetime + 0.2, function()
		self._activeCount = math.max(self._activeCount - 1, 0)
	end)
end

function BloodEffect:FireDeath(character: Model, deathType: string, hitDirection: Vector3?)
	local deathConfig = EffectsConfig.DEATH[deathType]
	if not deathConfig or not deathConfig.BloodBurst then
		deathConfig = EffectsConfig.DEATH.Standard
	end
	if not deathConfig then
		return
	end

	local burstConfig = deathConfig.BloodBurst

	-- Posición: HumanoidRootPart o torso
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")

	local position: Vector3
	if hrp then
		position = hrp.Position
	elseif torso and torso:IsA("BasePart") then
		position = torso.Position
	else
		return
	end

	local normal = hitDirection and hitDirection.Unit or Vector3.yAxis

	-- Burst principal (one-shot via pool)
	self._particlePool:Acquire(position, normal, burstConfig)

	-- Si es headshot, burst extra + emitter persistente en la cabeza
	if deathType == "Headshot" then
		local head = character:FindFirstChild("Head") :: BasePart?
		if head then
			self._particlePool:Acquire(head.Position, normal, burstConfig)
			self:_attachPersistentEmitter(head, burstConfig, 4.0)
		end
	end

	-- Si es dismember, bursts + emitters persistentes en extremidades
	if deathType == "Dismember" then
		for _, partName in { "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg" } do
			local limb = character:FindFirstChild(partName) :: BasePart?
			if limb then
				self._particlePool:Acquire(
					limb.Position,
					Vector3.new(math.random() - 0.5, math.random(), math.random() - 0.5).Unit,
					{
						ParticleCount = math.floor(burstConfig.ParticleCount * 0.4),
						Spread = burstConfig.Spread,
						Lifetime = burstConfig.Lifetime * 0.7,
						Speed = burstConfig.Speed * 0.6,
						Color = burstConfig.Color,
					}
				)
				self:_attachPersistentEmitter(limb, burstConfig, 3.0)
			end
		end
	end
end

------------------------------------------------------------------------
-- INTERNAL: Emitter persistente clonado desde Path, parenteado a un part
------------------------------------------------------------------------

--- Clona el template de partículas desde burstConfig.Path, lo attacha a `part`
--- con Enabled=true durante `duration` segundos, luego lo desactiva y destruye.
function BloodEffect:_attachPersistentEmitter(part: BasePart, burstConfig, duration: number)
	if not burstConfig.Path then
		return
	end

	local template = EffectsConstants.ResolvePath(burstConfig.Path)
	if not template then
		return
	end

	local clone = template:Clone()

	-- Habilitar todos los emitters (emisión continua, no burst)
	for _, desc in clone:GetDescendants() do
		if desc:IsA("ParticleEmitter") then
			desc.Enabled = true
		end
	end
	if clone:IsA("ParticleEmitter") then
		clone.Enabled = true
	end

	-- Parentear al part del character (Head, limb, etc.)
	if clone:IsA("BasePart") then
		clone.Transparency = 1
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.Massless = true
		clone.Anchored = false

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = part
		weld.Part1 = clone
		weld.Parent = clone

		clone.CFrame = part.CFrame
		clone.Parent = part.Parent
	else
		clone.Parent = part
	end

	-- Desactivar tras `duration`, luego destruir tras el lifetime residual
	task.delay(duration, function()
		for _, desc in clone:GetDescendants() do
			if desc:IsA("ParticleEmitter") then
				desc.Enabled = false
			end
		end
		if clone:IsA("ParticleEmitter") then
			clone.Enabled = false
		end

		local maxLifetime = burstConfig.Lifetime or 1.0
		task.delay(maxLifetime + 0.5, function()
			clone:Destroy()
		end)
	end)
end

return BloodEffect
