--[[
	MovementController.luau (Coordinator)
	═══════════════════════════════════════════════════════════════
	Ejecutor de Acciones Resueltas — Coordinator delgado
	═══════════════════════════════════════════════════════════════
	
	Recibe la acción resuelta por ActionResolver y la delega al
	sub-handler correspondiente (CoverMain, EvadeHandler).
	Gestiona:
	  - Delegación de acciones a sub-handlers
	  - RoadieRun velocity (AssemblyLinearVelocity directa)
	  - WalkSpeed por estado (via SpeedMap)
	  - Orquestación de Updates de sub-handlers
	
	NOTA: Esto es predicción del cliente. Las acciones que afectan
	gameplay (daño, inventario, HP) se validan en el servidor.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

-- Sub-handlers (siblings en el mismo folder Movement/)
local CoverMain = require(script.Parent.Cover)
local EvadeHandler = require(script.Parent.EvadeHandler)
local RotationHandler = require(script.Parent.RotationHandler)
local SpeedMap = require(script.Parent.SpeedMap)

local MovementController = {}
MovementController.__index = MovementController

function MovementController.new(stateMachine, actionResolver, environmentSensor, inputBuffer)
	local self = setmetatable({}, MovementController)

	self._stateMachine = stateMachine
	self._actionResolver = actionResolver
	self._envSensor = environmentSensor
	self._inputBuffer = inputBuffer
	self._player = Players.LocalPlayer

	-- Sub-handlers
	self._coverHandler = CoverMain.new(stateMachine, environmentSensor)
	self._evadeHandler = EvadeHandler.new(stateMachine, self._coverHandler)
	self._rotationHandler = RotationHandler.new()

	-- Conexiones gestionadas (cleanup en Destroy)
	self._connections = {}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function MovementController:Init()
	-- Configuración realizada en constructor
end

--- Conecta al Signal ActionResolved del ActionResolver.
--- MovementController reacciona a acciones resueltas sin acoplamiento directo.
function MovementController:Start()
	-- Inyectar CoverHandler al resolver (necesario para CoverSwap)
	self._actionResolver:SetCoverHandler(self._coverHandler)

	self._connections.actionResolved = self._actionResolver.ActionResolved:Connect(function(action, targetState, data)
		self:ExecuteAction(action, targetState, data)
	end)
end

function MovementController:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Ejecuta una acción resuelta por ActionResolver.
--- @param action string — nombre de la acción
--- @param targetState string? — estado destino (o nil si no hay transición)
--- @param data any? — datos adicionales
function MovementController:ExecuteAction(action: string, targetState: string?, data: any?)
	if action == "NoAction" then
		return
	end

	-- Transicionar si hay target state
	if targetState then
		local success = self._stateMachine:TransitionTo(targetState)
		if not success then
			-- ForceState para estados críticos (server-authoritative)
			if targetState == "DBNO" then
				self._stateMachine:ForceState(targetState)
			else
				return -- No se pudo transicionar, abortar acción
			end
		end
	end

	-- Intentar delegar a sub-handlers (cover → evade → fallback)
	if not self._coverHandler:HandleAction(action, data) then
		if not self._evadeHandler:HandleAction(action, data) then
			-- Acciones que no requieren handler especializado
			-- (StartWalking, StopWalking, StartRoadieRun, StopRoadieRun,
			--  StartAim, StopAim, Shoot, StopShoot, Reload, ActiveReload,
			--  Melee, Chainsaw, Interact, SwapWeapon, Crawl)
			-- Velocidad se aplica automáticamente abajo por estado.
		end
	end

	-- Aplicar velocidad al Humanoid según el nuevo estado
	self:_applyMovementSpeed()
end

--- Update cada frame. Maneja timers y lógica continua.
function MovementController:Update(dt: number)
	-- Cover redirect: solo permitir chain si el jugador pulsa cover de nuevo
	local wantsCoverRedirect = false
	local currentState = self._stateMachine:GetCurrentState()
	if currentState == "CoverEntering" and self._inputBuffer and self._inputBuffer:HasIntent("WantsCover") then
		self._inputBuffer:Consume("WantsCover")
		wantsCoverRedirect = true
	end

	local stateBefore = self._stateMachine:GetCurrentState()

	self._coverHandler:Update(dt, self._envSensor:GetContext(), wantsCoverRedirect)
	self._evadeHandler:Update(dt)

	if currentState == "RoadieRun" then
		self:_updateRoadieRun()
	end

	self._rotationHandler:Update(dt, currentState, self._coverHandler:GetNormal())

	-- Solo re-aplicar si el estado cambió internamente en un sub-handler
	if self._stateMachine:GetCurrentState() ~= stateBefore then
		self:_applyMovementSpeed()
	end
end

------------------------------------------------------------------------
-- PUBLIC: Sub-handler access (para Camera/Animation futuros)
------------------------------------------------------------------------

--- Retorna el CoverMain para que otros sistemas lean estado de cover.
function MovementController:GetCoverHandler()
	return self._coverHandler
end

------------------------------------------------------------------------
-- INTERNAL: Movement Speed
------------------------------------------------------------------------

function MovementController:_applyMovementSpeed()
	local character = self._player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
	if not humanoid then
		return
	end

	local state = self._stateMachine:GetCurrentState()
	humanoid.WalkSpeed = SpeedMap.GetSpeed(state)
end

------------------------------------------------------------------------
-- INTERNAL: RoadieRun
------------------------------------------------------------------------

--- Aplica AssemblyLinearVelocity directa durante RoadieRun.
--- WalkSpeed=0 en SpeedMap garantiza que el Humanoid no aporte ninguna fuerza propia,
--- por lo que esta función es el ÚNICO origen de velocidad horizontal en RoadieRun.
--- Dirección: MoveDirection (WASD activo) → LookVector (sin input, auto-forward GoW).
function MovementController:_updateRoadieRun()
	local character = self._player.Character
	local humanoid = character and character:FindFirstChild("Humanoid") :: Humanoid?
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then
		return
	end

	-- Elegir dirección base: input activo o look vector
	local rawDir: Vector3
	if humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD then
		rawDir = humanoid.MoveDirection
	else
		rawDir = hrp.CFrame.LookVector
	end

	-- Aplanar al plano horizontal y normalizar
	local flatDir = Vector3.new(rawDir.X, 0, rawDir.Z)
	if flatDir.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	flatDir = flatDir.Unit

	hrp.AssemblyLinearVelocity = Vector3.new(
		flatDir.X * Constants.ROADIE_RUN_SPEED,
		hrp.AssemblyLinearVelocity.Y,
		flatDir.Z * Constants.ROADIE_RUN_SPEED
	)
end

return MovementController
