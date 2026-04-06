--[[
	CornerCover.luau
	═══════════════════════════════════════════════════════════════
	Sub-estado: Esquina de cover
	═══════════════════════════════════════════════════════════════
	
	Lógica de bloqueo cuando el jugador llega al borde de la
	pared de cover. El movimiento lateral se detiene.
	
	Responsabilidades:
	  - Detectar si el jugador está en una esquina (izq/der)
	  - Bloquear movimiento lateral en esa dirección
	  - Servir de fuente de verdad para InCover y CoverRunning
	
	STATUS: Stub — usa datos de EnvironmentSensor directamente.
	         Se expandirá con lógica de peek, corner swap, etc.
]]

local CornerCover = {}
CornerCover.__index = CornerCover

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CornerCover.new(coverState)
	local self = setmetatable({}, CornerCover)

	self._state = coverState -- referencia al estado compartido de CoverMain

	-- Flags de esquina actualizados cada frame por Update
	self._atCornerRight = false
	self._atCornerLeft = false

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Actualiza el estado de esquinas a partir del EnvironmentContext.
--- Llamado cada frame por CoverMain mientras estés en cover.
--- @param envContext table? — EnvironmentContext del EnvironmentSensor
function CornerCover:Update(envContext: any?)
	if envContext then
		self._atCornerRight = envContext.IsAtCornerRight or false
		self._atCornerLeft = envContext.IsAtCornerLeft or false
	else
		self._atCornerRight = false
		self._atCornerLeft = false
	end
end

--- Consulta si el movimiento lateral está bloqueado en la dirección dada.
--- @param lateralAmount number — valor del dot product con wallRight (+derecha, -izquierda)
--- @return boolean — true si bloqueado
function CornerCover:IsBlocked(lateralAmount: number): boolean
	if lateralAmount > 0 and self._atCornerRight then
		return true
	end
	if lateralAmount < 0 and self._atCornerLeft then
		return true
	end
	return false
end

--- Retorna true si estás en esquina derecha.
function CornerCover:IsAtRight(): boolean
	return self._atCornerRight
end

--- Retorna true si estás en esquina izquierda.
function CornerCover:IsAtLeft(): boolean
	return self._atCornerLeft
end

--- Resetea los flags de esquina (al salir de cover).
function CornerCover:Reset()
	self._atCornerRight = false
	self._atCornerLeft = false
end

--- Comprueba si hay una cobertura adyacente alineada para hacer Cover Swap.
--- Solo se ejecuta cuando el jugador está en esquina y presiona hacia el vacío.
---
--- @param lateralAmount number — dot product con wallRight (+derecha, -izquierda)
--- @param envSensor any — EnvironmentSensor con CheckSwapCover()
--- @param hrp BasePart — HumanoidRootPart
--- @return table? — { newPart, newNormal, hitPosition, moveDir } o nil
function CornerCover:CheckSwapTrigger(lateralAmount: number, envSensor: any, hrp: BasePart): any?
	-- Solo intentar swap si el movimiento está bloqueado por una esquina
	if not self:IsBlocked(lateralAmount) then
		return nil
	end

	local coverNormal = self._state.coverNormal
	local wallRight = self._state.wallRight
	local coverInstance = self._state.coverInstance

	if not coverNormal or not wallRight or not coverInstance then
		return nil
	end

	local moveDir = if lateralAmount > 0 then 1 else -1

	local newPart, newNormal, hitPosition =
		envSensor:CheckSwapCover(hrp, coverNormal, wallRight, moveDir, coverInstance)

	if not newPart or not newNormal or not hitPosition then
		return nil
	end

	return {
		newPart = newPart,
		newNormal = newNormal,
		hitPosition = hitPosition,
		moveDir = moveDir,
	}
end

return CornerCover
