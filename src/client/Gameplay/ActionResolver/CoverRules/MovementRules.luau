--[[
	MovementRules.luau
	═══════════════════════════════════════════════════════════════
	Reglas de movimiento en cover:
	  - Idle
	  - Walking
	  - Running
]]

local Helpers = require(script.Parent.Parent:WaitForChild("Helpers"))
local SharedRules = require(script.Parent:WaitForChild("SharedRules"))

local MovementRules = {}

------------------------------------------------------------------------
-- COVER IDLE RULES
------------------------------------------------------------------------

MovementRules.Idle = {
	SharedRules.ExitCover, -- Prio 1

	-- Prio 2: Cover Swap
	{
		id = "CoverSwapIdle",
		check = function(resolver, ctx)
			return Helpers.checkCoverSwap(resolver, ctx)
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover")
			return "CoverSwap", "CoverSwap", ctx._swapData
		end,
	},

	-- Prio 3: Vault (cover bajo + moving into cover + cover button)
	SharedRules.VaultFromCover,

	SharedRules.CornerRollOut, -- Prio 4
	SharedRules.ExitCorner, -- Prio 5
	SharedRules.RollOutOfCover, -- Prio 6
	SharedRules.PopUpAim, -- Prio 7
	SharedRules.BlindFire, -- Prio 8
	SharedRules.ReloadInCover, -- Prio 9
	SharedRules.BlockCoverTap, -- Prio 10

	-- Prio 11: Start CoverWalking
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

MovementRules.Walking = {
	SharedRules.ExitCover, -- Prio 1

	-- Prio 2: Cover Swap
	{
		id = "CoverSwapWalking",
		check = function(resolver, ctx)
			return Helpers.checkCoverSwap(resolver, ctx)
		end,
		execute = function(_resolver, ctx)
			ctx.Buffer:Consume("WantsCover")
			return "CoverSwap", "CoverSwap", ctx._swapData
		end,
	},

	-- Prio 3: Vault
	SharedRules.VaultFromCover,

	SharedRules.CornerRollOut, -- Prio 4
	SharedRules.ExitCorner, -- Prio 5
	SharedRules.BlockCoverTap, -- Prio 6
	SharedRules.PopUpAim, -- Prio 7
	SharedRules.BlindFire, -- Prio 8
	SharedRules.ReloadInCover, -- Prio 9

	-- Prio 10: Start CoverRunning
	{
		id = "StartCoverRunning",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsRoadieRun") and Helpers.hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StartCoverRunning", "CoverRunning", nil
		end,
	},

	-- Prio 11: Stop CoverWalking
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

MovementRules.Running = {
	SharedRules.ExitCover, -- Prio 1
	SharedRules.CornerRollOut, -- Prio 2
	SharedRules.ExitCorner, -- Prio 3
	SharedRules.RollOutOfCover, -- Prio 4
	SharedRules.BlockCoverTap, -- Prio 5
	SharedRules.PopUpAim, -- Prio 6
	SharedRules.BlindFire, -- Prio 7
	SharedRules.ReloadInCover, -- Prio 8

	-- Prio 9: Soltar sprint + aún moviéndose
	{
		id = "SlowDownToWalking",
		check = function(_resolver, ctx)
			return not ctx.Intents:HasIntent("WantsRoadieRun") and Helpers.hasMovementIntent(ctx.Intents)
		end,
		execute = function()
			return "StopCoverRunning", "CoverWalking", nil
		end,
	},

	-- Prio 10: Sin movimiento
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

return MovementRules
