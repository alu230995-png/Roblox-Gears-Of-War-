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
		return "RollOutOfCover", "Evading", { direction = ctx.Env.MoveDirection }
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

	-- Prio 3: Vault (cover bajo + moving into cover + cover/mantle/vault button)
	-- Solo si no hay swap válido (ya evaluado arriba).
	{
		id = "Vault",
		check = function(_resolver, ctx)
			return (
				ctx.Buffer:HasIntent("WantsCover")
				or ctx.Buffer:HasIntent("WantsMantle")
				or ctx.Buffer:HasIntent("WantsVault")
			)
				and ctx.Env.CoverType == "Low"
				and Helpers.isMovingIntoCover(ctx)
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover") -- batch consumption limpia siblings
			return "Vault",
				"Vaulting",
				{
					coverNormal = ctx.Env.CoverNormal,
					coverInstance = ctx.Env.CoverInstance,
				}
		end,
	},

	RollOutOfCover, -- Prio 4 (fallback si no hay swap ni vault)
	PopUpAim, -- Prio 5
	BlindFire, -- Prio 6 (cubre BlindFire explícito + ShootAsBlindFire)
	ReloadInCover, -- Prio 7

	-- Prio 8: Start CoverWalking (cualquier input de movimiento)
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

	-- Prio 3: Vault (cover bajo + moving into cover)
	-- Solo si no hay swap válido (ya evaluado arriba).
	{
		id = "VaultWalking",
		check = function(_resolver, ctx)
			return (
				ctx.Buffer:HasIntent("WantsCover")
				or ctx.Buffer:HasIntent("WantsMantle")
				or ctx.Buffer:HasIntent("WantsVault")
			)
				and ctx.Env.CoverType == "Low"
				and Helpers.isMovingIntoCover(ctx)
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover") -- batch consumption limpia siblings
			return "Vault", "Vaulting", {
				coverNormal = ctx.Env.CoverNormal,
				coverInstance = ctx.Env.CoverInstance,
			}
		end,
	},

	RollOutOfCover, -- Prio 4 (fallback si no hay swap ni vault)
	BlockCoverTap, -- Prio 5
	PopUpAim, -- Prio 6
	BlindFire, -- Prio 7
	ReloadInCover, -- Prio 8

	-- Prio 9: Start CoverRunning (sprint intent mientras camina en cover)
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

	-- Prio 10: Stop CoverWalking → CoverIdle (sin movimiento)
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
	RollOutOfCover, -- Prio 2
	BlockCoverTap, -- Prio 3
	PopUpAim, -- Prio 4
	BlindFire, -- Prio 5
	ReloadInCover, -- Prio 6

	-- Prio 7: Soltar sprint + aún moviéndose → CoverWalking
	{
		id = "SlowDownToWalking",
		check = function(_resolver, ctx)
			return not ctx.Intents:HasIntent("WantsRoadieRun") and Helpers.hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StopCoverRunning", "CoverWalking", nil
		end,
	},

	-- Prio 8: Sin movimiento → CoverIdle
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
