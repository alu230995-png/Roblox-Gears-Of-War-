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

	return self
end

--- Marca que se necesita asentamiento de rotación (llamar al entrar desde entering/swap).
function InCover:NotifyEnterFromSnap()
	self._needsSettle = true
	self._settleTimer = 0
	self._settleStartRot = nil -- se captura en el primer frame de _applySettleRotation

	local hrp = self:_getHRP()
	if not hrp then
		return
	end

	-- SOLUCIÓN: Aplicar Wall-Glue una única vez para forzar la posición correcta
	-- ANTES de que comience el settle y desactivar las colisiones.
	self:_applyWallGlue(hrp)

	-- Capturar rotación inicial (ahora la posición ya es la correcta)
	self._settleStartRot = hrp.CFrame.Rotation

	-- (Opcional) Si usaste el código del mensaje anterior para anular el "Drift",
	-- guarda el _settleStartDist aquí mismo:
	if self._state.coverNormal and self._state.coverPosition then
		self._settleStartDist = (hrp.Position - self._state.coverPosition):Dot(self._state.coverNormal)
	end

	-- 1. DESACTIVAR COLISIONES (Para evitar que se atore con la pared)
	local coverPart = self._state.coverInstance
	if coverPart then
		local noCol = Instance.new("NoCollisionConstraint")
		noCol.Name = "CoverSettleNoCollision"
		noCol.Part0 = hrp
		noCol.Part1 = coverPart
		noCol.Parent = hrp
	end

	-- 2. DESACTIVAR AutoRotate del Humanoid
	local humanoid = hrp.Parent:FindFirstChild("Humanoid")
	if humanoid then
		humanoid.AutoRotate = false
	end
end

------------------------------------------------------------------------
-- PUBLIC API: CoverIdle
------------------------------------------------------------------------

--- Actualiza la física de CoverIdle cada frame.
--- Velocidad horizontal = 0, wall-glue activo.
--- @param _dt number — delta time (reservado para futuras mecánicas)
--- @param _envContext table? — EnvironmentContext del EnvironmentSensor
function InCover:UpdateIdle(_dt: number, _envContext: any?)
	local hrp = self:_getHRP()
	if not hrp then
		return
	end

	-- Restricción total: velocidad horizontal = 0
	hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)

	-- Pegamento: corregir posición si la física empujó al personaje
	if not self._needsSettle then
		self:_applyWallGlue(hrp)
	end

	-- Rotación de asentamiento: solo si viene de entering/swap (breve, ~0.3s)
	self:_applySettleRotation(hrp, _dt)
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
---   6. V = wallRight × movementScale × COVER_WALK_SPEED (preservar Y)
---   7. Wall-glue
---
--- @param _dt number — delta time
--- @param _envContext table? — EnvironmentContext del EnvironmentSensor
function InCover:UpdateWalking(dt: number, _envContext: any?)
	local hrp = self:_getHRP()
	if not hrp then
		return
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
	local cam = self._state.cameraController
	if cam then
		if movementScale < -0.1 then
			cam:SetShoulderSide("Left")
		elseif movementScale > 0.1 then
			cam:SetShoulderSide("Right")
		end
	end

	-- 4. TRANSICIÓN FLUIDA: esquina interna (pared perpendicular)
	-- Si hay movimiento lateral significativo, preguntar al sensor si hay una
	-- pared perpendicular justo enfrente. Si sí: actualizar normal + rotar CFrame
	-- + recalcular todo en el MISMO FRAME → movimiento continuo sin frenar.
	local sensor = self._state.envSensor
	if sensor and math.abs(movementScale) > Constants.LATERAL_TRIGGER_THRESHOLD then
		local newNormal, newPosition, newInstance = sensor:CheckInnerCorner(hrp, coverNormal, wallRight, movementScale)

		if newNormal then
			-- A) Actualizar estado compartido con la nueva pared
			self._state.coverNormal = newNormal
			self._state.coverPosition = newPosition
			self._state.coverInstance = newInstance
			self._state.wallRight = Vector3.yAxis:Cross(newNormal).Unit

			-- B) Rotación delegada a _smoothRotation (lerp al final del frame)

			-- C) Recalcular el riel y la proyección con la nueva normal
			coverNormal = newNormal
			wallRight = Vector3.yAxis:Cross(coverNormal)
			if wallRight.Magnitude < Constants.ZERO_MAGNITUDE then
				hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
				self:_applyWallGlue(hrp)
				return
			end
			wallRight = wallRight.Unit
			movementScale = moveDirWorld:Dot(wallRight)
		end
	end

	-- 5. BLOQUEAR EN ESQUINAS EXTERNAS via CornerCover
	if self._cornerCover and math.abs(movementScale) > Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		if self._cornerCover:IsBlocked(movementScale) then
			movementScale = 0
		end
	end

	-- 6. APLICAR VELOCIDAD sobre el riel
	if math.abs(movementScale) > Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		local velocity = wallRight * movementScale * Constants.COVER_WALK_SPEED
		hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, hrp.AssemblyLinearVelocity.Y, velocity.Z)
	else
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
	end

	-- 7. WALL-GLUE: corregir posición cada frame
	if not self._needsSettle then
		self:_applyWallGlue(hrp)
	end

	-- 8. SMOOTH ROTATION: lerp hacia la normal de cover (solo en esquinas internas)
	-- Saltar durante settle para no pelear con _applySettleRotation
	if not self._needsSettle and sensor and math.abs(movementScale) > Constants.LATERAL_TRIGGER_THRESHOLD then
		self:_smoothRotation(hrp, dt)
	end

	-- 9. Settle rotation (si viene de entering/swap)
	self:_applySettleRotation(hrp, dt)
end

------------------------------------------------------------------------
-- INTERNAL: Settle Rotation — solo al inicio desde entering/swap
------------------------------------------------------------------------

local SETTLE_DURATION = 0.3 -- duración del asentamiento en segundos

function InCover:_applySettleRotation(hrp: BasePart, dt: number)
	if not self._needsSettle then
		return
	end

	self._settleTimer = self._settleTimer + dt

	-- Si ya se cumplió el tiempo, REACTIVAMOS TODO y terminamos
	if self._settleTimer >= SETTLE_DURATION then
		-- Snap final exacto a la normal con drift corregido
		-- IMPORTANTE: leer _settleStartDist ANTES de limpiarlo
		local coverNormal = self._state.coverNormal
		if coverNormal then
			local pos = hrp.Position
			local coverPos = self._state.coverPosition
			if coverPos and self._settleStartDist then
				local currentDist = (pos - coverPos):Dot(coverNormal)
				local err = currentDist - self._settleStartDist
				pos = pos - coverNormal * err
			end
			hrp.CFrame = CFrame.new(pos) * CFrame.lookAt(Vector3.zero, coverNormal).Rotation
		end

		self._needsSettle = false
		self._settleStartRot = nil
		self._settleStartDist = nil

		self:_cleanupSettle(hrp)
		return
	end

	local coverNormal = self._state.coverNormal
	if not coverNormal then
		self._needsSettle = false
		self._settleStartRot = nil
		self._settleStartDist = nil
		self:_cleanupSettle(hrp)
		return
	end

	local startRot = self._settleStartRot
	if not startRot then
		self._needsSettle = false
		self:_cleanupSettle(hrp)
		return
	end

	-- Progreso normalizado 0→1
	local t = math.clamp(self._settleTimer / SETTLE_DURATION, 0, 1)

	-- EaseInOutSine: arranque suave, desaceleración suave
	local eased = -(math.cos(math.pi * t) - 1) / 2

	-- Posición con drift corregido en el eje perpendicular a la pared
	local pos = hrp.Position
	local coverPos = self._state.coverPosition
	if coverPos and self._settleStartDist then
		local currentDist = (pos - coverPos):Dot(coverNormal)
		local err = currentDist - self._settleStartDist
		pos = pos - coverNormal * err
	end

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

--- Limpia NoCollisionConstraint y restaura AutoRotate al terminar/abortar settle.
function InCover:_cleanupSettle(hrp: BasePart)
	local noCol = hrp:FindFirstChild("CoverSettleNoCollision")
	if noCol then
		noCol:Destroy()
	end
end

--- Obtiene el HumanoidRootPart del personaje local (nil si no existe).
function InCover:_getHRP(): BasePart?
	local character = self._state.player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

return InCover
