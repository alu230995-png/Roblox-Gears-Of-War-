--[[
	CameraController.luau
	═══════════════════════════════════════════════════════════════
	Controlador de cámara TPS estilo Gears of War
	═══════════════════════════════════════════════════════════════
	
	Sistemas:
	  1. Spring Arm (anti-colisión) — SphereCast, pull fast / push slow
	  2. Shoulder Offset + Swap — hombro derecho base, swap automático en cover
	  3. Dynamic Framing en Cover — encuadre cinemático con Slerp
	  4. Camera Shakes — impulse (disparo/daño) + noise loop (roadie run)
	  5. FOV dinámico por estado
	  6. Camera bob durante movimiento
	  7. Rotación manual via GetMouseDelta() (CameraType = Scriptable)
	  8. Sensibilidad variable por estado (más pesada en RoadieRun)
	
	Comunicación event-driven:
	  - Escucha StateMachine.StateChanged → ajusta FOV, bob, shoulder, noise, sensitivity
	  - Escucha ActionResolver.ActionResolved → impulse shake
	  - Heartbeat propio para orquestar el frame de cámara
	
	API pública adicional (llamada desde Cover system):
	  - SetCoverNormal(normal) — activa/desactiva Dynamic Framing
	  - SetShoulderSide(side) — swap de hombro desde InCover
	  - FireImpulseShake(rotX, rotY) — kick de cámara
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

------------------------------------------------------------------------
-- FOV por estado (module-level constant — creada una sola vez)
------------------------------------------------------------------------
local STATE_FOV = table.freeze({
	Idle = Constants.DEFAULT_FOV,
	Walking = Constants.DEFAULT_FOV,
	RoadieRun = Constants.ROADIE_RUN_FOV,
	CoverIdle = Constants.DEFAULT_FOV,
	CoverAim = Constants.DEFAULT_FOV + Constants.CAMERA_FOV_COVER_AIM_OFFSET,
	CoverBlindFire = Constants.DEFAULT_FOV,
	CoverSlide = Constants.ROADIE_RUN_FOV,
	CoverEntering = Constants.ROADIE_RUN_FOV,
	CoverWalking = Constants.DEFAULT_FOV,
	CoverRunning = Constants.DEFAULT_FOV + Constants.CAMERA_FOV_COVER_RUN_OFFSET,
	CoverExiting = Constants.DEFAULT_FOV,
	CoverCorners = Constants.DEFAULT_FOV,
	CoverSwap = Constants.ROADIE_RUN_FOV,
	Evading = Constants.DEFAULT_FOV,
	Mantling = Constants.DEFAULT_FOV,
	Aiming = Constants.DEFAULT_FOV + Constants.CAMERA_FOV_AIM_OFFSET,
	Firing = Constants.DEFAULT_FOV + Constants.CAMERA_FOV_FIRING_OFFSET,
	Reloading = Constants.DEFAULT_FOV,
	ActiveReloading = Constants.DEFAULT_FOV,
	DBNO = Constants.DEFAULT_FOV + Constants.CAMERA_FOV_DBNO_OFFSET,
	Executing = Constants.DEFAULT_FOV,
	Death = Constants.DEFAULT_FOV + Constants.CAMERA_FOV_DEATH_OFFSET,
	Spectator = Constants.DEFAULT_FOV,
	Lobby = Constants.DEFAULT_FOV,
})

------------------------------------------------------------------------
-- BOB multiplier por estado
------------------------------------------------------------------------
local STATE_BOB_MULTIPLIER = table.freeze({
	Idle = 0,
	Walking = Constants.CAMERA_BOB_WALK_MULTIPLIER,
	RoadieRun = Constants.CAMERA_BOB_ROADIE_MULTIPLIER,
	CoverIdle = 0,
	CoverAim = 0,
	CoverBlindFire = 0,
	CoverSlide = 0.5,
	CoverEntering = 0.3,
	CoverWalking = 0.4,
	CoverRunning = 0.7,
	CoverExiting = 0.3,
	CoverCorners = 0,
	CoverSwap = 0.5,
	Evading = 0,
	Mantling = 0,
	Aiming = 0.2,
	Firing = 0.3,
	Reloading = 0.5,
	ActiveReloading = 0.5,
	DBNO = 0.3,
	Executing = 0,
	Death = 0,
	Spectator = 0,
	Lobby = 0,
})

------------------------------------------------------------------------
-- Sensibilidad por estado
------------------------------------------------------------------------
local STATE_SENSITIVITY = table.freeze({
	Idle = Constants.CAM_SENSITIVITY_DEFAULT,
	Walking = Constants.CAM_SENSITIVITY_WALK,
	RoadieRun = Constants.CAM_SENSITIVITY_ROADIE,
	CoverIdle = Constants.CAM_SENSITIVITY_COVER,
	CoverAim = Constants.CAM_SENSITIVITY_AIM,
	CoverBlindFire = Constants.CAM_SENSITIVITY_COVER,
	CoverSlide = Constants.CAM_SENSITIVITY_ROADIE,
	CoverEntering = Constants.CAM_SENSITIVITY_ROADIE,
	CoverWalking = Constants.CAM_SENSITIVITY_COVER,
	CoverRunning = Constants.CAM_SENSITIVITY_COVER,
	CoverExiting = Constants.CAM_SENSITIVITY_DEFAULT,
	CoverCorners = Constants.CAM_SENSITIVITY_COVER,
	CoverSwap = Constants.CAM_SENSITIVITY_ROADIE,
	Evading = Constants.CAM_SENSITIVITY_ROADIE,
	Mantling = Constants.CAM_SENSITIVITY_ROADIE,
	Aiming = Constants.CAM_SENSITIVITY_AIM,
	Firing = Constants.CAM_SENSITIVITY_AIM,
	Reloading = Constants.CAM_SENSITIVITY_DEFAULT,
	ActiveReloading = Constants.CAM_SENSITIVITY_DEFAULT,
	DBNO = Constants.CAM_SENSITIVITY_DBNO,
	Executing = Constants.CAM_SENSITIVITY_DEFAULT,
	Death = Constants.CAM_SENSITIVITY_DBNO,
	Spectator = Constants.CAM_SENSITIVITY_DEFAULT,
	Lobby = Constants.CAM_SENSITIVITY_DEFAULT,
})

------------------------------------------------------------------------
-- Follow-yaw strength por estado (0 = no sigue, mayor = más fuerte)
------------------------------------------------------------------------
local STATE_FOLLOW_YAW = table.freeze({
	Idle = 0,
	Walking = Constants.CAM_FOLLOW_YAW_WALK,
	RoadieRun = Constants.CAM_FOLLOW_YAW_RUN,
	CoverIdle = 0,
	CoverAim = 0,
	CoverBlindFire = 0,
	CoverSlide = 0,
	CoverEntering = 0,
	CoverWalking = Constants.CAM_FOLLOW_YAW_COVER_WALK,
	CoverRunning = 0,
	CoverExiting = 0,
	CoverCorners = 0,
	CoverSwap = 0,
	Evading = Constants.CAM_FOLLOW_YAW_EVADE,
	Mantling = 0,
	Aiming = 0,
	Firing = 0,
	Reloading = 0,
	ActiveReloading = 0,
	DBNO = 0,
	Executing = 0,
	Death = 0,
	Spectator = 0,
	Lobby = 0,
})

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------
local CameraController = {}
CameraController.__index = CameraController

function CameraController.new(stateMachine, actionResolver)
	local self = setmetatable({}, CameraController)

	self._stateMachine = stateMachine
	self._actionResolver = actionResolver

	-- FOV
	self._targetFOV = Constants.DEFAULT_FOV
	self._currentFOV = Constants.DEFAULT_FOV

	-- Camera bob
	self._bobTime = 0
	self._targetBobMultiplier = 0
	self._currentBobMultiplier = 0

	-- Mouse rotation (Scriptable mode)
	self._yaw = 0
	self._pitch = 0
	self._sensitivityMultiplier = Constants.CAM_SENSITIVITY_DEFAULT
	self._pitchDamping = 1.0

	-- Spring Arm
	self._currentArmLength = Constants.CAM_ARM_LENGTH

	-- Shoulder Offset
	self._targetShoulderX = Constants.CAM_SHOULDER_RIGHT
	self._currentShoulderX = Constants.CAM_SHOULDER_RIGHT

	-- Dynamic Framing
	self._coverFrameActive = false
	self._coverNormal = nil :: Vector3?

	-- Camera Shakes — Impulse (target + attack/decay)
	self._shakeImpulseCFrame = CFrame.identity
	self._shakeImpulseTarget = CFrame.identity

	-- Camera Shakes — Noise Loop
	self._noiseTime = 0
	self._noiseActive = false
	self._noiseAmplitudeX = 0
	self._noiseAmplitudeY = 0

	-- Movement follow-yaw
	self._followYawStrength = 0
	self._roadieYawTimer = 0

	-- Spring Arm: RaycastParams reutilizable (evita allocation por frame)
	self._raycastParams = RaycastParams.new()
	self._raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	-- Conexiones gestionadas (cleanup en Destroy)
	self._connections = {}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function CameraController:Init()
	-- Sin side-effects
end

function CameraController:Start()
	-- Forzar Scriptable + lock de mouse
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	-- Inicializar yaw desde la orientación actual de la cámara
	if camera then
		local pitchRad, yawRad, _ = camera.CFrame:ToEulerAnglesYXZ()
		self._yaw = math.deg(yawRad)
		self._pitch = math.deg(pitchRad)
	end

	-- Escuchar cambios de estado → FOV, bob, shoulder, noise, sensitivity
	self._connections.stateChanged = self._stateMachine.StateChanged:Connect(
		function(newState: string, oldState: string)
			self:_onStateChanged(newState, oldState)
		end
	)

	-- Escuchar acciones resueltas → impulse shake
	self._connections.actionResolved = self._actionResolver.ActionResolved:Connect(
		function(action: string, _targetState: string?, _data: any?)
			self:_onActionResolved(action)
		end
	)

	-- Heartbeat para orquestar el frame de cámara
	self._connections.heartbeat = RunService.Heartbeat:Connect(function(dt: number)
		self:_update(dt)
	end)

	-- Re-forzar Scriptable si la cámara cambia (respawn, etc.)
	self._connections.cameraChanged = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local cam = workspace.CurrentCamera
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
		end
	end)

	-- Desactivar AutoRotate en el cliente (el servidor ya lo hace, pero hay race condition)
	self:_disableAutoRotate()
	self._connections.characterAdded = Players.LocalPlayer.CharacterAdded:Connect(function()
		self:_disableAutoRotate()
	end)

	if Constants.DEBUG_MODE then
		print("[GoW Camera] CameraController:Start() — listeners conectados")
	end
end

function CameraController:Destroy()
	for _, conn in self._connections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif type(conn) == "table" and type(conn.Disconnect) == "function" then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)
end

------------------------------------------------------------------------
-- PUBLIC API: Cover System Integration
------------------------------------------------------------------------

--- Inyecta la normal de la cover activa para el Dynamic Framing.
--- Llamar con nil al salir de cover.
function CameraController:SetCoverNormal(normal: Vector3?)
	self._coverNormal = normal
	self._coverFrameActive = normal ~= nil
end

--- Cambia el hombro de la cámara (llamado desde InCover).
function CameraController:SetShoulderSide(side: string)
	if side == "Left" then
		self._targetShoulderX = Constants.CAM_SHOULDER_LEFT
	else
		self._targetShoulderX = Constants.CAM_SHOULDER_RIGHT
	end
end

--- Aplica un impulso de shake que decae exponencialmente.
function CameraController:FireImpulseShake(rotX: number, rotY: number)
	-- Acumulamos en el target; el _update lo lerpa suavemente hacia _shakeImpulseCFrame
	self._shakeImpulseTarget = self._shakeImpulseTarget * CFrame.Angles(rotX, rotY, 0)
end

------------------------------------------------------------------------
-- INTERNAL: Disable Humanoid AutoRotate on the client
------------------------------------------------------------------------

function CameraController:_disableAutoRotate()
	local character = Players.LocalPlayer.Character
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.AutoRotate = false
	else
		task.spawn(function()
			local h = character:WaitForChild("Humanoid", 5)
			if h then
				h.AutoRotate = false
			end
		end)
	end
end

------------------------------------------------------------------------
-- INTERNAL: State Change Handler
------------------------------------------------------------------------

function CameraController:_onStateChanged(newState: string, oldState: string)
	-- FOV + bob (existente)
	self._targetFOV = STATE_FOV[newState] or Constants.DEFAULT_FOV
	self._targetBobMultiplier = STATE_BOB_MULTIPLIER[newState] or 0

	-- Sensibilidad por estado
	self._sensitivityMultiplier = STATE_SENSITIVITY[newState] or Constants.CAM_SENSITIVITY_DEFAULT

	-- Follow-yaw strength por estado
	self._followYawStrength = STATE_FOLLOW_YAW[newState] or 0

	-- Resetear timer de cámara al entrar en RoadieRun
	if newState == "RoadieRun" and oldState ~= "RoadieRun" then
		self._roadieYawTimer = 0
	end

	-- State-entry shakes
	if newState == "Evading" then
		self:FireImpulseShake(Constants.CAM_SHAKE_EVADE_X, Constants.CAM_SHAKE_EVADE_Y)
	elseif
		newState == "CoverIdle"
		and (oldState == "CoverEntering" or oldState == "CoverSwap" or oldState == "CoverSlide")
	then
		-- Micro-temblor solo al impactar la pared (entering, swap, slide) — NO desde CoverWalking
		self:FireImpulseShake(Constants.CAM_SHAKE_COVER_ENTER_X, Constants.CAM_SHAKE_COVER_ENTER_Y)
	end

	-- Shoulder: al salir de CoverGroup, volver al hombro derecho
	local inCoverGroup = self._stateMachine:IsInGroup("CoverGroup")
		or newState == "CoverEntering"
		or newState == "CoverExiting"
		or newState == "CoverSlide"
		or newState == "CoverSwap"
	if not inCoverGroup then
		self._targetShoulderX = Constants.CAM_SHOULDER_RIGHT
	end

	-- Dynamic Framing: desactivar al salir de cover
	if not inCoverGroup then
		self:SetCoverNormal(nil)
	end

	-- Pitch damping: más pesado al correr
	if newState == "RoadieRun" then
		self._pitchDamping = Constants.CAM_PITCH_DAMP_ROADIE
	elseif newState == "Walking" or newState == "CoverRunning" then
		self._pitchDamping = Constants.CAM_PITCH_DAMP_WALK
	else
		self._pitchDamping = 1.0
	end

	-- Noise loop: solo en RoadieRun (extender para chainsaw en Fase 8)
	if newState == "RoadieRun" then
		self._noiseActive = true
		self._noiseAmplitudeX = Constants.CAM_SHAKE_NOISE_ROADIE_X
		self._noiseAmplitudeY = Constants.CAM_SHAKE_NOISE_ROADIE_Y
	else
		self._noiseActive = false
		self._noiseAmplitudeX = 0
		self._noiseAmplitudeY = 0
	end
end

------------------------------------------------------------------------
-- INTERNAL: Action Handler
------------------------------------------------------------------------

function CameraController:_onActionResolved(action: string)
	if action == "Shoot" then
		self:FireImpulseShake(math.rad(1.2), math.rad(0.4))
	elseif action == "Evade" or action == "RollOutOfCover" then
		self:FireImpulseShake(math.rad(0.5), math.rad(0.8))
	end
end

------------------------------------------------------------------------
-- INTERNAL: Frame Update — Orquestador
------------------------------------------------------------------------

function CameraController:_update(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	-- Garantizar Scriptable cada frame (evita que Roblox lo resetee)
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	local character = Players.LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- 1. Procesar input de mouse → acumular yaw/pitch
	self:_processMouseInput(dt)

	-- 1b. Follow-yaw: rotar cámara suavemente hacia dirección de movimiento
	self:_applyFollowYaw(hrp, dt)

	-- 2. FOV
	self:_interpolateFOV(dt, camera)

	-- 3. Shoulder lerp
	self._currentShoulderX = self._currentShoulderX
		+ (self._targetShoulderX - self._currentShoulderX) * math.min(1, Constants.CAM_SHOULDER_LERP_SPEED * dt)

	-- 4. Spring Arm — calcular longitud real de brazo
	local armLength = self:_computeSpringArm(hrp, camera, dt)

	-- 5. Construir CFrame base de la cámara
	local pivot = hrp.Position + Constants.CAM_ARM_PIVOT_OFFSET

	-- Rotación a partir de yaw/pitch acumulados
	local rotationCF = CFrame.Angles(0, math.rad(self._yaw), 0) * CFrame.Angles(math.rad(self._pitch), 0, 0)
	local lookDir = rotationCF.LookVector
	local rightDir = rotationCF.RightVector

	-- Posición: pivot + shoulder offset lateral + retroceso del arm
	local camPos = pivot + rightDir * self._currentShoulderX - lookDir * armLength
	local baseCF = CFrame.new(camPos) * rotationCF

	-- 6. Dynamic Framing en Cover
	if self._coverFrameActive and self._coverNormal then
		baseCF = self:_applyDynamicFraming(baseCF, hrp, dt)
	end

	-- 7. Camera Bob (aditivo sobre baseCF)
	local bobOffset = self:_computeBobOffset(dt)

	-- 8. Impulse Shake: attack (ramp toward target) + decay (target toward identity)
	self._shakeImpulseCFrame =
		self._shakeImpulseCFrame:Lerp(self._shakeImpulseTarget, math.min(1, Constants.CAM_SHAKE_IMPULSE_ATTACK * dt))
	self._shakeImpulseTarget =
		self._shakeImpulseTarget:Lerp(CFrame.identity, math.min(1, Constants.CAM_SHAKE_IMPULSE_DECAY * dt))

	-- 9. Noise Loop
	local noiseCF = self:_computeNoiseCF(dt)

	-- 10. Componer y asignar
	camera.CFrame = baseCF * bobOffset * self._shakeImpulseCFrame * noiseCF
end

------------------------------------------------------------------------
-- INTERNAL: Mouse Rotation
------------------------------------------------------------------------

--- Lee GetMouseDelta() y acumula yaw/pitch con sensibilidad variable.
function CameraController:_processMouseInput(_dt: number)
	local delta = UserInputService:GetMouseDelta()
	if delta.Magnitude < 0.001 then
		return
	end

	local sens = self._sensitivityMultiplier
	self._yaw = self._yaw - delta.X * 0.3 * sens
	self._pitch = math.clamp(
		self._pitch - delta.Y * 0.3 * sens * self._pitchDamping,
		Constants.CAM_PITCH_MIN,
		Constants.CAM_PITCH_MAX
	)
end

------------------------------------------------------------------------
-- INTERNAL: FOV Interpolation
------------------------------------------------------------------------

function CameraController:_interpolateFOV(dt: number, camera: Camera)
	self._currentFOV = self._currentFOV
		+ (self._targetFOV - self._currentFOV) * math.min(1, Constants.CAMERA_FOV_LERP_SPEED * dt)
	camera.FieldOfView = self._currentFOV
end

------------------------------------------------------------------------
-- INTERNAL: Follow-Yaw (cámara sigue al personaje en RoadieRun)
------------------------------------------------------------------------

--- En RoadieRun la cámara sigue suavemente detrás del personaje (que rota por input).
--- Quick Snap: la cámara sigue rápido al inicio. Heavy: se vuelve pesada después.
--- En Walking/Idle/Evade la cámara no sigue — el personaje se alinea a la cámara (strafe).
function CameraController:_applyFollowYaw(hrp: BasePart, dt: number)
	local strength = self._followYawStrength
	if strength <= 0 then
		return
	end

	-- En RoadieRun: dos fases para la cámara también
	self._roadieYawTimer = self._roadieYawTimer + dt
	local inSnapPhase = self._roadieYawTimer < Constants.ROADIE_SNAP_DURATION
	local effectiveStrength = if inSnapPhase then Constants.CAM_FOLLOW_YAW_RUN_SNAP else strength

	-- La cámara sigue el forward del personaje (no MoveDirection)
	local charLook = hrp.CFrame.LookVector
	local charYaw = math.deg(math.atan2(-charLook.X, -charLook.Z))

	-- Diferencia angular más corta entre cámara y personaje
	local diff = charYaw - self._yaw
	-- Normalizar a [-180, 180]
	diff = ((diff + 180) % 360) - 180

	-- Aplicar con lerp exponencial suavizado por strength
	self._yaw = self._yaw + diff * math.min(1, effectiveStrength * dt)
end

------------------------------------------------------------------------
-- INTERNAL: Spring Arm (anti-colisión)
------------------------------------------------------------------------

--- SphereCast desde pivot hacia atrás. Acercamiento rápido, alejamiento lento.
function CameraController:_computeSpringArm(hrp: BasePart, _camera: Camera, dt: number): number
	local pivot = hrp.Position + Constants.CAM_ARM_PIVOT_OFFSET

	-- Dirección de la cámara a partir de yaw/pitch acumulados
	local rotationCF = CFrame.Angles(0, math.rad(self._yaw), 0) * CFrame.Angles(math.rad(self._pitch), 0, 0)
	local lookDir = rotationCF.LookVector
	local ideal = Constants.CAM_ARM_LENGTH

	self._raycastParams.FilterDescendantsInstances = { hrp.Parent }

	local castDir = -lookDir * ideal
	local hit = workspace:Spherecast(pivot, Constants.CAM_ARM_SPHERE_RADIUS, castDir, self._raycastParams)

	local targetLength: number
	if hit then
		targetLength = math.max(0.5, hit.Distance - Constants.CAM_ARM_SPHERE_RADIUS)
	else
		targetLength = ideal
	end

	-- Acercar rápido (colisión), alejar lento (despejar)
	local speed = if targetLength < self._currentArmLength
		then Constants.CAM_ARM_PULL_SPEED
		else Constants.CAM_ARM_PUSH_SPEED

	self._currentArmLength = self._currentArmLength + (targetLength - self._currentArmLength) * math.min(1, speed * dt)

	return self._currentArmLength
end

------------------------------------------------------------------------
-- INTERNAL: Dynamic Framing en Cover
------------------------------------------------------------------------

--- Slerp de rotación hacia un encuadre cinemático frente a la cover normal.
function CameraController:_applyDynamicFraming(baseCF: CFrame, hrp: BasePart, dt: number): CFrame
	-- Centro del encuadre: posición del jugador + offset hacia la normal (fuera de la pared)
	local lookTarget = hrp.Position + self._coverNormal * 1.5 + Vector3.new(0, 0.5, 0)

	-- CFrame objetivo: misma posición, mirando al target
	local targetCF = CFrame.new(baseCF.Position, lookTarget)

	-- Slerp suave entre la rotación actual y la objetivo
	local alpha = math.min(1, Constants.CAM_COVER_FRAME_SPEED * dt)
	return CFrame.new(baseCF.Position) * baseCF.Rotation:Lerp(targetCF.Rotation, alpha)
end

------------------------------------------------------------------------
-- INTERNAL: Camera Bob
------------------------------------------------------------------------

--- Retorna un CFrame de offset de bob con fade suave.
function CameraController:_computeBobOffset(dt: number): CFrame
	-- Lerp suave del multiplicador para evitar saltos al cambiar de estado
	self._currentBobMultiplier = self._currentBobMultiplier
		+ (self._targetBobMultiplier - self._currentBobMultiplier) * math.min(1, 6 * dt)

	if not Constants.CAMERA_BOB_ENABLED or self._currentBobMultiplier < 0.001 then
		-- No resetear _bobTime: así al reactivar no hay salto de fase
		self._currentBobMultiplier = 0
		return CFrame.identity
	end

	self._bobTime = self._bobTime + dt * Constants.CAMERA_BOB_FREQUENCY
	local mul = self._currentBobMultiplier
	local ox = math.sin(self._bobTime) * Constants.CAMERA_BOB_AMPLITUDE_X * mul
	-- Centrar Y en 0 usando cos sin abs → oscila entre -amp y +amp en vez de 0 y +amp
	local oy = math.cos(self._bobTime) * Constants.CAMERA_BOB_AMPLITUDE_Y * mul * 0.5
	return CFrame.new(ox, oy, 0)
end

------------------------------------------------------------------------
-- INTERNAL: Noise Loop (Perlin)
------------------------------------------------------------------------

--- Genera rotación con ruido Perlin para noise loop (RoadieRun, chainsaw futuro).
function CameraController:_computeNoiseCF(dt: number): CFrame
	if not self._noiseActive then
		self._noiseTime = 0
		return CFrame.identity
	end

	self._noiseTime = self._noiseTime + dt * Constants.CAM_SHAKE_NOISE_SPEED
	local nx = math.noise(self._noiseTime, 0) * self._noiseAmplitudeX
	local ny = math.noise(self._noiseTime + 100, 0) * self._noiseAmplitudeY
	return CFrame.Angles(nx, ny, 0)
end

return CameraController
