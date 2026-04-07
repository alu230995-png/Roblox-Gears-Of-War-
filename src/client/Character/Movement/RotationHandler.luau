--[[
	RotationHandler.luau
	═══════════════════════════════════════════════════════════════
	Rotación del personaje según estado — estilo Gears of War
	═══════════════════════════════════════════════════════════════
	
	MODELO DE ROTACIÓN:
	
	1. COMBAT STANCE (Idle, Walking, Evading, Aiming, Firing):
	   El personaje SIEMPRE mira hacia el forward de la cámara.
	   El movimiento es strafe puro — presionar derecha = caminar de lado.
	   Esto garantiza que siempre esté listo para disparar donde mira la cámara.
	
	2. ROADIE RUN (RoadieRun):
	   - Quick Snap: al entrar, el personaje rota rápido hacia la dirección de input.
	   - Heavy Steering: después de 0.25s, la rotación se vuelve muy lenta/pesada.
	   El personaje se desacopla de la cámara y rota hacia donde empuja el input.
	
	3. COVER: rotación la gestiona el cover snap (no se toca aquí).
	
	4. LOCKED: ciertos estados bloquean la rotación (Mantling, Executing, Death).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local RotationHandler = {}
RotationHandler.__index = RotationHandler

--- Estados en los que la rotación está controlada por el cover snap / normal.
--- El input del jugador NO debe rotar al personaje en estos estados.
local COVER_LOCKED_STATES: { [string]: boolean } = {
	Mantling = true,
	Executing = true,
	Death = true,
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
	self._roadieRunTimer = 0 -- tiempo en RoadieRun (para Quick Snap → Heavy Steering)
	self._lastState = ""
	return self
end

--- Actualiza la rotación del personaje cada frame.
--- @param dt number — delta time
--- @param state string — estado actual del jugador
--- @param coverNormal Vector3? — normal de la pared de cover (nil si no está en cover)
function RotationHandler:Update(dt: number, state: string, _coverNormal: Vector3?)
	local character = self._player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then
		return
	end

	-- Detectar entrada a RoadieRun para resetear timer
	if state == "RoadieRun" and self._lastState ~= "RoadieRun" then
		self._roadieRunTimer = 0
	end
	self._lastState = state

	-- LOCKED: Cover y estados especiales — no tocar rotación
	if COVER_LOCKED_STATES[state] then
		return
	end

	-- ROADIE RUN: rotación dictada por input (no cámara)
	if state == "RoadieRun" then
		self:_updateRoadieRun(dt, hrp, humanoid)
		return
	end

	-- COMBAT STANCE (Idle, Walking, Evading, Aiming, Firing, Reloading, etc.):
	-- El personaje SIEMPRE mira hacia el forward horizontal de la cámara (strafe)
	self:_alignToCamera(dt, hrp)
end

------------------------------------------------------------------------
-- INTERNAL: Combat Stance — alinear al forward de la cámara
------------------------------------------------------------------------

function RotationHandler:_alignToCamera(dt: number, hrp: BasePart)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local camLook = camera.CFrame.LookVector
	local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
	if flatLook.Magnitude < 0.01 then
		return
	end

	flatLook = flatLook.Unit
	local targetCFrame = CFrame.lookAt(hrp.Position, hrp.Position + flatLook)
	hrp.CFrame = hrp.CFrame:Lerp(targetCFrame, 1 - math.exp(-12 * dt))
end

------------------------------------------------------------------------
-- INTERNAL: Roadie Run — Quick Snap + Heavy Steering
------------------------------------------------------------------------

function RotationHandler:_updateRoadieRun(dt: number, hrp: BasePart, humanoid: Humanoid)
	self._roadieRunTimer = self._roadieRunTimer + dt

	if humanoid.MoveDirection.Magnitude < 0.1 then
		return
	end

	-- Determinar velocidad de rotación: snap rápido al inicio, pesado después
	local inSnapPhase = self._roadieRunTimer < Constants.ROADIE_SNAP_DURATION
	local rotSpeed = if inSnapPhase then Constants.ROADIE_SNAP_SPEED else Constants.ROADIE_STEER_SPEED

	-- Rotar hacia la dirección de input
	local targetCFrame = CFrame.lookAt(hrp.Position, hrp.Position + humanoid.MoveDirection)
	hrp.CFrame = hrp.CFrame:Lerp(targetCFrame, 1 - math.exp(-rotSpeed * dt))
end

return RotationHandler
