--[[
	SpeedMap.luau
	═══════════════════════════════════════════════════════════════
	Tabla de velocidades por estado — Pure Data Module
	═══════════════════════════════════════════════════════════════
	
	Centraliza la relación Estado → WalkSpeed en un solo lugar.
	No tiene estado interno ni metatables.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local SpeedMap = {}

local MAP = table.freeze({
	Idle = 0,
	Walking = Constants.WALK_SPEED,
	RoadieRun = 0, -- WalkSpeed=0: velocidad controlada 100% por AssemblyLinearVelocity en MovementController
	CoverSlide = Constants.COVER_SLIDE_SPEED,
	CoverEntering = 0, -- WalkSpeed=0: posición controlada 100% por EnteringCover._updateEntering
	CoverExiting = Constants.WALK_SPEED * 0.6,
	CoverSwap = Constants.COVER_SLIDE_SPEED,
	CoverWalking = 0, -- WalkSpeed=0: velocidad controlada 100% por AssemblyLinearVelocity en InCover
	CoverRunning = 0, -- WalkSpeed=0: velocidad controlada 100% por AssemblyLinearVelocity en CoverRunning
	CoverCorners = Constants.WALK_SPEED * 0.3,
	Evading = 0, -- Controlado por impulso decreciente
	ExitCorner = 0, -- Controlado por impulso decreciente (duración más corta que Evading)
	CoverIdle = 0, -- WalkSpeed=0: wall-glue + velocidad=0 (reposo total)
	CoverAim = 0,
	CoverAimHigh = 0, -- WalkSpeed=0: velocidad controlada por InCover:UpdateWalking con speedOverride
	CoverAimLow = 0, -- WalkSpeed=0: idem
	CoverFiring = 0, -- WalkSpeed=0: idem — disparo desde cover, física idéntica a CoverAimHigh/Low
	CoverPeek = 0, -- Sin movimiento: el personaje está asomado en esquina
	CoverBlindFire = 0,
	Mantling = 0,
	Vaulting = 0, -- WalkSpeed=0: posición controlada 100% por VaultHandler (Bezier)
	DBNO = Constants.WALK_SPEED * 0.2,
	Executing = 0,
	Aiming = Constants.WALK_SPEED * 0.6,
	Firing = Constants.WALK_SPEED * 0.5,
	Reloading = Constants.WALK_SPEED * 0.8,
	ActiveReloading = Constants.WALK_SPEED * 0.8,
	Death = 0,
	Spectator = 0,
	Lobby = 0,
})

--- Retorna la WalkSpeed que corresponde a un estado.
--- Si el estado no está en la tabla, retorna WALK_SPEED como fallback.
function SpeedMap.GetSpeed(state: string): number
	return MAP[state] or Constants.WALK_SPEED
end

return SpeedMap
