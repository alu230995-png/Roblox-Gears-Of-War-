--[[
	SwapDetector.luau
	═══════════════════════════════════════════════════════════════
	Detección de cover adyacente para Cover Swap
	═══════════════════════════════════════════════════════════════

	Responsabilidad única: determinar si existe una cobertura válida
	al otro lado del hueco, alineada y coplanar con la actual.

	Algoritmo de 6 pasos:
	  1. Rayo de detección en dirección de input → existencia
	  2. Extracción geométrica de 4 normales laterales desde CFrame
	  3. Construcción de tangentes (rieles) por cara: T = Up × N
	  4. Prueba de alineación: dot product ≥ threshold
	  5. Coplanaridad: |N · (faceNueva - faceActual)| < umbral
	  6. Obstrucción tangente: rayo libre entre coberturas

	Estado propio: RaycastParams (Exclude mode) reutilizable.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local RaycastUtils = require(script.Parent.RaycastUtils)

-- Debris solo se usa en debug — lazy-require para evitar costo en producción
local Debris = nil :: any
if Constants.DEBUG_MODE then
	Debris = game:GetService("Debris")
end

local SwapDetector = {}
SwapDetector.__index = SwapDetector

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function SwapDetector.new()
	local self = setmetatable({}, SwapDetector)

	-- RaycastParams reutilizable (Exclude mode: ignora character + cover actual)
	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Exclude
	self._rayParams.FilterDescendantsInstances = {}

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Chequea si hay una cobertura adyacente alineada al otro lado del hueco.
--- @param hrp BasePart — HumanoidRootPart
--- @param coverNormal Vector3 — normal de la cover actual
--- @param wallRight Vector3 — tangente de la cover actual (riel de referencia)
--- @param moveDir number — +1 (derecha) o -1 (izquierda)
--- @param currentCoverInstance BasePart — la cover en la que está el jugador
--- @param inputDirection Vector3 — humanoid.MoveDirection del jugador
--- @return BasePart? newCoverPart
--- @return Vector3? newCoverNormal
--- @return Vector3? hitPosition
function SwapDetector:Check(
	hrp: BasePart,
	coverNormal: Vector3,
	wallRight: Vector3,
	moveDir: number,
	currentCoverInstance: BasePart,
	inputDirection: Vector3
): (BasePart?, Vector3?, Vector3?)
	-- ═══════════════════════════════════════════════════════════
	-- PASO 1: Disparo de detección (normal de impacto DESECHADA)
	-- ═══════════════════════════════════════════════════════════
	local character = Players.LocalPlayer.Character
	if not character then
		return nil, nil, nil
	end

	self._rayParams.FilterDescendantsInstances = { character, currentCoverInstance }

	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET
	local flatInput = Vector3.new(inputDirection.X, 0, inputDirection.Z)
	if flatInput.Magnitude < Constants.ZERO_MAGNITUDE then
		flatInput = wallRight * moveDir
	else
		flatInput = flatInput.Unit
	end
	local rayDirection = flatInput * Constants.COVER_SWAP_MAX_DISTANCE

	local hitResult = workspace:Spherecast(origin, Constants.COVER_SWAP_SPHERE_RADIUS, rayDirection, self._rayParams)

	if Constants.DEBUG_MODE then
		self:_debugStep1(origin, rayDirection, flatInput, hitResult)
	end

	if not hitResult or not RaycastUtils.isCoverObject(hitResult.Instance) then
		if Constants.DEBUG_MODE and hitResult then
			print(string.format("[SwapRay] P1 RECHAZADO — %s no es CoverObject", hitResult.Instance.Name))
		end
		return nil, nil, nil
	end

	local newPart = hitResult.Instance :: BasePart

	-- ═══════════════════════════════════════════════════════════
	-- PASO 2–4: Extracción de normales + alineación de tangentes
	-- ═══════════════════════════════════════════════════════════
	local bestNormal, bestDot = self:_findBestAlignedFace(newPart, wallRight)

	if Constants.DEBUG_MODE then
		print(
			string.format(
				"[SwapRay] P4 Mejor alineación: dot=%.3f (min=%.2f) → %s",
				bestDot,
				Constants.COVER_SWAP_ALIGNMENT_THRESHOLD,
				if bestDot >= Constants.COVER_SWAP_ALIGNMENT_THRESHOLD then "OK" else "RECHAZADO"
			)
		)
	end

	if bestDot < Constants.COVER_SWAP_ALIGNMENT_THRESHOLD or not bestNormal then
		return nil, nil, nil
	end

	-- ═══════════════════════════════════════════════════════════
	-- PASO 5: Validación de coplanaridad (caras frontales)
	-- ═══════════════════════════════════════════════════════════
	local depthOffset = self:_computeCoplanarity(coverNormal, currentCoverInstance, bestNormal, newPart)

	if Constants.DEBUG_MODE then
		print(
			string.format(
				"[SwapRay] P5 Coplanaridad: desfase=%.2f studs (max=%.2f) → %s",
				depthOffset,
				Constants.COVER_SWAP_COPLANARITY_THRESHOLD,
				if depthOffset <= Constants.COVER_SWAP_COPLANARITY_THRESHOLD then "OK" else "RECHAZADO"
			)
		)
	end

	if depthOffset > Constants.COVER_SWAP_COPLANARITY_THRESHOLD then
		return nil, nil, nil
	end

	-- ═══════════════════════════════════════════════════════════
	-- PASO 6: Validación de obstrucción tangente
	-- ═══════════════════════════════════════════════════════════
	local tangentDir = wallRight * moveDir
	local swapDistance = (hitResult.Position - origin).Magnitude

	self._rayParams.FilterDescendantsInstances = { character, currentCoverInstance, newPart }
	local obstructionResult = workspace:Raycast(origin, tangentDir * (swapDistance + 8), self._rayParams)

	if Constants.DEBUG_MODE then
		self:_debugStep6(origin, tangentDir, swapDistance, obstructionResult)
	end

	if obstructionResult then
		return nil, nil, nil
	end

	-- ═══════════════════════════════════════════════════════════
	-- VÁLIDO — Todos los pasos pasaron
	-- ═══════════════════════════════════════════════════════════
	if Constants.DEBUG_MODE then
		print(
			string.format(
				"[SwapRay] SWAP VÁLIDO → %s | normal=(%.2f,%.2f,%.2f) | alineación=%.3f | desfase=%.2f",
				newPart.Name,
				bestNormal.X,
				bestNormal.Y,
				bestNormal.Z,
				bestDot,
				depthOffset
			)
		)
	end

	return newPart, bestNormal, hitResult.Position
end

------------------------------------------------------------------------
-- INTERNAL: Geometric Calculations
------------------------------------------------------------------------

--- Extrae 4 normales laterales del Part y encuentra la mejor alineada
--- con el riel actual (wallRight) usando tangentes geométricas.
--- @return Vector3? bestNormal — la normal ganadora
--- @return number bestDot — dot product de la mejor tangente
function SwapDetector:_findBestAlignedFace(newPart: BasePart, wallRight: Vector3): (Vector3?, number)
	local cf = newPart.CFrame
	local faceNormals = {
		cf.LookVector,
		-cf.LookVector,
		cf.RightVector,
		-cf.RightVector,
	}

	local bestDot = -math.huge
	local bestNormal: Vector3? = nil

	for _, faceN in faceNormals do
		local tangent = Vector3.yAxis:Cross(faceN)
		if tangent.Magnitude >= Constants.ZERO_MAGNITUDE then
			tangent = tangent.Unit
			local dot = tangent:Dot(wallRight)
			if Constants.DEBUG_MODE then
				print(
					string.format(
						"[SwapRay] P4 cara normal=(%.2f,%.2f,%.2f) tangente dot=%.3f",
						faceN.X,
						faceN.Y,
						faceN.Z,
						dot
					)
				)
			end
			if dot > bestDot then
				bestDot = dot
				bestNormal = faceN
			end
		end
	end

	return bestNormal, bestDot
end

--- Calcula el desfase de coplanaridad entre las caras frontales de dos covers.
--- Compara CARAS FRONTALES (no centros) para soportar diferente grosor.
--- @return number depthOffset — desfase absoluto en studs
function SwapDetector:_computeCoplanarity(
	coverNormal: Vector3,
	currentCover: BasePart,
	newNormal: Vector3,
	newPart: BasePart
): number
	-- Cara frontal de la cover actual
	local curHalfSize = currentCover.Size * 0.5
	local curLocalN = currentCover.CFrame:VectorToObjectSpace(coverNormal)
	local curHalfDepth = math.abs(curLocalN.X) * curHalfSize.X
		+ math.abs(curLocalN.Y) * curHalfSize.Y
		+ math.abs(curLocalN.Z) * curHalfSize.Z
	local currentFacePoint = currentCover.CFrame.Position + coverNormal * curHalfDepth

	-- Cara frontal de la cover nueva
	local newHalfSize = newPart.Size * 0.5
	local newLocalN = newPart.CFrame:VectorToObjectSpace(newNormal)
	local newHalfDepth = math.abs(newLocalN.X) * newHalfSize.X
		+ math.abs(newLocalN.Y) * newHalfSize.Y
		+ math.abs(newLocalN.Z) * newHalfSize.Z
	local newFacePoint = newPart.CFrame.Position + newNormal * newHalfDepth

	return math.abs(coverNormal:Dot(newFacePoint - currentFacePoint))
end

------------------------------------------------------------------------
-- INTERNAL: Debug Visualization
------------------------------------------------------------------------

function SwapDetector:_debugStep1(origin: Vector3, rayDirection: Vector3, flatInput: Vector3, hitResult: RaycastResult?)
	local rayLen = rayDirection.Magnitude
	local endPt = origin + rayDirection
	local midPt = (origin + endPt) / 2
	local debugRay = Instance.new("Part")
	debugRay.Name = "DEBUG_SwapRay"
	debugRay.Anchored = true
	debugRay.CanCollide = false
	debugRay.CanQuery = false
	debugRay.CastShadow = false
	debugRay.Size = Vector3.new(0.06, 0.06, rayLen)
	debugRay.CFrame = CFrame.new(midPt, endPt)
	debugRay.Color = Color3.fromRGB(200, 110, 30)
	debugRay.Material = Enum.Material.Neon
	debugRay.Parent = workspace
	Debris:AddItem(debugRay, 1.5)

	print(
		string.format(
			"[SwapRay] P1 origen=(%.1f,%.1f,%.1f) inputDir=(%.2f,%.2f,%.2f) dist=%.1f",
			origin.X,
			origin.Y,
			origin.Z,
			flatInput.X,
			flatInput.Y,
			flatInput.Z,
			Constants.COVER_SWAP_MAX_DISTANCE
		)
	)

	if hitResult then
		print(
			string.format(
				"[SwapRay] P1 HIT %s en (%.1f,%.1f,%.1f) — normal de impacto DESECHADA",
				hitResult.Instance.Name,
				hitResult.Position.X,
				hitResult.Position.Y,
				hitResult.Position.Z
			)
		)
		local hitSphere = Instance.new("Part")
		hitSphere.Name = "DEBUG_SwapHit"
		hitSphere.Shape = Enum.PartType.Ball
		hitSphere.Anchored = true
		hitSphere.CanCollide = false
		hitSphere.CanQuery = false
		hitSphere.CastShadow = false
		hitSphere.Size = Vector3.one * 0.45
		hitSphere.Position = hitResult.Position
		hitSphere.Color = Color3.fromRGB(220, 30, 30)
		hitSphere.Material = Enum.Material.Neon
		hitSphere.Parent = workspace
		Debris:AddItem(hitSphere, 1.5)
	else
		print("[SwapRay] P1 MISS — sin geometría de cover en dirección de input")
	end
end

function SwapDetector:_debugStep6(
	origin: Vector3,
	tangentDir: Vector3,
	swapDistance: number,
	obstructionResult: RaycastResult?
)
	local endPt = origin + tangentDir * swapDistance
	local midPt = (origin + endPt) / 2
	local debugObs = Instance.new("Part")
	debugObs.Name = "DEBUG_SwapObstruction"
	debugObs.Anchored = true
	debugObs.CanCollide = false
	debugObs.CanQuery = false
	debugObs.CastShadow = false
	debugObs.Size = Vector3.new(0.06, 0.06, swapDistance)
	debugObs.CFrame = CFrame.new(midPt, endPt)
	debugObs.Color = if obstructionResult then Color3.fromRGB(255, 0, 0) else Color3.fromRGB(0, 255, 0)
	debugObs.Material = Enum.Material.Neon
	debugObs.Parent = workspace
	Debris:AddItem(debugObs, 1.5)

	if obstructionResult then
		print(
			string.format(
				"[SwapRay] P6 OBSTRUCCIÓN: %s en (%.1f,%.1f,%.1f) — swap cancelado",
				obstructionResult.Instance.Name,
				obstructionResult.Position.X,
				obstructionResult.Position.Y,
				obstructionResult.Position.Z
			)
		)
	else
		print("[SwapRay] P6 Camino libre — sin obstrucción")
	end
end

return SwapDetector
