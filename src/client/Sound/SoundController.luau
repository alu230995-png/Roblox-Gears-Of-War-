--[[
	SoundController.luau
	═══════════════════════════════════════════════════════════════
	Controlador de sonido del cliente — 100% State-driven.
	═══════════════════════════════════════════════════════════════
	
	Arquitectura:
	  La StateMachine es el ÚNICO driver de sonidos de jugador.
	  StateChanged Signal → SoundController reacciona automáticamente.
	
	Categorías de sonido por estado:
	  ONE_SHOT  → Suena 1 vez al ENTRAR al estado (transiciones: Evade, Mantle, etc.)
	  TIMED     → Se repite a intervalos mientras estés en el estado (footsteps, breath)
	  LOOPED    → Loop continuo mientras estés en el estado (reservado para futuro)
	
	Playback:
	  Sonidos de jugador usan PlayOnCharacter → 3D atado al HumanoidRootPart.
	  NO se replican por red. Cada cliente corre su propio SoundController.
	  Sonidos de servidor (alarmas, rondas) se reciben vía RemoteEvent aparte.
	
	Signals expuestos:
	  SoundPlayed(soundName) → Para que otros sistemas reaccionen (cámara, UI, etc.)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))
local Signal = require(Shared:WaitForChild("Signal"))

local SoundPlayer = require(script.Parent.SoundPlayer)
local RobloxSoundDisabler = require(script.Parent.RobloxSoundDisabler)

------------------------------------------------------------------------
-- FOOTSTEP CONSTANTS
------------------------------------------------------------------------

-- Velocidad horizontal mínima (studs/s) para considerar que el personaje se mueve.
-- Usa AssemblyLinearVelocity en vez de MoveDirection para detectar
-- movimiento real (funciona con RoadieRun que usa velocidad directa).
local VELOCITY_MOVE_THRESHOLD = 1.0

-- Clave especial: timers con este sonido se resuelven al material del suelo
local FOOTSTEP_SOUND_KEY = "VFX_Footstep_Default"

local SoundController = {}
SoundController.__index = SoundController

------------------------------------------------------------------------
-- REMOTE EVENT NAMES (solo para sonidos del servidor)
------------------------------------------------------------------------

local REMOTE_SOUND_FROM_SERVER = "SoundFromServer"
local REMOTE_SOUND_REPLICATE = "SoundReplicate"

------------------------------------------------------------------------
-- SOUND DISPATCH TABLES — State Machine es el dueño
------------------------------------------------------------------------

--- ONE_SHOT: suena 1 vez al entrar al estado. Estados de transición.
local STATE_ONE_SHOT = {
	CoverEntering = "VFX_CoverEnter",
	CoverSlide = "VFX_CoverSlide",
	CoverExiting = "VFX_CoverExit",
	CoverSwap = "VFX_CoverSwap",
	Evading = "VFX_Evade_Roll",
	Mantling = "VFX_Mantle",
	Vaulting = "VFX_Vault",
	DBNO = "VFX_DBNO_Down",
	Executing = "VFX_Execution",
}

--- TRANSITION_ONE_SHOT: suena 1 vez al entrar al estado SOLO si vienes de un estado específico.
--- Key = newState, Value = { [oldState] = soundName }
local TRANSITION_ONE_SHOT = {
	CoverIdle = {
		CoverEntering = "VFX_CoverImpact",
	},
}

--- TIMED: se repiten a intervalos fijos mientras permaneces en el estado.
--- Cada estado puede tener múltiples sonidos concurrentes (footsteps + breath).
local STATE_TIMED = {
	Walking = {
		{ sound = "VFX_Footstep_Default", interval = 0.45 },
	},
	CoverWalking = {
		{ sound = "VFX_Footstep_Default", interval = 0.55 },
	},
	CoverRunning = {
		{ sound = "VFX_Footstep_Default", interval = 0.35 },
	},
	RoadieRun = {
		{ sound = "VFX_Footstep_Default", interval = 0.28 },
		{ sound = "VFX_RoadieRun_Breath", interval = 1.2 },
	},
}

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function SoundController.new(stateMachine: any, _actionResolver: any)
	local self = setmetatable({}, SoundController)

	self._stateMachine = stateMachine
	self._soundPlayer = SoundPlayer.new()
	self._connections = {}

	-- Remote para sonidos del servidor (alarmas, rondas)
	self._remoteFromServer = nil
	self._remoteReplicate = nil

	-- Signal para que otros sistemas escuchen reproducciones
	self.SoundPlayed = Signal.new()

	-- Timers activos para el estado actual: { { sound, interval, elapsed } }
	self._activeTimers = {}

	-- Cached character references (updated on CharacterAdded)
	self._character = nil :: Model?
	self._hrp = nil :: BasePart?
	self._humanoid = nil :: Humanoid?

	return self
end

------------------------------------------------------------------------
-- INIT / START / DESTROY
------------------------------------------------------------------------

function SoundController:Init()
	RobloxSoundDisabler.Disable()
	self._soundPlayer:Init()
end

function SoundController:Start()
	self._soundPlayer:Start()
	self:_setupCharacterCache()
	self:_connectStateSignal()
	self:_connectHeartbeat()
	self:_connectServerRemote()
end

function SoundController:Destroy()
	for _, conn in self._connections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif conn.Disconnect then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)
	table.clear(self._activeTimers)

	self.SoundPlayed:Destroy()
	self._soundPlayer:Destroy()
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Reproduce un sonido localmente (para uso directo desde otros sistemas).
function SoundController:PlayLocal(soundName: string, position: Vector3?)
	self._soundPlayer:Play(soundName, position)
	self.SoundPlayed:Fire(soundName)
end

--- Detiene un sonido looped.
function SoundController:StopLooped(soundName: string)
	self._soundPlayer:StopLooped(soundName)
end

--- Ajustar volumen de un grupo (0..1).
function SoundController:SetGroupVolume(group: string, volume: number)
	self._soundPlayer:SetGroupVolume(group, volume)
end

--- Acceso al SoundPlayer para uso avanzado.
function SoundController:GetSoundPlayer()
	return self._soundPlayer
end

------------------------------------------------------------------------
-- CHARACTER CACHE — avoid FindFirstChild per frame
------------------------------------------------------------------------

function SoundController:_setupCharacterCache()
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	local function cacheCharacter(character: Model?)
		if character then
			self._character = character
			self._hrp = character:WaitForChild("HumanoidRootPart", 5) :: BasePart?
			self._humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
		else
			self._character = nil
			self._hrp = nil
			self._humanoid = nil
		end
	end

	-- Cache current character
	cacheCharacter(localPlayer.Character)

	-- Update cache on respawn
	local conn = localPlayer.CharacterAdded:Connect(function(character)
		cacheCharacter(character)
	end)
	table.insert(self._connections, conn)

	local removeConn = localPlayer.CharacterRemoving:Connect(function()
		self._character = nil
		self._hrp = nil
		self._humanoid = nil
	end)
	table.insert(self._connections, removeConn)
end

------------------------------------------------------------------------
-- STATE SIGNAL — Único driver de sonidos de jugador
------------------------------------------------------------------------

function SoundController:_connectStateSignal()
	if not (self._stateMachine and self._stateMachine.StateChanged) then
		return
	end

	local conn = self._stateMachine.StateChanged:Connect(function(newState: string, oldState: string)
		self:_onStateChanged(newState, oldState)
	end)
	table.insert(self._connections, conn)
end

function SoundController:_onStateChanged(newState: string, oldState: string)
	-- 1. Detener timers del estado anterior
	table.clear(self._activeTimers)

	-- 2. One-shot del nuevo estado
	local oneShot = STATE_ONE_SHOT[newState]
	if oneShot then
		self:_playOnLocalCharacter(oneShot)
	end

	-- 3. Transition-specific one-shot (e.g. wall impact on CoverEntering → CoverIdle)
	local transitionMap = TRANSITION_ONE_SHOT[newState]
	if transitionMap then
		local transSound = transitionMap[oldState]
		if transSound then
			self:_playOnLocalCharacter(transSound)
		end
	end

	-- 4. Iniciar timers del nuevo estado
	local timedConfig = STATE_TIMED[newState]
	if timedConfig then
		for _, entry in timedConfig do
			table.insert(self._activeTimers, {
				sound = entry.sound,
				interval = entry.interval,
				elapsed = entry.interval, -- primer sonido inmediato
			})
		end
	end
end

------------------------------------------------------------------------
-- HEARTBEAT — Actualizar timers activos
------------------------------------------------------------------------

function SoundController:_connectHeartbeat()
	local conn = RunService.Heartbeat:Connect(function(dt: number)
		self:_updateTimers(dt)
	end)
	table.insert(self._connections, conn)
end

function SoundController:_updateTimers(dt: number)
	if #self._activeTimers == 0 then
		return
	end

	local hrp = self._hrp
	if not hrp then
		return
	end

	-- Avoid Vector3 allocation: compute horizontal speed with math.sqrt
	local vel = hrp.AssemblyLinearVelocity
	local horizontalSpeed = math.sqrt(vel.X * vel.X + vel.Z * vel.Z)

	if horizontalSpeed < VELOCITY_MOVE_THRESHOLD then
		return
	end

	for _, timer in self._activeTimers do
		timer.elapsed += dt
		if timer.elapsed >= timer.interval then
			timer.elapsed -= timer.interval
			local resolvedSound = self:_resolveFootstepSound(timer.sound)
			self:_playOnLocalCharacter(resolvedSound)
		end
	end
end

------------------------------------------------------------------------
-- SERVER REMOTE — Solo para sonidos iniciados por el servidor
------------------------------------------------------------------------

function SoundController:_connectServerRemote()
	local remoteFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remoteFolder then
		remoteFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
	end
	if not remoteFolder then
		return
	end

	self._remoteFromServer = remoteFolder:WaitForChild(REMOTE_SOUND_FROM_SERVER, 5)
	self._remoteReplicate = remoteFolder:WaitForChild(REMOTE_SOUND_REPLICATE, 5)

	local function connectRemote(remote: RemoteEvent?)
		if not remote then
			return
		end

		local conn = remote.OnClientEvent:Connect(function(soundName: string, position: Vector3?)
			if not SoundConfig[soundName] then
				return
			end
			self._soundPlayer:Play(soundName, position)
			self.SoundPlayed:Fire(soundName)
		end)
		table.insert(self._connections, conn)
	end

	connectRemote(self._remoteFromServer)
	connectRemote(self._remoteReplicate)
end

------------------------------------------------------------------------
-- FLOOR MATERIAL DETECTION
------------------------------------------------------------------------

--- Retorna el material del suelo usando Humanoid.FloorMaterial.
function SoundController:_getFloorMaterial(): Enum.Material?
	local humanoid = self._humanoid
	if not humanoid then
		return nil
	end
	local mat = humanoid.FloorMaterial
	if mat == Enum.Material.Air then
		return nil
	end
	return mat
end

--- Resuelve el nombre del sonido de pasos según el material del suelo.
--- Si el sonido no es un footstep (no es FOOTSTEP_SOUND_KEY), lo devuelve sin cambios.
function SoundController:_resolveFootstepSound(soundKey: string): string
	if soundKey ~= FOOTSTEP_SOUND_KEY then
		return soundKey
	end

	local material = self:_getFloorMaterial()
	if material then
		local materialMap = SoundConfig.FootstepMaterialMap
		if materialMap and materialMap[material] then
			return materialMap[material]
		end
	end

	return FOOTSTEP_SOUND_KEY -- Fallback al default
end

------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------

--- Reproduce un sonido 3D atado al personaje local.
function SoundController:_playOnLocalCharacter(soundName: string)
	local character = self._character
	if not character then
		return
	end
	self._soundPlayer:PlayOnCharacter(soundName, character)
	self.SoundPlayed:Fire(soundName)
end

return SoundController
