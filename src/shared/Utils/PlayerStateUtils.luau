--[[
	PlayerStateUtils.luau
	Resolución de capabilities por estado.

	Separa la lógica de merge (defaults + exceptions) del enum puro.
	Único consumidor: ActionResolver._buildContext().
]]

local PlayerStateUtils = {}

------------------------------------------------------------------------
-- CAPABILITY SYSTEM: Defaults + Exceptions
------------------------------------------------------------------------

--- El soldado base: todo habilitado. La mayoría de estados "activos"
--- (Idle, Walking, Aiming...) heredan esto sin cambios.
local CAPABILITY_DEFAULTS = {
	canShoot = true,
	canMove = true,
	canTakeCover = true,
	canEvade = true,
	canSprint = true,
	isVulnerable = true,
}

--- Templates reutilizables para evitar copy-paste de excepciones.
--- Todas las actions comprometidas bloquean todo.
local ALL_LOCKED = table.freeze({
	canShoot = false,
	canMove = false,
	canTakeCover = false,
	canEvade = false,
	canSprint = false,
})

--- Actions comprometidas + invulnerable (iframes, protección de pared, inactivo).
local ALL_LOCKED_INVULNERABLE = table.freeze({
	canShoot = false,
	canMove = false,
	canTakeCover = false,
	canEvade = false,
	canSprint = false,
	isVulnerable = false,
})

--- Solo los flags que DIFIEREN del default para cada estado.
--- Si un estado no aparece aquí, es idéntico al soldado base.
local CAPABILITY_EXCEPTIONS = {
	-- FREE MOVEMENT: Idle y Walking → sin excepciones (default completo)

	RoadieRun = {
		canShoot = false, -- NO puedes disparar en roadie run
		canSprint = false, -- Ya estás sprinting
	},

	Aiming = {
		canSprint = false, -- No sprint mientras apuntas
	},

	Firing = {
		canTakeCover = false, -- Debes dejar de disparar primero
		canSprint = false,
	},

	Reloading = {
		canShoot = false,
		canSprint = false,
	},

	ActiveReloading = {
		canShoot = false,
		canSprint = false,
	},

	-- COVER GROUP: estados activos donde el jugador toma decisiones

	CoverIdle = {
		canShoot = false, -- Debes hacer pop-out o blind fire
		canTakeCover = false, -- Ya en cover
		canSprint = false,
		isVulnerable = false, -- Protegido por la pared
	},

	CoverAim = {
		canMove = false, -- Estático mientras apuntas desde cover
		canTakeCover = false,
		canEvade = false, -- Debes volver a CoverIdle primero
		canSprint = false,
	},

	CoverAimHigh = {
		canMove = false, -- Pop-up desde high cover: estático, expuesto
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	CoverAimLow = {
		canMove = false, -- Apuntando sobre low cover: estático, expuesto
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	CoverPeek = {
		canMove = false, -- Asomado en esquina: sin movimiento
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	CoverBlindFire = {
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = false, -- Protegido pero poca precisión
	},

	CoverWalking = {
		canShoot = false,
		canTakeCover = false,
		canSprint = false,
		isVulnerable = false,
	},

	CoverRunning = {
		canShoot = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	CoverCorners = {
		canShoot = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = false,
	},

	-- ACTION GROUP: animaciones comprometidas — todo bloqueado
	CoverSlide = ALL_LOCKED,
	CoverEntering = ALL_LOCKED,
	CoverExiting = ALL_LOCKED,
	CoverSwap = ALL_LOCKED,
	Mantling = ALL_LOCKED,
	Vaulting = ALL_LOCKED,
	Executing = ALL_LOCKED,

	Evading = ALL_LOCKED_INVULNERABLE, -- iframes parciales

	-- DBNO GROUP
	DBNO = {
		canShoot = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	-- INACTIVE GROUP: sin character, sin mecánicas
	Death = ALL_LOCKED_INVULNERABLE,
	Spectator = ALL_LOCKED_INVULNERABLE,
	Lobby = ALL_LOCKED_INVULNERABLE,
}

------------------------------------------------------------------------
-- API
------------------------------------------------------------------------

--- Cache de capabilities mergeadas por estado (frozen).
--- Evita table.clone + merge en cada frame.
local _capabilityCache: { [string]: any } = {}

--- Obtiene la configuración de un estado con capabilities mergeadas.
--- Retorna una tabla frozen (inmutable) con Name + todos los capability flags.
--- Resultado cacheado: 0 allocaciones después de la primera llamada por estado.
function PlayerStateUtils.GetState(stateName: string)
	local cached = _capabilityCache[stateName]
	if cached then
		return cached
	end

	local state = table.clone(CAPABILITY_DEFAULTS)
	state.Name = stateName

	local exceptions = CAPABILITY_EXCEPTIONS[stateName]
	if exceptions then
		for key, value in exceptions do
			state[key] = value
		end
	end

	state = table.freeze(state)
	_capabilityCache[stateName] = state
	return state
end

return table.freeze(PlayerStateUtils)
