--[[
	CoverRules.luau
	═══════════════════════════════════════════════════════════════
	Todas las reglas de cover agrupadas:
	  - Reglas compartidas (ExitCover, RollOut, PopUpAim, BlindFire, Reload, BlockTap)
	  - Sub-estados: Aim, BlindFire, Idle, Walking, Running, Swap
	  - Mapa de selección SubRules[stateName] → rule table
	
	Agrupar todas las reglas de cover en un solo módulo facilita
	la reutilización de reglas compartidas sin dependencias circulares
	y permite ver de un vistazo toda la lógica de cover.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Helpers = require(script.Parent:WaitForChild("Helpers"))
local CoverRules = {}

------------------------------------------------------------------------
-- SHARED COVER RULES (reutilizadas en múltiples sub-estados)
------------------------------------------------------------------------

local ExitCover = {
	id = "ExitCover",
	check = function(_resolver, ctx)
		return ctx.Buffer:HasIntent("WantsExitCover") or ctx.Intents:HasIntent("WantsExitCover")
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsExitCover")
		return "ExitCover", "CoverExiting", nil
	end,
}

local RollOutOfCover = {
	id = "RollOutOfCover",
	check = function(resolver, ctx)
		return ctx.Buffer:HasIntent("WantsEvade") and Helpers.isEvadeCooldownMet(resolver)
	end,
	execute = function(resolver, ctx)
		resolver._evadeStartTime = os.clock()
		ctx.Buffer:Consume("WantsEvade")
		return "RollOutOfCover", "Evading", nil
	end,
}

--- CornerRollOut (fallback de CoverSwap): En esquina exterior + WantsCover
--- y NO se encontró swap válido + dirección MUY lateral (≈ paralela a la pared) →
--- roll completo con marometa (misma animación/sonido que Evade).
local CornerRollOut = {
	id = "CornerRollOut",
	check = function(resolver, ctx)
		return ctx.Env.IsAtOuterCorner
			and ctx.Buffer:HasIntent("WantsCover")
			and Helpers.isEvadeCooldownMet(resolver)
			and Helpers.computeLateralScale(ctx) >= Constants.EXIT_CORNER_LATERAL_THRESHOLD
	end,
	execute = function(resolver, ctx)
		resolver._evadeStartTime = os.clock()
		ctx.Buffer:Consume("WantsCover")
		local dir = ctx.Env.RawMovementDirection or ctx.Env.CornerExitDirection
		return "CornerRollOut", "Evading", { direction = dir }
	end,
}

--- ExitCorner (fallback de CoverSwap): En esquina exterior + WantsCover
--- y NO se encontró swap válido + dirección DIAGONAL (no puramente lateral) →
--- salida rápida sin marometa, misma física pero duración más corta.
--- Puede acumular con Idle → Walking → RoadieRun via input buffering natural.
local ExitCorner = {
	id = "ExitCorner",
	check = function(resolver, ctx)
		return ctx.Env.IsAtOuterCorner
			and ctx.Buffer:HasIntent("WantsCover")
			and Helpers.isEvadeCooldownMet(resolver)
			and Helpers.computeLateralScale(ctx) < Constants.EXIT_CORNER_LATERAL_THRESHOLD
	end,
	execute = function(resolver, ctx)
		resolver._evadeStartTime = os.clock()
		ctx.Buffer:Consume("WantsCover")
		local dir = ctx.Env.RawMovementDirection or ctx.Env.CornerExitDirection
		return "ExitCorner", "ExitCorner", { direction = dir }
	end,
}

local PopUpAim = {
	id = "PopUpAim",
	check = function(_resolver, ctx)
		return ctx.Intents:HasIntent("WantsAim")
	end,
	execute = function()
		return "PopUpAim", "CoverAim", nil
	end,
}

local BlindFire = {
	id = "BlindFire",
	check = function(_resolver, ctx)
		return ctx.Intents:HasIntent("WantsBlindFire")
			or (ctx.Intents:HasIntent("WantsShoot") and not ctx.Intents:HasIntent("WantsAim"))
	end,
	execute = function()
		return "BlindFire", "CoverBlindFire", nil
	end,
}

local ReloadInCover = {
	id = "ReloadInCover",
	check = function(_resolver, ctx)
		return ctx.Buffer:HasIntent("WantsReload")
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsReload")
		return "Reload", "Reloading", nil
	end,
}

local BlockCoverTap = {
	id = "BlockCoverTap",
	check = function(_resolver, ctx)
		return ctx.Buffer:HasIntent("WantsCover")
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsCover") -- batch consumption limpia WantsMantle + WantsEvade
		return "NoAction", nil, nil
	end,
}

------------------------------------------------------------------------
-- COVER AIM RULES
------------------------------------------------------------------------

CoverRules.Aim = {
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

------------------------------------------------------------------------
-- COVER BLIND FIRE RULES
------------------------------------------------------------------------

CoverRules.BlindFire = {
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

------------------------------------------------------------------------
-- COVER IDLE RULES
------------------------------------------------------------------------

CoverRules.Idle = {
	ExitCover, -- Prio 1

	-- Prio 2: Cover Swap (salto entre coberturas adyacentes en esquina)
	-- Evaluado ANTES de Vault: si hay swap válido en la esquina, el swap
	-- tiene prioridad sobre vault. Batch consumption limpia WantsEvade.
	{
		id = "CoverSwapIdle",
		check = function(resolver, ctx)
			return Helpers.checkCoverSwap(resolver, ctx)
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover") -- batch consumption limpia siblings
			return "CoverSwap", "CoverSwap", ctx._swapData
		end,
	},

	-- Prio 3: Vault (cover bajo + moving into cover + cover button)
	-- Solo si no hay swap válido (ya evaluado arriba).
	-- Usa CoverHandler como fuente de datos (fiable cuando ya estamos en cover).
	{
		id = "Vault",
		check = function(_resolver, ctx)
			local handler = ctx.CoverHandler
			if not (handler
				and ctx.Buffer:HasIntent("WantsCover")
				and handler:GetCoverType() == "Low"
				and Helpers.isMovingIntoCover(ctx, handler:GetNormal())) then
				return false
			end
			return Helpers.preCheckVault(ctx, handler:GetNormal(), handler:GetCoverInstance())
		end,
		execute = function(_resolver, ctx)
			local handler = ctx.CoverHandler
			ctx.Buffer:Consume("WantsCover") -- batch consumption limpia siblings
			local vd = ctx._vaultData
			return "Vault",
				"Vaulting",
				{
					coverNormal = handler:GetNormal(),
					coverInstance = handler:GetCoverInstance(),
					landingPos = vd.landingPos,
					landingType = vd.landingType,
				}
		end,
	},

	CornerRollOut, -- Prio 4: Fallback de CoverSwap en esquina (lateral → roll completo)
	ExitCorner, -- Prio 5: Fallback de CoverSwap en esquina (diagonal → salida rápida)
	RollOutOfCover, -- Prio 6: Evade roll (WantsEvade, cualquier posición)
	PopUpAim, -- Prio 7
	BlindFire, -- Prio 8 (cubre BlindFire explícito + ShootAsBlindFire)
	ReloadInCover, -- Prio 9
	BlockCoverTap, -- Prio 10: Consumir WantsCover huérfano

	-- Prio 11: Start CoverWalking (cualquier input de movimiento)
	{
		id = "StartCoverWalking",
		check = function(_resolver, ctx)
			return Helpers.hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StartCoverWalking", "CoverWalking", nil
		end,
	},
}

------------------------------------------------------------------------
-- COVER WALKING RULES
------------------------------------------------------------------------

CoverRules.Walking = {
	ExitCover, -- Prio 1

	-- Prio 2: Cover Swap (antes de Vault — si hay swap válido, no saltear)
	{
		id = "CoverSwapWalking",
		check = function(resolver, ctx)
			return Helpers.checkCoverSwap(resolver, ctx)
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover") -- batch consumption limpia siblings
			return "CoverSwap", "CoverSwap", ctx._swapData
		end,
	},

	-- Prio 3: Vault (cover bajo + moving into cover + cover button)
	-- Solo si no hay swap válido (ya evaluado arriba).
	-- Usa CoverHandler como fuente de datos (fiable cuando ya estamos en cover).
	{
		id = "VaultWalking",
		check = function(_resolver, ctx)
			local handler = ctx.CoverHandler
			if not (handler
				and ctx.Buffer:HasIntent("WantsCover")
				and handler:GetCoverType() == "Low"
				and Helpers.isMovingIntoCover(ctx, handler:GetNormal())) then
				return false
			end
			return Helpers.preCheckVault(ctx, handler:GetNormal(), handler:GetCoverInstance())
		end,
		execute = function(_resolver, ctx)
			local handler = ctx.CoverHandler
			ctx.Buffer:Consume("WantsCover") -- batch consumption limpia siblings
			local vd = ctx._vaultData
			return "Vault",
				"Vaulting",
				{
					coverNormal = handler:GetNormal(),
					coverInstance = handler:GetCoverInstance(),
					landingPos = vd.landingPos,
					landingType = vd.landingType,
				}
		end,
	},

	CornerRollOut, -- Prio 4: Fallback de CoverSwap en esquina (lateral → roll completo)
	ExitCorner, -- Prio 5: Fallback de CoverSwap en esquina (diagonal → salida rápida)
	BlockCoverTap, -- Prio 6
	PopUpAim, -- Prio 7
	BlindFire, -- Prio 8
	ReloadInCover, -- Prio 9

	-- Prio 10: Start CoverRunning (sprint intent mientras camina en cover)
	-- Evaluado ANTES de StopCoverWalking: si sprint + soltar movimiento
	-- ocurren en el mismo frame, sprint tiene prioridad (BUG-001 fix).
	{
		id = "StartCoverRunning",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsRoadieRun") and Helpers.hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StartCoverRunning", "CoverRunning", nil
		end,
	},

	-- Prio 11: Stop CoverWalking → CoverIdle (sin movimiento)
	{
		id = "StopCoverWalking",
		check = function(_resolver, ctx)
			return not Helpers.hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StopCoverWalking", "CoverIdle", nil
		end,
	},
}

------------------------------------------------------------------------
-- COVER RUNNING RULES
------------------------------------------------------------------------

CoverRules.Running = {
	ExitCover, -- Prio 1
	CornerRollOut, -- Prio 2: Fallback de CoverSwap en esquina (lateral → roll completo)
	ExitCorner, -- Prio 3: Fallback de CoverSwap en esquina (diagonal → salida rápida)
	BlockCoverTap, -- Prio 4
	PopUpAim, -- Prio 5
	BlindFire, -- Prio 6
	ReloadInCover, -- Prio 7

	-- Prio 8: Soltar sprint + aún moviéndose → CoverWalking
	{
		id = "SlowDownToWalking",
		check = function(_resolver, ctx)
	return not ctx.Intents:HasIntent("WantsRoadieRun") and Helpers.hasMovementIntent(ctx.Intents)
		end,
		execute = function()
	return "StopCoverRunning", "CoverWalking", nil
		end,
	},

	-- Prio 9: Sin movimiento → CoverIdle
	{
		id = "StopCoverRunning",
		check = function(_resolver, ctx)
			return not Helpers.hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StopCoverRunning", "CoverIdle", nil
		end,
	},
}

------------------------------------------------------------------------
-- COVER ENTERING RULES (ActionGroup — resolución limitada)
-- Solo dos acciones: vault pendiente (InteractButton + Low cover)
-- y cover chaining (WantsCover durante entering → redirigir snap).
------------------------------------------------------------------------

CoverRules.Entering = {
	-- Prio 1: Vault desde entering (F key + cover bajo)
	{
		id = "VaultFromEntering",
		check = function(_resolver, ctx)
			local handler = ctx.CoverHandler
			return handler and ctx.Buffer:HasIntent("WantsVault") and handler:GetCoverType() == "Low"
		end,
		execute = function(_resolver, ctx)
			local handler = ctx.CoverHandler
			ctx.Buffer:Consume("WantsVault")
			return "VaultFromEntering",
				nil,
				{
					coverNormal = handler:GetNormal(),
					coverInstance = handler:GetCoverInstance(),
				}
		end,
	},

	-- Prio 2: Cover chaining (re-pulsar cover durante entering)
	{
		id = "CoverChain",
		check = function(_resolver, ctx)
			return ctx.Buffer:HasIntent("WantsCover")
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover")
			return "CoverChain", nil, nil
		end,
	},
}

------------------------------------------------------------------------
-- COVER SWAP RULES (animación comprometida — ActionGroup)
-- Cancelaciones permitidas:
--   1. Cover desaparece → Idle (protección contra crash)
--   2. Hold Space (WantsRoadieRun) → RoadieRun (rompe cover)
------------------------------------------------------------------------

CoverRules.Swap = {
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

------------------------------------------------------------------------
-- SUB-STATE MAPPING
-- Los nuevos estados de cover (CoverCorners) usan Idle como fallback.
-- CoverSwap se maneja en init.luau (es ActionGroup, no CoverGroup).
------------------------------------------------------------------------

CoverRules.SubRules = {
	CoverAim = CoverRules.Aim,
	CoverBlindFire = CoverRules.BlindFire,
	CoverIdle = CoverRules.Idle,
	CoverWalking = CoverRules.Walking,
	CoverRunning = CoverRules.Running,
	CoverCorners = CoverRules.Idle,
}

return CoverRules
