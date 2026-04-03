--[[
	WeaponService.luau
	═══════════════════════════════════════════════════════════════
	Servicio autoritativo de armas en el servidor.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades futuras (Fase 7):
	- Ammo tracking autoritativo (el cliente NO modifica munición)
	- Fire rate validation
	- Hit validation (raycast server-side)
	- Active Reload system:
	    RELOAD_BAR_SPEED = 1.0
	    ACTIVE_RELOAD_WINDOW = 0.15 (15% sweet spot)
	    ACTIVE_RELOAD_BONUS_DAMAGE = 1.08 (8% bonus)
	    ACTIVE_RELOAD_BONUS_DURATION = 4.0s
	    FAILED_RELOAD_PENALTY = 1.5x tiempo
	
	Validación en cada FireRequest:
	  ✓ ¿tiene esa arma?
	  ✓ ¿tiene munición?
	  ✓ ¿rate of fire respetado?
	  ✓ ¿jugador está vivo (no DBNO)?
	
	Armas: Lancer, Gnasher, Longshot, TorqueBow, HammerOfDawn, Boomshot, Snub
	
	ESTADO: Stub — se implementará en Fase 7.
]]

local WeaponService = {}

function WeaponService:Init()
	-- Sin side-effects
end

function WeaponService:Start()
	-- TODO (Fase 7): Inicializar inventarios de armas por jugador
end

function WeaponService:Destroy()
	-- Sin conexiones que limpiar
end

return WeaponService
