--[[
	AnimationController.luau
	═══════════════════════════════════════════════════════════════
	Controlador de animaciones basado en estado FSM
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades:
	  - Escuchar StateChanged del StateMachine → crossfade animaciones
	  - Escuchar ActionExecuted del MovementController → one-shot animations
	  - Gestionar AnimationTracks por estado (carga, play, stop, crossfade)

	Comunicación event-driven:
	  - Escucha StateMachine.StateChanged(newState, oldState)
	  - Escucha MovementController.ActionExecuted(action, targetState, data)
	  - No conoce la existencia de otros listeners de estos signals.
	
	FASE 4 — Skeleton funcional. Las AnimationTracks se implementarán
	cuando se tengan los assets de animación.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local AnimationController = {}
AnimationController.__index = AnimationController

function AnimationController.new(stateMachine, actionExecutedSignal)
	local self = setmetatable({}, AnimationController)

	self._stateMachine = stateMachine
	self._actionExecutedSignal = actionExecutedSignal

	-- Mapa de estado → AnimationTrack (se poblará con assets reales)
	self._stateAnimations = {}

	-- Track actualmente en reproducción
	self._currentTrack = nil
	self._currentState = nil

	-- Conexiones gestionadas (cleanup en Destroy)
	self._connections = {}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function AnimationController:Init()
	-- Sin side-effects — tracks se cargarán en Start o al tener character
end

function AnimationController:Start()
	-- Escuchar cambios de estado para crossfade
	self._connections.stateChanged = self._stateMachine.StateChanged:Connect(
		function(newState: string, oldState: string)
			self:_onStateChanged(newState, oldState)
		end
	)

	-- Escuchar acciones ejecutadas para one-shot animations (recoil, melee, etc.)
	self._connections.actionExecuted = self._actionExecutedSignal:Connect(
		function(action: string, _targetState: string?, _data: any?)
			self:_onActionResolved(action, _data)
		end
	)

	if Constants.DEBUG_MODE then
		print("[GoW Animation] AnimationController:Start() — listeners conectados")
	end
end

function AnimationController:Destroy()
	for _, conn in self._connections do
		conn.Disconnect()
	end
	table.clear(self._connections)

	self:_stopCurrentTrack()
	table.clear(self._stateAnimations)
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Registra un AnimationTrack para un estado específico.
--- Llamar después de obtener el Animator del character.
function AnimationController:RegisterStateAnimation(stateName: string, track: AnimationTrack)
	self._stateAnimations[stateName] = track
end

------------------------------------------------------------------------
-- INTERNAL: State Change Handler
------------------------------------------------------------------------

--- Crossfade al cambiar de estado FSM.
--- Detiene el track anterior y reproduce el del nuevo estado.
function AnimationController:_onStateChanged(newState: string, _oldState: string)
	if newState == self._currentState then
		return
	end

	self._currentState = newState

	-- Detener track anterior
	self:_stopCurrentTrack()

	-- Reproducir track del nuevo estado (si existe)
	local track = self._stateAnimations[newState]
	if track then
		track:Play(Constants.STATE_TRANSITION_TIME)
		self._currentTrack = track
	end

	if Constants.DEBUG_MODE then
		local hasTrack = track and "✓" or "—"
		print(`[GoW Animation] State → {newState} [{hasTrack}]`)
	end
end

------------------------------------------------------------------------
-- INTERNAL: Action Handler
------------------------------------------------------------------------

--- Maneja animaciones one-shot (disparar, melee, reload, etc.)
--- Estas se superponen al estado base, no lo reemplazan.
function AnimationController:_onActionResolved(action: string, _data: any?)
	-- Placeholder: cuando haya assets, aquí se reproducirán one-shots
	-- Ejemplo futuro:
	-- if action == "Shoot" then self:_playOneShot("ShootRecoil") end
	-- if action == "Melee" then self:_playOneShot("MeleeSwing") end
	-- if action == "Reload" then self:_playOneShot("ReloadAnim") end

	if Constants.DEBUG_MODE and action ~= "StartWalking" and action ~= "StopWalking" then
		print(`[GoW Animation] Action: {action}`)
	end
end

------------------------------------------------------------------------
-- INTERNAL: Track Management
------------------------------------------------------------------------

function AnimationController:_stopCurrentTrack()
	if self._currentTrack then
		self._currentTrack:Stop(Constants.STATE_TRANSITION_TIME)
		self._currentTrack = nil
	end
end

return AnimationController
