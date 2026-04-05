--[[
	CoverRunning.luau
	═══════════════════════════════════════════════════════════════
	Sub-estado: Corriendo en cover
	═══════════════════════════════════════════════════════════════
	
	Movimiento rápido a lo largo de la pared de cover.
	Diferente de CoverWalking (InCover) en velocidad y animación.
	
	Las mecánicas de InCover pueden estar activas simultáneamente
	mientras CoverRunning se ejecuta (ej: peek, aim disponibles).
	
	STATUS: Stub — estructura lista para implementación futura.
]]

local CoverRunning = {}
CoverRunning.__index = CoverRunning

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CoverRunning.new(coverState, cornerCover)
	local self = setmetatable({}, CoverRunning)

	self._state = coverState -- referencia al estado compartido de CoverMain
	self._cornerCover = cornerCover -- para bloqueo en esquinas
	self._isActive = false

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Inicia CoverRunning en la dirección indicada.
--- @param direction number — +1 derecha, -1 izquierda (relativo a wallRight)
function CoverRunning:Begin(direction: number)
	self._isActive = true
	self._direction = direction
	-- TODO: aplicar velocidad de cover run, trigger animación
end

--- Detiene CoverRunning.
function CoverRunning:Stop()
	self._isActive = false
	self._direction = 0
end

--- Retorna true si CoverRunning está activo.
function CoverRunning:IsActive(): boolean
	return self._isActive
end

--- Actualiza CoverRunning cada frame.
--- @param dt number — delta time
--- @param envContext table? — EnvironmentContext
function CoverRunning:Update(dt: number, envContext: any?)
	if not self._isActive then
		return
	end

	-- TODO: Implementar movimiento rápido lateral constrañido
	-- - Velocidad mayor que CoverWalking
	-- - Animación de cover run
	-- - Bloqueo en esquinas via CornerCover
	-- - Frenar si CornerCover:IsBlocked(self._direction)
end

return CoverRunning
