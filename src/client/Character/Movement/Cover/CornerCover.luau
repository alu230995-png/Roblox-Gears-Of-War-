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
	  - Servir de fuente de verdad para InCover, CoverRunning y CoverSwap
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local CornerCover = {}
CornerCover.__index = CornerCover

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CornerCover.new(coverState)
	local self = setmetatable({}, CornerCover)

	self._state = coverState -- referencia al estado compartido de CoverMain

	-- Flags de esquina actualizados cada frame por Update (con histéresis)
	self._atCornerRight = false
	self._atCornerLeft = false

	-- Histéresis: una vez que se activa el bloqueo, se mantiene un mínimo
	-- de frames antes de poder desactivarse. Esto previene el parpadeo
	-- de raycasts en la frontera de la esquina.
	self._lockRightFrames = 0
	self._lockLeftFrames = 0

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

-- Mínimo de frames consecutivos que el sensor debe reportar "no corner"
-- antes de desactivar el bloqueo. Previene flicker de raycasts.
local HYSTERESIS_FRAMES = Constants.CORNER_HYSTERESIS_FRAMES

--- Actualiza el estado de esquinas a partir del EnvironmentContext.
--- Usa histéresis: activación instantánea, desactivación retardada.
--- Llamado cada frame por CoverMain mientras estés en cover.
--- @param envContext table? — EnvironmentContext del EnvironmentSensor
function CornerCover:Update(envContext: any?)
	local rawRight = envContext and (envContext.IsAtCornerRight or false) or false
	local rawLeft = envContext and (envContext.IsAtCornerLeft or false) or false

	-- Derecha: activar inmediato, desactivar solo tras N frames sin detección
	if rawRight then
		self._atCornerRight = true
		self._lockRightFrames = HYSTERESIS_FRAMES
	else
		self._lockRightFrames = math.max(0, self._lockRightFrames - 1)
		if self._lockRightFrames <= 0 then
			self._atCornerRight = false
		end
	end

	-- Izquierda: mismo patrón
	if rawLeft then
		self._atCornerLeft = true
		self._lockLeftFrames = HYSTERESIS_FRAMES
	else
		self._lockLeftFrames = math.max(0, self._lockLeftFrames - 1)
		if self._lockLeftFrames <= 0 then
			self._atCornerLeft = false
		end
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
	self._lockRightFrames = 0
	self._lockLeftFrames = 0
end

return CornerCover
