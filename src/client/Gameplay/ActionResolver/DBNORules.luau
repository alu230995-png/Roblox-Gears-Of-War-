--[[
	DBNORules.luau
	═══════════════════════════════════════════════════════════════
	Reglas para el estado DBNO (Down But Not Out).
	El jugador puede arrastrarse y presionar A/Space para auto-revive.
	Prioridad: SelfRevive > Crawl (ambas pueden coexistir en un frame).
]]

local DBNORules = {
	-- Auto-revive: el jugador presiona A/Space para acumular puntos
	{
		id = "SelfRevive",
		check = function(_resolver, ctx)
	return ctx.Buffer:HasIntent("WantsSelfRevive")
		end,
		execute = function(_resolver, ctx)
	ctx.Buffer:Consume("WantsSelfRevive")
	return "SelfReviveAttempt", nil, nil
		end,
	},

	-- Arrastrarse: movimiento reducido mientras está caído
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
