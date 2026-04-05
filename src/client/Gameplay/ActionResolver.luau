--[[
	ActionResolver.luau
	═══════════════════════════════════════════════════════════════
	CAPA 5: Resolución por Prioridad — Table-Driven Rule System
	═══════════════════════════════════════════════════════════════
	
	El mismo input puede significar muchas cosas. La resolución se hace
	por prioridad: primero verifica si la acción de mayor prioridad es
	posible, si no, baja al siguiente nivel.
	
	Principio GoW — A (tap):
	  1. ¿Puedo entrar en cover? → Sí → EnterCover
	  2. ¿No? ¿Puedo evadirme?  → Sí → Evade/Roll
	  3. ¿No?                    → Idle (sin acción)
	
	Comunicación event-driven:
	  - self.ActionResolved (Signal) se dispara con (action, targetState, data)
	  - MovementController, AnimationController y CameraController escuchan
	    este signal sin que ActionResolver sepa de su existencia.
	
	ARQUITECTURA: Table-Driven Rules
	  Cada grupo de estados tiene un array de reglas ordenadas por prioridad.
	  Cada regla: { id, check(resolver, ctx) → bool, execute(resolver, ctx) → (action, state?, data?) }
	  Un método genérico _evaluateRules itera el array: la primera regla cuyo
	  check() pasa gana. Añadir una nueva acción = append una regla al array
	  en la posición de prioridad deseada. Sin tocar lógica existente.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerStateModule = require(Shared:WaitForChild("Enums"):WaitForChild("PlayerState"))
local Constants = require(Shared:WaitForChild("Constants"))
local Signal = require(Shared:WaitForChild("Signal"))

------------------------------------------------------------------------
-- HELPER: Detecta si hay movimiento en los intents continuos
------------------------------------------------------------------------
local function hasMovementIntent(intents): boolean
	return intents:HasIntent("WantsMoveForward")
		or intents:HasIntent("WantsMoveBackward")
		or intents:HasIntent("WantsMoveLeft")
		or intents:HasIntent("WantsMoveRight")
end

------------------------------------------------------------------------
-- HELPER: Verifica cooldown del evade
------------------------------------------------------------------------
local function isEvadeCooldownMet(resolver): boolean
	return (os.clock() - resolver._evadeStartTime) >= (Constants.EVADE_DURATION + Constants.EVADE_COOLDOWN)
end

------------------------------------------------------------------------
-- RULE TABLES (module-level constants — creadas una sola vez)
------------------------------------------------------------------------
-- Cada regla: { id: string, check: (resolver, ctx) → bool, execute: (resolver, ctx) → (string, string?, any?) }
-- ctx = ResolverContext { State, StateConfig, Env, Buffer, Intents, HasMovement }

--- FREE STATE RULES: Idle, Walking, Aiming, Firing, Reloading, ActiveReloading
local FREE_STATE_RULES = {
	-- Prio 1: Cover (el botón más importante de GoW)
	{
		id = "EnterCover",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsCover") and ctx.Env.HasCoverNearby and ctx.StateConfig.canTakeCover
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover")
			return "EnterCover",
				"CoverEntering",
				{
					coverNormal = ctx.Env.CoverNormal,
					coverPos = ctx.Env.CoverPosition,
					coverInstance = ctx.Env.CoverInstance,
					coverType = ctx.Env.CoverType,
				}
		end,
	},

	-- Prio 2: Mantle
	{
		id = "Mantle",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsMantle") and ctx.Env.HasLowCoverAhead and ctx.Env.HasCoverNearby
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsMantle")
			return "Mantle", "Mantling", nil
		end,
	},

	-- Prio 3: Evade / Roll
	{
		id = "Evade",
		check = function(resolver, ctx)
			return ctx.Buffer:HasIntent("WantsEvade") and ctx.StateConfig.canEvade and isEvadeCooldownMet(resolver)
		end,
		execute = function(resolver, ctx)
			resolver._evadeStartTime = os.clock()
			ctx.Buffer:Consume("WantsEvade")
			return "Evade", "Evading", { direction = ctx.Env.MoveDirection }
		end,
	},

	-- Prio 4: RoadieRun (intent continuo)
	{
		id = "StartRoadieRun",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsRoadieRun")
				and ctx.StateConfig.canSprint
				and (ctx.State == "Idle" or ctx.State == "Walking")
		end,
		execute = function()
			return "StartRoadieRun", "RoadieRun", nil
		end,
	},

	-- Prio 5a: Aim
	{
		id = "StartAim",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsAim")
				and ctx.StateConfig.canShoot
				and (ctx.State == "Idle" or ctx.State == "Walking")
		end,
		execute = function()
			return "StartAim", "Aiming", nil
		end,
	},

	-- Prio 5b: Stop Aim
	{
		id = "StopAim",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsStopAim") and ctx.State == "Aiming"
		end,
		execute = function()
			return "StopAim", "Idle", nil
		end,
	},

	-- Prio 6a: Shoot
	{
		id = "Shoot",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsShoot") and ctx.StateConfig.canShoot and ctx.State == "Aiming"
		end,
		execute = function()
			return "Shoot", "Firing", nil
		end,
	},

	-- Prio 6b: Stop Shoot
	{
		id = "StopShoot",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsStopShoot") and ctx.State == "Firing"
		end,
		execute = function()
			return "StopShoot", "Aiming", nil
		end,
	},

	-- Prio 7: Reload / Active Reload
	{
		id = "Reload",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsReload")
		end,
		execute = function(_resolver, ctx)
			if ctx.State == "Reloading" then
				ctx.Buffer:Consume("WantsReload")
				return "ActiveReload", "ActiveReloading", nil
			elseif ctx.StateConfig.canMove then
				ctx.Buffer:Consume("WantsReload")
				return "Reload", "Reloading", nil
			end
			return "NoAction", nil, nil
		end,
	},

	-- Prio 8a: Melee
	{
		id = "Melee",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsMelee")
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsMelee")
			return "Melee", nil, nil
		end,
	},

	-- Prio 8b: Chainsaw
	{
		id = "Chainsaw",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsChainsaw")
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsChainsaw")
			return "Chainsaw", nil, nil
		end,
	},

	-- Prio 9: Interact
	{
		id = "Interact",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsInteract")
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsInteract")
			return "Interact", nil, nil
		end,
	},

	-- Prio 10: Swap Weapon
	{
		id = "SwapWeapon",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsSwapWeapon")
		end,
		execute = function(_resolver, ctx)
			local _, swapData = ctx.Buffer:Consume("WantsSwapWeapon")
			return "SwapWeapon", nil, { slot = swapData }
		end,
	},

	-- Prio 11: Movement (Walking / Idle transitions)
	{
		id = "Movement",
		check = function()
			return true -- Siempre se evalúa como fallback
		end,
		execute = function(_resolver, ctx)
			if ctx.HasMovement then
				if ctx.State == "Idle" then
					return "StartWalking", "Walking", nil
				end
			else
				if ctx.State == "Walking" then
					return "StopWalking", "Idle", nil
				end
			end
			return "NoAction", nil, nil
		end,
	},
}

--- ROADIE RUN RULES
local ROADIE_RUN_RULES = {
	-- Prio 1: Cover durante roadie run → CoverSlide (la más rápida del juego)
	{
		id = "SlideIntoCover",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsCover") and ctx.Env.HasCoverNearby
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover")
			return "SlideIntoCover",
				"CoverSlide",
				{
					coverNormal = ctx.Env.CoverNormal,
					coverPos = ctx.Env.CoverPosition,
					coverInstance = ctx.Env.CoverInstance,
					coverType = ctx.Env.CoverType,
				}
		end,
	},

	-- Prio 2a: Mantle con input explícito
	{
		id = "MantleExplicit",
		check = function(_resolver, ctx)
			return ctx.Env.HasLowCoverAhead and ctx.Env.HasCoverNearby and ctx.Buffer:HasIntent("WantsMantle")
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsMantle")
			return "Mantle", "Mantling", nil
		end,
	},

	-- Prio 2b: Auto-mantle (corriendo directo a cover bajo)
	{
		id = "AutoMantle",
		check = function(_resolver, ctx)
			return ctx.Env.HasLowCoverAhead
				and ctx.Env.HasCoverNearby
				and ctx.Env.MoveDirection.Y > 0.5
				and ctx.Env.IsFacingCover
		end,
		execute = function()
			return "Mantle", "Mantling", nil
		end,
	},

	-- Prio 3: Evade durante roadie run
	{
		id = "EvadeRoadie",
		check = function(resolver, ctx)
			return ctx.Buffer:HasIntent("WantsEvade") and isEvadeCooldownMet(resolver)
		end,
		execute = function(resolver, ctx)
			resolver._evadeStartTime = os.clock()
			ctx.Buffer:Consume("WantsEvade")
			return "Evade", "Evading", { direction = ctx.Env.MoveDirection }
		end,
	},

	-- Prio 4: Stop RoadieRun
	{
		id = "StopRoadieRun",
		check = function(_resolver, ctx)
			return not ctx.Intents:HasIntent("WantsRoadieRun")
		end,
		execute = function(_resolver, ctx)
			if ctx.HasMovement then
				return "StopRoadieRun", "Walking", nil
			else
				return "StopRoadieRun", "Idle", nil
			end
		end,
	},
}

--- COVER AIM RULES (sub-estado de CoverGroup)
local COVER_AIM_RULES = {
	{
		id = "ReturnToCover",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsStopAim")
		end,
		execute = function()
			return "ReturnToCover", "CoverIdle", nil
		end,
	},
	{
		id = "ShootFromCover",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsShoot")
		end,
		execute = function()
			return "Shoot", "Firing", nil
		end,
	},
}

--- COVER BLIND FIRE RULES (sub-estado de CoverGroup)
local COVER_BLINDFIRE_RULES = {
	{
		id = "StopBlindFire",
		check = function(_resolver, ctx)
			return not ctx.Intents:HasIntent("WantsBlindFire")
		end,
		execute = function()
			return "StopBlindFire", "CoverIdle", nil
		end,
	},
}

--- COVER IDLE RULES (sub-estado principal de CoverGroup)
local COVER_IDLE_RULES = {
	-- Prio 1: Exit cover
	{
		id = "ExitCover",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsExitCover") or ctx.Intents:HasIntent("WantsExitCover")
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsExitCover")
			return "ExitCover", "CoverExiting", nil
		end,
	},

	-- Prio 2: Roll out of cover
	{
		id = "RollOutOfCover",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsEvade")
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsEvade")
			return "RollOutOfCover", "Evading", { direction = ctx.Env.MoveDirection }
		end,
	},

	-- Prio 3: Vault (cover bajo + forward + cover/mantle button)
	{
		id = "Vault",
		check = function(_resolver, ctx)
			return (ctx.Buffer:HasIntent("WantsCover") or ctx.Buffer:HasIntent("WantsMantle"))
				and ctx.Env.CoverType == "Low"
				and ctx.Env.MoveDirection.Y > 0.3
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover")
			ctx.Buffer:Consume("WantsMantle")
			return "Vault", "Mantling", nil
		end,
	},

	-- Prio 4a: CoverSwap Left (aligned cover)
	{
		id = "CoverSwapLeft",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsMoveLeft") and ctx.Env.HasAlignedCoverLeft and ctx.Env.IsAtCornerLeft
		end,
		execute = function(_resolver, ctx)
			return "CoverSwap", "CoverSwap", { direction = "Left", envContext = ctx.Env }
		end,
	},

	-- Prio 4b: CoverSwap Right (aligned cover)
	{
		id = "CoverSwapRight",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsMoveRight") and ctx.Env.HasAlignedCoverRight and ctx.Env.IsAtCornerRight
		end,
		execute = function(_resolver, ctx)
			return "CoverSwap", "CoverSwap", { direction = "Right", envContext = ctx.Env }
		end,
	},

	-- Prio 5: Aim (pop-up / peek)
	{
		id = "PopUpAim",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsAim")
		end,
		execute = function()
			return "PopUpAim", "CoverAim", nil
		end,
	},

	-- Prio 6: Blind Fire (explicit)
	{
		id = "BlindFire",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsBlindFire")
		end,
		execute = function()
			return "BlindFire", "CoverBlindFire", nil
		end,
	},

	-- Prio 7: Shoot sin aim (= blind fire)
	{
		id = "ShootAsBlindFire",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsShoot") and not ctx.Intents:HasIntent("WantsAim")
		end,
		execute = function()
			return "BlindFire", "CoverBlindFire", nil
		end,
	},

	-- Prio 8: Reload en cover
	{
		id = "ReloadInCover",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsReload")
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsReload")
			return "Reload", "Reloading", nil
		end,
	},

	-- Prio 9a: Slide lateral izquierda
	{
		id = "CoverSlideLeft",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsMoveLeft") and not ctx.Env.IsAtCornerLeft
		end,
		execute = function()
			return "CoverSlideLeft", nil, nil
		end,
	},

	-- Prio 9b: Slide lateral derecha
	{
		id = "CoverSlideRight",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsMoveRight") and not ctx.Env.IsAtCornerRight
		end,
		execute = function()
			return "CoverSlideRight", nil, nil
		end,
	},

	-- Prio 10a: Peek esquina izquierda
	{
		id = "PeekCornerLeft",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsMoveLeft") and ctx.Env.IsAtCornerLeft
		end,
		execute = function()
			return "PeekCornerLeft", nil, nil
		end,
	},

	-- Prio 10b: Peek esquina derecha
	{
		id = "PeekCornerRight",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsMoveRight") and ctx.Env.IsAtCornerRight
		end,
		execute = function()
			return "PeekCornerRight", nil, nil
		end,
	},
}

--- DBNO RULES
local DBNO_RULES = {
	{
		id = "Crawl",
		check = function(_resolver, ctx)
			return ctx.HasMovement
		end,
		execute = function()
			return "Crawl", nil, nil
		end,
	},
}

--- Mapa de sub-estado de cover → rule table correspondiente
--- Los nuevos estados de cover (CoverWalking, CoverRunning, CoverCorners)
--- usan COVER_IDLE_RULES como fallback hasta que tengan reglas propias.
local COVER_SUB_RULES = {
	CoverAim = COVER_AIM_RULES,
	CoverBlindFire = COVER_BLINDFIRE_RULES,
	CoverIdle = COVER_IDLE_RULES,
	CoverWalking = COVER_IDLE_RULES,
	CoverRunning = COVER_IDLE_RULES,
	CoverCorners = COVER_IDLE_RULES,
}

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

	-- Signal de salida: (action: string, targetState: string?, data: any?)
	self.ActionResolved = Signal.new()

	-- Cooldown del evade: registra el tick en que se inició el último evade.
	-- Cooldown total = EVADE_DURATION + EVADE_COOLDOWN (el roll debe terminar
	-- y luego esperar la ventana de vulnerabilidad antes de poder volver a evadir).
	self._evadeStartTime = -math.huge

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function ActionResolver:Init()
	-- Signal creado en constructor
end

function ActionResolver:Start()
	-- Sin conexiones propias — Resolve() es llamado por el heartbeat
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
--- Retorna: actionName, targetState, actionData (para compatibilidad)
function ActionResolver:Resolve(): (string, string?, any?)
	local state = self._stateMachine:GetCurrentState()

	-- En estados bloqueantes (animación comprometida) o inactivos, no resolver nada.
	if self._stateMachine:IsInGroup("ActionGroup") or self._stateMachine:IsInGroup("InactiveGroup") then
		return "NoAction", nil, nil
	end

	-- Construir contexto una sola vez por frame
	local ctx = self:_buildContext(state)

	-- Seleccionar rule table según grupo de estado
	local rules = self:_selectRules(state, ctx)
	local action, targetState, data = self:_evaluateRules(rules, ctx)

	-- Disparar signal para listeners (MovementController, Camera, Animation)
	if action ~= "NoAction" then
		self.ActionResolved:Fire(action, targetState, data)

		if Constants.DEBUG_MODE then
			print(`[GoW] {action} → {targetState or "nil"} | State: {self._stateMachine:GetCurrentState()}`)
		end
	end

	return action, targetState, data
end

------------------------------------------------------------------------
-- INTERNAL: Context Builder
------------------------------------------------------------------------

--- Construye un ResolverContext snapshot para este frame.
--- Se crea una sola vez y se pasa a todas las reglas.
function ActionResolver:_buildContext(state: string)
	return {
		State = state,
		StateConfig = PlayerStateModule.GetState(state),
		Env = self._env:GetContext(),
		Buffer = self._buffer,
		Intents = self._intents,
		HasMovement = hasMovementIntent(self._intents),
	}
end

------------------------------------------------------------------------
-- INTERNAL: Rule Selection
------------------------------------------------------------------------

--- Selecciona la tabla de reglas apropiada según el estado actual.
function ActionResolver:_selectRules(state: string, _ctx)
	if state == "DBNO" then
		return DBNO_RULES
	end

	if self._stateMachine:IsInGroup("CoverGroup") then
		return COVER_SUB_RULES[state] or COVER_IDLE_RULES
	end

	if state == "RoadieRun" then
		return ROADIE_RUN_RULES
	end

	return FREE_STATE_RULES
end

------------------------------------------------------------------------
-- INTERNAL: Rule Evaluator
------------------------------------------------------------------------

--- Itera las reglas en orden de prioridad. La primera cuyo check() pasa gana.
--- @return action, targetState?, data?
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
