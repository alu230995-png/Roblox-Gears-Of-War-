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
	self._filterRefreshInterval = 45 -- frames entre re-escaneos periódicos

	self._tagAddedConn = CollectionService:GetInstanceAddedSignal("CoverObject"):Connect(function()
		self._filterDirty = true
	end)
	self._tagRemovedConn = CollectionService:GetInstanceRemovedSignal("CoverObject"):Connect(function()
		self._filterDirty = true
	end)

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

function EnvironmentSensor:Init()
	-- Configuración realizada en constructor
end

function EnvironmentSensor:Start()
	-- Sin conexiones propias — Update() es llamado por el heartbeat
end

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
	if wantsCoverSearch then
		-- Petición de entrada a cover (botón presionado + estado lo permite)
		self:_searchCover(hrp)
	elseif state == "RoadieRun" then
		-- Auto-detección frontal de cover mientras corre (rango corto)
		self:_scanRoadieRunCover(hrp)
	elseif (state == "CoverIdle" or state == "CoverWalking" or state == "CoverRunning") and coverNormal then
		-- Detectar esquinas para bloqueo lateral
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
	if humanoid and humanoid.MoveDirection.Magnitude > 0.1 then
		searchDir = humanoid.MoveDirection
	else
		searchDir = hrp.CFrame.LookVector
	end

	-- Aplanar al plano horizontal
	local flatDir = Vector3.new(searchDir.X, 0, searchDir.Z)
	if flatDir.Magnitude < 0.001 then
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

--- Escaneo per-frame durante RoadieRun. Dirección: lookVector.
--- Rango corto (COVER_AUTO_DETECT_DIST) porque auto-entra sin botón.
function EnvironmentSensor:_scanRoadieRunCover(hrp: BasePart)
	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET
	local lookDir = hrp.CFrame.LookVector

	-- Intento 1: Raycast preciso a rango corto
	local rayResult = self:_castRay(origin, lookDir, Constants.COVER_AUTO_DETECT_DIST)
	if rayResult and self:_isCoverObject(rayResult.Instance) then
		if self:_populateCoverContext(rayResult) then
			return
		end
	end

	-- Intento 2: Spherecast a rango corto
	local sphereResult = self:_castSphere(origin, lookDir, Constants.COVER_AUTO_DETECT_DIST)
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
	if wallParallel.Magnitude < 0.1 then
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
	if math.abs(movementScale) < 0.1 then
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
	local newNormal, newPosition =
		self:_snapNormalToFace(rayResult.Instance, rayResult.Position, rayResult.Normal)
	if not newNormal then
		return nil, nil, nil
	end

	-- Si las normales son muy similares (misma pared), no es transición
	if math.abs(currentNormal:Dot(newNormal)) > Constants.COVER_TRANSITION_DOT_THRESHOLD then
		return nil, nil, nil
	end

	return newNormal, newPosition, rayResult.Instance
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
	if absX < 0.01 and absZ < 0.01 then
		return nil, nil
	end

	-- FASE 2: Detectar eje dominante con tie-breaker
	local TIE_THRESHOLD = 0.15
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
	local margin = Constants.COVER_CORNER_MARGIN
	local pushIn = Constants.COVER_CORNER_PUSH_IN
	local clampedHit = Vector3.new(
		math.clamp(localHit.X, -halfSize.X + margin, halfSize.X - margin),
		localHit.Y,
		math.clamp(localHit.Z, -halfSize.Z + margin, halfSize.Z - margin)
	)

	-- Si el hit estaba justo en el borde → empujar hacia el centro del Part
	if slideAxis == "X" then
		if math.abs(localHit.X) > (halfSize.X - margin - 0.01) then
			clampedHit = Vector3.new(
				math.clamp(clampedHit.X, -halfSize.X + pushIn, halfSize.X - pushIn),
				clampedHit.Y,
				clampedHit.Z
			)
		end
	else
		if math.abs(localHit.Z) > (halfSize.Z - margin - 0.01) then
			clampedHit = Vector3.new(
				clampedHit.X,
				clampedHit.Y,
				math.clamp(clampedHit.Z, -halfSize.Z + pushIn, halfSize.Z - pushIn)
			)
		end
	end

	-- FASE 4: Convertir de vuelta al espacio del mundo
	local worldNormal = cf:VectorToWorldSpace(snappedLocalNormal)
	-- Asegurar horizontal puro (por si el Part está levemente inclinado)
	worldNormal = Vector3.new(worldNormal.X, 0, worldNormal.Z)
	if worldNormal.Magnitude < 0.001 then
		return nil, nil
	end
	worldNormal = worldNormal.Unit

	local worldHit = cf:PointToWorldSpace(clampedHit)

	return worldNormal, worldHit
end

function EnvironmentSensor:_updateRayFilter(character: Model)
	-- Incluir solo objetos taggeados como cover + geometría del mundo
	local coverObjects = CollectionService:GetTagged("CoverObject")

	-- También incluir partes con atributo IsCover
	local filterList = {}
	for _, obj in coverObjects do
		if obj:IsA("BasePart") then
			table.insert(filterList, obj)
		end
	end

	-- Buscar partes con atributo IsCover en workspace
	-- (fallback si no se usa CollectionService tags)
	for _, child in workspace:GetChildren() do
		if child:IsA("BasePart") and child:GetAttribute("IsCover") == true then
			if not table.find(filterList, child) then
				table.insert(filterList, child)
			end
		end
		-- Buscar dentro de modelos
		if child:IsA("Model") then
			for _, part in child:GetDescendants() do
				if part:IsA("BasePart") and part:GetAttribute("IsCover") == true then
					if not table.find(filterList, part) then
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
	if dir2D.Magnitude < 0.001 then
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
	if part.Anchored and part.Size.Y >= 2 and part.Size.X >= 2 then
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

return EnvironmentSensor
