--[[
	BulletTrailEffect.luau
	═══════════════════════════════════════════════════════════════
	Efecto animado de disparo con 4 attachments y 2 beams:

	  Beam 1 (bullet): segmento de luz que viaja de
	          origin → destino simulando la bala en vuelo.
	  Beam 2 (smoke):  estela que se extiende desde origin
	          y luego se desvanece con fade.

	Config soportada en EffectsConfig.BulletTrail:
	  Path         (string?) – template del beam de bala (se clona)
	  SmokePath    (string?) – template del beam de humo (se clona)
	  ParticlePath (string?) – template de partícula brillo en A0
	  Speed        (number)  – studs/s de la bala          [def 100]
	  TrailDelay   (number)  – seg antes de que A0 llegue, A1 sale [def 0.2]
	  HoldTime     (number)  – segundos que mantiene smoke  [def 0.4]
	  SmokeColor   (Color3)  – color del beam de humo       [gris]
	  SmokeWidth   (number)  – grosor del beam de humo      [0.04]

	Animación:
	  A0 (HEAD)  – viaja lineal origin→destino en travelTime.
	  A1 (TAIL)  – sale TrailDelay seg después de A0, misma velocidad
	               lineal (siempre a distancia fija detrás de A0).
	  A2         – sale al mismo tiempo que A1, sigue su posición.
	  A3         – permanece en origin.
	  Bullet     – beam A0→A1 se desactiva al llegar A1 (sin fade).
	  Smoke      – beam A2→A3 se estira desde origin; al finalizar
	               se desvanece (width→0, A3→dest).
	  Particle   – si ParticlePath, se clona un ParticleEmitter en A0
	               que queda Enabled; al llegar A0 a destino se hace
	               fade rápido (Enabled=false, las partículas vivas mueren
	               con su Lifetime natural).

	Si Path/SmokePath existe, se clona la instancia y se usa su
	Beam con todas sus propiedades visuales (Texture, Color, etc.)
	reasignando los Attachments animados. Si no existe, se crea
	el Beam desde código con los parámetros de config.
	═══════════════════════════════════════════════════════════════
]]

local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConfig = require(Shared:WaitForChild("EffectsConfig"))
local EffectsConstants = require(Shared:WaitForChild("EffectsConstants"))

local BulletTrailEffect = {}
BulletTrailEffect.__index = BulletTrailEffect

------------------------------------------------------------------------
-- DEFAULTS
------------------------------------------------------------------------

local DEFAULT_SPEED = 250 -- studs/s de la bala (se usa para calcular travelTime)
local DEFAULT_TRAIL_DELAY = 0.4
local DEFAULT_HOLD_TIME = 0.4
local DEFAULT_FADE_TIME = 0.3
local DEFAULT_BULLET_COLOR = Color3.fromRGB(255, 220, 100)
local DEFAULT_SMOKE_COLOR = Color3.fromRGB(200, 200, 200)
local DEFAULT_BULLET_WIDTH = 0.06
local DEFAULT_SMOKE_WIDTH = 0.04
local PARTICLE_FADE_TIME = 0.15 -- fade rápido de partículas al llegar A0

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function BulletTrailEffect.new(_trailPool)
	local self = setmetatable({}, BulletTrailEffect)
	self._folder = nil :: Folder?
	return self
end

function BulletTrailEffect:Destroy()
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
end

------------------------------------------------------------------------
-- PRIVATE: lazy-create folder
------------------------------------------------------------------------

function BulletTrailEffect:_ensureFolder(): Folder
	if not self._folder then
		local folder = Instance.new("Folder")
		folder.Name = "BulletTrailEffects"
		folder.Parent = Workspace
		self._folder = folder
	end
	return self._folder
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function BulletTrailEffect:Fire(
	origin: Vector3,
	hitPositions: { [string]: Vector3 },
	weaponName: string,
	hasActiveReload: boolean?
)
	local weaponConfig = EffectsConfig.WEAPONS[weaponName]
	if not weaponConfig or not weaponConfig.BulletTrail then
		return
	end

	local trailConfig = weaponConfig.BulletTrail
	if hasActiveReload and weaponConfig.ActiveReloadEffects and weaponConfig.ActiveReloadEffects.BulletTrail then
		trailConfig = weaponConfig.ActiveReloadEffects.BulletTrail
	end

	for _, hitPos in hitPositions do
		task.spawn(function()
			self:_fireAnimatedTrail(origin, hitPos, trailConfig)
		end)
	end
end

------------------------------------------------------------------------
-- PRIVATE: clonar un Beam desde un Path y reasignar attachments
------------------------------------------------------------------------

function BulletTrailEffect:_cloneBeamFromPath(
	path: string,
	attach0: Attachment,
	attach1: Attachment,
	parent: Part
): Beam?
	local template = EffectsConstants.ResolvePath(path)
	if not template then
		warn("[BulletTrailEffect] Path not found: " .. path)
		return nil
	end

	local clone = template:Clone()

	-- Buscar el Beam (puede ser la instancia misma o un hijo)
	local beam: Beam? = nil
	if clone:IsA("Beam") then
		beam = clone
	else
		beam = clone:FindFirstChildWhichIsA("Beam", true)
	end

	if not beam then
		clone:Destroy()
		return nil
	end

	-- Reasignar attachments al beam clonado
	beam.Attachment0 = attach0
	beam.Attachment1 = attach1
	beam.Parent = parent

	-- Destruir la cáscara sobrante (el beam ya fue reparentado)
	if clone ~= beam then
		clone:Destroy()
	end

	return beam
end

------------------------------------------------------------------------
-- PRIVATE: obtener beams de bala (clonar Path(s) o crear desde código)
-- Devuelve siempre una tabla de Beams.
------------------------------------------------------------------------

function BulletTrailEffect:_obtainBulletBeams(
	config: { Path: (string | { string })?, [string]: any },
	a0: Attachment,
	a1: Attachment,
	parent: Part,
	bulletWidth: number,
	bulletColor: Color3
): { Beam }
	local paths = config.Path

	-- Tabla de paths→ clonar cada uno
	if type(paths) == "table" then
		local beams: { Beam } = {}
		for _, p in paths do
			local cloned = self:_cloneBeamFromPath(p, a0, a1, parent)
			if cloned then
				table.insert(beams, cloned)
			end
		end
		if #beams > 0 then
			return beams
		end
	end

	-- String sola→ un beam clonado
	if type(paths) == "string" then
		local cloned = self:_cloneBeamFromPath(paths, a0, a1, parent)
		if cloned then
			return { cloned }
		end
	end

	-- Fallback: crear desde código
	local beam = Instance.new("Beam")
	beam.Name = "BulletBeam"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Segments = 1
	beam.Width0 = bulletWidth * 0.4
	beam.Width1 = bulletWidth
	beam.Color = ColorSequence.new(bulletColor)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.2, 0),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	beam.Parent = parent
	return { beam }
end

------------------------------------------------------------------------
-- PRIVATE: obtener beam de humo (clonar SmokePath o crear desde código)
------------------------------------------------------------------------

function BulletTrailEffect:_obtainSmokeBeam(
	config: { SmokePath: string?, [string]: any },
	a2: Attachment,
	a3: Attachment,
	parent: Part,
	smokeWidth: number,
	smokeColor: Color3
): Beam
	if config.SmokePath then
		local cloned = self:_cloneBeamFromPath(config.SmokePath, a2, a3, parent)
		if cloned then
			return cloned
		end
	end

	local beam = Instance.new("Beam")
	beam.Name = "SmokeBeam"
	beam.Attachment0 = a2
	beam.Attachment1 = a3
	beam.FaceCamera = true
	beam.LightEmission = 0.2
	beam.LightInfluence = 0.3
	beam.Segments = 1
	beam.Width0 = smokeWidth
	beam.Width1 = smokeWidth * 0.5
	beam.Color = ColorSequence.new(smokeColor)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.5, 0.3),
		NumberSequenceKeypoint.new(1, 0.7),
	})
	beam.Parent = parent
	return beam
end

------------------------------------------------------------------------
-- PRIVATE: clonar partícula de brillo en un Attachment (Enabled)
------------------------------------------------------------------------

function BulletTrailEffect:_cloneParticleToAttachment(path: string, attachment: Attachment)
	local template = EffectsConstants.ResolvePath(path)
	if not template then
		warn("[BulletTrailEffect] ParticlePath not found: " .. path)
		return
	end

	local clone = template:Clone()

	if clone:IsA("ParticleEmitter") then
		clone.Enabled = true
		clone.Parent = attachment
		clone:Emit(clone:GetAttribute("InitialEmit") or 1)
		return
	end

	-- Si es un contenedor, buscar ParticleEmitters dentro
	for _, desc in clone:GetDescendants() do
		if desc:IsA("ParticleEmitter") then
			local p = desc:Clone()
			p.Enabled = true
			p.Parent = attachment
			p:Emit(p:GetAttribute("InitialEmit") or 1)
		end
	end
	clone:Destroy()
end

------------------------------------------------------------------------
-- PRIVATE: animated trail – 4 attachments + 2 beams
------------------------------------------------------------------------

function BulletTrailEffect:_fireAnimatedTrail(origin: Vector3, destination: Vector3, config: {
	Path: string?,
	SmokePath: string?,
	ParticlePath: string?,
	Color: Color3?,
	Width: number?,
	FadeTime: number?,
	Speed: number?,
	TrailDelay: number?,
	HoldTime: number?,
	SmokeColor: Color3?,
	SmokeWidth: number?,
})
	local distance = (destination - origin).Magnitude
	if distance < 0.5 then
		return
	end

	-- Config con defaults
	local speed = config.Speed or DEFAULT_SPEED
	local trailDelay = config.TrailDelay or DEFAULT_TRAIL_DELAY
	local holdTime = config.HoldTime or DEFAULT_HOLD_TIME
	local fadeTime = config.FadeTime or DEFAULT_FADE_TIME
	local bulletColor = config.Color or DEFAULT_BULLET_COLOR
	local smokeColor = config.SmokeColor or DEFAULT_SMOKE_COLOR
	local bulletWidth = config.Width or DEFAULT_BULLET_WIDTH
	local smokeWidth = config.SmokeWidth or DEFAULT_SMOKE_WIDTH

	local travelTime = distance / speed

	-- Part en origin (sin rotación → offset local = offset world)
	local part = Instance.new("Part")
	part.Name = "AnimTrail"
	part.Size = Vector3.new(0.05, 0.05, 0.05)
	part.CFrame = CFrame.new(origin)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1

	local targetOffset = destination - origin

	----------------------------------------------------------------
	-- 4 Attachments (todos nacen en origin = Vector3.zero)
	----------------------------------------------------------------

	local a0 = Instance.new("Attachment") -- HEAD (punta líder)
	a0.Name = "A0_Lead"
	a0.Position = Vector3.zero
	a0.Parent = part

	local a1 = Instance.new("Attachment") -- TAIL (cola, sale con delay)
	a1.Name = "A1_Trail"
	a1.Position = Vector3.zero
	a1.Parent = part

	local a2 = Instance.new("Attachment") -- punta del smoke (sigue a a1)
	a2.Name = "A2_SmokeLead"
	a2.Position = Vector3.zero
	a2.Parent = part

	local a3 = Instance.new("Attachment") -- ancla del smoke (queda en origin)
	a3.Name = "A3_SmokeAnchor"
	a3.Position = Vector3.zero
	a3.Parent = part

	----------------------------------------------------------------
	-- Particle de brillo en A0 (sigue la punta de la bala)
	----------------------------------------------------------------

	if config.ParticlePath then
		self:_cloneParticleToAttachment(config.ParticlePath, a0)
	end

	----------------------------------------------------------------
	-- Beam 1: luz de bala (a0 HEAD → a1 TAIL)
	----------------------------------------------------------------

	local bulletBeams = self:_obtainBulletBeams(config, a0, a1, part, bulletWidth, bulletColor)
	for _, b in bulletBeams do
		b.Enabled = true
	end

	----------------------------------------------------------------
	-- Beam 2: estela de humo (a2 smokeLead → a3 smokeAnchor)
	----------------------------------------------------------------

	local smokeBeam = self:_obtainSmokeBeam(config, a2, a3, part, smokeWidth, smokeColor)
	smokeBeam.Enabled = false

	part.Parent = self:_ensureFolder()

	----------------------------------------------------------------
	-- ANIMACIÓN
	----------------------------------------------------------------

	local tweenLinear = TweenInfo.new(travelTime, Enum.EasingStyle.Linear)

	-- 1) A0 (HEAD) sale inmediatamente lineal al destino
	TweenService:Create(a0, tweenLinear, { Position = targetOffset }):Play()

	-- 2) Cuando A0 llega (travelTime): fade rápido de partículas en A0
	task.delay(travelTime, function()
		if not part.Parent then
			return
		end
		for _, child in a0:GetChildren() do
			if child:IsA("ParticleEmitter") then
				-- Dejar de emitir; las partículas vivas mueren solas
				child.Enabled = false
				-- Fade: reducir Size a 0 rápidamente
				local originalSize = child.Size
				local fadeSteps = 8
				local stepDt = PARTICLE_FADE_TIME / fadeSteps
				task.spawn(function()
					for i = 1, fadeSteps do
						task.wait(stepDt)
						if not child.Parent then
							break
						end
						local scale = 1 - (i / fadeSteps)
						local keys = {}
						for _, kp in originalSize.Keypoints do
							table.insert(
								keys,
								NumberSequenceKeypoint.new(kp.Time, kp.Value * scale, kp.Envelope * scale)
							)
						end
						child.Size = NumberSequence.new(keys)
					end
				end)
			end
		end
	end)

	-- 3) TrailDelay después: A1 (TAIL) sale lineal misma velocidad + A2 lo sigue
	task.delay(trailDelay, function()
		if not part.Parent then
			return
		end

		smokeBeam.Enabled = true

		TweenService:Create(a2, tweenLinear, { Position = targetOffset }):Play()
		TweenService:Create(a1, tweenLinear, { Position = targetOffset }):Play()
	end)

	-- 4) A1 llega a destino en TrailDelay + travelTime → apagar bullet beams
	local tailArrival = trailDelay + travelTime

	task.delay(tailArrival + 0.05, function()
		if not part.Parent then
			return
		end
		for _, b in bulletBeams do
			b.Enabled = false
		end
	end)

	-- 5) Hold del smoke, luego fade (solo smoke se desvanece)
	task.delay(tailArrival + holdTime, function()
		if not part.Parent then
			return
		end

		local fadeTweenInfo = TweenInfo.new(fadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

		-- Reducir grosor a 0 y mover a3 hacia destino (smoke se encoge)
		TweenService:Create(smokeBeam, fadeTweenInfo, {
			Width0 = 0,
			Width1 = 0,
		}):Play()

		TweenService:Create(a3, fadeTweenInfo, { Position = targetOffset }):Play()

		-- Cleanup
		task.delay(fadeTime + 0.1, function()
			if part.Parent then
				part:Destroy()
			end
		end)
	end)
end

return BulletTrailEffect
