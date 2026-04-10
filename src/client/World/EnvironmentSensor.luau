--[[
	EnvironmentSensor.luau
	═══════════════════════════════════════════════════════════════
	Detección de entorno mediante Raycast — State-Driven
	═══════════════════════════════════════════════════════════════
	
	Escaneo condicional según el estado del jugador:
	  - wantsCoverSearch → _searchCover() (ray + sphere fallback)
	  - RoadieRun        → _scanRoadieRunCover() (forward, rango corto, auto-entry)
	  - CoverIdle        → _detectCorners() (2 rays laterales)
	  - Otros estados    → 0 raycasts (solo passthrough de MoveDirection)
	
	Los objetos de cover deben tener el tag "CoverObject" de CollectionService
	o el atributo IsCover = true para ser detectados.
	
	NOTA: Este módulo corre en el CLIENTE como predicción visual.
	Las acciones finales se validan en el servidor.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local EnvironmentSensor = {}
EnvironmentSensor.__index = EnvironmentSensor

function EnvironmentSensor.new()
	local self = setmetatable({}, EnvironmentSensor)

	self._player = Players.LocalPlayer
	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Include
	self._rayParams.FilterDescendantsInstances = {}

	-- Cache de filtro de cover objects (se reconstruye solo cuando cambian tags/atributos)
	self._filterDirty = true
	self._filterFrameCounter = 0
	self._filterRefreshInterval = Constants.ENV_FILTER_REFRESH_FRAMES

	self._tagAddedConn = CollectionService:GetInstanceAddedSignal("CoverObject"):Connect(function()
		self._filterDirty = true
	end)
	self._tagRemovedConn = CollectionService:GetInstanceRemovedSignal("CoverObject"):Connect(function()
		self._filterDirty = true
	end)

	-- RaycastParams reutilizable para CheckSwapCover (evita alloc por llamada)
	self._swapRayParams = RaycastParams.new()
	self._swapRayParams.FilterType = Enum.RaycastFilterType.Exclude
	self._swapRayParams.FilterDescendantsInstances = {}

	-- Contexto actual (actualizado cada frame según estado)
	self._context = {
		HasCoverNearby = false,
		CoverType = nil,
		CoverNormal = nil,
		CoverPosition = nil,
		CoverInstance = nil,
		IsAtCornerLeft = false,
		IsAtCornerRight = false,
		MoveDirection = Vector2.zero,
	}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function EnvironmentSensor:Destroy()
	if self._tagAddedConn then
		self._tagAddedConn:Disconnect()
		self._tagAddedConn = nil
	end
	if self._tagRemovedConn then
		self._tagRemovedConn:Disconnect()
		self._tagRemovedConn = nil
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Retorna el EnvironmentContext actual (read-only snapshot).
function EnvironmentSensor:GetContext()
	return self._context
end

--- Actualizar el sensor según el estado actual del jugador.
--- Solo lanza raycasts cuando el estado lo requiere.
--- @param state string — estado actual de la StateMachine
--- @param coverNormal Vector3? — normal de la cover actual (solo en CoverIdle)
--- @param wantsCoverSearch boolean — true si el buffer tiene WantsCover y el estado lo permite
--- @param moveDirection Vector2 — dirección de input del jugador
function EnvironmentSensor:Update(
	state: string,
	coverNormal: Vector3?,
	wantsCoverSearch: boolean,
	moveDirection: Vector2
)
	-- Resetear contexto
	self:_resetContext(moveDirection)

	-- Obtener character y HumanoidRootPart
	local character = self._player.Character
	if not character then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Actualizar filtro de raycast solo cuando tags cambiaron o refresco periódico
	self._filterFrameCounter += 1
	if self._filterDirty or self._filterFrameCounter >= self._filterRefreshInterval then
		self:_updateRayFilter(character)
		self._filterDirty = false
		self._filterFrameCounter = 0
	end

	-- Rama por estado: solo lanzar raycasts cuando es necesario
	local inCoverState = (state == "CoverIdle" or state == "CoverWalking" or state == "CoverRunning")

	if wantsCoverSearch then
		-- Petición de entrada a cover (botón presionado + estado lo permite)
		self:_searchCover(hrp)
	elseif state == "RoadieRun" then
		-- Auto-detección frontal de cover mientras corre (rango corto)
		self:_scanRoadieRunCover(hrp)
	end

	-- Detectar esquinas siempre que estés en cover (independiente de wantsCoverSearch)
	-- Esto garantiza que IsAtCornerLeft/Right estén actualizados en el mismo frame
	-- que WantsCover entra al buffer → Cover Swap puede evaluar correctamente.
	if inCoverState and coverNormal then
		self:_detectCorners(hrp, coverNormal)
	end
	-- Otros estados: 0 raycasts, contexto vacío
end

------------------------------------------------------------------------
-- INTERNAL: Scan Methods
------------------------------------------------------------------------

--- Búsqueda on-demand de cover cercana (petición del jugador).
--- Dirección: moveDirection si hay input, sino lookVector del rootpart.
--- Método: ray primero, spherecast como fallback.
function EnvironmentSensor:_searchCover(hrp: BasePart)
	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET

	-- Dirección de búsqueda: input del jugador o look vector
	local humanoid = hrp.Parent and hrp.Parent:FindFirstChild("Humanoid") :: Humanoid?
	local searchDir: Vector3
	if humanoid and humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD then
		searchDir = humanoid.MoveDirection
	else
		searchDir = hrp.CFrame.LookVector
	end

	-- Aplanar al plano horizontal
	local flatDir = Vector3.new(searchDir.X, 0, searchDir.Z)
	if flatDir.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	flatDir = flatDir.Unit

	-- Intento 1: Raycast preciso
	local rayResult = self:_castRay(origin, flatDir, Constants.COVER_SCAN_RANGE)
	if rayResult and self:_isCoverObject(rayResult.Instance) then
		if self:_populateCoverContext(rayResult) then
			return
		end
	end

	-- Intento 2: Spherecast (más tolerante en bordes y ángulos rasantes)
	local sphereResult = self:_castSphere(origin, flatDir, Constants.COVER_SCAN_RANGE)
	if sphereResult and self:_isCoverObject(sphereResult.Instance) then
		self:_populateCoverContext(sphereResult)
	end
end

--- Escaneo per-frame durante RoadieRun. Dirección: lookVector (aplanado).
--- Rango corto (COVER_AUTO_DETECT_DIST) porque auto-entra sin botón.
function EnvironmentSensor:_scanRoadieRunCover(hrp: BasePart)
	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET
	local lookDir = hrp.CFrame.LookVector

	-- Aplanar al plano horizontal (consistente con _searchCover)
	local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
	if flatLook.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	flatLook = flatLook.Unit

	-- Intento 1: Raycast preciso a rango corto
	local rayResult = self:_castRay(origin, flatLook, Constants.COVER_AUTO_DETECT_DIST)
	if rayResult and self:_isCoverObject(rayResult.Instance) then
		if self:_populateCoverContext(rayResult) then
			return
		end
	end

	-- Intento 2: Spherecast a rango corto
	local sphereResult = self:_castSphere(origin, flatLook, Constants.COVER_AUTO_DETECT_DIST)
	if sphereResult and self:_isCoverObject(sphereResult.Instance) then
		self:_populateCoverContext(sphereResult)
	end
end

function EnvironmentSensor:_detectCorners(hrp: BasePart, coverNormal: Vector3)
	-- Origen base (posición del jugador + offset vertical al torso)
	local playerOrigin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET
	local ctx = self._context

	-- Vector paralelo a la pared: Up × N = apunta a la DERECHA del jugador
	-- (coverNormal:Cross(yAxis) apuntaba a la IZQUIERDA — bug de inversión)
	local wallParallel = Vector3.yAxis:Cross(coverNormal)
	if wallParallel.Magnitude < Constants.ZERO_MAGNITUDE then
		wallParallel = Vector3.xAxis
	else
		wallParallel = wallParallel.Unit
	end

	-- Distancia lateral a la que queremos revisar si hay esquina
	local cornerRange = Constants.COVER_CORNER_DETECTION_RANGE

	-- La distancia del rayo hacia la pared. Le sumamos 1 stud extra para
	-- asegurar que golpee la pared sin importar pequeñas irregularidades.
	local rayDistanceToWall = Constants.COVER_OFFSET + 1

	-- ==========================================
	-- SENSOR IZQUIERDO
	-- ==========================================
	-- Movemos el origen hacia la izquierda del jugador
	local leftOrigin = playerOrigin + (-wallParallel * cornerRange)

	-- Lanzamos el rayo HACIA LA PARED (-coverNormal)
	local leftResult = self:_castRay(leftOrigin, -coverNormal, rayDistanceToWall)

	-- Si NO golpea nada, o si lo que golpea no es cobertura -> ES UNA ESQUINA
	ctx.IsAtCornerLeft = not leftResult or not self:_isCoverObject(leftResult.Instance)

	-- ==========================================
	-- SENSOR DERECHO
	-- ==========================================
	-- Movemos el origen hacia la derecha del jugador
	local rightOrigin = playerOrigin + (wallParallel * cornerRange)

	-- Lanzamos el rayo HACIA LA PARED (-coverNormal)
	local rightResult = self:_castRay(rightOrigin, -coverNormal, rayDistanceToWall)

	ctx.IsAtCornerRight = not rightResult or not self:_isCoverObject(rightResult.Instance)
end

--- Chequea si hay una esquina interna (pared perpendicular) en la dirección de movimiento.
--- Llamado por InCover durante CoverWalking — solo dispara si hay movimiento significativo.
---
--- @param hrp BasePart — HumanoidRootPart
--- @param currentNormal Vector3 — normal actual de la cover
--- @param wallParallel Vector3 — vector paralelo a la pared (Unit)
--- @param movementScale number — dot product del movimiento sobre wallParallel
--- @return Vector3? newNormal — normal snapeada de la nueva pared (nil si no hay transición)
--- @return Vector3? newPosition — posición snapeada en la nueva pared
--- @return BasePart? newInstance — la nueva instancia de cover
function EnvironmentSensor:CheckInnerCorner(
	hrp: BasePart,
	currentNormal: Vector3,
	wallParallel: Vector3,
	movementScale: number
): (Vector3?, Vector3?, BasePart?)
	if math.abs(movementScale) < Constants.LATERAL_TRIGGER_THRESHOLD then
		return nil, nil, nil
	end

	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET
	local rayDirection = wallParallel * math.sign(movementScale)
	local checkDistance = Constants.COVER_TRANSITION_TRIGGER_DIST

	local rayResult = self:_castRay(origin, rayDirection, checkDistance)
	if not rayResult or not self:_isCoverObject(rayResult.Instance) then
		return nil, nil, nil
	end

	-- Verificar que sea un ángulo significativo (dot < 0.5 ≈ >60°)
	local newNormal, newPosition = self:_snapNormalToFace(rayResult.Instance, rayResult.Position, rayResult.Normal)
	if not newNormal then
		return nil, nil, nil
	end

	-- Si las normales son muy similares (misma pared), no es transición
	if math.abs(currentNormal:Dot(newNormal)) > Constants.COVER_TRANSITION_DOT_THRESHOLD then
		return nil, nil, nil
	end

	return newNormal, newPosition, rayResult.Instance
end

--- Chequea si hay una cobertura adyacente alineada al otro lado del hueco (Cover Swap).
--- Algoritmo de 5 pasos:
---   1. Rayo de detección en dirección de input → interruptor de existencia (normal de impacto DESECHADA)
---   2. Extracción geométrica de 4 normales laterales desde CFrame del Part golpeado
---   3. Construcción de tangentes (rieles) por cara: T = Up × N
---   4. Prueba de alineación: dot product tangente actual vs 4 tangentes → mejor match ≥ 0.9
---   5. Coplanaridad: |(P_nueva - P_actual) · N_actual| < umbral
---
--- @param hrp BasePart — HumanoidRootPart
--- @param coverNormal Vector3 — normal de la cover actual
--- @param wallRight Vector3 — tangente de la cover actual (riel de referencia)
--- @param moveDir number — +1 (derecha) o -1 (izquierda)
--- @param currentCoverInstance BasePart — la cover en la que está el jugador
--- @param inputDirection Vector3 — humanoid.MoveDirection del jugador (dirección del rayo)
--- @return BasePart? newCoverPart — la nueva cobertura detectada (nil si no hay)
--- @return Vector3? newCoverNormal — normal geométrica ganadora de la nueva cover
--- @return Vector3? hitPosition — punto de impacto del rayo
function EnvironmentSensor:CheckSwapCover(
	hrp: BasePart,
	coverNormal: Vector3,
	wallRight: Vector3,
	moveDir: number,
	currentCoverInstance: BasePart,
	inputDirection: Vector3
): (BasePart?, Vector3?, Vector3?)
	-- ═══════════════════════════════════════════════════════════
	-- PASO 1: Disparo de detección (normal de impacto DESECHADA)
	-- Solo sirve como interruptor de existencia: ¿hay una Part
	-- catalogada como "CoverObject" en la dirección de input?
	-- ═══════════════════════════════════════════════════════════
	local character = self._player.Character
	if not character then
		return nil, nil, nil
	end

	local swapParams = self._swapRayParams
	swapParams.FilterDescendantsInstances = { character, currentCoverInstance }

	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET

	-- Usar la dirección de input real (camera-relative, ya convertida a world
	-- por Helpers.scanCoverSwap). Esto permite que diagonales (W+D) apunten
	-- el rayo en la dirección combinada, no en un eje fijo del riel.
	-- Aplanar al plano horizontal por seguridad.
	local flatInput = Vector3.new(inputDirection.X, 0, inputDirection.Z)
	if flatInput.Magnitude < Constants.ZERO_MAGNITUDE then
		flatInput = wallRight * moveDir -- fallback al riel si input es nulo
	else
		flatInput = flatInput.Unit
	end
	local rayDirection = flatInput * Constants.COVER_SWAP_MAX_DISTANCE

	local hitResult = workspace:Raycast(origin, rayDirection, swapParams)

	if Constants.DEBUG_MODE then
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

	if not hitResult or not self:_isCoverObject(hitResult.Instance) then
		if Constants.DEBUG_MODE and hitResult then
			print(string.format("[SwapRay] P1 RECHAZADO — %s no es CoverObject", hitResult.Instance.Name))
		end
		return nil, nil, nil
	end

	local newPart = hitResult.Instance :: BasePart

	-- ═══════════════════════════════════════════════════════════
	-- PASO 2: Extracción geométrica de normales laterales
	-- Usamos el CFrame del Part para obtener 4 normales perfectas.
	-- No dependemos de la normal espuria del raycast.
	-- ═══════════════════════════════════════════════════════════
	local cf = newPart.CFrame
	local faceNormals = {
		cf.LookVector, -- Adelante
		-cf.LookVector, -- Atrás
		cf.RightVector, -- Derecha
		-cf.RightVector, -- Izquierda
	}

	-- ═══════════════════════════════════════════════════════════
	-- PASO 3 + 4: Tangentes y prueba de alineación
	-- Para cada cara: T = Up × N, luego dot(T, wallRight_actual).
	-- La cara con mayor alineación (≥ threshold) gana.
	-- ═══════════════════════════════════════════════════════════
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
	-- PASO 5: Validación de coplanaridad (filtro de profundidad)
	-- Comparamos las CARAS FRONTALES, no los centros. Dos partes de
	-- distinto grosor pueden ser coplanares por delante pero tener
	-- centros a diferente profundidad.
	--   facePoint = center + normal * halfExtent_a_lo_largo_de_normal
	--   Desfase  = |N_actual · (faceNueva - faceActual)|
	-- ═══════════════════════════════════════════════════════════

	-- Cara frontal de la cover actual (la que da al jugador = dirección coverNormal)
	local curHalfSize = currentCoverInstance.Size * 0.5
	local curLocalN = currentCoverInstance.CFrame:VectorToObjectSpace(coverNormal)
	local curHalfDepth = math.abs(curLocalN.X) * curHalfSize.X
		+ math.abs(curLocalN.Y) * curHalfSize.Y
		+ math.abs(curLocalN.Z) * curHalfSize.Z
	local currentFacePoint = currentCoverInstance.CFrame.Position + coverNormal * curHalfDepth

	-- Cara frontal de la cover nueva (dirección bestNormal)
	local newHalfSize = newPart.Size * 0.5
	local newLocalN = newPart.CFrame:VectorToObjectSpace(bestNormal)
	local newHalfDepth = math.abs(newLocalN.X) * newHalfSize.X
		+ math.abs(newLocalN.Y) * newHalfSize.Y
		+ math.abs(newLocalN.Z) * newHalfSize.Z
	local newFacePoint = newPart.CFrame.Position + bestNormal * newHalfDepth

	local depthOffset = math.abs(coverNormal:Dot(newFacePoint - currentFacePoint))

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
	-- Lanzar un rayo desde el jugador en la dirección tangente
	-- (wallRight × moveDir) hasta la distancia al punto de impacto.
	-- Si hay algo en el camino que NO sea la cover destino ni la
	-- cover actual, el swap se cancela — el jugador permanece.
	-- ═══════════════════════════════════════════════════════════
	local tangentDir = wallRight * moveDir
	local swapDistance = (hitResult.Position - origin).Magnitude

	-- Reutilizar swapParams pero excluir character + ambas covers
	swapParams.FilterDescendantsInstances = { character, currentCoverInstance, newPart }
	local obstructionResult = workspace:Raycast(origin, tangentDir * (swapDistance + 8), swapParams)

	if Constants.DEBUG_MODE then
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

	if obstructionResult then
		return nil, nil, nil
	end

	-- ═══════════════════════════════════════════════════════════
	-- VÁLIDO — Normal ganadora del Paso 4 + coplanaridad del Paso 5
	--          + camino libre del Paso 6
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
-- INTERNAL: Helpers
------------------------------------------------------------------------

--- Valida un RaycastResult y popula el contexto con datos de cover.
--- @return boolean — true si se pobló exitosamente
function EnvironmentSensor:_populateCoverContext(result: RaycastResult): boolean
	local coverPart = result.Instance
	local snNormal, snPosition = self:_snapNormalToFace(coverPart, result.Position, result.Normal)
	if not snNormal then
		return false
	end

	local ctx = self._context
	ctx.HasCoverNearby = true
	ctx.CoverNormal = snNormal
	ctx.CoverPosition = snPosition
	ctx.CoverInstance = coverPart
	ctx.CoverType = self:_classifyCover(coverPart)
	return true
end

--- Resetea todos los campos del contexto al inicio de cada frame.
function EnvironmentSensor:_resetContext(moveDirection: Vector2)
	local ctx = self._context
	ctx.HasCoverNearby = false
	ctx.CoverType = nil
	ctx.CoverNormal = nil
	ctx.CoverPosition = nil
	ctx.CoverInstance = nil
	ctx.IsAtCornerLeft = false
	ctx.IsAtCornerRight = false
	ctx.MoveDirection = moveDirection
end

------------------------------------------------------------------------
-- INTERNAL: Raycast Infrastructure
------------------------------------------------------------------------

--- Convierte la normal cruda del raycast a una normal pura snappada al eje
--- dominante de la cara del Part en espacio local. Elimina componentes espurios
--- de la normal y garantiza que el jugador mire exactamente perpendicular a la pared.
---
--- Algoritmo (4 fases):
---   1. Convertir hitPos y rawNormal al espacio local del coverPart
---   2. Detectar eje dominante: |localNormal.X| vs |localNormal.Z|
---      Tie-breaker (AAA): si la diferencia es mínima (~45°), elegir
---      el eje cuya cara del Part es más larga (más espacio de slide)
---   3. Producir normal local pura: (±1, 0, 0) o (0, 0, ±1)
---   4. Corner push-in: clamp hitPos local a los bounds de la cara,
---      empujar hacia el centro si estaba justo en el borde
---   5. Convertir de vuelta al espacio del mundo
---
--- @param coverPart BasePart
--- @param hitPos Vector3 — punto de impacto del raycast (world space)
--- @param rawNormal Vector3 — normal cruda del raycast (world space)
--- @return Vector3? snappedNormal — normal pura en world space (nil si inválida)
--- @return Vector3? snappedPosition — posición ajustada en world space
function EnvironmentSensor:_snapNormalToFace(
	coverPart: BasePart,
	hitPos: Vector3,
	rawNormal: Vector3
): (Vector3?, Vector3?)
	local cf = coverPart.CFrame
	local halfSize = coverPart.Size * 0.5

	-- FASE 1: Convertir al espacio local del Part
	local localHit = cf:PointToObjectSpace(hitPos)
	local localNormal = cf:VectorToObjectSpace(rawNormal)

	-- Solo nos interesan caras laterales (X/Z). Si la normal es casi vertical → no es cover
	local absX = math.abs(localNormal.X)
	local absZ = math.abs(localNormal.Z)
	if absX < Constants.ENV_CORNER_EPSILON and absZ < Constants.ENV_CORNER_EPSILON then
		return nil, nil
	end

	-- FASE 2: Detectar eje dominante con tie-breaker
	local TIE_THRESHOLD = Constants.ENV_CORNER_NORMAL_TIE_THRESHOLD
	local snappedLocalNormal: Vector3
	local slideAxis: string -- "X" o "Z": eje a lo largo del cual el jugador se desliza

	if math.abs(absZ - absX) < TIE_THRESHOLD then
		-- Tie-breaker (Regla AAA): elegir la cara con más espacio para slide
		if halfSize.X >= halfSize.Z then
			snappedLocalNormal = Vector3.new(0, 0, math.sign(localNormal.Z))
			slideAxis = "X"
		else
			snappedLocalNormal = Vector3.new(math.sign(localNormal.X), 0, 0)
			slideAxis = "Z"
		end
	elseif absZ > absX then
		snappedLocalNormal = Vector3.new(0, 0, math.sign(localNormal.Z))
		slideAxis = "X"
	else
		snappedLocalNormal = Vector3.new(math.sign(localNormal.X), 0, 0)
		slideAxis = "Z"
	end

	-- FASE 3: Corner push-in (anti-esquinas)
	-- Proteger contra Parts pequeños donde margin/pushIn > halfSize → min > max
	local margin = Constants.COVER_CORNER_MARGIN
	local pushIn = Constants.COVER_CORNER_PUSH_IN

	local mxMin = -halfSize.X + margin
	local mxMax = halfSize.X - margin
	if mxMin > mxMax then
		local mid = 0
		mxMin, mxMax = mid, mid
	end
	local mzMin = -halfSize.Z + margin
	local mzMax = halfSize.Z - margin
	if mzMin > mzMax then
		local mid = 0
		mzMin, mzMax = mid, mid
	end

	local clampedHit =
		Vector3.new(math.clamp(localHit.X, mxMin, mxMax), localHit.Y, math.clamp(localHit.Z, mzMin, mzMax))

	-- Si el hit estaba justo en el borde → empujar hacia el centro del Part
	if slideAxis == "X" then
		if math.abs(localHit.X) > (halfSize.X - margin - Constants.ENV_CORNER_EPSILON) then
			local pxMin = -halfSize.X + pushIn
			local pxMax = halfSize.X - pushIn
			if pxMin > pxMax then
				pxMin, pxMax = 0, 0
			end
			clampedHit = Vector3.new(math.clamp(clampedHit.X, pxMin, pxMax), clampedHit.Y, clampedHit.Z)
		end
	else
		if math.abs(localHit.Z) > (halfSize.Z - margin - Constants.ENV_CORNER_EPSILON) then
			local pzMin = -halfSize.Z + pushIn
			local pzMax = halfSize.Z - pushIn
			if pzMin > pzMax then
				pzMin, pzMax = 0, 0
			end
			clampedHit = Vector3.new(clampedHit.X, clampedHit.Y, math.clamp(clampedHit.Z, pzMin, pzMax))
		end
	end

	-- FASE 4: Convertir de vuelta al espacio del mundo
	local worldNormal = cf:VectorToWorldSpace(snappedLocalNormal)
	-- Asegurar horizontal puro (por si el Part está levemente inclinado)
	worldNormal = Vector3.new(worldNormal.X, 0, worldNormal.Z)
	if worldNormal.Magnitude < Constants.ZERO_MAGNITUDE then
		return nil, nil
	end
	worldNormal = worldNormal.Unit

	local worldHit = cf:PointToWorldSpace(clampedHit)

	return worldNormal, worldHit
end

function EnvironmentSensor:_updateRayFilter(character: Model)
	-- Incluir solo objetos taggeados como cover + geometría del mundo
	local coverObjects = CollectionService:GetTagged("CoverObject")

	-- Set para dedup O(1) en lugar de table.find O(n)
	local filterSet = {}
	local filterList = {}

	for _, obj in coverObjects do
		if obj:IsA("BasePart") and not filterSet[obj] then
			filterSet[obj] = true
			table.insert(filterList, obj)
		end
	end

	-- Buscar partes con atributo IsCover en workspace
	-- (fallback si no se usa CollectionService tags)
	for _, child in workspace:GetChildren() do
		if child:IsA("BasePart") and child:GetAttribute("IsCover") == true then
			if not filterSet[child] then
				filterSet[child] = true
				table.insert(filterList, child)
			end
		end
		-- Buscar dentro de modelos
		if child:IsA("Model") then
			for _, part in child:GetDescendants() do
				if part:IsA("BasePart") and part:GetAttribute("IsCover") == true then
					if not filterSet[part] then
						filterSet[part] = true
						table.insert(filterList, part)
					end
				end
			end
		end
	end

	-- Si no hay cover objects registrados, usar Exclude mode con el character
	-- para que cualquier pared pueda funcionar como cover (desarrollo temprano)
	if #filterList == 0 then
		self._rayParams.FilterType = Enum.RaycastFilterType.Exclude
		self._rayParams.FilterDescendantsInstances = { character }
	else
		self._rayParams.FilterType = Enum.RaycastFilterType.Include
		self._rayParams.FilterDescendantsInstances = filterList
	end
end

function EnvironmentSensor:_castRay(origin: Vector3, direction: Vector3, distance: number): RaycastResult?
	return workspace:Raycast(origin, direction * distance, self._rayParams)
end

--- Spherecast horizontal para detección de cover más robusta.
--- Ignora el componente Y de la dirección para mantener el cast horizontal.
function EnvironmentSensor:_castSphere(origin: Vector3, direction: Vector3, distance: number): RaycastResult?
	local dir2D = Vector3.new(direction.X, 0, direction.Z)
	if dir2D.Magnitude < Constants.ZERO_MAGNITUDE then
		return nil
	end
	dir2D = dir2D.Unit * distance
	return workspace:Spherecast(origin, Constants.COVER_SPHERECAST_RADIUS, dir2D, self._rayParams)
end

function EnvironmentSensor:_isCoverObject(part: BasePart): boolean
	if not part then
		return false
	end

	-- Check tag
	if CollectionService:HasTag(part, "CoverObject") then
		return true
	end

	-- Check attribute
	if part:GetAttribute("IsCover") == true then
		return true
	end

	-- Fallback durante desarrollo: cualquier pared anchored que sea suficientemente grande
	if
		part.Anchored
		and part.Size.Y >= Constants.COVER_FALLBACK_MIN_SIZE
		and part.Size.X >= Constants.COVER_FALLBACK_MIN_SIZE
	then
		return true
	end

	return false
end

function EnvironmentSensor:_classifyCover(part: BasePart): string
	if part.Size.Y <= Constants.COVER_HEIGHT_LOW_MAX then
		return "Low"
	else
		return "High"
	end
end

------------------------------------------------------------------------
-- VAULT SAFETY — validación para VaultHandler
------------------------------------------------------------------------

--- Verifica que la instancia de cover siga existiendo y sea válida.
function EnvironmentSensor:ValidateCoverInstance(instance: BasePart?): boolean
	if not instance then
		return false
	end
	if not instance:IsDescendantOf(workspace) then
		return false
	end
	return true
end

--- Lanza raycasts de seguridad para verificar que el destino del vault es transitable.
--- Usa _swapRayParams (Exclude mode) para ignorar el character y la cover.
--- @param startPos Vector3 — posición actual del character
--- @param forwardDir Vector3 — dirección horizontal normalizada del vault (-coverNormal)
--- @param character Model — el character del jugador
--- @param coverInstance BasePart — la pieza de cover que se salta
--- @return boolean, Vector3? — (isSafe, landingPosition)
function EnvironmentSensor:CheckVaultSafety(
	startPos: Vector3,
	forwardDir: Vector3,
	character: Model,
	coverInstance: BasePart
): (boolean, Vector3?)
	-- Config Exclude para ignorar character + cover
	self._swapRayParams.FilterDescendantsInstances = { character, coverInstance }

	-- 1) Overhead clearance: rayo vertical encima del end-point
	local endHorizontal = startPos + forwardDir * Constants.VAULT_FORWARD_DIST
	local overheadOrigin = endHorizontal + Vector3.new(0, Constants.VAULT_OVERHEAD_RAY_HEIGHT, 0)
	local overheadResult =
		workspace:Raycast(overheadOrigin, Vector3.new(0, -Constants.VAULT_OVERHEAD_RAY_HEIGHT, 0), self._swapRayParams)
	-- Si el overhead ray golpea algo, hay un techo bajo → no seguro
	if overheadResult then
		return false, nil
	end

	-- 2) Landing zone: rayo hacia abajo desde el end-point elevado
	local landingOrigin = endHorizontal + Vector3.new(0, Constants.VAULT_LANDING_RAY_UP, 0)
	local landingResult = workspace:Raycast(
		landingOrigin,
		Vector3.new(0, -(Constants.VAULT_LANDING_RAY_UP + Constants.VAULT_LANDING_RAY_DOWN), 0),
		self._swapRayParams
	)
	if not landingResult then
		-- No hay suelo → no seguro
		return false, nil
	end

	local landingPos = landingResult.Position
	return true, landingPos
end

return EnvironmentSensor
