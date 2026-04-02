--[[
	PlayerState.luau
	Enumeración de estados del jugador estilo Gears of War.
	
	Cada estado define:
	- canShoot: si puede disparar en este estado
	- canMove: si puede moverse libremente
	- canTakeCover: si puede entrar en cover
	- canEvade: si puede hacer dodge roll
	- canSprint: si puede activar roadie run
	- isVulnerable: si recibe daño normal (false = iframes)
]]

local PlayerState = {}

PlayerState.States = {
	Idle = {
		Name = "Idle",
		canShoot = true,
		canMove = true,
		canTakeCover = true,
		canEvade = true,
		canSprint = true,
		isVulnerable = true,
	},

	Walking = {
		Name = "Walking",
		canShoot = true,
		canMove = true,
		canTakeCover = true,
		canEvade = true,
		canSprint = true,
		isVulnerable = true,
	},

	RoadieRun = {
		Name = "RoadieRun",
		canShoot = false, -- NO puedes disparar en roadie run
		canMove = true,
		canTakeCover = true, -- Puedes deslizarte a cover desde roadie
		canEvade = true,
		canSprint = false, -- Ya estás sprinting
		isVulnerable = true,
	},

	CoverIdle = {
		Name = "CoverIdle",
		canShoot = false, -- Debes hacer pop-out o blind fire
		canMove = true, -- Movimiento lateral en cover
		canTakeCover = false, -- Ya en cover
		canEvade = true, -- Puedes salir con roll
		canSprint = false, -- No sprint en cover
		isVulnerable = false, -- Protegido por la pared
	},

	CoverAim = {
		Name = "CoverAim",
		canShoot = true, -- Pop-out para apuntar/disparar
		canMove = false, -- Estático mientras apuntas desde cover
		canTakeCover = false,
		canEvade = false, -- Debes volver a CoverIdle primero
		canSprint = false,
		isVulnerable = true, -- Expuesto al hacer pop-out
	},

	CoverBlindFire = {
		Name = "CoverBlindFire",
		canShoot = true, -- Disparo a ciegas sin apuntar
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = false, -- Protegido pero poca precisión
	},

	CoverSlide = {
		Name = "CoverSlide",
		canShoot = false,
		canMove = false, -- Animación de deslizamiento
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = true,
	},

	Evading = {
		Name = "Evading",
		canShoot = false,
		canMove = false, -- Comprometido en el roll
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = false, -- iframes parciales
	},

	Mantling = {
		Name = "Mantling",
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = true,
	},

	DBNO = {
		Name = "DBNO",
		canShoot = false,
		canMove = true, -- Arrastrarse
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = true,
	},

	Executing = {
		Name = "Executing",
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = true, -- Puedes ser interrumpido
	},

	Reloading = {
		Name = "Reloading",
		canShoot = false,
		canMove = true,
		canTakeCover = true,
		canEvade = true,
		canSprint = false,
		isVulnerable = true,
	},

	ActiveReloading = {
		Name = "ActiveReloading",
		canShoot = false,
		canMove = true,
		canTakeCover = true,
		canEvade = true,
		canSprint = false,
		isVulnerable = true,
	},

	Aiming = {
		Name = "Aiming",
		canShoot = true,
		canMove = true, -- Movimiento reducido al apuntar
		canTakeCover = true,
		canEvade = true,
		canSprint = false, -- No sprint mientras apuntas
		isVulnerable = true,
	},

	Firing = {
		Name = "Firing",
		canShoot = true, -- Disparo continuo
		canMove = true, -- Movimiento reducido
		canTakeCover = false, -- Debes dejar de disparar primero
		canEvade = true,
		canSprint = false,
		isVulnerable = true,
	},
}

--- Tabla de transiciones válidas: From → {To1, To2, ...}
PlayerState.Transitions = {
	Idle = { "Walking", "RoadieRun", "CoverSlide", "Evading", "Aiming", "Firing", "Reloading", "DBNO" },
	Walking = { "Idle", "RoadieRun", "CoverSlide", "Evading", "Aiming", "Firing", "Reloading", "DBNO" },
	RoadieRun = { "Idle", "Walking", "CoverSlide", "Evading", "Mantling", "DBNO" },
	CoverIdle = { "CoverAim", "CoverBlindFire", "Evading", "Idle", "Mantling", "Reloading", "DBNO" },
	CoverAim = { "CoverIdle", "Firing", "DBNO" },
	CoverBlindFire = { "CoverIdle", "DBNO" },
	CoverSlide = { "CoverIdle", "DBNO" },
	Evading = { "Idle", "DBNO" },
	Mantling = { "Idle", "DBNO" },
	DBNO = { "Idle", "Executing" }, -- Idle = revivido
	Executing = { "Idle" },
	Reloading = { "Idle", "ActiveReloading", "Evading", "CoverIdle", "DBNO" },
	ActiveReloading = { "Idle", "Evading", "CoverIdle", "DBNO" },
	Aiming = { "Idle", "Walking", "Firing", "Evading", "CoverSlide", "DBNO" },
	Firing = { "Idle", "Aiming", "Reloading", "Evading", "DBNO" },
}

--- Verifica si una transición de estado es válida.
function PlayerState.CanTransition(from: string, to: string): boolean
	local validTargets = PlayerState.Transitions[from]
	if not validTargets then
		return false
	end

	for _, target in validTargets do
		if target == to then
			return true
		end
	end

	return false
end

--- Obtiene la configuración de un estado.
function PlayerState.GetState(stateName: string)
	return PlayerState.States[stateName]
end

return PlayerState
