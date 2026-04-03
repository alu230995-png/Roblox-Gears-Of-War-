--[[
	CombatService.luau
	═══════════════════════════════════════════════════════════════
	Servicio autoritativo de combate en el servidor.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades futuras (Fase 6-8):
	- Daño autoritativo (el servidor calcula, NO el cliente)
	- Health management (MAX_HEALTH = 600, regen delay = 5s, regen rate = 60HP/s)
	- Kill feed
	- DBNO system (DBNO_HEALTH = 150, DBNO_BLEEDOUT_TIME = 30s)
	- Ejecuciones (curb stomp, etc.)
	
	REGLA 05: El cliente predice. El servidor decide.
	
	ESTADO: Stub — se implementará en Fase 6.
]]

local CombatService = {}

function CombatService:Init()
	-- Sin side-effects
end

function CombatService:Start()
	-- TODO (Fase 6): Escuchar WeaponService para hit validation results
end

function CombatService:Destroy()
	-- Sin conexiones que limpiar
end

return CombatService
