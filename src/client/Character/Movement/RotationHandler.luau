--[[
	RotationHandler.luau
	═══════════════════════════════════════════════════════════════
	Rotación del personaje según estado
	═══════════════════════════════════════════════════════════════
	
	En cover: rotación la gestiona el cover snap.
	En CoverAim / Aiming / Firing: rotación se gestionará con el sistema de cámara.
	En free movement: rota suavemente hacia la dirección de movimiento (MoveDirection).
]]

local Players = game:GetService("Players")

local RotationHandler = {}
RotationHandler.__index = RotationHandler

--- Estados en los que la rotación está controlada por el cover snap / normal.
--- El input del jugador NO debe rotar al personaje en estos estados.
local COVER_LOCKED_STATES: { [string]: boolean } = {
	Evading = true,
	CoverEntering = true,
	CoverSlide = true,
	CoverIdle = true,
	CoverWalking = true,
	CoverRunning = true,
	CoverCorners = true,
	CoverBlindFire = true,
	CoverExiting = true,
	CoverSwap = true,
}

function RotationHandler.new()
	local self = setmetatable({}, RotationHandler)
	self._player = Players.LocalPlayer
	return self
end

--- Actualiza la rotación del personaje cada frame.
--- @param dt number — delta time
--- @param state string — estado actual del jugador
--- @param coverNormal Vector3? — normal de la pared de cover (nil si no está en cover)
function RotationHandler:Update(dt: number, state: string, coverNormal: Vector3?)
	local character = self._player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then
		return
	end

	-- En estados de cover: rotación la gestiona el cover snap / handler
	-- No aplicar rotación por input — el personaje solo mira hacia la normal
	if COVER_LOCKED_STATES[state] then
		return
	end

	-- En CoverAim / Aiming / Firing: rotación se gestionará con la cámara
	if state == "CoverAim" or state == "Aiming" or state == "Firing" then
		return
	end

	-- En estados normales: rotar hacia la dirección de movimiento
	if humanoid.MoveDirection.Magnitude > 0.1 then
		local targetCFrame = CFrame.lookAt(hrp.Position, hrp.Position + humanoid.MoveDirection)
		hrp.CFrame = hrp.CFrame:Lerp(targetCFrame, math.min(10 * dt, 1))
	end
end

return RotationHandler
