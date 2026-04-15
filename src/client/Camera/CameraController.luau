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
	  - Escucha MovementController.ActionExecuted → impulse shake
	  - Heartbeat propio para orquestar el frame de cámara
	
	API pública adicional (llamada desde Cover system):
	  - SetCoverNormal(normal) — activa/desactiva Dynamic Framing
	  - SetShoulderSide(side) — swap de hombro desde InCover
	  - FireImpulseShake(rotX, rotY) — kick de cámara
]]

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
	CoverIdle = Constants.COVERS_FOV,
	CoverAim = Constants.COVERS_FOV + Constants.CAMERA_FOV_COVER_AIM_OFFSET,
	CoverAimHigh = Constants.COVERS_FOV,
	CoverAimLow = Constants.COVERS_FOV,
	CoverPeek = Constants.COVERS_FOV,
	CoverBlindFire = Constants.COVERS_FOV,
	CoverSlide = Constants.COVERS_FOV,
	CoverEntering = Constants.DEFAULT_FOV,
	CoverWalking = Constants.COVERS_FOV,
	CoverRunning = Constants.COVERS_FOV,
	CoverExiting = Constants.COVERS_FOV,
	CoverCorners = Constants.COVERS_FOV,
	CoverSwap = Constants.DEFAULT_FOV,
	Evading = Constants.DEFAULT_FOV,
	Mantling = Constants.DEFAULT_FOV,
	Vaulting = Constants.DEFAULT_FOV,
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

-- Velocidad horizontal mínima (studs/s) para activar el bob.
-- Igual que SoundController — detecta movimiento real sin importar cómo se aplica la velocidad.

------------------------------------------------------------------------
-- BOB multiplier por estado
------------------------------------------------------------------------
local STATE_BOB_MULTIPLIER = table.freeze({
	Idle = 0,
	Walking = Constants.CAMERA_BOB_WALK_MULTIPLIER,
	RoadieRun = Constants.CAMERA_BOB_ROADIE_MULTIPLIER,
	CoverIdle = 0,
	CoverAim = 0,
	CoverAimHigh = 0,
	CoverAimLow = 0,
	CoverPeek = 0,
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
	Vaulting = 0.3,
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
	CoverAimHigh = Constants.CAM_SENSITIVITY_AIM,
	CoverAimLow = Constants.CAM_SENSITIVITY_AIM,
	CoverPeek = Constants.CAM_SENSITIVITY_AIM,
	CoverBlindFire = Constants.CAM_SENSITIVITY_COVER,
	CoverSlide = Constants.CAM_SENSITIVITY_ROADIE,
	CoverEntering = Constants.CAM_SENSITIVITY_DEFAULT,
	CoverWalking = Constants.CAM_SENSITIVITY_COVER,
	CoverRunning = Constants.CAM_SENSITIVITY_COVER,
	CoverExiting = Constants.CAM_SENSITIVITY_DEFAULT,
	CoverCorners = Constants.CAM_SENSITIVITY_COVER,
	CoverSwap = Constants.CAM_SENSITIVITY_ROADIE,
	Evading = Constants.CAM_SENSITIVITY_ROADIE,
	Mantling = Constants.CAM_SENSITIVITY_ROADIE,
	Vaulting = Constants.CAM_SENSITIVITY_ROADIE,
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
	CoverAimHigh = 0,
	CoverAimLow = 0,
	CoverPeek = 0,
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
	Vaulting = 0,
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

function CameraController.new(stateMachine, actionExecutedSignal, mouseInput)
	local self = setmetatable({}, CameraController)

	self._stateMachine = stateMachine
	self._actionExecutedSignal = actionExecutedSignal
	self._mouseInput = mouseInput

	-- FOV
	self._targetFOV = Constants.DEFAULT_FOV
	self._currentFOV = Constants.DEFAULT_FOV
	self._fovDelta = 0 -- Aditivo: aplicado por AimingController para zoom de apuntado

	-- Camera bob
	self._bobTime = 0
	self._stateBobMultiplier = 0 -- valor definido por estado (máximo posible)
	self._targetBobMultiplier = 0 -- efectivo: 0 si el personaje no se mueve
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

	-- Inner corner yaw nudge (solo cámara, no player)
	self._cornerYawNudge = 0

	-- Cover settle guard: true mientras InCover hace settle rotation.
	-- Dynamic Framing se desactiva hasta que termine para evitar spinning.
	self._coverSettleActive = false

	-- Spring Arm: RaycastParams reutilizable (evita allocation por frame)
	self._raycastParams = RaycastParams.new()
	self._raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	self._lastFilterCharacter = nil :: Model?

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
	-- Forzar Scriptable
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end

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

	-- Escuchar acciones ejecutadas → impulse shake
	self._connections.actionExecuted = self._actionExecutedSignal:Connect(
		function(action: string, _targetState: string?, _data: any?)
			self:_onActionResolved(action)
		end
	)

	-- Heartbeat de cámara ELIMINADO: ahora ClientApp llama Update(dt) después
	-- de movementController:Update(dt) para garantizar que la cámara siempre
	-- vea el estado post-corrección del HRP (sin jitter de 1-frame lag).

	-- Re-forzar Scriptable si la cámara cambia (respawn, etc.)
	self._connections.cameraChanged = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local cam = workspace.CurrentCamera
		if cam then
			cam.CameraType = Enum.CameraType.Scriptable
		end
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

--- Notifica una transición de esquina interna.
--- Aplica un nudge suave al yaw de la cámara hacia la nueva normal
--- para re-encuadrar al personaje de frente sin rotar al player.
function CameraController:NotifyInnerCornerTransition(newNormal: Vector3)
	local targetYaw = math.deg(math.atan2(newNormal.X, newNormal.Z))
	local diff = targetYaw - self._yaw
	-- Normalizar a [-180, 180]
	diff = ((diff + 180) % 360) - 180
	self._cornerYawNudge = diff * Constants.CAM_CORNER_YAW_FRACTION
end

--- Indica a la cámara si InCover está en fase de settle rotation.
--- Mientras es true, Dynamic Framing se desactiva para evitar spinning.
function CameraController:SetCoverSettleActive(active: boolean)
	self._coverSettleActive = active
end

--- Delta aditivo de FOV usado por AimingController para zoom de apuntado.
--- Se suma al _targetFOV (state-driven) en _interpolateFOV.
function CameraController:SetFOVDelta(delta: number)
	self._fovDelta = delta
end

------------------------------------------------------------------------
-- INTERNAL: State Change Handler
------------------------------------------------------------------------

function CameraController:_onStateChanged(newState: string, oldState: string)
	-- FOV + bob (existente)
	self._targetFOV = STATE_FOV[newState] or Constants.DEFAULT_FOV
	self._stateBobMultiplier = STATE_BOB_MULTIPLIER[newState] or 0

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

	-- Shoulder: centrar durante RoadieRun (pierde desplazamiento lateral — cámara a la espalda)
	if newState == "RoadieRun" then
		self._targetShoulderX = Constants.ROADIE_SHOULDER_X
	end

	-- Dynamic Framing: desactivar al salir de cover
	if not inCoverGroup then
		self:SetCoverNormal(nil)
		self._coverSettleActive = false
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
	-- Shake de disparo movido a ShotFired signal (solo tras disparo real validado por WeaponClient)
	if action == "Evade" or action == "RollOutOfCover" then
		self:FireImpulseShake(math.rad(0.5), math.rad(0.8))
	end
end

------------------------------------------------------------------------
-- PUBLIC API: Frame Update (llamado por ClientApp después de movement)
------------------------------------------------------------------------

function CameraController:Update(dt: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	-- Garantizar Scriptable cada frame (evita que Roblox lo resetee)
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	-- En Spectator/Death la cámara la controla SpectatorController — no sobrescribir
	local currentState = self._stateMachine:GetCurrentState()
	if currentState == "Spectator" or currentState == "Death" then
		return
	end

	local character = Players.LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- 0. Velocity-gate del bob: solo activar si el personaje se mueve de verdad.
	-- Usa AssemblyLinearVelocity (igual que SoundController) para detectar
	-- movimiento real en todos los estados, incluso con WalkSpeed=0.
	local vel = hrp.AssemblyLinearVelocity
	local horizontalSpeed = math.sqrt(vel.X * vel.X + vel.Z * vel.Z)
	self._targetBobMultiplier = if horizontalSpeed > Constants.CAM_BOB_VELOCITY_THRESHOLD
		then self._stateBobMultiplier
		else 0

	-- 1. Procesar input de mouse → acumular yaw/pitch
	self:_processMouseInput(dt)

	-- 1b. Follow-yaw: rotar cámara suavemente hacia dirección de movimiento
	self:_applyFollowYaw(hrp, dt)

	-- 1c. Corner yaw nudge: rotar cámara suavemente tras esquina interna
	if math.abs(self._cornerYawNudge) > 0.1 then
		local step = self._cornerYawNudge * math.min(1, Constants.CAM_CORNER_YAW_SPEED * dt)
		self._yaw = self._yaw + step
		self._cornerYawNudge = self._cornerYawNudge - step
	else
		self._cornerYawNudge = 0
	end

	-- 2. FOV
	self:_interpolateFOV(dt, camera)

	-- 3. Shoulder lerp
	self._currentShoulderX = self._currentShoulderX
		+ (self._targetShoulderX - self._currentShoulderX) * math.min(1, Constants.CAM_SHOULDER_LERP_SPEED * dt)

	-- Rotación a partir de yaw/pitch acumulados (calculada una sola vez, reutilizada en Spring Arm y base CFrame)
	local rotationCF = CFrame.Angles(0, math.rad(self._yaw), 0) * CFrame.Angles(math.rad(self._pitch), 0, 0)

	-- 4. Spring Arm — calcular longitud real de brazo
	local armLength = self:_computeSpringArm(hrp, camera, dt, rotationCF)

	-- 5. Construir CFrame base de la cámara
	local pivot = hrp.Position + Constants.CAM_ARM_PIVOT_OFFSET

	local lookDir = rotationCF.LookVector
	local rightDir = rotationCF.RightVector

	-- Posición: pivot + shoulder offset lateral + retroceso del arm
	local camPos = pivot + rightDir * self._currentShoulderX - lookDir * armLength
	local baseCF = CFrame.new(camPos) * rotationCF

	-- 6. Dynamic Framing en Cover
	-- SOLO aplicar cuando el settle de rotación ya terminó.
	-- Durante el settle el HRP rota rápidamente → el yaw target oscila
	-- cada frame y la cámara se vuelve inestable (spinning bug).
	if self._coverFrameActive and self._coverNormal and not self._coverSettleActive then
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

--- Lee el delta via MouseInput (Capa 1) y acumula yaw/pitch con sensibilidad variable.
--- Durante Fase 2 de RoadieRun (Steering):
---   - Yaw bloqueado (sens=0): la dirección del movimiento dicta la rotación horizontal.
---   - Pitch libre: el jugador puede mirar arriba/abajo con el mouse.
function CameraController:_processMouseInput(_dt: number)
	local delta = self._mouseInput:GetDelta()
	if delta.Magnitude < 0.001 then
		return
	end

	local sens = self._sensitivityMultiplier
	local pitchSens = sens -- por defecto, pitch usa la misma sensibilidad que yaw

	-- Fase 2 (Steering) del RoadieRun: yaw bloqueado, pitch libre
	local currentState = self._stateMachine:GetCurrentState()
	if currentState == "RoadieRun" and self._roadieYawTimer >= Constants.ROADIE_SNAP_DURATION then
		sens = Constants.CAM_SENSITIVITY_ROADIE_STEER -- 0 → sin rotación horizontal libre
		-- pitchSens mantiene el valor del estado (CAM_SENSITIVITY_ROADIE = 0.2)
	end

	self._yaw = self._yaw - delta.X * Constants.CAM_MOUSE_SENSITIVITY_BASE * sens
	self._pitch = math.clamp(
		self._pitch - delta.Y * Constants.CAM_MOUSE_SENSITIVITY_BASE * pitchSens * self._pitchDamping,
		Constants.CAM_PITCH_MIN,
		Constants.CAM_PITCH_MAX
	)
end

------------------------------------------------------------------------
-- INTERNAL: FOV Interpolation
------------------------------------------------------------------------

function CameraController:_interpolateFOV(dt: number, camera: Camera)
	local effectiveFOV = self._targetFOV + self._fovDelta
	self._currentFOV = self._currentFOV
		+ (effectiveFOV - self._currentFOV) * math.min(1, Constants.CAMERA_FOV_LERP_SPEED * dt)
	camera.FieldOfView = self._currentFOV
end

------------------------------------------------------------------------
-- INTERNAL: Follow-Yaw (cámara sigue al personaje en RoadieRun)
------------------------------------------------------------------------

--- En RoadieRun la cámara sigue detrás del personaje con dos fases:
--- Fase 1 (Quick Snap): la cámara se alinea agresivamente detrás del personaje.
--- Fase 2 (Steering):   hard follow — la cámara se bloquea detrás, sin cámara libre.
--- En Walking/Idle/Evade la cámara no sigue — el personaje se alinea a la cámara (strafe).
function CameraController:_applyFollowYaw(hrp: BasePart, dt: number)
	local strength = self._followYawStrength
	if strength <= 0 then
		return
	end

	-- En RoadieRun: dos fases para la cámara también
	self._roadieYawTimer = self._roadieYawTimer + dt
	local inSnapPhase = self._roadieYawTimer < Constants.ROADIE_SNAP_DURATION

	-- Fase 1: snap agresivo. Fase 2: hard follow bloqueado.
	local effectiveStrength: number
	if inSnapPhase then
		effectiveStrength = Constants.CAM_FOLLOW_YAW_RUN_SNAP
	else
		effectiveStrength = Constants.CAM_FOLLOW_YAW_RUN_STEER
	end

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
function CameraController:_computeSpringArm(hrp: BasePart, _camera: Camera, dt: number, rotationCF: CFrame): number
	local pivot = hrp.Position + Constants.CAM_ARM_PIVOT_OFFSET

	-- Dirección de la cámara reutilizada desde Update (evita recalcular CFrame.Angles)
	local lookDir = rotationCF.LookVector
	local ideal = Constants.CAM_ARM_LENGTH

	local character = hrp.Parent
	if character ~= self._lastFilterCharacter then
		self._lastFilterCharacter = character
		self._raycastParams.FilterDescendantsInstances = { character }
	end

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

--- Nudge suave del yaw de cámara hacia la dirección de la cover normal.
--- Converge y se auto-desactiva — no corre indefinidamente.
--- El pitch queda 100% controlado por el mouse.
function CameraController:_applyDynamicFraming(baseCF: CFrame, hrp: BasePart, dt: number): CFrame
	local n = self._coverNormal
	-- Target estable: yaw que mira en la dirección de coverNormal.
	-- CFrame.Angles(0, yaw, 0) produce LookVector = (-sin(yaw), 0, -cos(yaw))
	-- Entonces: yaw = atan2(-n.X, -n.Z) para alinear LookVector con coverNormal.
	local targetYaw = math.atan2(-n.X, -n.Z)
	local currentYaw = math.rad(self._yaw)

	-- Diferencia angular más corta (normalizada a [-π, π])
	local diff = targetYaw - currentYaw
	diff = ((diff + math.pi) % (2 * math.pi)) - math.pi

	-- Convergió → desactivar hasta el próximo cambio de cover
	if math.abs(diff) < 0.01 then
		self._coverFrameActive = false
		return baseCF
	end

	-- Blend suave solo del yaw — pitch y roll permanecen intactos
	local alpha = math.min(1, Constants.CAM_COVER_FRAME_SPEED * dt)
	self._yaw = self._yaw + math.deg(diff * alpha)

	-- Reconstruir baseCF con el yaw corregido (pitch y shoulder ya aplicados)
	local rotationCF = CFrame.Angles(0, math.rad(self._yaw), 0) * CFrame.Angles(math.rad(self._pitch), 0, 0)
	local lookDir = rotationCF.LookVector
	local rightDir = rotationCF.RightVector

	local pivot = hrp.Position + Constants.CAM_ARM_PIVOT_OFFSET
	local camPos = pivot + rightDir * self._currentShoulderX - lookDir * self._currentArmLength
	return CFrame.new(camPos) * rotationCF
end

------------------------------------------------------------------------
-- INTERNAL: Camera Bob
------------------------------------------------------------------------

--- Retorna un CFrame de offset de bob con fade suave.
function CameraController:_computeBobOffset(dt: number): CFrame
	-- Lerp suave del multiplicador para evitar saltos al cambiar de estado
	self._currentBobMultiplier = self._currentBobMultiplier
		+ (self._targetBobMultiplier - self._currentBobMultiplier) * math.min(1, Constants.CAM_BOB_LERP_SPEED * dt)

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
