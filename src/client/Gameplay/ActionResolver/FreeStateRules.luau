--[[
	FreeStateRules.luau
	═══════════════════════════════════════════════════════════════
	Reglas para estados libres: Idle, Walking, Aiming, Firing,
	Reloading, ActiveReloading.
	
	Prioridad GoW — botón A (tap):
	  1. ¿Puedo entrar en cover? → Sí → EnterCover
	  2. ¿No? ¿Puedo mantlear?  → Sí → Mantle
	  3. ¿No? ¿Puedo evadirme?  → Sí → Evade/Roll
	  …y así sucesivamente hasta Movement como fallback.
]]

local Helpers = require(script.Parent:WaitForChild("Helpers"))

local FreeStateRules = {
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

	-- Prio 2: Vault (cover bajo + moving into cover + InteractButton/CoverButton)
	{
		id = "Vault",
		check = function(_resolver, ctx)
	return ctx.Buffer:HasIntent("WantsVault")
		and ctx.Env.HasCoverNearby
		and ctx.Env.CoverType == "Low"
		and Helpers.isMovingIntoCover(ctx)
		end,
		execute = function(_resolver, ctx)
	ctx.Buffer:Consume("WantsVault")
	return "Vault", "Vaulting", {
		coverNormal = ctx.Env.CoverNormal,
		coverInstance = ctx.Env.CoverInstance,
	}
		end,
	},

	-- Prio 3: Evade / Roll (CoverButton.Tap ahora inyecta WantsEvade directamente)
	{
		id = "Evade",
		check = function(resolver, ctx)
			return ctx.Buffer:HasIntent("WantsEvade")
				and ctx.StateConfig.canEvade
				and Helpers.isEvadeCooldownMet(resolver)
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

	-- Prio 11: Movement (Walking / Idle transitions — fallback)
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

return FreeStateRules
