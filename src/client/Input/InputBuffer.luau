--[[
	InputBuffer.luau
	═══════════════════════════════════════════════════════════════
	CAPA 3: Input Buffering con TTL + Batch Consumption
	═══════════════════════════════════════════════════════════════
	
	Guarda intenciones durante una ventana de tiempo para que acciones
	ligeramente anticipadas funcionen. Es la diferencia entre un juego
	"responsivo" y uno "sordo".
	
	Ejemplo: El jugador presiona Space (cover) 80ms antes de estar en
	rango de la pared. Sin buffer, no pasa nada. Con buffer de 120ms,
	la acción se ejecuta en cuanto entra al rango.
	
	Reglas:
	1. Un intent a la vez por tipo: si llega otro WantsCover mientras
	   hay uno pendiente, REEMPLAZA (no apila).
	2. Se consume al ejecutar: consumed = true.
	3. Expira por tiempo: si TTL expira, se descarta silenciosamente.
	4. Batch Consumption: cuando se consume un intent con BatchId,
	   TODOS los demás intents del mismo batch se consumen también.
	   Esto previene intenciones huérfanas del multi-intent.
	   Ej: CoverButton.Tap inyecta {WantsCover, WantsMantle, WantsEvade}
	   con BatchId=7. Al consumir WantsCover, WantsMantle y WantsEvade
	   se marcan Consumed automáticamente → no se disparan después.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local InputBuffer = {}
InputBuffer.__index = InputBuffer

--- TTL por tipo de intent (segundos).
--- Solo entries para intents que realmente se buffean (ver Constants.BUFFERABLE_INTENTS).
local INTENT_TTL = {
	WantsCover = Constants.BUFFER_TTL_COVER,
	WantsEvade = Constants.BUFFER_TTL_EVADE,
	WantsReload = Constants.BUFFER_TTL_RELOAD,
	WantsMelee = Constants.BUFFER_TTL_MELEE,
	WantsChainsaw = Constants.BUFFER_TTL_CHAINSAW,
	WantsInteract = Constants.BUFFER_TTL_INTERACT,
	WantsSwapWeapon = Constants.BUFFER_TTL_DEFAULT,
	WantsMantle = Constants.BUFFER_TTL_MANTLE,
	WantsVault = Constants.BUFFER_TTL_VAULT,
	WantsExitCover = Constants.BUFFER_TTL_DEFAULT,
}

function InputBuffer.new()
	local self = setmetatable({}, InputBuffer)

	-- Buffer: { [intentName] = BufferEntry }
	-- Solo un entry por tipo de intent (regla 1: reemplazar, no apilar)
	self._buffer = {}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function InputBuffer:Destroy()
	self:Clear()
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Inserta o reemplaza un intent en el buffer.
--- @param intentName string — nombre del intent
--- @param data any? — datos adicionales (ej: slot de arma)
--- @param batchId number? — ID de batch para batch consumption
function InputBuffer:Push(intentName: string, data: any?, batchId: number?)
	local ttl = INTENT_TTL[intentName] or Constants.BUFFER_TTL_DEFAULT

	self._buffer[intentName] = {
		Intent = intentName,
		Timestamp = os.clock(),
		TTL = ttl,
		Consumed = false,
		Data = data,
		BatchId = batchId,
	}
end

--- Inserta múltiples intents desde el IntentMapper.
--- Solo bufferea intents discretos que están activos.
--- Propaga el BatchId del IntentMapper para batch consumption.
--- Usa Constants.BUFFERABLE_INTENTS como single source of truth.
function InputBuffer:PushFromIntents(activeIntents: { [string]: { Active: boolean, Data: any? } })
	for _, intentName in Constants.BUFFERABLE_INTENTS do
		local entry = activeIntents[intentName]
		if entry and entry.Active then
			self:Push(intentName, entry.Data, entry.BatchId)
		end
	end
end

--- Limpia intents expirados. Llamar cada frame.
function InputBuffer:CleanExpired()
	local now = os.clock()

	for intentName, entry in self._buffer do
		-- TTL 0 = inmediato, nunca expira por tiempo (se consume o descarta)
		if entry.TTL > 0 then
			local age = now - entry.Timestamp
			if age > entry.TTL then
				self._buffer[intentName] = nil
			end
		end

		-- Limpiar consumidos
		if entry.Consumed then
			self._buffer[intentName] = nil
		end
	end
end

--- Intenta consumir un intent del buffer.
--- Retorna true si el intent estaba disponible y fue consumido.
--- Batch Consumption: si el intent tiene BatchId, consume TODOS los
--- siblings del mismo batch (previene intenciones huérfanas).
function InputBuffer:Consume(intentName: string): (boolean, any?)
	local entry = self._buffer[intentName]
	if not entry then
		return false, nil
	end
	if entry.Consumed then
		return false, nil
	end

	local now = os.clock()
	local age = now - entry.Timestamp

	-- Verificar TTL (si TTL > 0)
	if entry.TTL > 0 and age > entry.TTL then
		self._buffer[intentName] = nil
		return false, nil
	end

	-- Consumir
	entry.Consumed = true

	-- Batch Consumption: consumir todos los siblings del mismo batch
	local batchId = entry.BatchId
	if batchId then
		for siblingName, siblingEntry in self._buffer do
			if siblingName ~= intentName and siblingEntry.BatchId == batchId then
				siblingEntry.Consumed = true
			end
		end
	end

	return true, entry.Data
end

--- Verifica si un intent está disponible en el buffer (sin consumirlo).
function InputBuffer:HasIntent(intentName: string): boolean
	local entry = self._buffer[intentName]
	if not entry then
		return false
	end
	if entry.Consumed then
		return false
	end

	local now = os.clock()
	local age = now - entry.Timestamp
	if entry.TTL > 0 and age > entry.TTL then
		return false
	end

	return true
end

--- Retorna el data de un intent buffereado (sin consumirlo).
--- Verifica TTL y estado Consumed para no retornar datos stale.
function InputBuffer:PeekData(intentName: string): any?
	local entry = self._buffer[intentName]
	if not entry or entry.Consumed then
		return nil
	end

	if entry.TTL > 0 then
		local age = os.clock() - entry.Timestamp
		if age > entry.TTL then
			return nil
		end
	end

	return entry.Data
end

--- Limpia todo el buffer.
function InputBuffer:Clear()
	table.clear(self._buffer)
end

--- Debug: retorna cuántos intents hay en el buffer.
function InputBuffer:GetCount(): number
	local count = 0
	for _ in self._buffer do
		count += 1
	end
	return count
end

return InputBuffer
