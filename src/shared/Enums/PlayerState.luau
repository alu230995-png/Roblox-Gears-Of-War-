--[[
	PlayerState.luau
	Enumeración de estados del jugador estilo Gears of War.
	
	Sistema de capabilities:
	  CAPABILITY_DEFAULTS define el soldado base (todo habilitado).
	  CAPABILITY_EXCEPTIONS solo declara lo que DIFIERE del default.
	  GetState(name) hace el merge automático.
	
	Capabilities:
	- canShoot: si puede disparar en este estado
	- canMove: si puede moverse libremente
	- canTakeCover: si puede entrar en cover
	- canEvade: si puede hacer dodge roll
	- canSprint: si puede activar roadie run
	- isVulnerable: si recibe daño normal (false = iframes o protegido)
	
	Jerarquía de estados:
	  Root
	  ├── AliveGroup (gameplay activo — tiene character)
	  │   ├── FreeMovementGroup (estados libres fuera de cover)
	  │   │   └── Idle, Walking, RoadieRun, Aiming, Firing, Reloading, ActiveReloading
	  │   ├── CoverGroup (activamente en cover — tomando decisiones)
	  │   │   └── CoverIdle, CoverAim, CoverBlindFire, CoverWalking, CoverRunning, CoverCorners
	  │   └── ActionGroup (animaciones comprometidas — bloqueadas)
	  │       └── Evading, Mantling, CoverSlide, CoverEntering, CoverExiting, CoverSwap, Executing
	  ├── DBNOGroup (down but not out)
	  │   └── DBNO
	  └── InactiveGroup (sin character ni mecánicas de movimiento)
	      └── Death, Spectator, Lobby
]]

local PlayerState = {}

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

	CoverSlide = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	CoverEntering = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	CoverExiting = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	CoverSwap = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	Evading = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = false, -- iframes parciales
	},

	Mantling = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	Executing = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	-- DBNO GROUP

	DBNO = {
		canShoot = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
	},

	-- INACTIVE GROUP: sin character, sin mecánicas

	Death = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = false,
	},

	Spectator = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = false,
	},

	Lobby = {
		canShoot = false,
		canMove = false,
		canTakeCover = false,
		canEvade = false,
		canSprint = false,
		isVulnerable = false,
	},
}

------------------------------------------------------------------------
-- TRANSITIONS
------------------------------------------------------------------------

--- Tabla de transiciones válidas: From → {To1, To2, ...}
--- Las transiciones heredadas por grupo se declaran a nivel de grupo.
--- Los estados hoja solo declaran transiciones específicas de ese estado.
PlayerState.Transitions = {
	-- Transiciones de grupo (heredadas por todos los hijos)
	AliveGroup = { "DBNO" },
	FreeMovementGroup = { "CoverSlide", "CoverEntering", "Evading", "Mantling" },
	CoverGroup = { "Evading", "Idle", "CoverExiting" },
	ActionGroup = { "Idle" },

	-- Transiciones específicas de estados hoja — Free Movement
	Idle = { "Walking", "RoadieRun", "Aiming", "Firing", "Reloading" },
	Walking = { "Idle", "RoadieRun", "Aiming", "Firing", "Reloading" },
	RoadieRun = { "Idle", "Walking" },
	Aiming = { "Idle", "Walking", "Firing", "Evading", "CoverSlide" },
	Firing = { "Idle", "Aiming", "Reloading", "Evading" },
	Reloading = { "Idle", "ActiveReloading", "Evading", "CoverIdle" },
	ActiveReloading = { "Idle", "Evading", "CoverIdle" },

	-- Transiciones específicas — Cover Group
	CoverIdle = { "CoverAim", "CoverBlindFire", "CoverWalking", "CoverCorners", "CoverSwap", "Reloading", "Mantling" },
	CoverAim = { "CoverIdle", "Firing" },
	CoverBlindFire = { "CoverIdle" },
	CoverWalking = { "CoverIdle", "CoverRunning", "CoverAim", "CoverBlindFire" },
	CoverRunning = { "CoverWalking", "CoverIdle" },
	CoverCorners = { "CoverIdle", "CoverAim", "CoverBlindFire", "Idle" },

	-- Transiciones específicas — Action Group
	CoverSlide = { "CoverIdle" },
	CoverEntering = { "CoverIdle", "Idle" },
	CoverExiting = { "Idle" },
	CoverSwap = { "CoverIdle" },
	Evading = { "Idle" },
	Mantling = { "Idle" },
	Executing = { "Idle" },

	-- DBNO
	DBNO = { "Idle", "Executing", "Death" },

	-- Inactive Group
	Death = { "Lobby", "Spectator" },
	Spectator = { "Lobby" },
	Lobby = { "Idle" },
}

------------------------------------------------------------------------
-- GROUPS (HSM Hierarchy)
------------------------------------------------------------------------

--- Definición de grupos jerárquicos.
--- Parent = grupo padre (nil = raíz)
--- States = estados hoja que pertenecen a este grupo
PlayerState.Groups = {
	AliveGroup = {
		Parent = nil,
		States = {
			"Idle",
			"Walking",
			"RoadieRun",
			"Aiming",
			"Firing",
			"Reloading",
			"ActiveReloading",
			"CoverIdle",
			"CoverAim",
			"CoverBlindFire",
			"CoverWalking",
			"CoverRunning",
			"CoverCorners",
			"CoverSlide",
			"CoverEntering",
			"CoverExiting",
			"CoverSwap",
			"Evading",
			"Mantling",
			"Executing",
		},
	},
	FreeMovementGroup = {
		Parent = "AliveGroup",
		States = { "Idle", "Walking", "RoadieRun", "Aiming", "Firing", "Reloading", "ActiveReloading" },
	},
	CoverGroup = {
		Parent = "AliveGroup",
		States = { "CoverIdle", "CoverAim", "CoverBlindFire", "CoverWalking", "CoverRunning", "CoverCorners" },
	},
	ActionGroup = {
		Parent = "AliveGroup",
		States = { "Evading", "Mantling", "CoverSlide", "CoverEntering", "CoverExiting", "CoverSwap", "Executing" },
	},
	DBNOGroup = {
		Parent = nil,
		States = { "DBNO" },
	},
	InactiveGroup = {
		Parent = nil,
		States = { "Death", "Spectator", "Lobby" },
	},
}

------------------------------------------------------------------------
-- API
------------------------------------------------------------------------

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

--- Obtiene la configuración de un estado con capabilities mergeadas.
--- Retorna una tabla nueva con Name + todos los capability flags.
function PlayerState.GetState(stateName: string)
	local state = table.clone(CAPABILITY_DEFAULTS)
	state.Name = stateName

	local exceptions = CAPABILITY_EXCEPTIONS[stateName]
	if exceptions then
		for key, value in exceptions do
			state[key] = value
		end
	end

	return state
end

--- Retorna la lista de todos los nombres de estado definidos.
function PlayerState.GetAllStateNames(): { string }
	local names = {}
	-- Recopilar todos los estados de todos los grupos
	for _, group in PlayerState.Groups do
		for _, stateName in group.States do
			if not table.find(names, stateName) then
				table.insert(names, stateName)
			end
		end
	end
	-- Añadir DBNO si no está (está en su propio grupo)
	if not table.find(names, "DBNO") then
		table.insert(names, "DBNO")
	end
	return names
end

return PlayerState
