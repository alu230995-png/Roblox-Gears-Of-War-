--[[
	InCover.luau
	═══════════════════════════════════════════════════════════════
	Sub-estado: En cover (CoverIdle + CoverWalking)
	═══════════════════════════════════════════════════════════════

	Física directa mediante AssemblyLinearVelocity — el Humanoid
	WalkSpeed=0 en ambos estados (SpeedMap), así que ESTE módulo
	es el ÚNICO origen de movimiento horizontal en cover.

	Dos sub-comportamientos:

	  CoverIdle (reposo total):
	    - Velocidad horizontal = 0
	    - Wall-glue: corrección de posición cada frame

	  CoverWalking (desplazamiento restringido):
	    - Movimiento SOLO a lo largo del Tangente T = Up × N
	    - V = InputLateral × T × COVER_WALK_SPEED
	    - Bloqueo en esquinas via CornerCover
	    - Wall-glue: corrección de posición cada frame

	Wall-glue (compartido):
	  Proyecta la posición del HumanoidRootPart al plano de la pared
	  + COVER_OFFSET a lo largo de la Normal. Si el motor de física
	  empuja al personaje fuera del umbral COVER_GLUE_MAX_DIST,
	  se fuerza la posición de vuelta y se anula la componente de
	  velocidad perpendicular a la pared.

	FUTURO: PopUpAim, BlindFire, ReturnToCover se añadirán como
	capas combinables que corren simultáneamente.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local CoverMovementUtils = require(script.Parent.CoverMovementUtils)

local InCover = {}
InCover.__index = InCover

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function InCover.new(coverState, cornerCover)
	local self = setmetatable({}, InCover)

	self._state = coverState -- referencia al estado compartido de CoverMain
	self._cornerCover = cornerCover -- referencia a CornerCover para consultar bloqueos
	self._settleTimer = 0 -- timer para rotación de asentamiento al entrar
	self._needsSettle = false -- true si viene de entering/swap y necesita alinear a normal
	self._cornerCooldown = 0 -- cooldown tras transición de esquina interna (anti ping-pong)

	-- Cache de character refs (evita FindFirstChild cada frame)
	self._cachedCharacter = nil :: Model?
	self._cachedHRP = nil :: BasePart?

	return self
end

--- Marca que se necesita asentamiento de rotación (llamar al entrar desde entering/swap).
function InCover:NotifyEnterFromSnap()
	self._needsSettle = true
	self._settleTimer = 0
	self._settleStartRot = nil -- se captura en el primer frame de _applySettleRotation
	self._cornerCooldown = 0

	-- Notificar a la cámara que el settle está activo (desactiva Dynamic Framing)
	self._state.onCoverSettleChanged:Fire(true)

	local hrp = self:_getHRP()
	if not hrp then
		return
	end

	self:_applyWallGlue(hrp)

	-- Capturar rotación y posición iniciales (ahora la posición ya es la correcta).
	-- _settleStartPos pin-ea la posición XZ completa durante el settle:
	-- el personaje solo rota (eje Y), sin desplazamiento visible.
	self._settleStartRot = hrp.CFrame.Rotation
	self._settleStartPos = hrp.Position

	-- 1. DESACTIVAR COLISIONES (Para evitar que se atore con la pared)
	local coverPart = self._state.coverInstance
	if coverPart then
		-- Destruir constraint existente para evitar acumulación si se llama antes de cleanup
		local existing = hrp:FindFirstChild("CoverSettleNoCollision")
		if existing then
			existing:Destroy()
		end

		local noCol = Instance.new("NoCollisionConstraint")
		noCol.Name = "CoverSettleNoCollision"
		noCol.Part0 = hrp
		noCol.Part1 = coverPart
		noCol.Parent = hrp
	end
end

------------------------------------------------------------------------
-- PUBLIC API: CoverIdle
------------------------------------------------------------------------

--- Actualiza la física de CoverIdle cada frame.
--- Velocidad horizontal = 0, wall-glue activo, rotación estabilizada.
--- @param dt number — delta time
--- @param _envContext table? — EnvironmentContext del EnvironmentSensor
function InCover:UpdateIdle(dt: number, _envContext: any?)
	local hrp = self:_getHRP()
	if not hrp then
		return
	end

	-- Restricción total: velocidad horizontal = 0
	hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)

	if self._needsSettle then
		-- Durante settle: solo rotar en el lugar (posición pin-eada)
		self:_applySettleRotation(hrp, dt)
		return
	end

	-- Pegamento: corregir posición si la física empujó al personaje
	self:_applyWallGlue(hrp)
	-- Smooth rotation: mantener alineación a la normal de cover
	-- (necesario después de settle y tras transiciones de esquina interna)
	self:_smoothRotation(hrp, dt)
end

------------------------------------------------------------------------
-- PUBLIC API: CoverWalking
------------------------------------------------------------------------

--- Actualiza la física de CoverWalking cada frame.
--- Movimiento restringido al riel de la pared usando proyección de cámara.
---
--- Pipeline:
---   1. Calcular wallRight = Up × N (riel de la pared, apunta a la DERECHA del jugador)
---   2. Obtener MoveDirection (ya es camera-relative en Roblox)
---   3. Proyectar MoveDirection sobre wallRight con Dot → movementScale (-1..1)
---   4. Detectar esquina interna → cambiar normal + rotar CFrame al vuelo
---   5. Bloquear en esquinas externas via CornerCover
---   6. V = wallRight × movementScale × speed (preservar Y)
---   7. Wall-glue
---
--- @param _dt number — delta time
--- @param _envContext table? — EnvironmentContext del EnvironmentSensor
--- @param speedOverride number? — velocidad alternativa (ej: reducida al apuntar); usa COVER_WALK_SPEED si nil
function InCover:UpdateWalking(dt: number, _envContext: any?, speedOverride: number?)
	local hrp = self:_getHRP()
	if not hrp then
		return
	end

	-- Si el settle está activo y el jugador empieza a moverse, cancelar settle:
	-- el movimiento lateral tiene prioridad sobre la rotación de asentamiento.
	-- Sin este guard, _applySettleRotation pin-ea XZ a _settleStartPos causando un TP.
	if self._needsSettle then
		self:_cancelSettle(hrp)
	end

	local coverNormal = self._state.coverNormal
	if not coverNormal then
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
		return
	end

	-- 1. CALCULAR EL RIEL: wallRight = Up × N → apunta a la DERECHA del jugador
	local wallRight = Vector3.yAxis:Cross(coverNormal)
	if wallRight.Magnitude < Constants.ZERO_MAGNITUDE then
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
		self:_applyWallGlue(hrp)
		return
	end
	wallRight = wallRight.Unit

	-- 2. OBTENER DIRECCIÓN DE MOVIMIENTO (camera-relative)
	local humanoid = hrp.Parent and hrp.Parent:FindFirstChild("Humanoid") :: Humanoid?
	local moveDirWorld = Vector3.zero
	if humanoid and humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		moveDirWorld = humanoid.MoveDirection
	end

	-- 3. PROYECTAR SOBRE EL RIEL (producto punto)
	local movementScale = moveDirWorld:Dot(wallRight)

	-- 3b. SHOULDER SWAP: notificar a la cámara el lado del movimiento
	if movementScale < -Constants.MOVE_DIRECTION_THRESHOLD then
		self._state.onShoulderSideChanged:Fire("Left")
	elseif movementScale > Constants.MOVE_DIRECTION_THRESHOLD then
		self._state.onShoulderSideChanged:Fire("Right")
	end

	-- 4. COOLDOWN de transición de esquina interna (anti ping-pong)
	if self._cornerCooldown > 0 then
		self._cornerCooldown = self._cornerCooldown - dt
	end

	-- 4b. BLOQUEAR EN ESQUINAS EXTERNAS via CornerCover
	-- IMPORTANTE: debe ocurrir ANTES de CheckInnerCorner.
	if self._cornerCover and math.abs(movementScale) > Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		if self._cornerCover:IsBlocked(movementScale) then
			movementScale = 0
			-- Anclar velocidad tangencial inmediatamente para evitar que la física
			-- filtre movimiento residual que causa oscilación en la esquina.
			hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
		end
	end

	-- 5. TRANSICIÓN FLUIDA: esquina interna (pared 30°–90°)
	local sensor = self._state.envSensor
	if self._cornerCooldown <= 0 and math.abs(movementScale) > Constants.LATERAL_TRIGGER_THRESHOLD then
		if sensor then
			local newCoverNormal, newWallRight, newMovementScale, transitioned =
				CoverMovementUtils.handleInnerCornerTransition(
					self._state,
					hrp,
					coverNormal,
					wallRight,
					movementScale,
					moveDirWorld
				)

			if transitioned then
				coverNormal = newCoverNormal
				wallRight = newWallRight
				movementScale = newMovementScale
				self._cornerCooldown = Constants.CORNER_TRANSITION_COOLDOWN

				if wallRight.Magnitude < Constants.ZERO_MAGNITUDE then
					hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
					self:_applyWallGlue(hrp)
					return
				end
			end
		end
	end

	-- 6. APLICAR VELOCIDAD sobre el riel
	if math.abs(movementScale) > Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		local targetSpeed = speedOverride or Constants.COVER_WALK_SPEED
		local velocity = wallRight * movementScale * targetSpeed
		hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, hrp.AssemblyLinearVelocity.Y, velocity.Z)
	else
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
	end

	-- 7. WALL-GLUE: corregir posición cada frame
	self:_applyWallGlue(hrp)
	-- Smooth rotation: mantener alineación a la normal de cover
	-- (corrige orientación tras transición de esquina interna)
	-- NO aplicar en estados de aim: RotationHandler gestiona la rotación allí
	-- para evitar que _smoothRotation (→ pared) luche con _alignToDirection (→ afuera).
	local currentState = self._state.stateMachine and self._state.stateMachine:GetCurrentState()
	local isAimState = currentState == "CoverAimHigh" or currentState == "CoverAimLow" or currentState == "CoverFiring"
	if not isAimState then
		self:_smoothRotation(hrp, dt)
	end
end

------------------------------------------------------------------------
-- INTERNAL: Settle Rotation — solo al inicio desde entering/swap
------------------------------------------------------------------------

function InCover:_applySettleRotation(hrp: BasePart, dt: number)
	if not self._needsSettle then
		return
	end

	self._settleTimer = self._settleTimer + dt

	-- Si ya se cumplió el tiempo, REACTIVAMOS TODO y terminamos
	if self._settleTimer >= Constants.COVER_SETTLE_DURATION then
		-- Snap final exacto a la normal en la posición pin-eada
		local coverNormal = self._state.coverNormal
		local pinnedPos = self._settleStartPos or hrp.Position
		local finalPos = Vector3.new(pinnedPos.X, hrp.Position.Y, pinnedPos.Z)
		if coverNormal then
			hrp.CFrame = CFrame.new(finalPos) * CFrame.lookAt(Vector3.zero, coverNormal).Rotation
		end

		self._needsSettle = false
		self._settleStartRot = nil
		self._settleStartPos = nil

		self:_cleanupSettle(hrp)
		return
	end

	local coverNormal = self._state.coverNormal
	if not coverNormal then
		self._needsSettle = false
		self._settleStartRot = nil
		self._settleStartPos = nil
		self:_cleanupSettle(hrp)
		return
	end

	local startRot = self._settleStartRot
	if not startRot then
		self._needsSettle = false
		self._settleStartPos = nil
		self:_cleanupSettle(hrp)
		return
	end

	-- Progreso normalizado 0→1
	local t = math.clamp(self._settleTimer / Constants.COVER_SETTLE_DURATION, 0, 1)

	-- EaseInOutSine: arranque suave, desaceleración suave
	local eased = -(math.cos(math.pi * t) - 1) / 2

	-- Posición pin-eada: usar la posición capturada al inicio del settle.
	-- Solo preservar Y del frame actual (gravedad) y fijar XZ.
	local pinnedPos = self._settleStartPos or hrp.Position
	local pos = Vector3.new(pinnedPos.X, hrp.Position.Y, pinnedPos.Z)

	local targetRot = CFrame.lookAt(Vector3.zero, coverNormal).Rotation
	local blendedRot = startRot:Lerp(targetRot, eased)
	hrp.CFrame = CFrame.new(pos) * blendedRot
end

------------------------------------------------------------------------
-- INTERNAL: Smooth Rotation — delegado a CoverMovementUtils
------------------------------------------------------------------------

function InCover:_smoothRotation(hrp: BasePart, dt: number)
	CoverMovementUtils.smoothRotation(self._state, hrp, dt)
end

------------------------------------------------------------------------
-- INTERNAL: Wall-Glue — delegado a CoverMovementUtils
------------------------------------------------------------------------

function InCover:_applyWallGlue(hrp: BasePart)
	CoverMovementUtils.applyWallGlue(self._state, hrp)
end

------------------------------------------------------------------------
-- INTERNAL: Helpers
------------------------------------------------------------------------

--- Cancela el settle inmediatamente cuando el movimiento lateral toma prioridad.
--- Limpia el pin de posición para evitar TPs y restaura colisiones.
function InCover:_cancelSettle(hrp: BasePart?)
	if not self._needsSettle then
		return
	end
	self._needsSettle = false
	self._settleStartRot = nil
	self._settleStartPos = nil
	self:_cleanupSettle(hrp)
end

--- Limpia NoCollisionConstraint y restaura estado al terminar/abortar settle.
function InCover:_cleanupSettle(hrp: BasePart?)
	-- BUG-005 fix: guard defensivo si hrp es nil (evita constraint huérfana)
	if not hrp then
		hrp = self:_getHRP()
	end
	if hrp then
		local noCol = hrp:FindFirstChild("CoverSettleNoCollision")
		if noCol then
			noCol:Destroy()
		end
	end

	-- Solo desbloquear el settle guard. NO activar Dynamic Framing aquí:
	-- durante CoverIdle normal la cámara no debe ser empujada cada frame
	-- hacia la cover normal. SetCoverNormal solo se llama cuando la cover
	-- realmente cambia (esquina interna, cover swap).
	self._state.onCoverSettleChanged:Fire(false)
end

--- Obtiene el HumanoidRootPart del personaje local con cache (nil si no existe).
function InCover:_getHRP(): BasePart?
	return CoverMovementUtils.getHRP(self._state, self)
end

return InCover
