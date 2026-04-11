--[[
	VaultSafety.luau
	═══════════════════════════════════════════════════════════════
	Validación de seguridad para vault sobre cover bajo
	═══════════════════════════════════════════════════════════════

	Responsabilidad única: determinar si el destino de un vault es
	transitable (sin techo bajo, con suelo firme).

	Dos checks:
	  1. Overhead clearance — rayo vertical encima del end-point
	  2. Landing zone — rayo hacia abajo para detectar suelo

	Estado propio: RaycastParams (Exclude mode) reutilizable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local VaultSafety = {}
VaultSafety.__index = VaultSafety

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function VaultSafety.new()
	local self = setmetatable({}, VaultSafety)

	-- Overhead raycasts: excluye character + cover
	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Exclude
	self._rayParams.FilterDescendantsInstances = {}

	-- Landing raycast: excluye solo el character — necesario para detectar
	-- si el rayo golpea la cover (landingType = "top") o el suelo ("through")
	self._landingParams = RaycastParams.new()
	self._landingParams.FilterType = Enum.RaycastFilterType.Exclude
	self._landingParams.FilterDescendantsInstances = {}

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Verifica que la instancia de cover siga existiendo y sea válida.
--- @param instance BasePart? — la instancia a validar
--- @return boolean
function VaultSafety:ValidateInstance(instance: BasePart?): boolean
	if not instance then
		return false
	end
	return instance:IsDescendantOf(workspace)
end

--- Lanza raycasts de seguridad para verificar que el destino del vault
--- es transitable (sin techo bajo, con suelo).
--- @param startPos Vector3 — posición actual del character
--- @param forwardDir Vector3 — dirección horizontal normalizada (-coverNormal)
--- @param character Model — el character del jugador
--- @param coverInstance BasePart — la pieza de cover que se salta
--- @return boolean isSafe
--- @return Vector3? landingPosition
--- @return string? landingType — "through" | "top"
function VaultSafety:CheckSafety(
	startPos: Vector3,
	forwardDir: Vector3,
	character: Model,
	coverInstance: BasePart
): (boolean, Vector3?, string?)
	self._rayParams.FilterDescendantsInstances = { character, coverInstance }
	self._landingParams.FilterDescendantsInstances = { character }

	-- 1) Overhead clearance en la POSICIÓN DEL JUGADOR: rayo diagonal (forward + up)
	-- Cubre el arco real del vault — detecta techos inclinados, vigas y obstáculos
	-- que estén tanto adelante como arriba del personaje antes de arrancar.
	local playerOverheadOrigin = startPos + Vector3.new(0, Constants.VAULT_OVERHEAD_CLEARANCE_OFFSET, 0)
	local diagonalDir = (forwardDir + Vector3.new(0, 1, 0)).Unit * Constants.VAULT_OVERHEAD_CLEARANCE_UP
	local playerOverheadResult = workspace:Raycast(playerOverheadOrigin, diagonalDir, self._rayParams)
	if playerOverheadResult then
		print("No se puede hacer vault")
		return false, nil, nil
	end

	local endHorizontal = startPos + forwardDir * Constants.VAULT_FORWARD_DIST

	-- 2) Overhead clearance en el END-POINT: rayo hacia abajo desde arriba
	-- Si hay obstáculo bloqueando el paso por arriba del destino → denegar
	local overheadOrigin = endHorizontal + Vector3.new(0, Constants.VAULT_OVERHEAD_RAY_HEIGHT, 0)
	local overheadResult =
		workspace:Raycast(overheadOrigin, Vector3.new(0, -Constants.VAULT_OVERHEAD_RAY_HEIGHT, 0), self._rayParams)
	if overheadResult then
		return false, nil, nil
	end

	-- 3) Landing zone: rayo hacia abajo desde el end-point elevado.
	-- Usa _landingParams (NO excluye coverInstance) para poder detectar
	-- si el punto de impacto ES la propia cover (landingType = "top").
	local landingOrigin = endHorizontal + Vector3.new(0, Constants.VAULT_LANDING_RAY_UP, 0)
	local landingResult = workspace:Raycast(
		landingOrigin,
		Vector3.new(0, -(Constants.VAULT_LANDING_RAY_UP + Constants.VAULT_LANDING_RAY_DOWN), 0),
		self._landingParams
	)
	if not landingResult then
		return false, nil, nil
	end

	-- 4) Clasificar landingType:
	--   "top"     → el rayo golpeó la cover part → el jugador cae encima de ella
	--   "through" → el rayo golpeó otra superficie (suelo al otro lado)
	local landingType: string
	if landingResult.Instance == coverInstance then
		landingType = "top"
	else
		landingType = "through"
	end

	return true, landingResult.Position, landingType
end

return VaultSafety
