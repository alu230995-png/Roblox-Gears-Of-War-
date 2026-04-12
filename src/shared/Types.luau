--[[
	Types.luau
	Definiciones de tipos compartidos para el proyecto Gears of War.
	Usado por client, server y shared.
]]

export type PlayerState =
	"Idle"
	| "Walking"
	| "RoadieRun"
	| "CoverIdle"
	| "CoverAim"
	| "CoverAimHigh"
	| "CoverAimLow"
	| "CoverPeek"
	| "CoverBlindFire"
	| "CoverSlide"
	| "CoverEntering"
	| "CoverWalking"
	| "CoverRunning"
	| "CoverExiting"
	| "CoverCorners"
	| "CoverSwap"
	| "Evading"
	| "Mantling"
	| "Vaulting"
	| "DBNO"
	| "Executing"
	| "Reloading"
	| "ActiveReloading"
	| "Aiming"
	| "Firing"
	| "Death"
	| "Spectator"
	| "Lobby"

-- RESERVED Phase 3 — not yet used
export type InputAction =
	"MoveForward"
	| "MoveBackward"
	| "MoveLeft"
	| "MoveRight"
	| "RoadieRun"
	| "TakeCover"
	| "Aim"
	| "Fire"
	| "Reload"
	| "Evade"
	| "Mantle"
	| "Execute"
	| "SwapWeapon"
	| "MeleeChainsaw"

-- RESERVED Phase 3 — not yet used
export type MovementConfig = {
	WalkSpeed: number,
	RoadieRunSpeed: number,
	CoverSlideSpeed: number,
	EvadeSpeed: number,
	Acceleration: number,
	Deceleration: number,
	Friction: number,
	Gravity: number,
	JumpPower: number,
}

-- RESERVED Phase 5 — not yet used
export type CameraBobConfig = {
	Enabled: boolean,
	Frequency: number,
	AmplitudeX: number,
	AmplitudeY: number,
	RoadieRunMultiplier: number,
}

-- RESERVED Phase 3 — not yet used
export type CoverSnapConfig = {
	MaxDetectionRange: number,
	SnapSpeed: number,
	MagnetismAngle: number,
	ExitSpeed: number,
}

-- RESERVED Phase 3 — not yet used
export type StateTransition = {
	From: PlayerState,
	To: PlayerState,
	Condition: string,
}

-- RESERVED Phase 3 — not yet used
export type InputBinding = {
	Action: InputAction,
	KeyCode: Enum.KeyCode?,
	UserInputType: Enum.UserInputType?,
	HoldDuration: number?,
}

------------------------------------------------------------------------
-- HSM (Hierarchical State Machine)
------------------------------------------------------------------------

-- RESERVED Phase 3 — not yet used
export type StateGroup = {
	Name: string,
	Parent: string?,
	States: { string },
}

-- RESERVED Phase 3 — not yet used
export type HSMCallbacks = {
	OnEnter: ((fromState: string) -> ())?,
	OnExit: ((toState: string) -> ())?,
}

------------------------------------------------------------------------
-- INPUT SYSTEM (Capas 1-5)
------------------------------------------------------------------------

-- RESERVED Phase 3 — not yet used
export type RawInputEvent = {
	Name: string,
	Mode: string, -- "Tap" | "HoldStart" | "Release" | "Pressed" | "Released"
	Data: any?,
	Timestamp: number,
}

export type Intent =
	"WantsCover"
	| "WantsEvade"
	| "WantsRoadieRun"
	| "WantsStopRoadieRun"
	| "WantsMoveForward"
	| "WantsMoveBackward"
	| "WantsMoveLeft"
	| "WantsMoveRight"
	| "WantsShoot"
	| "WantsStopShoot"
	| "WantsAim"
	| "WantsStopAim"
	| "WantsReload"
	| "WantsBlindFire"
	| "WantsStopBlindFire"
	| "WantsMelee"
	| "WantsChainsaw"
	| "WantsStopChainsaw"
	| "WantsInteract"
	| "WantsSwapWeapon"
	| "WantsMantle"
	| "WantsVault"
	| "WantsExitCover"

-- RESERVED Phase 3 — not yet used (only referenced in comments)
export type BufferEntry = {
	Intent: Intent,
	Timestamp: number,
	TTL: number,
	Consumed: boolean,
	Data: any?,
	BatchId: number?,
}

export type EnvironmentContext = {
	HasCoverNearby: boolean,
	CoverType: string?, -- "Low" | "High" | nil
	CoverNormal: Vector3?,
	CoverPosition: Vector3?,
	CoverInstance: BasePart?,
	IsAtCornerLeft: boolean,
	IsAtCornerRight: boolean,
	MoveDirection: Vector2,
	-- Corner exit system (outer corners)
	IsAtOuterCorner: boolean,
	CornerExitDirection: Vector3?, -- perpendicular al muro, hacia el espacio abierto
	RawMovementDirection: Vector3?, -- input del jugador en world-space
}

------------------------------------------------------------------------
-- WEAPON SYSTEM — RESERVED Phase 7 — not yet used
------------------------------------------------------------------------

export type WeaponType = "Lancer" | "Gnasher" | "Longshot" | "TorqueBow" | "HammerOfDawn" | "Boomshot" | "Snub"

export type WeaponState = "Equipped" | "Unequipped" | "Shooting" | "Reloading"

export type WeaponConfig = {
	Name: string,
	Type: WeaponType,
	Damage: number,
	FireRate: number,
	MagazineSize: number,
	ReloadTime: number,
	Range: number,
	HeadshotMultiplier: number,
	ActiveReloadBonus: number,
}

--- Stats de arma tal como se definen en WeaponConstants.STATS[weaponName].
export type WeaponStats = {
	Damage: number,
	FireRate: number,
	MagazineSize: number,
	ReloadTime: number,
	Range: number,
	Spread: number,
	FireMode: "Auto" | "Semi" | "Burst",
}

--- Datos de un arma dropeada en el mundo (atributos del Model).
export type WeaponDropInfo = {
	WeaponName: string,
	DroppedBy: string,
}

------------------------------------------------------------------------
-- COMBAT — RESERVED Phase 6 — not yet used
------------------------------------------------------------------------

export type CombatResult = {
	Hit: boolean,
	Damage: number,
	Headshot: boolean,
	KilledTarget: boolean,
	DBNOTarget: boolean,
}

------------------------------------------------------------------------
-- ACTION RESOLVER (Capa 5)
------------------------------------------------------------------------

--- Contexto snapshot construido una vez por frame en ActionResolver:Resolve().
--- Agrupa buffer, intents, environment, estado y config para las reglas de resolución.
export type ResolverContext = {
	State: string,
	StateConfig: any,
	Env: EnvironmentContext,
	Buffer: any, -- InputBuffer instance
	Intents: any, -- IntentMapper instance
	HasMovement: boolean,
}

------------------------------------------------------------------------
-- SOUND SYSTEM
------------------------------------------------------------------------

--- Scope de reproducción de un sonido.
export type SoundScope = "Player" | "Global"

--- Grupo lógico de sonido.
export type SoundGroupType = "VFX" | "Ambient" | "Music" | "Server"

--- Definición de una entrada de sonido en SoundConfig.
export type SoundEntry = {
	Ids: { string },
	Random: boolean,
	Looped: boolean,
	Scope: SoundScope,
	Group: SoundGroupType,
	Volume: number,
	MaxDistance: number?,
	PitchVariation: number?,
}

--- Payload que viaja por red para replicar sonidos.
export type SoundReplicationPayload = {
	SoundName: string,
	Position: Vector3?,
	SourcePlayer: Player?,
}

------------------------------------------------------------------------
-- NETWORK — RESERVED Phase 6 — not yet used
------------------------------------------------------------------------

export type NetworkPayload = {
	Action: string,
	Timestamp: number,
	Data: { [string]: any }?,
}

return nil
