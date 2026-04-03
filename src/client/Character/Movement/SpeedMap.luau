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

local MAP = {
	Idle = 0,
	Walking = Constants.WALK_SPEED,
	RoadieRun = 0, -- WalkSpeed=0: velocidad controlada 100% por AssemblyLinearVelocity en MovementController
	CoverSlide = Constants.COVER_SLIDE_SPEED,
	Evading = 0, -- Controlado por impulso decreciente
	CoverIdle = Constants.WALK_SPEED * 0.5,
	CoverAim = 0,
	CoverBlindFire = 0,
	Mantling = 0,
	DBNO = Constants.WALK_SPEED * 0.2,
	Executing = 0,
	Aiming = Constants.WALK_SPEED * 0.6,
	Firing = Constants.WALK_SPEED * 0.5,
	Reloading = Constants.WALK_SPEED * 0.8,
	ActiveReloading = Constants.WALK_SPEED * 0.8,
}

--- Retorna la WalkSpeed que corresponde a un estado.
--- Si el estado no está en la tabla, retorna WALK_SPEED como fallback.
function SpeedMap.GetSpeed(state: string): number
	return MAP[state] or Constants.WALK_SPEED
end

return SpeedMap
