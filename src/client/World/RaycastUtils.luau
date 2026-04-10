--[[
	RaycastUtils.luau
	═══════════════════════════════════════════════════════════════
	Funciones puras para detección de cover via raycast.
	═══════════════════════════════════════════════════════════════

	Sin estado propio. Todas las funciones reciben sus datos como
	parámetros y retornan resultados sin side effects.

	Responsabilidad única: transformar resultados de raycast en
	datos semánticos de cover (normal snapeada, clasificación, validación).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local RaycastUtils = {}

------------------------------------------------------------------------
-- COVER IDENTIFICATION
------------------------------------------------------------------------

--- Determina si un BasePart califica como objeto de cover.
--- Prioridad: tag CollectionService > atributo IsCover > fallback dev.
--- @param part BasePart — la instancia a evaluar
--- @return boolean
function RaycastUtils.isCoverObject(part: BasePart): boolean
	if not part then
		return false
	end

	if CollectionService:HasTag(part, "CoverObject") then
		return true
	end

	if part:GetAttribute("IsCover") == true then
		return true
	end

	-- Fallback desarrollo: cualquier pared anchored suficientemente grande.
	-- Desactivar en producción via Constants.COVER_FALLBACK_ENABLED = false.
	if
		Constants.COVER_FALLBACK_ENABLED
		and part.Anchored
		and part.Size.Y >= Constants.COVER_FALLBACK_MIN_SIZE
		and part.Size.X >= Constants.COVER_FALLBACK_MIN_SIZE
	then
		return true
	end

	return false
end

--- Clasifica un Part de cover como "Low" o "High" según su altura.
--- @param part BasePart — el objeto de cover
--- @return string — "Low" o "High"
function RaycastUtils.classifyCover(part: BasePart): string
	if part.Size.Y <= Constants.COVER_HEIGHT_LOW_MAX then
		return "Low"
	end
	return "High"
end

------------------------------------------------------------------------
-- NORMAL SNAPPING
------------------------------------------------------------------------

--- Convierte la normal cruda del raycast a una normal pura snapeada
--- al eje dominante de la cara del Part en espacio local.
---
--- Algoritmo (4 fases):
---   1. Convertir hitPos y rawNormal al espacio local del coverPart
---   2. Detectar eje dominante: |localNormal.X| vs |localNormal.Z|
---      Tie-breaker (AAA): elegir la cara más ancha (más espacio de slide)
---   3. Corner push-in: clamp hitPos a los bounds de la cara
---   4. Convertir de vuelta al espacio del mundo
---
--- @param coverPart BasePart
--- @param hitPos Vector3 — punto de impacto del raycast (world space)
--- @param rawNormal Vector3 — normal cruda del raycast (world space)
--- @return Vector3? snappedNormal — normal pura en world space (nil si inválida)
--- @return Vector3? snappedPosition — posición ajustada en world space
function RaycastUtils.snapNormalToFace(coverPart: BasePart, hitPos: Vector3, rawNormal: Vector3): (Vector3?, Vector3?)
	local cf = coverPart.CFrame
	local halfSize = coverPart.Size * 0.5

	-- FASE 1: Convertir al espacio local del Part
	local localHit = cf:PointToObjectSpace(hitPos)
	local localNormal = cf:VectorToObjectSpace(rawNormal)

	-- Solo caras laterales (X/Z). Normal casi vertical → no es cover
	local absX = math.abs(localNormal.X)
	local absZ = math.abs(localNormal.Z)
	if absX < Constants.ENV_CORNER_EPSILON and absZ < Constants.ENV_CORNER_EPSILON then
		return nil, nil
	end

	-- FASE 2: Eje dominante con tie-breaker
	local snappedLocalNormal: Vector3
	local slideAxis: string -- "X" o "Z": eje de deslizamiento

	if math.abs(absZ - absX) < Constants.ENV_CORNER_NORMAL_TIE_THRESHOLD then
		-- Tie-breaker: cara más ancha = más espacio para slide
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

	local mxMin = -halfSize.X + margin
	local mxMax = halfSize.X - margin
	if mxMin > mxMax then
		mxMin, mxMax = 0, 0
	end
	local mzMin = -halfSize.Z + margin
	local mzMax = halfSize.Z - margin
	if mzMin > mzMax then
		mzMin, mzMax = 0, 0
	end

	local clampedHit =
		Vector3.new(math.clamp(localHit.X, mxMin, mxMax), localHit.Y, math.clamp(localHit.Z, mzMin, mzMax))

	-- Hit en el borde → empujar hacia el centro
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

------------------------------------------------------------------------
-- CONTEXT POPULATION
------------------------------------------------------------------------

--- Valida un RaycastResult y escribe datos de cover en el contexto dado.
--- @param ctx table — tabla de contexto (EnvironmentContext) a poblar
--- @param result RaycastResult — resultado del raycast
--- @return boolean — true si se pobló exitosamente
function RaycastUtils.populateCoverContext(ctx: any, result: RaycastResult): boolean
	local coverPart = result.Instance
	local snNormal, snPosition = RaycastUtils.snapNormalToFace(coverPart, result.Position, result.Normal)
	if not snNormal then
		return false
	end

	ctx.HasCoverNearby = true
	ctx.CoverNormal = snNormal
	ctx.CoverPosition = snPosition
	ctx.CoverInstance = coverPart
	ctx.CoverType = RaycastUtils.classifyCover(coverPart)
	return true
end

return RaycastUtils
