--[[
	EnvironmentSensor.luau
	═══════════════════════════════════════════════════════════════
	Detección de entorno mediante Raycast.
	═══════════════════════════════════════════════════════════════
	
	Escanea el entorno cada frame para producir un EnvironmentContext:
	- ¿Hay cover cerca? ¿Tipo Low/High?
	- ¿Normal de la pared? ¿Posición?
	- ¿Cover adyacente a los lados? (swat turn)
	- ¿Cover bajo adelante? (mantle/vault)
	- ¿Estoy en una esquina? (peek)
	
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

	-- Contexto actual (actualizado cada frame)
	self._context = {
		HasCoverNearby = false,
		CoverType = nil,
		CoverNormal = nil,
		CoverPosition = nil,
		CoverInstance = nil,
		HasAdjacentCoverLeft = false,
		HasAdjacentCoverRight = false,
		HasLowCoverAhead = false,
		IsAtCornerLeft = false,
		IsAtCornerRight = false,
		MoveDirection = Vector2.zero,
		IsFacingCover = false,
		HasAlignedCoverLeft = false,
		HasAlignedCoverRight = false,
		AlignedCoverNormalLeft = nil,
		AlignedCoverPositionLeft = nil,
		AlignedCoverInstanceLeft = nil,
		AlignedCoverNormalRight = nil,
		AlignedCoverPositionRight = nil,
		AlignedCoverInstanceRight = nil,
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

--- Actualizar el sensor. Llamar cada frame desde el orquestador.
--- @param moveDirection Vector2 — dirección de input del jugador
function EnvironmentSensor:Update(moveDirection: Vector2)
	-- Resetear contexto
	local ctx = self._context
	ctx.HasCoverNearby = false
	ctx.CoverType = nil
	ctx.CoverNormal = nil
	ctx.CoverPosition = nil
	ctx.CoverInstance = nil
	ctx.HasAdjacentCoverLeft = false
	ctx.HasAdjacentCoverRight = false
	ctx.HasLowCoverAhead = false
	ctx.IsAtCornerLeft = false
	ctx.IsAtCornerRight = false
	ctx.MoveDirection = moveDirection
	ctx.IsFacingCover = false
	ctx.HasAlignedCoverLeft = false
	ctx.HasAlignedCoverRight = false
	ctx.AlignedCoverNormalLeft = nil
	ctx.AlignedCoverPositionLeft = nil
	ctx.AlignedCoverInstanceLeft = nil
	ctx.AlignedCoverNormalRight = nil
	ctx.AlignedCoverPositionRight = nil
	ctx.AlignedCoverInstanceRight = nil

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

	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET
	local lookDir = hrp.CFrame.LookVector
	local rightDir = hrp.CFrame.RightVector

	-- 1) Spherecast frontal: cover directamente adelante
	-- Spherecast detecta cover de forma más robusta que un Raycast puntual,
	-- especialmente en ángulos rasantes y bordes de geometría.
	local frontResult = self:_castSphere(origin, lookDir, Constants.COVER_SCAN_RANGE)
	if frontResult then
		local coverPart = frontResult.Instance
		if self:_isCoverObject(coverPart) then
			local snNormal, snPosition = self:_snapNormalToFace(coverPart, frontResult.Position, frontResult.Normal)
			if snNormal then
				ctx.HasCoverNearby = true
				ctx.CoverNormal = snNormal
				ctx.CoverPosition = snPosition
				ctx.CoverInstance = coverPart
				ctx.IsFacingCover = true

				-- Determinar tipo de cover (Low/High)
				local coverHeight = coverPart.Size.Y
				if coverHeight <= Constants.COVER_HEIGHT_LOW_MAX then
					ctx.CoverType = "Low"
					ctx.HasLowCoverAhead = true
				else
					ctx.CoverType = "High"
				end
			end
		end
	end

	-- 2) Si no encontramos cover frontal, probar diagonal izq/der
	if not ctx.HasCoverNearby then
		local angleRad = math.rad(Constants.COVER_MAGNETISM_ANGLE)
		local leftDir = (lookDir * math.cos(angleRad) - rightDir * math.sin(angleRad)).Unit
		local rightDirAngled = (lookDir * math.cos(angleRad) + rightDir * math.sin(angleRad)).Unit

		local leftResult = self:_castSphere(origin, leftDir, Constants.COVER_SCAN_RANGE)
		if leftResult and self:_isCoverObject(leftResult.Instance) then
			local snNormal, snPosition =
				self:_snapNormalToFace(leftResult.Instance, leftResult.Position, leftResult.Normal)
			if snNormal then
				ctx.HasCoverNearby = true
				ctx.CoverNormal = snNormal
				ctx.CoverPosition = snPosition
				ctx.CoverInstance = leftResult.Instance
				ctx.CoverType = self:_classifyCover(leftResult.Instance)
				ctx.IsFacingCover = true
			end
		end

		if not ctx.HasCoverNearby then
			local rightResult = self:_castSphere(origin, rightDirAngled, Constants.COVER_SCAN_RANGE)
			if rightResult and self:_isCoverObject(rightResult.Instance) then
				local snNormal, snPosition =
					self:_snapNormalToFace(rightResult.Instance, rightResult.Position, rightResult.Normal)
				if snNormal then
					ctx.HasCoverNearby = true
					ctx.CoverNormal = snNormal
					ctx.CoverPosition = snPosition
					ctx.CoverInstance = rightResult.Instance
					ctx.CoverType = self:_classifyCover(rightResult.Instance)
					ctx.IsFacingCover = true
				end
			end
		end
	end

	-- 3) Detectar cover adyacente (para swat turn) — solo si ya estamos en cover range
	if ctx.HasCoverNearby then
		local leftAdj = self:_castRay(origin, -rightDir, Constants.COVER_ADJACENT_SCAN_RANGE)
		if leftAdj and self:_isCoverObject(leftAdj.Instance) and leftAdj.Instance ~= ctx.CoverInstance then
			ctx.HasAdjacentCoverLeft = true
		end

		local rightAdj = self:_castRay(origin, rightDir, Constants.COVER_ADJACENT_SCAN_RANGE)
		if rightAdj and self:_isCoverObject(rightAdj.Instance) and rightAdj.Instance ~= ctx.CoverInstance then
			ctx.HasAdjacentCoverRight = true
		end
	end

	-- 4) Detectar cover alineada (CoverSwap / wall bounce)
	-- Raycast lateral ampliado para encontrar covers cuya normal sea ~paralela a la actual.
	if ctx.HasCoverNearby and ctx.CoverNormal then
		local wallParallel = ctx.CoverNormal:Cross(Vector3.yAxis).Unit
		if wallParallel.Magnitude < 0.1 then
			wallParallel = Vector3.xAxis
		end

		-- Izquierda: raycast a lo largo de la pared en -wallParallel
		local leftAligned = self:_castRay(origin, -wallParallel, Constants.COVER_SWAP_MAX_DISTANCE)
		if leftAligned and self:_isCoverObject(leftAligned.Instance) and leftAligned.Instance ~= ctx.CoverInstance then
			local snNormal, snPosition =
				self:_snapNormalToFace(leftAligned.Instance, leftAligned.Position, leftAligned.Normal)
			if snNormal then
				local dotNormals = ctx.CoverNormal:Dot(snNormal)
				if dotNormals >= Constants.COVER_SWAP_ALIGNMENT_DOT then
					ctx.HasAlignedCoverLeft = true
					ctx.AlignedCoverNormalLeft = snNormal
					ctx.AlignedCoverPositionLeft = snPosition
					ctx.AlignedCoverInstanceLeft = leftAligned.Instance
				end
			end
		end

		-- Derecha: raycast a lo largo de la pared en +wallParallel
		local rightAligned = self:_castRay(origin, wallParallel, Constants.COVER_SWAP_MAX_DISTANCE)
		if
			rightAligned
			and self:_isCoverObject(rightAligned.Instance)
			and rightAligned.Instance ~= ctx.CoverInstance
		then
			local snNormal, snPosition =
				self:_snapNormalToFace(rightAligned.Instance, rightAligned.Position, rightAligned.Normal)
			if snNormal then
				local dotNormals = ctx.CoverNormal:Dot(snNormal)
				if dotNormals >= Constants.COVER_SWAP_ALIGNMENT_DOT then
					ctx.HasAlignedCoverRight = true
					ctx.AlignedCoverNormalRight = snNormal
					ctx.AlignedCoverPositionRight = snPosition
					ctx.AlignedCoverInstanceRight = rightAligned.Instance
				end
			end
		end
	end

	-- 5) Detectar esquinas (peek corners)
	-- Si el raycast lateral NO golpea nada → estamos al borde de la pared → esquina
	if ctx.HasCoverNearby and ctx.CoverNormal then
		-- Calcular dirección paralela a la pared
		local wallParallel = ctx.CoverNormal:Cross(Vector3.yAxis).Unit
		if wallParallel.Magnitude < 0.1 then
			wallParallel = Vector3.xAxis
		end

		-- Raycast a lo largo de la pared en ambas direcciones
		local cornerRange = Constants.COVER_CORNER_DETECTION_RANGE
		local leftCorner = self:_castRay(origin, -wallParallel, cornerRange)
		local rightCorner = self:_castRay(origin, wallParallel, cornerRange)

		-- Si NO hay pared en esa dirección → es una esquina
		if not leftCorner or not self:_isCoverObject(leftCorner.Instance) then
			ctx.IsAtCornerLeft = true
		end
		if not rightCorner or not self:_isCoverObject(rightCorner.Instance) then
			ctx.IsAtCornerRight = true
		end
	end
end

------------------------------------------------------------------------
-- INTERNAL
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
