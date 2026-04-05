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

local InCover = {}
InCover.__index = InCover

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function InCover.new(coverState, cornerCover)
	local self = setmetatable({}, InCover)

	self._state = coverState -- referencia al estado compartido de CoverMain
	self._cornerCover = cornerCover -- referencia a CornerCover para consultar bloqueos

	return self
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
	self:_applyWallGlue(hrp)
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
	if wallRight.Magnitude < 0.001 then
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
		self:_applyWallGlue(hrp)
		return
	end
	wallRight = wallRight.Unit

	-- 2. OBTENER DIRECCIÓN DE MOVIMIENTO (camera-relative)
	local humanoid = hrp.Parent and hrp.Parent:FindFirstChild("Humanoid") :: Humanoid?
	local moveDirWorld = Vector3.zero
	if humanoid and humanoid.MoveDirection.Magnitude > 0.01 then
		moveDirWorld = humanoid.MoveDirection
	end

	-- 3. PROYECTAR SOBRE EL RIEL (producto punto)
	local movementScale = moveDirWorld:Dot(wallRight)

	-- 4. TRANSICIÓN FLUIDA: esquina interna (pared perpendicular)
	-- Si hay movimiento lateral significativo, preguntar al sensor si hay una
	-- pared perpendicular justo enfrente. Si sí: actualizar normal + rotar CFrame
	-- + recalcular todo en el MISMO FRAME → movimiento continuo sin frenar.
	local sensor = self._state.envSensor
	if sensor and math.abs(movementScale) > 0.1 then
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
			if wallRight.Magnitude < 0.001 then
				hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
				self:_applyWallGlue(hrp)
				return
			end
			wallRight = wallRight.Unit
			movementScale = moveDirWorld:Dot(wallRight)
		end
	end

	-- 5. BLOQUEAR EN ESQUINAS EXTERNAS via CornerCover
	if self._cornerCover and math.abs(movementScale) > 0.01 then
		if self._cornerCover:IsBlocked(movementScale) then
			movementScale = 0
		end
	end

	-- 6. APLICAR VELOCIDAD sobre el riel
	if math.abs(movementScale) > 0.01 then
		local velocity = wallRight * movementScale * Constants.COVER_WALK_SPEED
		hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, hrp.AssemblyLinearVelocity.Y, velocity.Z)
	else
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
	end

	-- 7. WALL-GLUE: corregir posición cada frame
	self:_applyWallGlue(hrp)

	-- 8. SMOOTH ROTATION: lerp hacia la normal de cover (evita snap brusco en esquinas)
	self:_smoothRotation(hrp, dt)
end

------------------------------------------------------------------------
-- INTERNAL: Smooth Rotation (lerp hacia la normal de cover)
------------------------------------------------------------------------

--- Interpola la orientación del HRP hacia coverNormal cada frame.
--- Usa exponential smoothing independiente del framerate.
function InCover:_smoothRotation(hrp: BasePart, dt: number)
	local coverNormal = self._state.coverNormal
	if not coverNormal then
		return
	end

	local pos = hrp.Position
	local targetCF = CFrame.lookAt(pos, pos + coverNormal)
	local alpha = 1 - math.exp(-Constants.CORNER_TURN_SPEED * dt)
	hrp.CFrame = hrp.CFrame:Lerp(targetCF, alpha)
end

------------------------------------------------------------------------
-- INTERNAL: Wall-Glue (corrección de posición contra la pared)
------------------------------------------------------------------------

--- Proyecta la posición del HRP al plano de la pared + COVER_OFFSET.
--- Si la distancia perpendicular excede COVER_GLUE_MAX_DIST, fuerza
--- la posición de vuelta y anula la componente de velocidad sobre N.
function InCover:_applyWallGlue(hrp: BasePart)
	local coverNormal = self._state.coverNormal
	local coverPosition = self._state.coverPosition
	if not coverNormal or not coverPosition then
		return
	end

	-- Vector del punto de contacto de la pared al jugador
	local toPlayer = hrp.Position - coverPosition
	-- Componente perpendicular a la pared (positivo = alejándose de la pared)
	local perpDist = toPlayer:Dot(coverNormal)
	-- Distancia deseada: COVER_OFFSET studs fuera de la pared
	local desiredDist = Constants.COVER_OFFSET
	local error = perpDist - desiredDist

	-- Si el error excede el umbral, corregir posición
	if math.abs(error) > Constants.COVER_GLUE_MAX_DIST then
		local correction = coverNormal * error
		hrp.CFrame = hrp.CFrame - Vector3.new(correction.X, 0, correction.Z)

		-- Anular componente de velocidad perpendicular a la pared
		local vel = hrp.AssemblyLinearVelocity
		local perpVel = vel:Dot(coverNormal)
		hrp.AssemblyLinearVelocity = vel - coverNormal * perpVel
	end
end

------------------------------------------------------------------------
-- INTERNAL: Helpers
------------------------------------------------------------------------

--- Obtiene el HumanoidRootPart del personaje local (nil si no existe).
function InCover:_getHRP(): BasePart?
	local character = self._state.player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

return InCover
