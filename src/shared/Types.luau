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
	| "CoverBlindFire"
	| "CoverSlide"
	| "Evading"
	| "Mantling"
	| "DBNO"
	| "Executing"
	| "Reloading"
	| "ActiveReloading"
	| "Aiming"
	| "Firing"

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

export type CameraBobConfig = {
	Enabled: boolean,
	Frequency: number,
	AmplitudeX: number,
	AmplitudeY: number,
	RoadieRunMultiplier: number,
}

export type CoverSnapConfig = {
	MaxDetectionRange: number,
	SnapSpeed: number,
	MagnetismAngle: number,
	ExitSpeed: number,
}

export type StateTransition = {
	From: PlayerState,
	To: PlayerState,
	Condition: string,
}

export type InputBinding = {
	Action: InputAction,
	KeyCode: Enum.KeyCode?,
	UserInputType: Enum.UserInputType?,
	HoldDuration: number?,
}

------------------------------------------------------------------------
-- HSM (Hierarchical State Machine)
------------------------------------------------------------------------

export type StateGroup = {
	Name: string,
	Parent: string?,
	States: { string },
}

export type HSMCallbacks = {
	OnEnter: ((fromState: string) -> ())?,
	OnExit: ((toState: string) -> ())?,
}

------------------------------------------------------------------------
-- INPUT SYSTEM (Capas 1-5)
------------------------------------------------------------------------

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
	| "WantsInteract"
	| "WantsSwapWeapon"
	| "WantsMantle"
	| "WantsExitCover"

export type BufferEntry = {
	Intent: Intent,
	Timestamp: number,
	TTL: number,
	Consumed: boolean,
	Data: any?,
}

export type EnvironmentContext = {
	HasCoverNearby: boolean,
	CoverType: string?, -- "Low" | "High" | nil
	CoverNormal: Vector3?,
	CoverPosition: Vector3?,
	CoverInstance: BasePart?,
	HasAdjacentCoverLeft: boolean,
	HasAdjacentCoverRight: boolean,
	HasLowCoverAhead: boolean,
	IsAtCornerLeft: boolean,
	IsAtCornerRight: boolean,
	MoveDirection: Vector2,
	IsFacingCover: boolean,
}

------------------------------------------------------------------------
-- WEAPON SYSTEM (Fase 7)
------------------------------------------------------------------------

export type WeaponType = "Lancer" | "Gnasher" | "Longshot" | "TorqueBow" | "HammerOfDawn" | "Boomshot" | "Snub"

export type WeaponState = "WeaponIdle" | "Reloading" | "ActiveReloading" | "WeaponDrawing"

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

------------------------------------------------------------------------
-- COMBAT (Fase 6)
------------------------------------------------------------------------

export type CombatResult = {
	Hit: boolean,
	Damage: number,
	Headshot: boolean,
	KilledTarget: boolean,
	DBNOTarget: boolean,
}

------------------------------------------------------------------------
-- NETWORK (Fase 6)
------------------------------------------------------------------------

export type NetworkPayload = {
	Action: string,
	Timestamp: number,
	Data: { [string]: any }?,
}

return nil
