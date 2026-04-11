--[[
	SoundPlayer.luau
	═══════════════════════════════════════════════════════════════
	Motor de reproducción de sonido de bajo nivel.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades:
	  - Crear y cachear instancias de Sound por asset ID
	  - Reproducir sonidos según SoundConfig (random/secuencial, looped, pitch)
	  - Manejar sonido 2D (Player) y 3D posicional (Global)
	  - Pool de sonidos para evitar crear/destruir instancias cada frame
	  - Controlar volumen por grupo (VFX, Ambient, Music, Server)
	
	NO decide CUÁNDO reproducir — eso lo decide SoundController.
	Solo ejecuta: "reproduce este sonido con estos parámetros".
	
	Arquitectura:
	  SoundController → SoundPlayer.Play(soundName, position?)
	  SoundPlayer consulta SoundConfig, elige Id, crea/reutiliza Sound, reproduce.
]]

local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))

local SoundPlayer = {}
SoundPlayer.__index = SoundPlayer

------------------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------------------

local DEFAULT_MAX_DISTANCE = 100
local POOL_MAX_PER_SOUND = 8

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function SoundPlayer.new()
	local self = setmetatable({}, SoundPlayer)

	-- Volumen master por grupo (0..1)
	self._groupVolumes = {
		VFX = 1,
		Ambient = 1,
		Music = 1,
		Server = 1,
	}

	-- Índice secuencial por soundName para modo Random=false
	self._sequentialIndex = {} -- { [string]: number }

	-- Pool de Sound instances reutilizables: { [assetId] = { Sound } }
	self._pool = {} -- { [string]: { Sound } }

	-- Sonidos looped activos: { [soundName] = Sound }
	self._loopedSounds = {} -- { [string]: Sound }

	-- Contenedores en SoundService para organizar sonidos
	self._containers = {}

	return self
end

------------------------------------------------------------------------
-- INIT / START (compatibles con ServiceLocator)
------------------------------------------------------------------------

function SoundPlayer:Init()
	-- Crear carpetas contenedoras bajo SoundService
	for _, groupName in { "VFX", "Ambient", "Music", "Server" } do
		local folder = Instance.new("Folder")
		folder.Name = groupName
		folder.Parent = SoundService
		self._containers[groupName] = folder
	end

	-- Precargar todos los assets de sonido para eliminar latencia de descarga
	self:_preloadAssets()
end

function SoundPlayer:Start()
	-- Sin conexiones propias
end

------------------------------------------------------------------------
-- VOLUMEN POR GRUPO
------------------------------------------------------------------------

--- Ajustar volumen de un grupo completo (0..1).
function SoundPlayer:SetGroupVolume(group: string, volume: number)
	self._groupVolumes[group] = math.clamp(volume, 0, 1)

	-- Actualizar sonidos looped activos de este grupo
	-- FIX: _loopedSounds ahora almacena { sound, assetId } en lugar de Sound directa
	for soundName, entry in self._loopedSounds do
		local config = SoundConfig[soundName]
		if config and config.Group == group then
			entry.sound.Volume = config.Volume * self._groupVolumes[group]
		end
	end
end

function SoundPlayer:GetGroupVolume(group: string): number
	return self._groupVolumes[group] or 1
end

------------------------------------------------------------------------
-- CORE: PLAY
------------------------------------------------------------------------

--- Reproduce un sonido por nombre (clave de SoundConfig).
--- @param soundName string — Clave en SoundConfig (ej: "VFX_Footstep_Concrete")
--- @param position Vector3? — Requerido para Scope="Global". Posición 3D del sonido.
function SoundPlayer:Play(soundName: string, position: Vector3?)
	local config = SoundConfig[soundName]
	if not config then
		warn(`[SoundPlayer] Sonido no encontrado en SoundConfig: {soundName}`)
		return
	end

	-- Seleccionar asset ID
	local assetId = self:_selectId(soundName, config)
	if not assetId then
		return
	end

	-- Obtener o crear instancia de Sound
	local sound = self:_acquireSound(assetId, config, soundName)
	if not sound then
		return
	end

	-- Configurar propiedades
	local groupVol = self._groupVolumes[config.Group] or 1
	sound.Volume = config.Volume * groupVol
	sound.Looped = config.Looped

	-- Pitch variation
	if config.PitchVariation and config.PitchVariation > 0 then
		local variation = (math.random() * 2 - 1) * config.PitchVariation
		sound.PlaybackSpeed = 1 + variation
	else
		sound.PlaybackSpeed = 1
	end

	-- Posicionamiento
	if config.Scope == "Global" then
		if not position then
			warn(`[SoundPlayer] Scope=Global requiere posición para: {soundName}`)
			return
		end
		self:_setupPositional(sound, position, config.MaxDistance or DEFAULT_MAX_DISTANCE)
	else
		self:_setupPlayer(sound)
	end

	-- Reproducir
	if config.Looped then
		-- Detener loop previo del mismo sonido si existe
		self:StopLooped(soundName)
		-- FIX: guardar { sound, assetId } para que StopLooped devuelva el sonido
		-- al pool correcto (assetId real, no siempre Ids[1]).
		self._loopedSounds[soundName] = { sound = sound, assetId = assetId }
		sound:Play()
	else
		sound:Play()
		-- Retornar al pool cuando termine (single listener handles both pool + emitter cleanup)
		sound.Ended:Once(function()
			-- Capture emitter before reparenting (if 3D positional)
			local parent = sound.Parent
			local emitter: Part? = nil
			if parent and parent:IsA("Part") and parent.Name == "SoundEmitter" then
				emitter = parent
			end

			self:_releaseSound(assetId, sound)

			-- Destroy emitter after sound was reparented away
			if emitter then
				emitter:Destroy()
			end
		end)
	end
end

------------------------------------------------------------------------
-- CORE: STOP LOOPED
------------------------------------------------------------------------

--- Detiene un sonido looped activo.
function SoundPlayer:StopLooped(soundName: string)
	local entry = self._loopedSounds[soundName]
	if entry then
		local sound = entry.sound
		local assetId = entry.assetId
		sound:Stop()
		self._loopedSounds[soundName] = nil

		-- Clean up emitter Part if sound was 3D positional
		local parent = sound.Parent
		local emitter: Part? = nil
		if parent and parent:IsA("Part") and parent.Name == "SoundEmitter" then
			emitter = parent
		end

		-- FIX: usar el assetId real capturado en Play(), no Ids[1] hardcodeado.
		if SoundConfig[soundName] then
			self:_releaseSound(assetId, sound)
		end

		if emitter then
			emitter:Destroy()
		end
	end
end

--- Detiene todos los sonidos looped de un grupo.
function SoundPlayer:StopGroupLooped(group: string)
	local toStop = {}
	for soundName, _ in self._loopedSounds do
		local config = SoundConfig[soundName]
		if config and config.Group == group then
			table.insert(toStop, soundName)
		end
	end
	for _, soundName in toStop do
		self:StopLooped(soundName)
	end
end

--- Detiene todos los sonidos looped.
function SoundPlayer:StopAllLooped()
	local toStop = {}
	for soundName, _ in self._loopedSounds do
		table.insert(toStop, soundName)
	end
	for _, soundName in toStop do
		self:StopLooped(soundName)
	end
end

------------------------------------------------------------------------
-- ID SELECTION (Random vs Sequential)
------------------------------------------------------------------------

function SoundPlayer:_selectId(
	soundName: string,
	config: { Ids: { string }, Random: boolean, Looped: boolean }
): string?
	local ids = config.Ids
	if #ids == 0 then
		warn(`[SoundPlayer] Tabla de Ids vacía para: {soundName}`)
		return nil
	end

	if #ids == 1 then
		return ids[1]
	end

	if config.Random then
		return ids[math.random(1, #ids)]
	else
		-- Secuencial: avanza uno cada vez
		local idx = (self._sequentialIndex[soundName] or 0) + 1
		if idx > #ids then
			idx = 1
		end
		self._sequentialIndex[soundName] = idx
		return ids[idx]
	end
end

------------------------------------------------------------------------
-- SOUND POOLING
------------------------------------------------------------------------

function SoundPlayer:_acquireSound(assetId: string, config: any, soundName: string): Sound?
	local pool = self._pool[assetId]
	if pool and #pool > 0 then
		local reused = table.remove(pool)
		reused.Name = soundName
		reused.SoundId = assetId
		return reused
	end

	-- Crear nueva instancia
	local sound = Instance.new("Sound")
	sound.SoundId = assetId
	sound.Name = soundName

	local container = self._containers[config.Group]
	if container then
		sound.Parent = container
	else
		sound.Parent = SoundService
	end

	return sound
end

function SoundPlayer:_releaseSound(assetId: string, sound: Sound)
	sound:Stop()

	-- Reparentar al contenedor del grupo
	local config = SoundConfig[sound.Name]
	local container = self._containers[config and config.Group or "VFX"] or SoundService
	sound.Parent = container

	if not self._pool[assetId] then
		self._pool[assetId] = {}
	end

	if #self._pool[assetId] < POOL_MAX_PER_SOUND then
		table.insert(self._pool[assetId], sound)
	else
		sound:Destroy()
	end
end

------------------------------------------------------------------------
-- POSITIONING
------------------------------------------------------------------------

--- Configura sonido 3D posicional usando un Part temporal como emisor.
function SoundPlayer:_setupPositional(sound: Sound, position: Vector3, maxDistance: number)
	-- Usar un Part invisible como emisor 3D
	local emitter = Instance.new("Part")
	emitter.Name = "SoundEmitter"
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.CanTouch = false
	emitter.Transparency = 1
	emitter.Size = Vector3.new(0.1, 0.1, 0.1)
	emitter.Position = position
	emitter.Parent = workspace

	sound.Parent = emitter
	sound.RollOffMode = Enum.RollOffMode.Linear
	sound.RollOffMinDistance = 5
	sound.RollOffMaxDistance = maxDistance
	-- Emitter cleanup is handled by the caller (Play/StopLooped)
end

--- Configura sonido 2D (Player scope) — directo en SoundService.
function SoundPlayer:_setupPlayer(sound: Sound)
	local config = SoundConfig[sound.Name]
	local container = self._containers[config and config.Group or "VFX"]
	sound.Parent = container or SoundService
	sound.RollOffMode = Enum.RollOffMode.Inverse
end

------------------------------------------------------------------------
-- CHARACTER-ATTACHED PLAYBACK (zero-alloc 3D)
------------------------------------------------------------------------

--- Reproduce un sonido directo en el HumanoidRootPart de un personaje.
--- NO crea Parts emisores. El sonido se mueve con el personaje.
--- Ideal para footsteps y sonidos frecuentes atados al jugador.
function SoundPlayer:PlayOnCharacter(soundName: string, character: Model)
	local config = SoundConfig[soundName]
	if not config then
		warn(`[SoundPlayer] Sonido no encontrado en SoundConfig: {soundName}`)
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	local assetId = self:_selectId(soundName, config)
	if not assetId then
		return
	end

	local sound = self:_acquireSound(assetId, config, soundName)
	if not sound then
		return
	end

	-- Configurar
	local groupVol = self._groupVolumes[config.Group] or 1
	sound.Volume = config.Volume * groupVol
	sound.Looped = false

	if config.PitchVariation and config.PitchVariation > 0 then
		local variation = (math.random() * 2 - 1) * config.PitchVariation
		sound.PlaybackSpeed = 1 + variation
	else
		sound.PlaybackSpeed = 1
	end

	-- Parentear directo al rootPart (3D natural, sin crear Parts)
	sound.Parent = rootPart
	sound.RollOffMode = Enum.RollOffMode.Linear
	sound.RollOffMinDistance = 5
	sound.RollOffMaxDistance = config.MaxDistance or 40

	sound:Play()
	sound.Ended:Once(function()
		self:_releaseSound(assetId, sound)
	end)
end

------------------------------------------------------------------------
-- ASSET PRELOADING
------------------------------------------------------------------------

--- Precarga todos los assets de SoundConfig para eliminar latencia de descarga.
function SoundPlayer:_preloadAssets()
	local preloadList = {}

	for _, config in SoundConfig do
		if type(config) == "table" and config.Ids then
			for _, assetId in config.Ids do
				if assetId ~= "rbxassetid://0" then
					local holder = Instance.new("Sound")
					holder.SoundId = assetId
					table.insert(preloadList, holder)
				end
			end
		end
	end

	if #preloadList > 0 then
		-- Precargar en background para no bloquear Init
		task.spawn(function()
			ContentProvider:PreloadAsync(preloadList)
			-- Limpiar holders temporales
			for _, holder in preloadList do
				holder:Destroy()
			end
		end)
	end
end

------------------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------------------

function SoundPlayer:Destroy()
	self:StopAllLooped()

	for _, pool in self._pool do
		for _, sound in pool do
			sound:Destroy()
		end
	end
	table.clear(self._pool)

	for _, folder in self._containers do
		folder:Destroy()
	end
	table.clear(self._containers)
end

return SoundPlayer
