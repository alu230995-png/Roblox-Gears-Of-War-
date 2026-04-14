--[[
	ParticlePool.luau
	═══════════════════════════════════════════════════════════════
	Pool reutilizable de ParticleEmitters en Parts invisibles.
	═══════════════════════════════════════════════════════════════

	Evita crear/destruir Parts por cada impacto. Cada Part tiene
	un ParticleEmitter hijo. Al adquirir, posiciona y emite.
	Al liberar, devuelve al pool. Auto-release vía task.delay.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConstants = require(Shared:WaitForChild("EffectsConstants"))

local ParticlePool = {}
ParticlePool.__index = ParticlePool

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function ParticlePool.new(maxSize: number)
	local self = setmetatable({}, ParticlePool)

	self._maxSize = maxSize or 20
	self._available = {} :: { Part }
	self._active = {} :: { [Part]: true }
	self._folder = nil :: Folder?

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function ParticlePool:Init()
	self._folder = Instance.new("Folder")
	self._folder.Name = "EffectsParticlePool"
	self._folder.Parent = Workspace

	for _ = 1, self._maxSize do
		local part = self:_createPoolPart()
		table.insert(self._available, part)
	end
end

function ParticlePool:Destroy()
	for part in self._active do
		part:Destroy()
	end
	for _, part in self._available do
		part:Destroy()
	end
	table.clear(self._active)
	table.clear(self._available)

	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function ParticlePool:Acquire(
	position: Vector3,
	normal: Vector3?,
	config: {
		Path: (string | { string })?,
		PathDelay: number?,
		ParticleCount: number,
		Spread: number,
		Lifetime: number,
		Speed: number,
		Color: Color3,
	}
): Part?
	-- Si config tiene Path, clonar instancia(s) pre-hecha(s) (ignora otros params)
	if config.Path then
		local paths = EffectsConstants.NormalizePaths(config.Path)
		if paths then
			local pathDelay = config.PathDelay or 0
			if pathDelay > 0 and #paths > 1 then
				-- Secuencial con delay: spawn para no bloquear
				task.spawn(function()
					for i, p in paths do
						if i > 1 then
							task.wait(pathDelay)
						end
						self:_acquireFromPath(position, normal, p, config.Lifetime or 1, config.ParticleCount)
					end
				end)
			else
				-- Todos simultáneos
				for _, p in paths do
					self:_acquireFromPath(position, normal, p, config.Lifetime or 1, config.ParticleCount)
				end
			end
		end
		return nil
	end

	local part = table.remove(self._available)
	if not part then
		if self._maxSize > 0 then
			part = self:_createPoolPart()
		else
			return nil
		end
	end

	self._active[part] = true

	-- Posicionar
	local lookDir = normal or Vector3.yAxis
	part.CFrame = CFrame.lookAt(position, position + lookDir)

	-- Configurar emitter
	local emitter = part:FindFirstChildWhichIsA("ParticleEmitter")
	if emitter then
		emitter.Color = ColorSequence.new(config.Color)
		emitter.Lifetime = NumberRange.new(config.Lifetime * 0.5, config.Lifetime)
		emitter.Speed = NumberRange.new(config.Speed * 0.5, config.Speed)
		emitter.SpreadAngle = Vector2.new(config.Spread, config.Spread)
		emitter.Enabled = false
		emitter:Emit(config.ParticleCount)
	end

	-- Auto-release
	task.delay(config.Lifetime + 0.1, function()
		self:Release(part)
	end)

	return part
end

function ParticlePool:Release(part: Part)
	if not self._active[part] then
		return
	end
	self._active[part] = nil

	-- Reset
	local emitter = part:FindFirstChildWhichIsA("ParticleEmitter")
	if emitter then
		emitter:Clear()
		emitter.Enabled = false
	end

	part.CFrame = CFrame.new(0, -1000, 0)
	table.insert(self._available, part)
end

------------------------------------------------------------------------
-- PRIVATE
------------------------------------------------------------------------

function ParticlePool:_acquireFromPath(position: Vector3, normal: Vector3?, path: string, lifetime: number, particleCount: number?): Part?
	local template = EffectsConstants.ResolvePath(path)
	if not template then
		warn("[ParticlePool] Path not found: " .. path)
		return nil
	end

	local clone = template:Clone()

	-- Orientación inteligente:
	-- El LookVector (-Z / Front) del Part apunta en la dirección del normal.
	-- Así los emitters con EmissionDirection = Front salen hacia la superficie,
	-- y los que usan Top/Bottom/Left/Right quedan orientados correctamente.
	local lookDir = normal or Vector3.yAxis

	-- Si el template es un BasePart, posicionarlo y orientarlo
	if clone:IsA("BasePart") then
		clone.CFrame = CFrame.lookAt(position, position + lookDir)
		clone.Parent = self._folder

		-- Emit burst en todos los ParticleEmitters (NO Enabled)
		EffectsConstants.EmitAll(clone, particleCount)

		task.delay(lifetime + 0.5, function()
			clone:Destroy()
		end)
		return clone
	end

	-- Si es un Model u otro contenedor
	if clone:IsA("Model") then
		clone:PivotTo(CFrame.lookAt(position, position + lookDir))
		clone.Parent = self._folder

		EffectsConstants.EmitAll(clone, particleCount)

		task.delay(lifetime + 0.5, function()
			clone:Destroy()
		end)
		return clone:FindFirstChildWhichIsA("BasePart")
	end

	-- Fallback: si es un ParticleEmitter suelto, montarlo en un part del pool
	if clone:IsA("ParticleEmitter") then
		local part = table.remove(self._available)
		if not part then
			part = self:_createPoolPart()
		end
		self._active[part] = true

		-- Desactivar el emitter genérico del pool part
		local existingEmitter = part:FindFirstChildWhichIsA("ParticleEmitter")
		if existingEmitter then
			existingEmitter.Enabled = false
		end

		part.CFrame = CFrame.lookAt(position, position + lookDir)

		clone.Parent = part
		clone.Enabled = false
		local count = particleCount or clone:GetAttribute("EmitCount") or 1
		clone:Emit(count)

		task.delay(lifetime + 0.5, function()
			clone:Destroy()
			if existingEmitter then
				existingEmitter.Enabled = false
			end
			self:Release(part)
		end)
		return part
	end

	clone:Destroy()
	return nil
end

function ParticlePool:_createPoolPart(): Part
	local part = Instance.new("Part")
	part.Name = "PoolParticle"
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.CFrame = CFrame.new(0, -1000, 0)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Lifetime = NumberRange.new(0.5, 1.0)
	emitter.Speed = NumberRange.new(5, 10)
	emitter.SpreadAngle = Vector2.new(15, 15)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(1, 0.02),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.8, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Parent = part

	part.Parent = self._folder

	return part
end

return ParticlePool
