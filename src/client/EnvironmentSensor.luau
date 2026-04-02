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
	}

	return self
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

	-- Obtener character y HumanoidRootPart
	local character = self._player.Character
	if not character then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Actualizar filtro de raycast con objetos de cover
	self:_updateRayFilter(character)

	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET
	local lookDir = hrp.CFrame.LookVector
	local rightDir = hrp.CFrame.RightVector

	-- 1) Raycast frontal: cover directamente adelante
	local frontResult = self:_castRay(origin, lookDir, Constants.COVER_SCAN_RANGE)
	if frontResult then
		local coverPart = frontResult.Instance
		if self:_isCoverObject(coverPart) then
			ctx.HasCoverNearby = true
			ctx.CoverNormal = frontResult.Normal
			ctx.CoverPosition = frontResult.Position
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

	-- 2) Si no encontramos cover frontal, probar diagonal izq/der
	if not ctx.HasCoverNearby then
		local angleRad = math.rad(Constants.COVER_MAGNETISM_ANGLE)
		local leftDir = (lookDir * math.cos(angleRad) - rightDir * math.sin(angleRad)).Unit
		local rightDirAngled = (lookDir * math.cos(angleRad) + rightDir * math.sin(angleRad)).Unit

		local leftResult = self:_castRay(origin, leftDir, Constants.COVER_SCAN_RANGE)
		if leftResult and self:_isCoverObject(leftResult.Instance) then
			ctx.HasCoverNearby = true
			ctx.CoverNormal = leftResult.Normal
			ctx.CoverPosition = leftResult.Position
			ctx.CoverInstance = leftResult.Instance
			ctx.CoverType = self:_classifyCover(leftResult.Instance)
			ctx.IsFacingCover = true
		end

		if not ctx.HasCoverNearby then
			local rightResult = self:_castRay(origin, rightDirAngled, Constants.COVER_SCAN_RANGE)
			if rightResult and self:_isCoverObject(rightResult.Instance) then
				ctx.HasCoverNearby = true
				ctx.CoverNormal = rightResult.Normal
				ctx.CoverPosition = rightResult.Position
				ctx.CoverInstance = rightResult.Instance
				ctx.CoverType = self:_classifyCover(rightResult.Instance)
				ctx.IsFacingCover = true
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

	-- 4) Detectar esquinas (peek corners)
	-- Si el raycast lateral NO golpea nada → estamos al borde de la pared → esquina
	if ctx.HasCoverNearby and ctx.CoverNormal then
		-- Calcular dirección paralela a la pared
		local wallParallel = ctx.CoverNormal:Cross(Vector3.yAxis).Unit
		if wallParallel.Magnitude < 0.1 then
			wallParallel = Vector3.xAxis
		end

		-- Raycast a lo largo de la pared en ambas direcciones
		local cornerRange = 2.0 -- studs
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
