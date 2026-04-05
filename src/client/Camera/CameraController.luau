--[[
	CameraController.luau
	═══════════════════════════════════════════════════════════════
	Controlador de cámara estilo Gears of War
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades:
	  - FOV dinámico por estado (DEFAULT_FOV=70, ROADIE_RUN_FOV=80)
	  - Camera bob durante movimiento y roadie run
	  - ADS zoom (future)
	  - Cover lean / peek offset (future)
	  - Recoil shake al disparar (future)
	
	Comunicación event-driven:
	  - Escucha StateMachine.StateChanged → ajusta FOV target
	  - Escucha ActionResolver.ActionResolved → shake, kick
	  - Heartbeat propio para interpolar FOV y aplicar camera bob
	  - No conoce la existencia de otros listeners de estos signals.
	
	FASE 5 — Skeleton funcional. Camera bob y FOV transiciones
	implementados, efectos avanzados se añadirán con el sistema de combate.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

------------------------------------------------------------------------
-- FOV por estado (module-level constant — creada una sola vez)
------------------------------------------------------------------------
local STATE_FOV = {
	Idle = Constants.DEFAULT_FOV,
	Walking = Constants.DEFAULT_FOV,
	RoadieRun = Constants.ROADIE_RUN_FOV,
	CoverIdle = Constants.DEFAULT_FOV,
	CoverAim = Constants.DEFAULT_FOV - 5,
	CoverBlindFire = Constants.DEFAULT_FOV,
	CoverSlide = Constants.ROADIE_RUN_FOV,
	CoverEntering = Constants.ROADIE_RUN_FOV,
	CoverWalking = Constants.DEFAULT_FOV,
	CoverRunning = Constants.DEFAULT_FOV + 3,
	CoverExiting = Constants.DEFAULT_FOV,
	CoverCorners = Constants.DEFAULT_FOV,
	CoverSwap = Constants.ROADIE_RUN_FOV,
	Evading = Constants.DEFAULT_FOV,
	Mantling = Constants.DEFAULT_FOV,
	Aiming = Constants.DEFAULT_FOV - 10,
	Firing = Constants.DEFAULT_FOV - 8,
	Reloading = Constants.DEFAULT_FOV,
	ActiveReloading = Constants.DEFAULT_FOV,
	DBNO = Constants.DEFAULT_FOV - 5,
	Executing = Constants.DEFAULT_FOV,
	Death = Constants.DEFAULT_FOV - 10,
	Spectator = Constants.DEFAULT_FOV,
	Lobby = Constants.DEFAULT_FOV,
}

------------------------------------------------------------------------
-- BOB multiplier por estado
------------------------------------------------------------------------
local STATE_BOB_MULTIPLIER = {
	Idle = 0,
	Walking = Constants.CAMERA_BOB_WALK_MULTIPLIER,
	RoadieRun = Constants.CAMERA_BOB_ROADIE_MULTIPLIER,
	CoverIdle = 0,
	CoverAim = 0,
	CoverBlindFire = 0,
	CoverSlide = 0.5,
	CoverEntering = 0.3,
	CoverWalking = 0.4,
	CoverRunning = 0.7,
	CoverExiting = 0.3,
	CoverCorners = 0,
	CoverSwap = 0.5,
	Evading = 0,
	Mantling = 0,
	Aiming = 0.2,
	Firing = 0.3,
	Reloading = 0.5,
	ActiveReloading = 0.5,
	DBNO = 0.3,
	Executing = 0,
	Death = 0,
	Spectator = 0,
	Lobby = 0,
}

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------
local CameraController = {}
CameraController.__index = CameraController

function CameraController.new(stateMachine, actionResolver)
	local self = setmetatable({}, CameraController)

	self._stateMachine = stateMachine
	self._actionResolver = actionResolver

	-- FOV state
	self._targetFOV = Constants.DEFAULT_FOV
	self._currentFOV = Constants.DEFAULT_FOV

	-- Camera bob state
	self._bobTime = 0
	self._bobMultiplier = 0

	-- Conexiones gestionadas (cleanup en Destroy)
	self._connections = {}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function CameraController:Init()
	-- Sin side-effects
end

function CameraController:Start()
	-- Escuchar cambios de estado → FOV target
	self._connections.stateChanged = self._stateMachine.StateChanged:Connect(
		function(newState: string, _oldState: string)
			self:_onStateChanged(newState)
		end
	)

	-- Escuchar acciones resueltas → shake, kick
	self._connections.actionResolved = self._actionResolver.ActionResolved:Connect(
		function(action: string, _targetState: string?, _data: any?)
			self:_onActionResolved(action)
		end
	)

	-- Heartbeat para interpolación de FOV y camera bob
	self._connections.heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		self:_update(dt)
	end)

	if Constants.DEBUG_MODE then
		print("[GoW Camera] CameraController:Start() — listeners conectados")
	end
end

function CameraController:Destroy()
	for _, conn in self._connections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		else
			conn.Disconnect()
		end
	end
	table.clear(self._connections)
end

------------------------------------------------------------------------
-- INTERNAL: State Change Handler
------------------------------------------------------------------------

function CameraController:_onStateChanged(newState: string)
	self._targetFOV = STATE_FOV[newState] or Constants.DEFAULT_FOV
	self._bobMultiplier = STATE_BOB_MULTIPLIER[newState] or 0
end

------------------------------------------------------------------------
-- INTERNAL: Action Handler
------------------------------------------------------------------------

function CameraController:_onActionResolved(action: string)
	-- Placeholder: cuando haya combate, aquí se aplicarán efectos
	-- if action == "Shoot" then self:_applyRecoilShake() end
	-- if action == "Evade" then self:_applyRollCamera() end

	if Constants.DEBUG_MODE and (action == "Shoot" or action == "Evade") then
		print(`[GoW Camera] Action effect: {action}`)
	end
end

------------------------------------------------------------------------
-- INTERNAL: Frame Update
------------------------------------------------------------------------

function CameraController:_update(dt: number)
	self:_interpolateFOV(dt)
	self:_applyCameraBob(dt)
end

--- Interpola suavemente el FOV actual hacia el target.
function CameraController:_interpolateFOV(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local lerpSpeed = 8
	self._currentFOV = self._currentFOV + (self._targetFOV - self._currentFOV) * math.min(1, lerpSpeed * dt)
	camera.FieldOfView = self._currentFOV
end

--- Aplica camera bob basado en el estado actual.
function CameraController:_applyCameraBob(dt: number)
	if not Constants.CAMERA_BOB_ENABLED then
		return
	end

	if self._bobMultiplier <= 0 then
		self._bobTime = 0
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	self._bobTime = self._bobTime + dt * Constants.CAMERA_BOB_FREQUENCY

	local offsetX = math.sin(self._bobTime) * Constants.CAMERA_BOB_AMPLITUDE_X * self._bobMultiplier
	local offsetY = math.abs(math.cos(self._bobTime)) * Constants.CAMERA_BOB_AMPLITUDE_Y * self._bobMultiplier

	camera.CFrame = camera.CFrame * CFrame.new(offsetX, offsetY, 0)
end

return CameraController
