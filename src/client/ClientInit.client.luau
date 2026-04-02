--[[
	ClientInit.client.luau
	═══════════════════════════════════════════════════════════════
	ORQUESTADOR DEL CLIENTE — Gears of War Input System
	═══════════════════════════════════════════════════════════════
	
	Conecta las 5 capas del sistema de input en un game loop:
	
	Cada frame (Heartbeat):
	  1. InputDetector    → detecta raw inputs (teclas, hold/tap)
	  2. EnvironmentSensor → escanea cover nearby (raycast)
	  3. IntentMapper      → traduce raw inputs + env → intenciones
	  4. InputBuffer       → bufferea intents discretos con TTL
	  5. ActionResolver    → resuelve intents + estado + env → acción
	  6. MovementController → ejecuta la acción (velocidad, CFrame, etc.)
	  7. StateMachine      → update del estado actual (OnUpdate callback)
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

------------------------------------------------------------------------
-- SHARED MODULES
------------------------------------------------------------------------
local Shared = ReplicatedStorage:WaitForChild("Shared")
local _Constants = require(Shared:WaitForChild("Constants"))
local StateMachine = require(Shared:WaitForChild("StateMachine"))
local PlayerState = require(Shared:WaitForChild("Enums"):WaitForChild("PlayerState"))

------------------------------------------------------------------------
-- CLIENT MODULES — Capas del Input System
------------------------------------------------------------------------
local InputDetector = require(script.Parent.Input.InputDetector)
local IntentMapper = require(script.Parent.Input.IntentMapper)
local InputBuffer = require(script.Parent.Input.InputBuffer)
local EnvironmentSensor = require(script.Parent.EnvironmentSensor)
local ActionResolver = require(script.Parent.ActionResolver)
local MovementController = require(script.Parent.MovementController)

------------------------------------------------------------------------
-- INICIALIZACIÓN
------------------------------------------------------------------------
local _player = Players.LocalPlayer

-- Capa 4: State Machine con transiciones de PlayerState
local stateMachine = StateMachine.new("Idle", PlayerState.Transitions)

-- Capa 1: Detección de raw inputs
local inputDetector = InputDetector.new()

-- Sensor de entorno (raycast cover detection)
local envSensor = EnvironmentSensor.new()

-- Capa 2: Traductor de inputs → intenciones
local intentMapper = IntentMapper.new(inputDetector, envSensor)

-- Capa 3: Buffer de intenciones con TTL
local inputBuffer = InputBuffer.new()

-- Capa 5: Resolver de acciones por prioridad
local actionResolver = ActionResolver.new(stateMachine, inputBuffer, intentMapper, envSensor)

-- Ejecutor de movimiento
local movementController = MovementController.new(stateMachine)

------------------------------------------------------------------------
-- REGISTRAR CALLBACKS DE ESTADOS
-- Esqueleto — se expandirán con animaciones/cámara en fases siguientes
------------------------------------------------------------------------

stateMachine:RegisterState("Idle", {
	OnEnter = function(_oldState: string)
		-- Restaurar FOV, detener camera bob
	end,
})

stateMachine:RegisterState("Walking", {
	OnEnter = function(_oldState: string)
		-- Camera bob suave
	end,
})

stateMachine:RegisterState("RoadieRun", {
	OnEnter = function(_oldState: string)
		-- Camera bob intenso, FOV a ROADIE_RUN_FOV, cámara baja
	end,
	OnExit = function(_newState: string)
		-- Restaurar cámara gradualmente
	end,
})

stateMachine:RegisterState("CoverIdle", {
	OnEnter = function(_oldState: string)
		-- Snap visual a la pared
	end,
	OnExit = function(_newState: string)
		-- Despegar de la pared
	end,
})

stateMachine:RegisterState("CoverSlide", {
	OnEnter = function(_oldState: string)
		-- Animación de slide hacia cover
	end,
})

stateMachine:RegisterState("Evading", {
	OnEnter = function(_oldState: string)
		-- Animación de roll, iframes
	end,
})

stateMachine:RegisterState("Mantling", {
	OnEnter = function(_oldState: string)
		-- Animación de vault/mantle
	end,
})

stateMachine:RegisterState("Aiming", {
	OnEnter = function(_oldState: string)
		-- ADS: zoom, reducir velocidad, cambiar crosshair
	end,
	OnExit = function(_newState: string)
		-- Restaurar zoom y crosshair
	end,
})

stateMachine:RegisterState("CoverAim", {
	OnEnter = function(_oldState: string)
		-- Pop-up / peek desde cover
	end,
})

stateMachine:RegisterState("CoverBlindFire", {
	OnEnter = function(_oldState: string)
		-- Blind fire animation
	end,
})

stateMachine:RegisterState("DBNO", {
	OnEnter = function(_oldState: string)
		-- Animación de caída, UI de bleedout
	end,
})

------------------------------------------------------------------------
-- ARRANCAR INPUT DETECTOR
------------------------------------------------------------------------
inputDetector:Start()

------------------------------------------------------------------------
-- GAME LOOP — Heartbeat (cada frame)
------------------------------------------------------------------------
local DEBUG_MODE = true -- Imprime acciones detectadas y estado actual cada frame

RunService.Heartbeat:Connect(function(dt: number)
	-- Paso 1: EnvironmentSensor escanea el entorno
	local moveDir = inputDetector:GetMoveDirection()
	envSensor:Update(moveDir)

	-- Paso 2: IntentMapper traduce eventos + polling → intenciones
	local activeIntents = intentMapper:Update()

	-- Paso 3: InputBuffer almacena intents discretos
	inputBuffer:PushFromIntents(activeIntents)
	inputBuffer:CleanExpired()

	-- Paso 4: ActionResolver evalúa intents + estado + env
	local action, targetState, data = actionResolver:Resolve()

	-- Paso 5: MovementController ejecuta la acción
	movementController:ExecuteAction(action, targetState, data)

	-- Paso 6: Update continuo (timers, cover snap, rotación)
	movementController:Update(dt)

	-- Paso 7: StateMachine update (callbacks OnUpdate)
	stateMachine:Update(dt)

	-- Debug output
	if DEBUG_MODE and action ~= "NoAction" then
		print(`[GoW] {action} → {targetState or "nil"} | State: {stateMachine:GetCurrentState()}`)
	end
end)

------------------------------------------------------------------------
-- STARTUP LOG
------------------------------------------------------------------------
print(
	"[GoW Client] ═══════════════════════════════════════"
)
print("[GoW Client] Gears of War Input System — ACTIVE")
print(`[GoW Client] Estado inicial: {stateMachine:GetCurrentState()}`)
print(`[GoW Client] Gravity: {workspace.Gravity}`)
print("[GoW Client] Capas: Detector → Mapper → Buffer → Resolver → Controller")
print(
	"[GoW Client] ═══════════════════════════════════════"
)
