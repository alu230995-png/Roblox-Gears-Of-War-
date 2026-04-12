--[[
	ClientApp.client.luau
	═══════════════════════════════════════════════════════════════
	ENTRY POINT DEL CLIENTE — Solo bootstrapping
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades:
	  1. Crear instancias de todos los sistemas
	  2. Registrar en ServiceLocator
	  3. Fase Init(): sin side-effects, sin conexiones
	  4. Fase Start(): conectar signals, arrancar conexiones
	  5. Heartbeat: game loop central (temporal — se moverá a CharacterController)
	
	Este archivo NO contiene lógica de gameplay. Solo bootstrapping.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

------------------------------------------------------------------------
-- SHARED MODULES
------------------------------------------------------------------------
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local StateMachine = require(Shared:WaitForChild("Utils"):WaitForChild("StateMachine"))
local PlayerState = require(Shared:WaitForChild("Enums"):WaitForChild("PlayerState"))

------------------------------------------------------------------------
-- CLIENT MODULES
------------------------------------------------------------------------
-- Core
local ServiceLocator = require(script.Parent.Core.ServiceLocator)

-- Input (Capas 1-3 — ya cumplen SRP)
local InputDetector = require(script.Parent.Input.InputDetector)
local IntentMapper = require(script.Parent.Input.IntentMapper)
local InputBuffer = require(script.Parent.Input.InputBuffer)
local MouseInput = require(script.Parent.Input.MouseInput)

-- World
local EnvironmentSensor = require(script.Parent.World.EnvironmentSensor)

-- Gameplay (Capa 5)
local ActionResolver = require(script.Parent.Gameplay.ActionResolver)

-- Movement (refactored — Character/Movement/ con sub-handlers)
local MovementController = require(script.Parent.Character.Movement.MovementController)

-- Animation (Fase 4 — skeleton funcional)
local AnimationController = require(script.Parent.Animation.AnimationController)

-- Camera (Fase 5 — skeleton funcional)
local CameraController = require(script.Parent.Camera.CameraController)

-- Aiming (Fase 1B/1C — shoulder, FOV zoom, deadzone)
local AimingController = require(script.Parent.Gameplay.Aiming.AimingController)

-- Sound System
local SoundController = require(script.Parent.Sound.SoundController)

------------------------------------------------------------------------
-- BOOTSTRAP
------------------------------------------------------------------------
local locator = ServiceLocator.new()

-- Crear instancias (orden importa: dependencias primero)
local stateMachine = StateMachine.new("Idle", PlayerState.Transitions)

-- Registrar grupos HSM (orden: padres antes de hijos)
for groupName, groupConfig in PlayerState.Groups do
	stateMachine:RegisterGroup(groupName, {
		Parent = groupConfig.Parent,
		States = groupConfig.States,
	})
end
stateMachine:BuildGroupHierarchy()

local inputDetector = InputDetector.new()
local mouseInput = MouseInput.new()
local envSensor = EnvironmentSensor.new()
local intentMapper = IntentMapper.new(inputDetector)
local inputBuffer = InputBuffer.new()
local actionResolver = ActionResolver.new(stateMachine, inputBuffer, intentMapper, envSensor)
local movementController =
	MovementController.new(stateMachine, actionResolver, envSensor, inputDetector)
local animationController = AnimationController.new(stateMachine, movementController.ActionExecuted)
local cameraController = CameraController.new(stateMachine, movementController.ActionExecuted, mouseInput)

-- Conectar señales del Cover system a CameraController (Capa 4 → Capa 5 via signals)
local coverHandler = movementController:GetCoverHandler()
coverHandler.CoverSettleChanged:Connect(function(active)
	cameraController:SetCoverSettleActive(active)
end)
coverHandler.ShoulderSideChanged:Connect(function(side)
	cameraController:SetShoulderSide(side)
end)
coverHandler.InnerCornerTransition:Connect(function(newNormal)
	cameraController:NotifyInnerCornerTransition(newNormal)
end)

-- AimingController: cerebro del sistema de apuntado (Fase 1B/1C)
local aimingController = AimingController.new(stateMachine, coverHandler, cameraController)
movementController.ActionExecuted:Connect(function(action, targetState, data)
	aimingController:HandleAction(action, targetState, data)
end)

-- DI: RotationHandler necesita leer GetRotationOverride() para Low Cover aim
movementController:SetAimingController(aimingController)

-- Nota: SetCoverHandler se llama dentro de MovementController:Start() — no duplicar aquí.
local soundController = SoundController.new(stateMachine)

-- Registrar en ServiceLocator (orden de registro = orden de Init/Start)
locator:Register("StateMachine", stateMachine)
locator:Register("InputDetector", inputDetector)
locator:Register("MouseInput", mouseInput)
locator:Register("EnvironmentSensor", envSensor)
locator:Register("IntentMapper", intentMapper)
locator:Register("InputBuffer", inputBuffer)
locator:Register("ActionResolver", actionResolver)
locator:Register("MovementController", movementController)
locator:Register("AnimationController", animationController)
locator:Register("CameraController", cameraController)
locator:Register("AimingController", aimingController)
locator:Register("SoundController", soundController)

-- FASE 1: Init (sin side-effects, sin conexiones)
locator:InitAll()

-- FASE 2: Start (conecta signals, arranca conexiones)
-- Después de Start:
--   InputDetector escucha UIS events (su propio Heartbeat interno)
--   MovementController escucha ActionResolver.ActionResolved via Signal
--   AnimationController escucha StateChanged + ActionExecuted
--   CameraController escucha StateChanged + ActionExecuted
locator:StartAll()

------------------------------------------------------------------------
-- HEARTBEAT — Game Loop central
------------------------------------------------------------------------
-- NOTA ARQUITECTURA: Este heartbeat es TEMPORAL. En el refactor de
-- Fase 3 (CharacterController), el loop se moverá allí.
-- ClientApp solo hará bootstrap. Por ahora permanece aquí como
-- orquestador del pipeline de input (ARQREG 06: un solo Heartbeat).

RunService.Heartbeat:Connect(function(dt: number)
	-- Paso 1: IntentMapper traduce eventos + polling → intenciones
	intentMapper:Update()

	-- Paso 2: InputBuffer almacena intents discretos y limpia expirados
	inputBuffer:PushFromIntents(intentMapper:GetActiveIntents())
	inputBuffer:CleanExpired()

	-- Paso 3: EnvironmentSensor escanea el entorno (state-driven)
	-- Solo hace raycasts cuando el estado lo requiere
	local currentState = stateMachine:GetCurrentState()
	local coverNormal = movementController:GetCoverHandler():GetNormal()
	local wantsCoverSearch = inputBuffer:HasIntent("WantsCover")
	local moveDir = inputDetector:GetMoveDirection()
	envSensor:Update(currentState, coverNormal, wantsCoverSearch, moveDir)

	-- Paso 4: ActionResolver evalúa intents + estado + env
	-- Dispara ActionResolved Signal → MovementController reacciona automáticamente
	actionResolver:Resolve()

	-- Paso 5: Update continuo (timers, cover snap, rotación, evade decay)
	movementController:Update(dt)

	-- Paso 5a: AimingController — lee cover state fresco, aplica shoulder/FOV antes de cámara
	aimingController:Update(dt)

	-- Paso 5b: MouseInput lee delta ANTES de la cámara
	mouseInput:Update()

	-- Paso 5c: Cámara DESPUÉS de movement — garantiza que lea el HRP post-corrección
	-- (wall-glue, smooth rotation) sin jitter de 1-frame lag.
	cameraController:Update(dt)

	-- Paso 6: StateMachine update (callbacks OnUpdate de estados)
	stateMachine:Update(dt)
end)

------------------------------------------------------------------------
-- STARTUP LOG
------------------------------------------------------------------------
if Constants.DEBUG_MODE then
	print(
		"[GoW Client] ═══════════════════════════════════════"
	)
	print("[GoW Client] Gears of War — Sistema iniciado")
	print(`[GoW Client] Estado inicial: {stateMachine:GetCurrentState()}`)
	print(`[GoW Client] Gravity: {workspace.Gravity}`)
	print("[GoW Client] Arquitectura: ServiceLocator + Signal-driven")
	print("[GoW Client] Capas: Detector → Mapper → Buffer → Resolver → [Signal] → Controller")
	print("[GoW Client] Sound System: SoundController + SoundPlayer")
	print(
		"[GoW Client] ═══════════════════════════════════════"
	)
end
