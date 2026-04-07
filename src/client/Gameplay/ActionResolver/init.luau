--[[
	ActionResolver — init.luau
	═══════════════════════════════════════════════════════════════
	CAPA 5: Resolución por Prioridad — Table-Driven Rule System
	═══════════════════════════════════════════════════════════════
	
	Orquestador delgado: construye el contexto del frame, selecciona la
	tabla de reglas apropiada según el estado actual, evalúa la primera
	regla cuyo check() pasa, y dispara ActionResolved signal.
	
	Las reglas viven en módulos separados para escalabilidad:
	  - FreeStateRules  → estados libres (Idle, Walking, Aiming…)
	  - RoadieRunRules  → estado RoadieRun
	  - CoverRules      → todos los sub-estados de cover + CoverSwap
	  - DBNORules       → estado DBNO
	
	Añadir una nueva acción = append una regla al array correspondiente
	en la posición de prioridad deseada. Sin tocar este orquestador.
	
	Comunicación event-driven:
	  - self.ActionResolved (Signal) se dispara con (action, targetState, data)
	  - MovementController, AnimationController y CameraController escuchan
	    este signal sin que ActionResolver sepa de su existencia.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerStateModule = require(Shared:WaitForChild("Enums"):WaitForChild("PlayerState"))
local Constants = require(Shared:WaitForChild("Constants"))
local Signal = require(Shared:WaitForChild("Signal"))

-- Rule tables (cada módulo exporta un array de reglas)
local Helpers = require(script:WaitForChild("Helpers"))
local FreeStateRules = require(script:WaitForChild("FreeStateRules"))
local RoadieRunRules = require(script:WaitForChild("RoadieRunRules"))
local CoverRules = require(script:WaitForChild("CoverRules"))
local DBNORules = require(script:WaitForChild("DBNORules"))

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------
local ActionResolver = {}
ActionResolver.__index = ActionResolver

function ActionResolver.new(stateMachine, inputBuffer, intentMapper, environmentSensor)
	local self = setmetatable({}, ActionResolver)

	self._stateMachine = stateMachine
	self._buffer = inputBuffer
	self._intents = intentMapper
	self._env = environmentSensor
	self._coverHandler = nil -- Inyectado después via SetCoverHandler()

	-- Signal de salida: (action: string, targetState: string?, data: any?)
	self.ActionResolved = Signal.new()

	-- Cooldown del evade: registra el tick en que se inició el último evade.
	self._evadeStartTime = -math.huge

	-- Throttle de debug para Cover Swap (per-instance)
	self._swapDebugLastPrint = 0

	-- Tabla reutilizable para _buildContext (evita alloc por frame)
	self._ctxCache = {}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

--- Inyecta la referencia al CoverHandler (CoverMain) después de su creación.
function ActionResolver:SetCoverHandler(coverHandler)
	self._coverHandler = coverHandler
end

function ActionResolver:Destroy()
	if self.ActionResolved then
		self.ActionResolved:Destroy()
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Resuelve la acción a ejecutar este frame.
--- Dispara ActionResolved signal si la acción no es NoAction.
function ActionResolver:Resolve(): (string, string?, any?)
	local state = self._stateMachine:GetCurrentState()

	-- En estados bloqueantes (animación comprometida) o inactivos, no resolver nada.
	-- Excepción: CoverSwap permite cancelación.
	if self._stateMachine:IsInGroup("InactiveGroup") then
		return "NoAction", nil, nil
	end
	if self._stateMachine:IsInGroup("ActionGroup") and state ~= "CoverSwap" then
		return "NoAction", nil, nil
	end

	local ctx = self:_buildContext(state)
	local rules = self:_selectRules(state)
	local action, targetState, data = self:_evaluateRules(rules, ctx)

	if action ~= "NoAction" then
		self.ActionResolved:Fire(action, targetState, data)

		if Constants.DEBUG_MODE then
			print(`[GoW] {action} → {targetState or "nil"} | State: {state}`)
		end
	end

	return action, targetState, data
end

------------------------------------------------------------------------
-- INTERNAL: Context Builder
------------------------------------------------------------------------

--- Construye un ResolverContext snapshot para este frame.
function ActionResolver:_buildContext(state: string)
	local ctx = self._ctxCache
	ctx.State = state
	ctx.StateConfig = PlayerStateModule.GetState(state)
	ctx.Env = self._env:GetContext()
	ctx.EnvSensor = self._env
	ctx.CoverHandler = self._coverHandler
	ctx.Buffer = self._buffer
	ctx.Intents = self._intents
	ctx.HasMovement = Helpers.hasMovementIntent(self._intents)
	ctx._swapData = nil -- Clear stale data from previous frame
	return ctx
end

------------------------------------------------------------------------
-- INTERNAL: Rule Selection
------------------------------------------------------------------------

--- Selecciona la tabla de reglas apropiada según el estado actual.
function ActionResolver:_selectRules(state: string)
	if state == "DBNO" then
		return DBNORules
	end

	-- CoverSwap es ActionGroup pero tiene su propia tabla de cancelación
	if state == "CoverSwap" then
		return CoverRules.Swap
	end

	if self._stateMachine:IsInGroup("CoverGroup") then
		return CoverRules.SubRules[state] or CoverRules.Idle
	end

	if state == "RoadieRun" then
		return RoadieRunRules
	end

	return FreeStateRules
end

------------------------------------------------------------------------
-- INTERNAL: Rule Evaluator
------------------------------------------------------------------------

--- Itera las reglas en orden de prioridad. La primera cuyo check() pasa gana.
function ActionResolver:_evaluateRules(rules, ctx): (string, string?, any?)
	for _, rule in rules do
		if rule.check(self, ctx) then
			local action, targetState, data = rule.execute(self, ctx)
			if action ~= "NoAction" then
				return action, targetState, data
			end
		end
	end
	return "NoAction", nil, nil
end

return ActionResolver
