--[[
	PlayerState.luau
	Enumeración de estados del jugador estilo Gears of War.
	Solo datos: transiciones válidas y jerarquía de grupos.
	La lógica de capabilities vive en Utils/PlayerStateUtils.luau.

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
-- TRANSITIONS
------------------------------------------------------------------------

--- Tabla de transiciones válidas: From → {To1, To2, ...}
--- Las transiciones heredadas por grupo se declaran a nivel de grupo.
--- Los estados hoja solo declaran transiciones específicas de ese estado.
PlayerState.Transitions = {
	-- Transiciones de grupo (heredadas por todos los hijos)
	AliveGroup = { "DBNO" },
	FreeMovementGroup = { "CoverSlide", "CoverEntering", "Evading", "Mantling", "Vaulting" },
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
	CoverIdle = {
		"CoverAim",
		"CoverBlindFire",
		"CoverWalking",
		"CoverCorners",
		"CoverSwap",
		"Reloading",
		"Mantling",
		"Vaulting",
	},
	CoverAim = { "CoverIdle", "Firing" },
	CoverBlindFire = { "CoverIdle" },
	CoverWalking = { "CoverIdle", "CoverRunning", "CoverAim", "CoverBlindFire", "CoverSwap", "Vaulting" },
	CoverRunning = { "CoverWalking", "CoverIdle" },
	CoverCorners = { "CoverIdle", "CoverAim", "CoverBlindFire", "Idle", "CoverSwap" },

	-- Transiciones específicas — Action Group
	CoverSlide = { "CoverIdle" },
	CoverEntering = { "CoverIdle", "Idle", "Vaulting" },
	CoverExiting = { "Idle" },
	CoverSwap = { "CoverIdle", "RoadieRun", "CoverWalking", "Idle" },
	Evading = { "Idle" },
	Mantling = { "Idle" },
	Vaulting = { "Idle", "Walking", "RoadieRun" },
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
			"Vaulting",
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
		States = { "Evading", "Mantling", "Vaulting", "CoverSlide", "CoverEntering", "CoverExiting", "CoverSwap", "Executing" },
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

return table.freeze(PlayerState)
