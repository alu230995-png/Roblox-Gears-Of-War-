--[[
	CoverRunning.luau
	═══════════════════════════════════════════════════════════════
	Sub-estado: Corriendo en cover (movimiento rápido lateral)
	═══════════════════════════════════════════════════════════════

	Misma mecánica que InCover:UpdateWalking pero con COVER_RUN_SPEED
	(ligeramente más rápido) y fallback a dirección de cámara cuando
	no hay input de movimiento (estilo RoadieRun auto-forward).

	Física directa mediante AssemblyLinearVelocity — WalkSpeed=0
	en SpeedMap, por lo que ESTE módulo controla la velocidad
	horizontal cuando está activo.

	Pipeline (idéntico a InCover:UpdateWalking):
	  1. Calcular wallRight = Up × N
	  2. Obtener dirección: MoveDirection (input) o Camera LookVector (fallback)
	  3. Proyectar sobre wallRight → movementScale
	  4. Esquina interna → cambiar normal + rotar CFrame
	  5. Bloquear esquinas externas via CornerCover
	  6. V = wallRight × movementScale × COVER_RUN_SPEED
	  7. Wall-glue
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local CoverMovementUtils = require(script.Parent.CoverMovementUtils)

local CoverRunning = {}
CoverRunning.__index = CoverRunning

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CoverRunning.new(coverState, cornerCover)
	local self = setmetatable({}, CoverRunning)

	self._state = coverState -- referencia al estado compartido de CoverMain
	self._cornerCover = cornerCover -- para bloqueo en esquinas
	self._isActive = false
	self._cornerCooldown = 0 -- cooldown tras transición de esquina interna (anti ping-pong)

	-- Cache de character refs (evita FindFirstChild cada frame)
	self._cachedCharacter = nil :: Model?
	self._cachedHRP = nil :: BasePart?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Inicia CoverRunning.
function CoverRunning:Begin()
	self._isActive = true
	self._cornerCooldown = 0 -- BUG-002 fix: resetear cooldown residual de sesión anterior
end

--- Detiene CoverRunning.
function CoverRunning:Stop()
	self._isActive = false
end

--- Retorna true si CoverRunning está activo.
function CoverRunning:IsActive(): boolean
	return self._isActive
end

--- Actualiza CoverRunning cada frame.
--- @param _dt number — delta time
--- @param _envContext table? — EnvironmentContext
function CoverRunning:Update(dt: number, _envContext: any?)
	if not self._isActive then
		return
	end

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

	-- 2. OBTENER DIRECCIÓN: MoveDirection (input) o Camera LookVector (fallback auto-forward)
	local humanoid = hrp.Parent and hrp.Parent:FindFirstChild("Humanoid") :: Humanoid?
	local moveDirWorld = Vector3.zero
	if humanoid and humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		moveDirWorld = humanoid.MoveDirection
	else
		-- Fallback: usar Camera LookVector aplanado (auto-forward estilo RoadieRun)
		local camera = workspace.CurrentCamera
		if camera then
			local lookDir = camera.CFrame.LookVector
			local flat = Vector3.new(lookDir.X, 0, lookDir.Z)
			if flat.Magnitude > Constants.ZERO_MAGNITUDE then
				moveDirWorld = flat.Unit
			end
		end
	end

	-- 3. PROYECTAR SOBRE EL RIEL (producto punto)
	local movementScale = moveDirWorld:Dot(wallRight)

	-- 4. COOLDOWN de transición de esquina interna (anti ping-pong)
	if self._cornerCooldown > 0 then
		self._cornerCooldown = self._cornerCooldown - dt
	end

	-- 4b. BLOQUEAR EN ESQUINAS EXTERNAS via CornerCover
	if self._cornerCover and math.abs(movementScale) > Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		if self._cornerCover:IsBlocked(movementScale) then
			movementScale = 0
			-- Anclar velocidad tangencial inmediatamente para evitar oscilación en esquina
			hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
		end
	end

	-- 5. TRANSICIÓN FLUIDA: esquina interna (pared 30°–90°)
	if self._cornerCooldown <= 0 and math.abs(movementScale) > Constants.LATERAL_TRIGGER_THRESHOLD then
		local newCoverNormal, newWallRight, newMovementScale, transitioned =
			CoverMovementUtils.handleInnerCornerTransition(
				self._state, hrp, coverNormal, wallRight, movementScale, moveDirWorld
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

	-- 6. APLICAR VELOCIDAD sobre el riel (COVER_RUN_SPEED — más rápido que COVER_WALK_SPEED)
	if math.abs(movementScale) > Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		local velocity = wallRight * movementScale * Constants.COVER_RUN_SPEED
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
-- INTERNAL: Smooth Rotation — delegado a CoverMovementUtils
------------------------------------------------------------------------

function CoverRunning:_smoothRotation(hrp: BasePart, dt: number)
	CoverMovementUtils.smoothRotation(self._state, hrp, dt)
end

------------------------------------------------------------------------
-- INTERNAL: Wall-Glue — delegado a CoverMovementUtils
------------------------------------------------------------------------

function CoverRunning:_applyWallGlue(hrp: BasePart)
	CoverMovementUtils.applyWallGlue(self._state, hrp)
end

------------------------------------------------------------------------
-- INTERNAL: Helpers
------------------------------------------------------------------------

function CoverRunning:_getHRP(): BasePart?
	return CoverMovementUtils.getHRP(self._state, self)
end

return CoverRunning
