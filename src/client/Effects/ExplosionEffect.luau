--[[
	ExplosionEffect.luau
	═══════════════════════════════════════════════════════════════
	VFX de explosión para armas explosivas.
	═══════════════════════════════════════════════════════════════

	Crea fireball, shockwave ring y debris en el punto de impacto.
	Boomshot, TorqueBow, HammerOfDawn.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConfig = require(Shared:WaitForChild("EffectsConfig"))
local EffectsConstants = require(Shared:WaitForChild("EffectsConstants"))

local ExplosionEffect = {}
ExplosionEffect.__index = ExplosionEffect

function ExplosionEffect.new()
	local self = setmetatable({}, ExplosionEffect)
	self._activeCount = 0
	return self
end

function ExplosionEffect:Destroy() end

------------------------------------------------------------------------
-- PRIVATE — clone desde Path array con delay opcional
------------------------------------------------------------------------

function ExplosionEffect:_cloneFromPaths(
	subConfig: { Path: (string | { string })?, PathDelay: number? },
	position: Vector3,
	lifetime: number
): { Instance }
	local paths = EffectsConstants.NormalizePaths(subConfig.Path)
	if not paths then
		return {}
	end

	local clones = {} :: { Instance }
	local pathDelay = subConfig.PathDelay or 0

	local function cloneOne(path: string)
		local template = EffectsConstants.ResolvePath(path)
		if not template then
			warn("[ExplosionEffect] Path not found: " .. path)
			return
		end

		local clone = template:Clone()
		if clone:IsA("BasePart") then
			clone.CFrame = CFrame.new(position)
			clone.Anchored = true
			clone.CanCollide = false
			clone.CanQuery = false
			clone.CanTouch = false
		elseif clone:IsA("Model") then
			clone:PivotTo(CFrame.new(position))
		end
		clone.Parent = Workspace

		-- Emit burst (NO Enabled)
		EffectsConstants.EmitAll(clone)

		table.insert(clones, clone)

		task.delay(lifetime + 0.5, function()
			clone:Destroy()
		end)
	end

	if pathDelay > 0 and #paths > 1 then
		task.spawn(function()
			for i, p in paths do
				if i > 1 then
					task.wait(pathDelay)
				end
				cloneOne(p)
			end
		end)
	else
		for _, p in paths do
			cloneOne(p)
		end
	end

	return clones
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function ExplosionEffect:Fire(position: Vector3, radius: number, _weaponName: string)
	if self._activeCount >= EffectsConstants.MAX_ACTIVE_EXPLOSIONS then
		return
	end

	self._activeCount += 1

	local expConfig = EffectsConfig.EXPLOSION

	-- FireBall: si tiene Path, clonar en vez de crear desde código
	local fireball = nil :: Instance?
	local light = nil :: PointLight?

	if expConfig.FireBall.Path then
		local clones = self:_cloneFromPaths(expConfig.FireBall, position, expConfig.FireBall.Lifetime)
		fireball = clones[1] -- referencia para cleanup tracking
	else
		local fb = Instance.new("Part")
		fb.Name = "ExplosionFireball"
		fb.Shape = Enum.PartType.Ball
		fb.Size = Vector3.one * (radius * 0.3)
		fb.Position = position
		fb.Anchored = true
		fb.CanCollide = false
		fb.CanQuery = false
		fb.CanTouch = false
		fb.Material = Enum.Material.Neon
		fb.Color = expConfig.FireBall.Color
		fb.Transparency = 0.2
		fb.Parent = Workspace
		fireball = fb

		light = Instance.new("PointLight")
		light.Color = expConfig.FireBall.Color
		light.Range = radius * 2
		light.Brightness = 5
		light.Parent = fb

		local fireEmitter = Instance.new("ParticleEmitter")
		fireEmitter.Rate = 0
		fireEmitter.Enabled = false
		fireEmitter.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, expConfig.FireBall.Color),
			ColorSequenceKeypoint.new(1, expConfig.FireBall.SecondaryColor),
		})
		fireEmitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, radius * 0.2),
			NumberSequenceKeypoint.new(0.5, radius * 0.5),
			NumberSequenceKeypoint.new(1, radius * 0.1),
		})
		fireEmitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.7, 0.5),
			NumberSequenceKeypoint.new(1, 1),
		})
		fireEmitter.Lifetime = NumberRange.new(0.3, expConfig.FireBall.Lifetime)
		fireEmitter.Speed = NumberRange.new(expConfig.FireBall.Speed * 0.5, expConfig.FireBall.Speed)
		fireEmitter.SpreadAngle = Vector2.new(180, 180)
		fireEmitter.LightEmission = 1
		fireEmitter.LightInfluence = 0
		fireEmitter.Parent = fb
		fireEmitter:Emit(expConfig.FireBall.ParticleCount)
	end

	-- Shockwave ring
	local ring = nil :: Instance?

	if expConfig.ShockwaveRing.Path then
		local clones = self:_cloneFromPaths(expConfig.ShockwaveRing, position, expConfig.ShockwaveRing.Duration or 0.3)
		ring = clones[1]
	else
		local r = Instance.new("Part")
		r.Name = "ShockwaveRing"
		r.Shape = Enum.PartType.Cylinder
		r.Size = Vector3.new(0.1, radius * 0.3, radius * 0.3)
		r.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
		r.Anchored = true
		r.CanCollide = false
		r.CanQuery = false
		r.CanTouch = false
		r.Material = Enum.Material.Neon
		r.Color = expConfig.ShockwaveRing.Color
		r.Transparency = expConfig.ShockwaveRing.Transparency
		r.Parent = Workspace
		ring = r

		-- Animación: expandir shockwave ring
		local ringDuration = expConfig.ShockwaveRing.Duration
		local maxScale = expConfig.ShockwaveRing.MaxScale
		local finalDiameter = radius * 2 * maxScale

		task.spawn(function()
			local elapsed = 0
			while elapsed < ringDuration do
				local dt = task.wait()
				elapsed += dt
				local t = math.min(elapsed / ringDuration, 1)
				local currentSize = radius * 0.3 + (finalDiameter - radius * 0.3) * t
				r.Size = Vector3.new(0.1 + t * 0.3, currentSize, currentSize)
				r.Transparency = expConfig.ShockwaveRing.Transparency + (1 - expConfig.ShockwaveRing.Transparency) * t
			end
		end)
	end

	-- Debris
	local debrisPart = nil :: Instance?

	if expConfig.Debris.Path then
		local clones = self:_cloneFromPaths(expConfig.Debris, position, expConfig.Debris.Lifetime)
		debrisPart = clones[1]
	else
		local dp = Instance.new("Part")
		dp.Name = "ExplosionDebris"
		dp.Size = Vector3.new(0.1, 0.1, 0.1)
		dp.Position = position
		dp.Anchored = true
		dp.CanCollide = false
		dp.CanQuery = false
		dp.CanTouch = false
		dp.Transparency = 1
		dp.Parent = Workspace
		debrisPart = dp

		local debrisEmitter = Instance.new("ParticleEmitter")
		debrisEmitter.Rate = 0
		debrisEmitter.Enabled = false
		debrisEmitter.Color = ColorSequence.new(expConfig.Debris.Color)
		debrisEmitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 0.1),
		})
		debrisEmitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.8, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		})
		debrisEmitter.Lifetime = NumberRange.new(0.8, expConfig.Debris.Lifetime)
		debrisEmitter.Speed = NumberRange.new(expConfig.Debris.Speed * 0.5, expConfig.Debris.Speed)
		debrisEmitter.SpreadAngle = Vector2.new(expConfig.Debris.Spread, expConfig.Debris.Spread)
		debrisEmitter.RotSpeed = NumberRange.new(-360, 360)
		debrisEmitter.Parent = dp
		debrisEmitter:Emit(expConfig.Debris.Count)
	end

	-- Fade fireball (solo si fue creado por código, no Path)
	if not expConfig.FireBall.Path and fireball and fireball:IsA("BasePart") then
		task.spawn(function()
			local elapsed = 0
			local duration = expConfig.FireBall.Lifetime
			while elapsed < duration do
				local dt = task.wait()
				elapsed += dt
				local t = math.min(elapsed / duration, 1)
				fireball.Transparency = 0.2 + 0.8 * t
				if light then
					light.Brightness = 5 * (1 - t)
				end
			end
		end)
	end

	-- Cleanup
	local ringDuration = expConfig.ShockwaveRing.Duration or 0.3
	local cleanupTime = math.max(expConfig.FireBall.Lifetime, expConfig.Debris.Lifetime, ringDuration) + 0.5
	task.delay(cleanupTime, function()
		if fireball then
			fireball:Destroy()
		end
		if ring then
			ring:Destroy()
		end
		if debrisPart then
			debrisPart:Destroy()
		end
		self._activeCount = math.max(self._activeCount - 1, 0)
	end)
end

return ExplosionEffect
