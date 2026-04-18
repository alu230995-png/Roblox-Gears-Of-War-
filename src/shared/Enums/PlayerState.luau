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
	  │   │   └── CoverIdle, CoverAim, CoverAimHigh, CoverAimLow, CoverPeek, CoverBlindFire, CoverWalking, CoverRunning, CoverCorners
	  │   └── ActionGroup (animaciones comprometidas — bloqueadas)
	  │       └── Evading, Mantling, CoverSlide, CoverEntering, CoverExiting, CoverSwap, ExitCorner, Executing
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
	CoverGroup = { "Evading", "Idle", "CoverExiting", "ExitCorner" },
	ActionGroup = { "Idle" },

	-- Transiciones específicas de estados hoja — Free Movement
	Idle = { "Walking", "RoadieRun", "Aiming", "Firing", "Reloading" },
	Walking = { "Idle", "RoadieRun", "Aiming", "Firing", "Reloading" },
	RoadieRun = { "Idle", "Walking" },
	Aiming = { "Idle", "Walking", "Firing", "Evading", "CoverSlide" },
	Firing = { "Idle", "Walking", "Aiming", "Reloading", "Evading" },
	Reloading = { "Idle", "ActiveReloading", "Evading", "RoadieRun", "CoverIdle" },
	ActiveReloading = { "Idle", "Evading", "RoadieRun", "CoverIdle" },

	-- Transiciones específicas — Cover Group
	CoverIdle = {
		"CoverAim",
		"CoverAimHigh",
		"CoverAimLow",
		"CoverBlindFire",
		"CoverWalking",
		"CoverCorners",
		"CoverSwap",
		"Mantling",
		"Vaulting",
	},
	CoverAim = { "CoverIdle", "Firing" },
	CoverAimHigh = { "CoverIdle", "CoverPeek", "CoverFiring" },
	CoverAimLow = { "CoverIdle", "CoverPeek", "CoverFiring" },
	CoverPeek = { "CoverAimHigh", "CoverAimLow", "CoverIdle", "CoverFiring" },
	CoverFiring = { "CoverAimHigh", "CoverAimLow", "CoverIdle", "CoverPeek" },
	CoverBlindFire = { "CoverIdle" },
	CoverWalking = {
		"CoverIdle",
		"CoverRunning",
		"CoverAim",
		"CoverAimHigh",
		"CoverAimLow",
		"CoverPeek",
		"CoverBlindFire",
		"CoverSwap",
		"Vaulting",
	},
	CoverRunning = { "CoverWalking", "CoverIdle" },
	CoverCorners = { "CoverIdle", "CoverAim", "CoverAimHigh", "CoverAimLow", "CoverBlindFire", "Idle", "CoverSwap" },

	-- Transiciones específicas — Action Group
	CoverSlide = { "CoverIdle" },
	CoverEntering = { "CoverIdle", "Idle", "Vaulting" },
	CoverExiting = { "Idle" },
	CoverSwap = { "CoverIdle", "RoadieRun", "CoverWalking", "Idle" },
	ExitCorner = { "Idle", "Walking", "RoadieRun" },
	Evading = { "Idle", "Walking", "RoadieRun"},
	Mantling = { "Idle" },
	Vaulting = { "Idle", "Walking", "RoadieRun" },
	Executing = { "Idle" },

	-- DBNO
	DBNO = { "Idle", "Executing", "Death" },

	-- Inactive Group
	Death = { "Lobby", "Spectator", "Idle" },
	Spectator = { "Lobby", "Idle" },
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
			"CoverAimHigh",
			"CoverAimLow",
			"CoverPeek",
			"CoverFiring",
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
			"ExitCorner",
			"Executing",
		},
	},
	FreeMovementGroup = {
		Parent = "AliveGroup",
		States = { "Idle", "Walking", "RoadieRun", "Aiming", "Firing", "Reloading", "ActiveReloading" },
	},
	CoverGroup = {
		Parent = "AliveGroup",
		States = {
			"CoverIdle",
			"CoverAim",
			"CoverAimHigh",
			"CoverAimLow",
			"CoverPeek",
			"CoverFiring",
			"CoverBlindFire",
			"CoverWalking",
			"CoverRunning",
			"CoverCorners",
		},
	},
	ActionGroup = {
		Parent = "AliveGroup",
		States = { "Evading", "Mantling", "Vaulting", "CoverSlide", "CoverEntering", "CoverExiting", "CoverSwap", "ExitCorner", "Executing" },
	},
	DBNOGroup = {
		Parent = nil,
		States = { "DBNO" },
	},
	InactiveGroup = {
		Parent = nil,
		States = { "Death", "Spectator", "Lobby" },
	},

	-- Grupos de query: permiten preguntar "¿está en algún estado de apuntado?"
	AimingGroup = {
		Parent = "AliveGroup",
		States = { "Aiming", "CoverAimHigh", "CoverAimLow", "CoverPeek" },
	},
	CoverAimGroup = {
		Parent = "CoverGroup",
		States = { "CoverAimHigh", "CoverAimLow", "CoverPeek", "CoverFiring" },
	},
}

return table.freeze(PlayerState)
