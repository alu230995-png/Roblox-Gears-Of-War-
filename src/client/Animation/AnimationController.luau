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

	-- Mapa de acción → AnimationId para one-shots
	self._oneShotAnimationIds = {
		Shoot = "rbxassetid://0",
		Melee = "rbxassetid://0",
		Reload = "rbxassetid://0",
		Evade = "rbxassetid://0",
		Mantle = "rbxassetid://0",
		Vault = "rbxassetid://0",
	}

	-- Cache de AnimationTracks cargados para one-shots
	self._oneShotTracks = {} :: { [string]: AnimationTrack }

	-- Track actualmente en reproducción
	self._currentTrack = nil
	self._currentState = nil

	-- Animator reference (set when character spawns)
	self._animator = nil :: Animator?

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
	-- Cache Animator del personaje local
	self:_setupAnimator()

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
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif conn.Disconnect then
			conn:Disconnect()
		end
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
	local animId = self._oneShotAnimationIds[action]
	if not animId or animId == "rbxassetid://0" then
		if Constants.DEBUG_MODE and action ~= "StartWalking" and action ~= "StopWalking" then
			print(`[GoW Animation] Action: {action} (no animation asset)`)
		end
		return
	end

	self:_playOneShot(action, animId)
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

------------------------------------------------------------------------
-- INTERNAL: Animator Setup & One-Shot Playback
------------------------------------------------------------------------

function AnimationController:_setupAnimator()
	local Players = game:GetService("Players")
	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		return
	end

	local function cacheAnimator(character: Model?)
		if not character then
			self._animator = nil
			table.clear(self._oneShotTracks)
			return
		end
		local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
		if humanoid then
			self._animator = humanoid:FindFirstChildWhichIsA("Animator")
				or humanoid:WaitForChild("Animator", 3) :: Animator?
		end
		table.clear(self._oneShotTracks)
	end

	cacheAnimator(localPlayer.Character)
	self._connections.charAdded = localPlayer.CharacterAdded:Connect(function(character)
		cacheAnimator(character)
	end)
	self._connections.charRemoving = localPlayer.CharacterRemoving:Connect(function()
		self._animator = nil
		table.clear(self._oneShotTracks)
	end)
end

function AnimationController:_playOneShot(actionName: string, animId: string)
	if not self._animator then
		return
	end

	-- Cache: reutilizar tracks ya cargados
	local track = self._oneShotTracks[actionName]
	if not track then
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		track = self._animator:LoadAnimation(anim)
		track.Priority = Enum.AnimationPriority.Action
		track.Looped = false
		self._oneShotTracks[actionName] = track
	end

	track:Play(0.1)

	if Constants.DEBUG_MODE then
		print(`[GoW Animation] One-shot: {actionName}`)
	end
end

return AnimationController
