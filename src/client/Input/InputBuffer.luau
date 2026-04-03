--[[
	InputBuffer.luau
	═══════════════════════════════════════════════════════════════
	CAPA 3: Input Buffering con TTL
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
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local InputBuffer = {}
InputBuffer.__index = InputBuffer

--- TTL por tipo de intent (segundos)
local INTENT_TTL = {
	WantsCover = Constants.BUFFER_TTL_COVER,
	WantsEvade = Constants.BUFFER_TTL_EVADE,
	WantsRoadieRun = Constants.BUFFER_TTL_ROADIE_RUN,
	WantsStopRoadieRun = Constants.BUFFER_TTL_DEFAULT,
	WantsShoot = Constants.BUFFER_TTL_SHOOT,
	WantsStopShoot = Constants.BUFFER_TTL_SHOOT,
	WantsAim = Constants.BUFFER_TTL_AIM,
	WantsStopAim = Constants.BUFFER_TTL_AIM,
	WantsReload = Constants.BUFFER_TTL_RELOAD,
	WantsBlindFire = Constants.BUFFER_TTL_BLIND_FIRE,
	WantsStopBlindFire = Constants.BUFFER_TTL_BLIND_FIRE,
	WantsMelee = Constants.BUFFER_TTL_MELEE,
	WantsChainsaw = Constants.BUFFER_TTL_CHAINSAW,
	WantsInteract = Constants.BUFFER_TTL_INTERACT,
	WantsSwapWeapon = Constants.BUFFER_TTL_DEFAULT,
	WantsMantle = Constants.BUFFER_TTL_MANTLE,
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

function InputBuffer:Init()
	-- Configuración realizada en constructor
end

function InputBuffer:Start()
	-- Sin conexiones propias — métodos son llamados por el heartbeat
end

function InputBuffer:Destroy()
	self:Clear()
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Inserta o reemplaza un intent en el buffer.
--- @param intentName string — nombre del intent
--- @param data any? — datos adicionales (ej: slot de arma)
function InputBuffer:Push(intentName: string, data: any?)
	local ttl = INTENT_TTL[intentName] or Constants.BUFFER_TTL_DEFAULT

	self._buffer[intentName] = {
		Intent = intentName,
		Timestamp = os.clock(),
		TTL = ttl,
		Consumed = false,
		Data = data,
	}
end

--- Inserta múltiples intents desde el IntentMapper.
--- Solo bufferea intents discretos que están activos.
function InputBuffer:PushFromIntents(activeIntents: { [string]: { Active: boolean, Data: any? } })
	-- Solo buffear intents discretos (one-shot)
	-- Los continuos (movimiento, aim held, fire held) no van al buffer
	local discreteIntents = {
		"WantsCover",
		"WantsEvade",
		"WantsMantle",
		"WantsReload",
		"WantsMelee",
		"WantsChainsaw",
		"WantsInteract",
		"WantsSwapWeapon",
		"WantsExitCover",
	}

	for _, intentName in discreteIntents do
		local entry = activeIntents[intentName]
		if entry and entry.Active then
			self:Push(intentName, entry.Data)
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
function InputBuffer:PeekData(intentName: string): any?
	local entry = self._buffer[intentName]
	if entry and not entry.Consumed then
		return entry.Data
	end
	return nil
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
