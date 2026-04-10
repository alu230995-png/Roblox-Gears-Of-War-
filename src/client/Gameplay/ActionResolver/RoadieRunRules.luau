--[[
	RoadieRunRules.luau
	═══════════════════════════════════════════════════════════════
	Reglas para el estado RoadieRun.
	
	En GoW, durante RoadieRun el jugador auto-entra en cover al
	detectar una pared frontal, y auto-mantlea si es cover bajo.
]]

local Helpers = require(script.Parent:WaitForChild("Helpers"))

local RoadieRunRules = {
	-- Prio 1: Auto-entry cover (cover alto detectado al frente → CoverSlide sin botón)
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

	-- Prio 2: Evade durante roadie run (CoverButton.Tap inyecta WantsEvade directamente)
	{
		id = "EvadeRoadie",
		check = function(resolver, ctx)
	return ctx.Buffer:HasIntent("WantsEvade") and Helpers.isEvadeCooldownMet(resolver)
		end,
		execute = function(resolver, ctx)
	resolver._evadeStartTime = os.clock()
	ctx.Buffer:Consume("WantsEvade")
	return "Evade", "Evading", { direction = ctx.Env.MoveDirection }
		end,
	},

	-- Prio 3: Stop RoadieRun
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

return RoadieRunRules
