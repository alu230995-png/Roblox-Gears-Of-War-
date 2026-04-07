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
-- HELPER: Cover Swap — Escaneo Pasivo + Gatillo de Acción
------------------------------------------------------------------------
-- Arquitectura de 2 fases:
--   Fase A (Escaneo pasivo): Mientras el jugador está en esquina y mantiene
--     input lateral hacia el vacío, el sistema lanza el rayo de detección
--     frame a frame. No desplaza al jugador; solo reporta si hay cover válida.
--   Fase B (Gatillo manual): Al pulsar el botón de acción (Space tap /
--     WantsCover), el sistema evalúa:
--       - Si hay escaneo positivo → Cover Swap.
--       - Si no hay cover válida → se ignora (protección contra salto suicida).
------------------------------------------------------------------------
local Players = game:GetService("Players")

-- Throttle: evitar spam en consola (imprime como máximo cada 0.3 s)
-- NOTA: Se mueve a instancia en el constructor (self._swapDebugLastPrint)

--- Fase A: Escaneo pasivo — se ejecuta cada frame cuando el jugador está
--- en esquina y tiene input lateral hacia el vacío.
--- @return table? swapData — { newPart, newNormal, hitPosition, moveDir } o nil
local function _scanCoverSwap(resolver, ctx): any?
	local env = ctx.Env
	local coverHandler = ctx.CoverHandler
	if not coverHandler or not ctx.EnvSensor then
		return nil
	end

	local coverNormal = coverHandler:GetNormal()
	local wallRight = coverHandler:GetWallRight()
	if not coverNormal or not wallRight then
		return nil
	end

	-- Detectar dirección lateral del input
	local character = Players.LocalPlayer.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
	if not humanoid or humanoid.MoveDirection.Magnitude < Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		return nil
	end

	local movementScale = humanoid.MoveDirection:Dot(wallRight)
	if math.abs(movementScale) < Constants.LATERAL_TRIGGER_THRESHOLD then
		return nil
	end

	-- Verificar que estamos en una esquina bloqueada en esa dirección
	local atCorner = (movementScale > 0 and env.IsAtCornerRight) or (movementScale < 0 and env.IsAtCornerLeft)

	if Constants.DEBUG_MODE then
		local now = os.clock()
		if now - resolver._swapDebugLastPrint > 0.3 then
			resolver._swapDebugLastPrint = now
			print(
				string.format(
					"[CoverSwap] Escaneo pasivo: scale=%.2f | esquina=%s (izq=%s, der=%s)",
					movementScale,
					tostring(atCorner),
					tostring(env.IsAtCornerLeft),
					tostring(env.IsAtCornerRight)
				)
			)
		end
	end

	if not atCorner then
		return nil
	end

	-- Lanzar rayo de detección (escaneo pasivo frame a frame)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end

	local moveDir = if movementScale > 0 then 1 else -1
	local coverInstance = coverHandler:GetCoverInstance()
	if not coverInstance then
		return nil
	end

	local newPart, newNormal, hitPos =
		ctx.EnvSensor:CheckSwapCover(hrp, coverNormal, wallRight, moveDir, coverInstance, humanoid.MoveDirection)

	if newPart and newNormal and hitPos then
		if Constants.DEBUG_MODE then
			print(
				string.format(
					"[CoverSwap] Escaneo POSITIVO — newPart=%s | hitPos=(%.1f,%.1f,%.1f) | dir=%s",
					newPart.Name,
					hitPos.X,
					hitPos.Y,
					hitPos.Z,
					if moveDir > 0 then "→" else "←"
				)
			)
		end
		return {
			newPart = newPart,
			newNormal = newNormal,
			hitPosition = hitPos,
			moveDir = moveDir,
		}
	end

	return nil
end

--- Fase B: Check completo — escaneo pasivo + gatillo de botón (WantsCover tap).
--- Si el escaneo reporta cover válida Y el jugador presionó el botón → true.
--- Si no hay cover o no hay botón → false (protección contra salto suicida).
local function _checkCoverSwap(resolver, ctx): boolean
	local scanData = _scanCoverSwap(resolver, ctx)
	if not scanData then
		return false
	end

	-- Gatillo manual: el jugador debe presionar el botón de acción (Space tap)
	if not ctx.Buffer:HasIntent("WantsCover") then
		if Constants.DEBUG_MODE then
			local now = os.clock()
			if now - resolver._swapDebugLastPrint > 0.3 then
				resolver._swapDebugLastPrint = now
				print("[CoverSwap] Escaneo POSITIVO pero NO hay WantsCover — esperando botón…")
			end
		end
		return false
	end

	if Constants.DEBUG_MODE then
		print("[CoverSwap] GATILLO ACTIVADO — Escaneo + WantsCover → ejecutando Cover Swap!")
	end

	ctx._swapData = scanData
	return true
end

------------------------------------------------------------------------
-- RULE TABLES (module-level constants — creadas una sola vez)
------------------------------------------------------------------------
-- Cada regla: { id: string, check: (resolver, ctx) → bool, execute: (resolver, ctx) → (string, string?, any?) }
-- ctx = ResolverContext { State, StateConfig, Env, Buffer, Intents, HasMovement }

------------------------------------------------------------------------
-- SHARED COVER RULES — Reglas reutilizadas en múltiples tablas de cover
------------------------------------------------------------------------

local SHARED_ExitCover = {
	id = "ExitCover",
	check = function(_resolver, ctx)
		return ctx.Buffer:HasIntent("WantsExitCover") or ctx.Intents:HasIntent("WantsExitCover")
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsExitCover")
		return "ExitCover", "CoverExiting", nil
	end,
}

local SHARED_RollOutOfCover = {
	id = "RollOutOfCover",
	check = function(resolver, ctx)
		return ctx.Buffer:HasIntent("WantsEvade") and isEvadeCooldownMet(resolver)
	end,
	execute = function(resolver, ctx)
		resolver._evadeStartTime = os.clock()
		ctx.Buffer:Consume("WantsEvade")
		return "RollOutOfCover", "Evading", { direction = ctx.Env.MoveDirection }
	end,
}

local SHARED_PopUpAim = {
	id = "PopUpAim",
	check = function(_resolver, ctx)
		return ctx.Intents:HasIntent("WantsAim")
	end,
	execute = function()
		return "PopUpAim", "CoverAim", nil
	end,
}

local SHARED_BlindFire = {
	id = "BlindFire",
	check = function(_resolver, ctx)
		return ctx.Intents:HasIntent("WantsBlindFire")
			or (ctx.Intents:HasIntent("WantsShoot") and not ctx.Intents:HasIntent("WantsAim"))
	end,
	execute = function()
		return "BlindFire", "CoverBlindFire", nil
	end,
}

local SHARED_ReloadInCover = {
	id = "ReloadInCover",
	check = function(_resolver, ctx)
		return ctx.Buffer:HasIntent("WantsReload")
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsReload")
		return "Reload", "Reloading", nil
	end,
}

local SHARED_BlockCoverTap = {
	id = "BlockCoverTap",
	check = function(_resolver, ctx)
		return ctx.Buffer:HasIntent("WantsCover")
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsCover")
		ctx.Buffer:Consume("WantsMantle")
		return "NoAction", nil, nil
	end,
}

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
			return ctx.Buffer:HasIntent("WantsMantle") and ctx.Env.HasCoverNearby and ctx.Env.CoverType == "Low"
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsMantle")
			ctx.Buffer:Consume("WantsCover")
			return "Mantle", "Mantling", nil
		end,
	},

	-- Prio 3: Evade / Roll (también se activa con WantsCover si no hay cover cerca)
	{
		id = "Evade",
		check = function(resolver, ctx)
			local wantsEvade = ctx.Buffer:HasIntent("WantsEvade")
			local coverFallback = ctx.Buffer:HasIntent("WantsCover") and not ctx.Env.HasCoverNearby
			return (wantsEvade or coverFallback) and ctx.StateConfig.canEvade and isEvadeCooldownMet(resolver)
		end,
		execute = function(resolver, ctx)
			resolver._evadeStartTime = os.clock()
			ctx.Buffer:Consume("WantsEvade")
			ctx.Buffer:Consume("WantsCover")
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
	-- Prio 1: Auto-mantle (cover bajo detectado al frente → vault automático)
	{
		id = "AutoMantle",
		check = function(_resolver, ctx)
			return ctx.Env.HasCoverNearby and ctx.Env.CoverType == "Low"
		end,
		execute = function()
			return "Mantle", "Mantling", nil
		end,
	},

	-- Prio 2: Auto-entry cover (cover alto detectado al frente → CoverSlide sin botón)
	{
		id = "SlideIntoCover",
		check = function(_resolver, ctx)
			return ctx.Env.HasCoverNearby
		end,
		execute = function(_resolver, ctx)
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

	-- Prio 3: Evade durante roadie run (también con WantsCover fallback)
	{
		id = "EvadeRoadie",
		check = function(resolver, ctx)
			local wantsEvade = ctx.Buffer:HasIntent("WantsEvade")
			local coverFallback = ctx.Buffer:HasIntent("WantsCover") and not ctx.Env.HasCoverNearby
			return (wantsEvade or coverFallback) and isEvadeCooldownMet(resolver)
		end,
		execute = function(resolver, ctx)
			resolver._evadeStartTime = os.clock()
			ctx.Buffer:Consume("WantsEvade")
			ctx.Buffer:Consume("WantsCover")
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
	SHARED_ExitCover, -- Prio 1
	SHARED_RollOutOfCover, -- Prio 2

	-- Prio 3: Vault (cover bajo + forward + cover/mantle button)
	{
		id = "Vault",
		check = function(_resolver, ctx)
			return (ctx.Buffer:HasIntent("WantsCover") or ctx.Buffer:HasIntent("WantsMantle"))
				and ctx.Env.CoverType == "Low"
				and ctx.Env.MoveDirection.Y > Constants.FORWARD_INPUT_THRESHOLD
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover")
			ctx.Buffer:Consume("WantsMantle")
			return "Vault", "Mantling", nil
		end,
	},

	-- Prio 3b: Cover Swap (salto entre coberturas adyacentes en esquina)
	{
		id = "CoverSwapIdle",
		check = function(resolver, ctx)
			return _checkCoverSwap(resolver, ctx)
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover")
			ctx.Buffer:Consume("WantsMantle")
			return "CoverSwap", "CoverSwap", ctx._swapData
		end,
	},

	SHARED_PopUpAim, -- Prio 4
	SHARED_BlindFire, -- Prio 5 (cubre BlindFire explícito + ShootAsBlindFire)
	SHARED_ReloadInCover, -- Prio 6

	-- Prio 7: Start CoverWalking (cualquier input de movimiento)
	{
		id = "StartCoverWalking",
		check = function(_resolver, ctx)
			return hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StartCoverWalking", "CoverWalking", nil
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

--- COVER WALKING RULES (movimiento lateral activo sobre la pared)
--- Transiciones disponibles mientras el jugador se desplaza en cover.
local COVER_WALKING_RULES = {
	SHARED_ExitCover, -- Prio 1
	SHARED_RollOutOfCover, -- Prio 2

	-- Prio 3: Cover Swap (se evalúa ANTES de BlockCoverTap)
	{
		id = "CoverSwapWalking",
		check = function(resolver, ctx)
			return _checkCoverSwap(resolver, ctx)
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover")
			ctx.Buffer:Consume("WantsMantle")
			return "CoverSwap", "CoverSwap", ctx._swapData
		end,
	},

	SHARED_BlockCoverTap, -- Prio 3b
	SHARED_PopUpAim, -- Prio 4
	SHARED_BlindFire, -- Prio 5
	SHARED_ReloadInCover, -- Prio 6

	-- Prio 7: Stop CoverWalking → CoverIdle (sin movimiento)
	{
		id = "StopCoverWalking",
		check = function(_resolver, ctx)
			return not hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StopCoverWalking", "CoverIdle", nil
		end,
	},

	-- Prio 8: Start CoverRunning (sprint intent mientras camina en cover)
	{
		id = "StartCoverRunning",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsRoadieRun")
		end,
		execute = function()
			return "StartCoverRunning", "CoverRunning", nil
		end,
	},
}

--- COVER RUNNING RULES (sprint lateral sobre la pared)
--- Transiciones disponibles mientras el jugador corre en cover.
local COVER_RUNNING_RULES = {
	SHARED_ExitCover, -- Prio 1
	SHARED_RollOutOfCover, -- Prio 2
	SHARED_BlockCoverTap, -- Prio 3
	SHARED_PopUpAim, -- Prio 4
	SHARED_BlindFire, -- Prio 5
	SHARED_ReloadInCover, -- Prio 6

	-- Prio 7: Soltar sprint + aún moviéndose → CoverWalking
	{
		id = "SlowDownToWalking",
		check = function(_resolver, ctx)
			return not ctx.Intents:HasIntent("WantsRoadieRun") and hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StopCoverRunning", "CoverWalking", nil
		end,
	},

	-- Prio 8: Sin movimiento → CoverIdle
	{
		id = "StopCoverRunning",
		check = function(_resolver, ctx)
			return not hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StopCoverRunning", "CoverIdle", nil
		end,
	},
}

--- COVER SWAP RULES (animación comprometida — ActionGroup)
--- Cancelaciones permitidas:
---   1. Cover desaparece → Idle (protección contra crash)
---   2. Hold Space (WantsRoadieRun) → RoadieRun (rompe cover completamente)
local COVER_SWAP_RULES = {
	-- Prio 1: Cover destino destruida/inválida → abortar a Idle
	{
		id = "InvalidatedSwap",
		check = function(_resolver, ctx)
			local coverHandler = ctx.CoverHandler
			if not coverHandler then
				return true
			end
			local coverInstance = coverHandler:GetCoverInstance()
			return coverInstance == nil or coverInstance.Parent == nil
		end,
		execute = function()
			return "ExitCover", "Idle", nil
		end,
	},

	-- Prio 2: Hold Space → RoadieRun (cancela swap y sale de cover)
	{
		id = "CancelSwapToRun",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsRoadieRun")
		end,
		execute = function()
			return "CancelSwapToRun", "RoadieRun", nil
		end,
	},
}

--- Mapa de sub-estado de cover → rule table correspondiente
--- Los nuevos estados de cover (CoverCorners) usan COVER_IDLE_RULES como fallback.
--- CoverSwap se maneja en _selectRules (es ActionGroup, no CoverGroup).
local COVER_SUB_RULES = {
	CoverAim = COVER_AIM_RULES,
	CoverBlindFire = COVER_BLINDFIRE_RULES,
	CoverIdle = COVER_IDLE_RULES,
	CoverWalking = COVER_WALKING_RULES,
	CoverRunning = COVER_RUNNING_RULES,
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
	self._coverHandler = nil -- Inyectado después via SetCoverHandler()

	-- Signal de salida: (action: string, targetState: string?, data: any?)
	self.ActionResolved = Signal.new()

	-- Cooldown del evade: registra el tick en que se inició el último evade.
	-- Cooldown total = EVADE_DURATION + EVADE_COOLDOWN (el roll debe terminar
	-- y luego esperar la ventana de vulnerabilidad antes de poder volver a evadir).
	self._evadeStartTime = -math.huge

	-- Throttle de debug para Cover Swap (per-instance, no module-level)
	self._swapDebugLastPrint = 0

	-- Tabla reutilizable para _buildContext (evita alloc por frame)
	self._ctxCache = {}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

--- Inyecta la referencia al CoverHandler (CoverMain) después de su creación.
--- Necesario porque MovementController crea CoverMain internamente y
--- MovementController a su vez recibe ActionResolver → dependencia circular.
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
--- Retorna: actionName, targetState, actionData (para compatibilidad)
function ActionResolver:Resolve(): (string, string?, any?)
	local state = self._stateMachine:GetCurrentState()

	-- En estados bloqueantes (animación comprometida) o inactivos, no resolver nada.
	-- Excepción: CoverSwap permite cancelación (cover destruida → Idle, hold Space → RoadieRun).
	if self._stateMachine:IsInGroup("InactiveGroup") then
		return "NoAction", nil, nil
	end
	if self._stateMachine:IsInGroup("ActionGroup") and state ~= "CoverSwap" then
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
			print(`[GoW] {action} → {targetState or "nil"} | State: {state}`)
		end
	end

	return action, targetState, data
end

------------------------------------------------------------------------
-- INTERNAL: Context Builder
------------------------------------------------------------------------

--- Construye un ResolverContext snapshot para este frame.
--- Se crea una sola vez y se pasa a todas las reglas.
--- _swapData se limpia explícitamente para evitar stale data de _checkCoverSwap.
function ActionResolver:_buildContext(state: string)
	local ctx = self._ctxCache
	ctx.State = state
	ctx.StateConfig = PlayerStateModule.GetState(state)
	ctx.Env = self._env:GetContext()
	ctx.EnvSensor = self._env
	ctx.CoverHandler = self._coverHandler
	ctx.Buffer = self._buffer
	ctx.Intents = self._intents
	ctx.HasMovement = hasMovementIntent(self._intents)
	ctx._swapData = nil -- Clear stale data from previous frame
	return ctx
end

------------------------------------------------------------------------
-- INTERNAL: Rule Selection
------------------------------------------------------------------------

--- Selecciona la tabla de reglas apropiada según el estado actual.
function ActionResolver:_selectRules(state: string, _ctx)
	if state == "DBNO" then
		return DBNO_RULES
	end

	-- CoverSwap es ActionGroup pero tiene su propia tabla de reglas (cancelación)
	if state == "CoverSwap" then
		return COVER_SWAP_RULES
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
