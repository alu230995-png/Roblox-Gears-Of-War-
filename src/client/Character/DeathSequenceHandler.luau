--[[
	DeathSequenceHandler.luau
	═══════════════════════════════════════════════════════════════
	Orquestador de la secuencia de muerte del jugador local.
	═══════════════════════════════════════════════════════════════

	Flujo:
	  1. StateMachine entra en "Death"
	  2. Iniciar efecto de sangre (4 segundos)
	  3. Hooks se disparan: sonido de muerte, UI de "te mató X con Y"
	  4. Tras 4 segundos → transicionar a "Spectator"
	  5. Recibir countdown de respawn del servidor via RemoteEvent
	  6. Al respawnear → CharacterAdded / HealthObserver reseta a Idle

	Hooks expuestos (señales públicas):
	  - DeathStarted(killInfo) → para UI de kill feed, sonido, etc.
	  - SpectatorEntered() → para UI de espectador
	  - RespawnCountdownUpdated(timeRemaining, isGlobal) → para UI de timer

	Capa: Handler de acción (Capa 4)
	Depende de: StateMachine, EffectsController (BloodEffect)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Signal = require(Shared:WaitForChild("Signal"))

local DeathSequenceHandler = {}
DeathSequenceHandler.__index = DeathSequenceHandler

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function DeathSequenceHandler.new(stateMachine, effectsController)
	local self = setmetatable({}, DeathSequenceHandler)

	self._stateMachine = stateMachine
	self._effectsController = effectsController
	self._connections = {} :: { any }
	self._sequenceThread = nil :: thread?
	self._respawnRemote = nil :: RemoteEvent?

	--- Hook: se dispara al iniciar la secuencia de muerte.
	--- Payload: { KillerName: string?, KillerWeapon: string?, DeathType: string? }
	self.DeathStarted = Signal.new()

	--- Hook: se dispara al entrar en modo espectador.
	self.SpectatorEntered = Signal.new()

	--- Hook: se dispara cada tick del countdown de respawn.
	--- Payload: (timeRemaining: number, isGlobalCountdown: boolean)
	self.RespawnCountdownUpdated = Signal.new()

	--- Hook: se dispara justo antes del respawn.
	self.RespawnImminent = Signal.new()

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function DeathSequenceHandler:Init()
	-- Sin side-effects
end

function DeathSequenceHandler:Start()
	-- Escuchar entrada al estado Death
	self._connections.stateChanged = self._stateMachine.StateChanged:Connect(
		function(newState: string, _oldState: string)
			if newState == "Death" then
				self:_startDeathSequence()
			elseif newState == "Idle" and self._sequenceThread then
				-- Respawn: cancelar secuencia si aún corre
				self:_cancelSequence()
			end
		end
	)

	-- Conectar RemoteEvent del servidor para countdown de respawn
	task.spawn(function()
		local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if remotesFolder then
			self._respawnRemote = remotesFolder:WaitForChild("RespawnCountdown", 10) :: RemoteEvent?
			if self._respawnRemote then
				self._connections.respawnRemote = self._respawnRemote.OnClientEvent:Connect(function(data)
					self:_onRespawnCountdown(data)
				end)
			end
		end
	end)
end

function DeathSequenceHandler:Destroy()
	self:_cancelSequence()
	for _, conn in self._connections do
		if type(conn) == "table" and type(conn.Disconnect) == "function" then
			conn:Disconnect()
		elseif typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)
	self.DeathStarted:Destroy()
	self.SpectatorEntered:Destroy()
	self.RespawnCountdownUpdated:Destroy()
	self.RespawnImminent:Destroy()
end

------------------------------------------------------------------------
-- PRIVATE: Death sequence
------------------------------------------------------------------------

function DeathSequenceHandler:_startDeathSequence()
	-- Cancelar secuencia anterior si existe
	self:_cancelSequence()

	local localPlayer = Players.LocalPlayer
	local character = localPlayer.Character

	-- Leer kill info de atributos del character (escritos por HealthStateManager)
	local killInfo = {
		KillerName = character and character:GetAttribute("KillerName") or nil,
		KillerWeapon = character and character:GetAttribute("KillerWeapon") or nil,
		DeathType = character and character:GetAttribute("DeathType") or "Standard",
	}

	-- Hook: notificar muerte (para UI, sonido, kill feed)
	self.DeathStarted:Fire(killInfo)

	-- Iniciar secuencia: efecto de sangre → espera → espectador
	self._sequenceThread = task.spawn(function()
		-- Efecto de sangre ya lo maneja DeathEffectsHandler via LifeState.
		-- Aquí solo esperamos la duración del efecto antes de transicionar.
		task.wait(Constants.DEATH_BLOOD_EFFECT_DURATION)

		-- Guard: verificar que seguimos en Death (podría haber respawneado)
		local currentState = self._stateMachine:GetCurrentState()
		if currentState ~= "Death" then
			return
		end

		-- Transicionar a Spectator
		self._stateMachine:TransitionTo("Spectator")

		-- Hook: notificar entrada a espectador
		self.SpectatorEntered:Fire()

		self._sequenceThread = nil
	end)
end

function DeathSequenceHandler:_cancelSequence()
	if self._sequenceThread then
		task.cancel(self._sequenceThread)
		self._sequenceThread = nil
	end
end

------------------------------------------------------------------------
-- PRIVATE: Respawn countdown from server
------------------------------------------------------------------------

function DeathSequenceHandler:_onRespawnCountdown(data: any)
	if not data then
		return
	end

	local timeRemaining = data.TimeRemaining or 0
	local isGlobal = data.IsGlobalCountdown or false

	-- Hook: notificar UI
	self.RespawnCountdownUpdated:Fire(timeRemaining, isGlobal)

	-- Si el countdown llegó a 0, disparar hook de respawn inminente
	if timeRemaining <= 0 then
		self.RespawnImminent:Fire()
	end
end

return DeathSequenceHandler
