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

function RotationHandler.new(inputDetector)
	local self = setmetatable({}, RotationHandler)
	self._player = Players.LocalPlayer
	self._inputDetector = inputDetector -- referencia al InputDetector para leer raw input Vector2
	self._roadieRunTimer = 0 -- tiempo en RoadieRun (para Quick Snap → Heavy Steering)
	self._lastState = ""
	self._lockedRunDirection = nil :: Vector3? -- Direction Caching: dirección fija durante Fase 1

	-- Cache de character refs (evita FindFirstChild cada frame)
	self._cachedCharacter = nil :: Model?
	self._cachedHumanoid = nil :: Humanoid?
	self._cachedHRP = nil :: BasePart?

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

	-- Actualizar cache si el character cambió (respawn)
	if character ~= self._cachedCharacter then
		self._cachedCharacter = character
		self._cachedHumanoid = character:FindFirstChildOfClass("Humanoid")
		self._cachedHRP = character:FindFirstChild("HumanoidRootPart")
	end

	local humanoid = self._cachedHumanoid
	local hrp = self._cachedHRP
	if not humanoid or not hrp then
		return
	end

	-- Detectar entrada a RoadieRun para resetear timer y cachear dirección
	if state == "RoadieRun" and self._lastState ~= "RoadieRun" then
		self._roadieRunTimer = 0
		-- Direction Caching: capturar la dirección world-space en el fotograma de entrada.
		-- Combina input del jugador + cámara actual para obtener un vector fijo.
		self._lockedRunDirection = self:_captureWorldDirection(humanoid)
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
-- INTERNAL: Roadie Run — Dos Fases
------------------------------------------------------------------------

--- Fase 1 (Quick Snap): el personaje rota hacia _lockedRunDirection (cacheada al entrar).
---   La cámara se mueve independientemente a la espalda sin re-rotar al personaje.
--- Fase 2 (Steering): input lateral gira al personaje con radio de giro limitado.
---   El personaje siempre avanza hacia donde mira; no hay rotación absoluta.
function RotationHandler:_updateRoadieRun(dt: number, hrp: BasePart, humanoid: Humanoid)
	self._roadieRunTimer = self._roadieRunTimer + dt

	local inSnapPhase = self._roadieRunTimer < Constants.ROADIE_SNAP_DURATION

	if inSnapPhase then
		-- Fase 1: Quick Snap — rotar hacia dirección CACHEADA (no live input)
		local dir = self._lockedRunDirection
		if not dir or dir.Magnitude < 0.01 then
			-- Fallback: si no hay dirección cacheada, usar LookVector actual
			dir = hrp.CFrame.LookVector
		end
		local targetCFrame = CFrame.lookAt(hrp.Position, hrp.Position + dir)
		hrp.CFrame = hrp.CFrame:Lerp(targetCFrame, 1 - math.exp(-Constants.ROADIE_SNAP_SPEED * dt))
	else
		-- Fase 2: Steering — input lateral gira con radio de giro limitado
		if humanoid.MoveDirection.Magnitude < 0.1 then
			return
		end
		self:_applySteering(dt, hrp, humanoid)
	end
end

------------------------------------------------------------------------
-- INTERNAL: Steering (Fase 2 del Roadie Run)
------------------------------------------------------------------------

--- Extrae la componente lateral del input relativa al eje derecho del personaje
--- y aplica una rotación limitada en grados/segundo (volante de vehículo).
--- Sin giros instantáneos de 90° o 180°: el jugador tiene inercia y peso.
function RotationHandler:_applySteering(dt: number, hrp: BasePart, humanoid: Humanoid)
	-- Vector derecho del personaje (plano horizontal)
	local charRight = hrp.CFrame.RightVector
	local flatRight = Vector3.new(charRight.X, 0, charRight.Z)
	if flatRight.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	flatRight = flatRight.Unit

	-- Componente lateral del input: -1 (izquierda) a +1 (derecha)
	local lateralInput = humanoid.MoveDirection:Dot(flatRight)

	-- Aplicar velocidad de giro limitada (grados/segundo × dt)
	local steerAngle = lateralInput * Constants.ROADIE_STEER_RATE * dt
	hrp.CFrame = hrp.CFrame * CFrame.Angles(0, math.rad(-steerAngle), 0)
end

------------------------------------------------------------------------
-- INTERNAL: Direction Caching — capturar dirección world-space
------------------------------------------------------------------------

--- Calcula la dirección de movimiento en World Space combinando el raw input
--- del jugador (Vector2 del InputDetector) con los vectores de la cámara.
--- Se llama UNA SOLA VEZ al entrar en RoadieRun; el resultado se almacena
--- en _lockedRunDirection y se usa durante toda la Fase 1.
---
--- Usa inputDetector:GetMoveDirection() (Vector2: X = A/D, Y = W/S) para
--- construir un vector 3D en world-space usando los ejes planos de la cámara.
--- Esto evita el feedback loop donde MoveDirection ya está resuelto contra
--- una cámara que está girando.
function RotationHandler:_captureWorldDirection(_humanoid: Humanoid): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	-- 1. Leer raw input 2D del InputDetector (X: lateral, Y: forward)
	local rawInput = Vector2.zero
	if self._inputDetector then
		rawInput = self._inputDetector:GetMoveDirection()
	end

	-- 2. Aplanar vectores de cámara al plano horizontal (ignorar pitch)
	local camLook = camera.CFrame.LookVector
	local camRight = camera.CFrame.RightVector

	local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
	if flatLook.Magnitude > 0.01 then
		flatLook = flatLook.Unit
	else
		return nil
	end

	local flatRight = Vector3.new(camRight.X, 0, camRight.Z)
	if flatRight.Magnitude > 0.01 then
		flatRight = flatRight.Unit
	else
		return nil
	end

	-- 3. Si no hay input, asumir "quiere ir hacia adelante" (forward de cámara)
	if math.abs(rawInput.X) < 0.01 and math.abs(rawInput.Y) < 0.01 then
		return flatLook
	end

	-- 4. Construir dirección world-space: combinar lateral + forward
	-- rawInput.X = A(-1) / D(+1), rawInput.Y = W(+1) / S(-1)
	local worldDir = (flatRight * rawInput.X) + (flatLook * rawInput.Y)

	if worldDir.Magnitude < 0.01 then
		return flatLook
	end

	return worldDir.Unit
end

return RotationHandler
