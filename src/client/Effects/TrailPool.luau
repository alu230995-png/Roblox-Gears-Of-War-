--[[
	TrailPool.luau
	═══════════════════════════════════════════════════════════════
	Pool reutilizable de Beams para bullet trails.
	═══════════════════════════════════════════════════════════════

	Cada trail es un Part con dos Attachments y un Beam.
	Fire() posiciona origin→destination, fade automático.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConstants = require(Shared:WaitForChild("EffectsConstants"))

local TrailPool = {}
TrailPool.__index = TrailPool

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function TrailPool.new(maxSize: number)
	local self = setmetatable({}, TrailPool)

	self._maxSize = maxSize or 12
	self._available = {} :: { Part }
	self._active = {} :: { [Part]: true }
	self._folder = nil :: Folder?

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function TrailPool:Init()
	self._folder = Instance.new("Folder")
	self._folder.Name = "EffectsTrailPool"
	self._folder.Parent = Workspace

	for _ = 1, self._maxSize do
		local part = self:_createTrailPart()
		table.insert(self._available, part)
	end
end

function TrailPool:Destroy()
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

function TrailPool:Fire(
	origin: Vector3,
	destination: Vector3,
	config: {
		Path: (string | { string })?,
		PathDelay: number?,
		Width: number,
		Lifetime: number,
		Color: Color3,
		FadeTime: number,
	}
)
	-- Si config tiene Path, clonar instancia(s) pre-hecha(s) (ignora otros params)
	if config.Path then
		local paths = EffectsConstants.NormalizePaths(config.Path)
		if paths then
			local pathDelay = config.PathDelay or 0
			local lifetime = config.Lifetime or 0.3
			if pathDelay > 0 and #paths > 1 then
				task.spawn(function()
					for i, p in paths do
						if i > 1 then
							task.wait(pathDelay)
						end
						self:_fireFromPath(origin, destination, p, lifetime)
					end
				end)
			else
				for _, p in paths do
					self:_fireFromPath(origin, destination, p, lifetime)
				end
			end
		end
		return
	end

	local part = table.remove(self._available)
	if not part then
		return
	end

	self._active[part] = true

	-- Calcular posición media y orientación
	local mid = (origin + destination) * 0.5
	local distance = (destination - origin).Magnitude
	part.CFrame = CFrame.lookAt(mid, destination)
	part.Size = Vector3.new(0.1, 0.1, distance)

	-- Posicionar attachments en los extremos
	local a0 = part:FindFirstChild("A0") :: Attachment
	local a1 = part:FindFirstChild("A1") :: Attachment
	if a0 and a1 then
		a0.Position = Vector3.new(0, 0, -distance * 0.5)
		a1.Position = Vector3.new(0, 0, distance * 0.5)
	end

	-- Configurar beam
	local beam = part:FindFirstChildWhichIsA("Beam")
	if beam then
		beam.Color = ColorSequence.new(config.Color)
		beam.Width0 = config.Width
		beam.Width1 = config.Width * 0.3
		beam.Transparency = NumberSequence.new(0)
		beam.Enabled = true
	end

	-- Fade out y release
	local fadeTime = config.FadeTime or 0.1
	local totalTime = config.Lifetime or 0.3

	task.delay(totalTime - fadeTime, function()
		if beam and beam.Parent then
			-- Fade rápido
			beam.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.5),
				NumberSequenceKeypoint.new(1, 1),
			})
		end
	end)

	task.delay(totalTime, function()
		self:_release(part)
	end)
end

------------------------------------------------------------------------
-- PRIVATE
------------------------------------------------------------------------

function TrailPool:_fireFromPath(origin: Vector3, destination: Vector3, path: string, lifetime: number)
	local template = EffectsConstants.ResolvePath(path)
	if not template then
		warn("[TrailPool] Path not found: " .. path)
		return
	end

	local clone = template:Clone()

	-- Orientación: LookVector apunta de origin → destination
	local mid = (origin + destination) * 0.5
	if clone:IsA("BasePart") then
		local distance = (destination - origin).Magnitude
		clone.CFrame = CFrame.lookAt(mid, destination)
		clone.Size = Vector3.new(clone.Size.X, clone.Size.Y, distance)

		-- Ajustar attachments si existen
		local a0 = clone:FindFirstChild("A0") :: Attachment?
		local a1 = clone:FindFirstChild("A1") :: Attachment?
		if a0 and a1 then
			a0.Position = Vector3.new(0, 0, -distance * 0.5)
			a1.Position = Vector3.new(0, 0, distance * 0.5)
		end

		-- Habilitar beams/trails (estos SÍ usan Enabled)
		for _, child in clone:GetDescendants() do
			if child:IsA("Beam") or child:IsA("Trail") then
				child.Enabled = true
			end
		end

		-- ParticleEmitters: burst con Emit (NO Enabled)
		EffectsConstants.EmitAll(clone)

		clone.Parent = self._folder
	elseif clone:IsA("Model") then
		clone:PivotTo(CFrame.lookAt(mid, destination))
		clone.Parent = self._folder
		EffectsConstants.EmitAll(clone)
	else
		clone.Parent = self._folder
	end

	task.delay(lifetime + 0.2, function()
		clone:Destroy()
	end)
end

function TrailPool:_release(part: Part)
	if not self._active[part] then
		return
	end
	self._active[part] = nil

	local beam = part:FindFirstChildWhichIsA("Beam")
	if beam then
		beam.Enabled = false
	end

	part.CFrame = CFrame.new(0, -1000, 0)
	table.insert(self._available, part)
end

function TrailPool:_createTrailPart(): Part
	local part = Instance.new("Part")
	part.Name = "PoolTrail"
	part.Size = Vector3.new(0.1, 0.1, 0.1)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1

	local a0 = Instance.new("Attachment")
	a0.Name = "A0"
	a0.Parent = part

	local a1 = Instance.new("Attachment")
	a1.Name = "A1"
	a1.Parent = part

	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.LightEmission = 0.8
	beam.LightInfluence = 0
	beam.Segments = 1
	beam.Enabled = false
	beam.Parent = part

	part.CFrame = CFrame.new(0, -1000, 0)
	part.Parent = self._folder

	return part
end

return TrailPool
