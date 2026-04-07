--[[
	DBNORules.luau
	═══════════════════════════════════════════════════════════════
	Reglas para el estado DBNO (Down But Not Out).
	El jugador solo puede arrastrarse o esperar ser revivido.
]]

local DBNORules = {
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

return DBNORules
