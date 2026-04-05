--[[
	EnteringCover.luau
	═══════════════════════════════════════════════════════════════
	Sub-estado: Entrada a cover (CoverEntering / CoverSlide)
	═══════════════════════════════════════════════════════════════
	
	Toda la lógica de snap magnético hacia la pared:
	  - Movimiento por velocidad × dt (ease-out cúbico)
	  - Rotación suave via slerp/lerp blend progresivo
	  - Cancelación: empujar hacia atrás, stuck timeout, cover destruida
	  - Cover chaining: re-dirige a otra cover mid-entry
	  - Corner clamp: evita snap en aristas del Part
	
	NOTA: Controla CFrame directamente durante el entering.
	WalkSpeed=0 durante CoverEntering (SpeedMap).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local EnteringCover = {}
EnteringCover.__index = EnteringCover

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function EnteringCover.new(coverState)
	local self = setmetatable({}, EnteringCover)

	self._state = coverState -- referencia al estado compartido de CoverMain

	-- Entering data (solo existe durante CoverEntering / CoverSlide)
	-- Struct: { snapCFrame, wallNormal, wallRight, coverPart, startTime, initialDist }
	self._entering = nil

	-- Normal de la cover en el momento exacto en que el jugador detectó la cover.
	-- Se captura UNA sola vez en Begin/BeginSlide y NO cambia con chaining.
	-- Es la referencia fija para decidir si el jugador se está alejando (cancelación).
	self._cancelNormal = nil :: Vector3?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Inicia el entering desde walk. Calcula snapCFrame con corner clamp.
function EnteringCover:Begin(data)
	if not data then
		return
	end

	local character = self._state.player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Eliminar inercia horizontal para que el snap sea limpio
	hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)

	self._entering = self:_buildEnteringData(data.coverInstance, data.coverPos, data.coverNormal, hrp)
	self._state.wallRight = self._entering.wallRight

	-- Guardar la normal de detección original. Solo se fija aquí, nunca en chaining.
	self._cancelNormal = data.coverNormal
end

--- Inicia el entering desde slide (RoadieRun). Misma lógica de snap.
function EnteringCover:BeginSlide(data)
	if not data then
		return
	end

	local character = self._state.player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)

	self._entering = self:_buildEnteringData(data.coverInstance, data.coverPos, data.coverNormal, hrp)
	self._state.wallRight = self._entering.wallRight

	-- Guardar la normal de detección original.
	self._cancelNormal = data.coverNormal
end

--- Retorna true si el entering está en progreso.
function EnteringCover:IsActive(): boolean
	return self._entering ~= nil
end

--- Cancela el entering sin transición de estado.
function EnteringCover:Cancel()
	self._entering = nil
	self._cancelNormal = nil
end

--- Actualiza el entering cada frame.
--- @param dt number
--- @param envContext table? — EnvironmentContext del EnvironmentSensor
--- @param wantsCoverRedirect boolean? — true si el jugador pulsó cover de nuevo
--- @return string — "continue" | "complete" | "cancel"
function EnteringCover:Update(dt: number, envContext: any?, wantsCoverRedirect: boolean?): string
	if not self._entering then
		return "continue"
	end

	local character = self._state.player.Character
	if not character then
		return "continue"
	end

	local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then
		return "continue"
	end

	-- Cover chaining: si hay cover diferente durante la entrada, re-dirigir
	if
		wantsCoverRedirect
		and envContext
		and envContext.HasCoverNearby
		and envContext.CoverInstance ~= self._entering.coverPart
	then
		local chainData = self:_tryChainCover(
			self._entering,
			envContext.CoverPosition,
			envContext.CoverNormal,
			envContext.CoverInstance,
			hrp
		)
		if chainData then
			self._entering = chainData
			self._state.coverNormal = chainData.wallNormal
			self._state.coverPosition = envContext.CoverPosition
			self._state.coverInstance = envContext.CoverInstance
			self._state.coverType = envContext.CoverType
			self._state.wallRight = chainData.wallRight

			-- Chain = nueva acción del jugador → actualizar la normal de cancelación
			-- a la nueva cover. La referencia original ya no es relevante.
			self._cancelNormal = envContext.CoverNormal

			if Constants.DEBUG_MODE then
				print("[GoW] EnteringCover: Chain — re-dirigido a nueva cover")
			end
		end
	end

	local result = self:_updateEntering(self._entering, hrp, humanoid, dt)

	if result == "cancel" or result == "complete" then
		self._entering = nil
		self._cancelNormal = nil
	end

	return result
end

------------------------------------------------------------------------
-- INTERNAL: Corner Clamp — evita snap en la arista del Part
------------------------------------------------------------------------

function EnteringCover:_clampHitToFace(
	coverPart: BasePart,
	hitPos: Vector3,
	wallNormal: Vector3,
	margin: number
): Vector3
	-- Up × N = vector que apunta a la DERECHA del jugador mirando la pared
	local wallRight = Vector3.yAxis:Cross(wallNormal)
	if wallRight.Magnitude < 0.001 then
		return hitPos
	end
	wallRight = wallRight.Unit

	local cf = coverPart.CFrame
	local half = coverPart.Size * 0.5

	local halfExt = math.abs(cf.RightVector:Dot(wallRight)) * half.X
		+ math.abs(cf.UpVector:Dot(wallRight)) * half.Y
		+ math.abs(cf.LookVector:Dot(wallRight)) * half.Z

	local proj = (hitPos - coverPart.Position):Dot(wallRight)
	local clamped = math.clamp(proj, -(halfExt - margin), halfExt - margin)

	return hitPos + wallRight * (clamped - proj)
end

------------------------------------------------------------------------
-- INTERNAL: Build Entering Data
------------------------------------------------------------------------

function EnteringCover:_buildEnteringData(coverPart: BasePart, hitPos: Vector3, wallNormal: Vector3, rootPart: BasePart)
	local safeHit = self:_clampHitToFace(coverPart, hitPos, wallNormal, Constants.COVER_CORNER_MARGIN)

	local rawTarget = safeHit + wallNormal * Constants.COVER_OFFSET

	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	local character = rootPart.Parent
	groundParams.FilterDescendantsInstances = if character then { character } else {}

	local playerGround = workspace:Raycast(rootPart.Position, Vector3.new(0, -10, 0), groundParams)
	local hipHeight = if playerGround then (rootPart.Position.Y - playerGround.Position.Y) else 3.0

	local destProbe = Vector3.new(rawTarget.X, rawTarget.Y + 5, rawTarget.Z)
	local destGround = workspace:Raycast(destProbe, Vector3.new(0, -15, 0), groundParams)
	local destGroundY = if destGround then destGround.Position.Y else (rootPart.Position.Y - hipHeight)

	local targetPos = Vector3.new(rawTarget.X, destGroundY + hipHeight, rawTarget.Z)

	local snapCFrame = CFrame.lookAt(targetPos, targetPos + wallNormal)

	-- Up × N = vector que apunta a la DERECHA del jugador mirando la pared
	local wallRight = Vector3.yAxis:Cross(wallNormal)
	if wallRight.Magnitude < 0.001 then
		wallRight = Vector3.xAxis
	else
		wallRight = wallRight.Unit
	end

	local initialDist = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(
		rootPart.Position.X,
		0,
		rootPart.Position.Z
	)).Magnitude
	if initialDist < 0.5 then
		initialDist = 0.5
	end

	return {
		snapCFrame = snapCFrame,
		wallNormal = wallNormal,
		wallRight = wallRight,
		coverPart = coverPart,
		startTime = os.clock(),
		initialDist = initialDist,
	}
end

------------------------------------------------------------------------
-- INTERNAL: Update Entering (loop Heartbeat)
------------------------------------------------------------------------

function EnteringCover:_updateEntering(data, rootPart: BasePart, humanoid: Humanoid, dt: number): string
	local currentPos = rootPart.Position
	local targetCF = data.snapCFrame
	local targetPos = targetCF.Position

	-- ── 1. CANCELACIÓN ────────────────────────────────────────────

	if not data.coverPart or not data.coverPart:IsDescendantOf(workspace) then
		if Constants.DEBUG_MODE then
			print("[GoW] EnteringCover: cancelado — cover part destruida")
		end
		return "cancel"
	end

	local moveDir = humanoid.MoveDirection
	if moveDir.Magnitude > 0.1 and self._cancelNormal then
		local awayDot = moveDir:Dot(self._cancelNormal)
		if awayDot > Constants.COVER_ENTRY_CANCEL_DOT then
			return "cancel"
		end
	end

	if (os.clock() - data.startTime) > Constants.COVER_STUCK_TIMEOUT then
		if Constants.DEBUG_MODE then
			print("[GoW] EnteringCover: cancelado por stuck timeout")
		end
		return "cancel"
	end

	-- ── 2. MOVIMIENTO con ease-out ──────────────────────────────

	local toTarget = Vector3.new(targetPos.X - currentPos.X, 0, targetPos.Z - currentPos.Z)
	local distXZ = toTarget.Magnitude

	local t = 1 - math.clamp(distXZ / data.initialDist, 0, 1)
	local easeFactor = 1 - (1 - t) * (1 - t) * (1 - t)

	local speedFrac = 1 - easeFactor * (1 - Constants.COVER_SNAP_MIN_SPEED_FRAC)
	local currentSpeed = Constants.COVER_SNAP_SPEED * speedFrac
	local maxStep = currentSpeed * dt

	local newPos
	if distXZ <= maxStep then
		newPos = Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)
	else
		local step = toTarget.Unit * maxStep
		newPos = Vector3.new(currentPos.X + step.X, currentPos.Y, currentPos.Z + step.Z)
	end

	-- ── 3. ROTACIÓN progresiva ──────────────────────────────────

	local rotBlend = Constants.COVER_ROTATION_BLEND_MIN
		+ (Constants.COVER_ROTATION_BLEND_MAX - Constants.COVER_ROTATION_BLEND_MIN) * easeFactor

	local currentRot = rootPart.CFrame.Rotation
	local targetRot = targetCF.Rotation
	local blendedRot = currentRot:Lerp(targetRot, rotBlend)

	rootPart.CFrame = CFrame.new(newPos) * blendedRot

	-- ── 4. COMPROBACIÓN DE COMPLETADO ─────────────────────────────

	local finalDistXZ = Vector3.new(targetPos.X - newPos.X, 0, targetPos.Z - newPos.Z).Magnitude

	if finalDistXZ < Constants.COVER_COMPLETION_XZ then
		rootPart.CFrame = CFrame.new(Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)) * targetCF.Rotation
		return "complete"
	end

	return "continue"
end

------------------------------------------------------------------------
-- INTERNAL: Cover Chaining (Cover A → Cover B mid-entry)
------------------------------------------------------------------------

function EnteringCover:_tryChainCover(
	currentData,
	newHitPos: Vector3,
	newNormal: Vector3,
	newPart: BasePart,
	rootPart: BasePart
)
	if newPart == currentData.coverPart then
		return nil
	end
	return self:_buildEnteringData(newPart, newHitPos, newNormal, rootPart)
end

return EnteringCover
