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

	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Exclude
	self._rayParams.FilterDescendantsInstances = {}

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
function VaultSafety:CheckSafety(
	startPos: Vector3,
	forwardDir: Vector3,
	character: Model,
	coverInstance: BasePart
): (boolean, Vector3?)
	self._rayParams.FilterDescendantsInstances = { character, coverInstance }

	local endHorizontal = startPos + forwardDir * Constants.VAULT_FORWARD_DIST

	-- 1) Overhead clearance: rayo vertical encima del end-point
	local overheadOrigin = endHorizontal + Vector3.new(0, Constants.VAULT_OVERHEAD_RAY_HEIGHT, 0)
	local overheadResult =
		workspace:Raycast(overheadOrigin, Vector3.new(0, -Constants.VAULT_OVERHEAD_RAY_HEIGHT, 0), self._rayParams)
	if overheadResult then
		return false, nil
	end

	-- 2) Landing zone: rayo hacia abajo desde el end-point elevado
	local landingOrigin = endHorizontal + Vector3.new(0, Constants.VAULT_LANDING_RAY_UP, 0)
	local landingResult = workspace:Raycast(
		landingOrigin,
		Vector3.new(0, -(Constants.VAULT_LANDING_RAY_UP + Constants.VAULT_LANDING_RAY_DOWN), 0),
		self._rayParams
	)
	if not landingResult then
		return false, nil
	end

	return true, landingResult.Position
end

return VaultSafety
