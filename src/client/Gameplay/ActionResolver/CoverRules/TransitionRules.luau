--[[
	TransitionRules.luau
	═══════════════════════════════════════════════════════════════
	Reglas de transición de cover:
	  - Entering (CoverEntering)
	  - Swap (CoverSwap)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Helpers = require(script.Parent.Parent:WaitForChild("Helpers"))
local SharedRules = require(script.Parent:WaitForChild("SharedRules"))

local TransitionRules = {}

------------------------------------------------------------------------
-- COVER ENTERING RULES (ActionGroup — resolución limitada)
------------------------------------------------------------------------

TransitionRules.Entering = {
	-- Prio 1: Vault desde entering (F key + cover bajo + landing seguro)
	{
		id = "VaultFromEntering",
		check = function(_resolver, ctx)
	if not (ctx.Env.IsInActiveCover and ctx.Buffer:HasIntent("WantsVault") and ctx.Env.ActiveCoverType == "Low") then
		return false
	end
	-- Validar seguridad de landing
	local vaultData = Helpers.preCheckVault(ctx)
	return vaultData ~= nil
		end,
		execute = function(_resolver, ctx)
	ctx.Buffer:Consume("WantsVault")
	local vaultData = Helpers.preCheckVault(ctx)
	if vaultData then
		return "VaultFromEntering", "Vaulting", vaultData
	end
			-- Fallback si preCheck falla entre check y execute
			return "VaultFromEntering",
				nil,
				{
					coverNormal = ctx.Env.ActiveCoverNormal,
					coverInstance = ctx.Env.ActiveCoverInstance,
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

	-- Prio 3: BlindFire durante entering (disparo sin apuntar)
	{
		id = "BlindFireFromEntering",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsShoot")
		end,
		execute = function()
			return "BlindFire", nil, nil
		end,
	},

	-- Prio 4: ExitCorner desde entering (reduce latencia de input)
	SharedRules.ExitCorner,

	-- Prio 5: CornerRollOut desde entering (roll lateral completo)
	SharedRules.CornerRollOut,
}

------------------------------------------------------------------------
-- COVER SWAP RULES (animación comprometida — ActionGroup)
------------------------------------------------------------------------

TransitionRules.Swap = {
	-- Prio 1: Cover destino destruida/inválida → abortar a Idle
	{
		id = "InvalidatedSwap",
		check = function(_resolver, ctx)
			if not ctx.Env.IsInActiveCover then
				return true
			end
			local coverInstance = ctx.Env.ActiveCoverInstance
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
		execute = function(_resolver, ctx)
			local worldDir = Helpers.computeWorldMoveDirection(ctx.Env.MoveDirection)
			return "CancelSwapToRun", "RoadieRun", { direction = worldDir }
		end,
	},
}

return TransitionRules
