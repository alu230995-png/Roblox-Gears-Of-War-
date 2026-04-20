--[[
	IntentMapper.luau
	═══════════════════════════════════════════════════════════════
	CAPA 2: Raw Inputs → Intenciones Semánticas
	═══════════════════════════════════════════════════════════════

	Arquitectura AAA: Action-Based Input Mapping.

	El hardware JAMÁS habla directamente con el personaje.
	Esta capa traduce eventos físicos (Tap, Hold, Pressed, Released)
	en intenciones abstractas usando un mapa dinámico reconstruible.

	Filosofía clave:
	  - Un solo botón puede inyectar MÚLTIPLES intenciones simultáneas.
	    ej: CoverButton.Tap → { WantsCover, WantsMantle, WantsEvade }
	  - El Árbitro Contextual (ActionResolver, Capa 4) decide cuál gana
	    usando prioridad + estado + entorno.
	  - Todas las intenciones del mismo evento comparten un BatchId.
	    Cuando el buffer consume una, las demás del batch se descartan
	    automáticamente (batch consumption).
	  - Para rebind de controles, llamar RebuildBindings() con una nueva
	    tabla de PlayerBindings. La lógica del personaje permanece intacta.

	El mapa se construye dinámicamente desde PlayerBindings:
	  IntentName → { RawInput, Mode, StopMode? }  (o array de binds)
	  → Builder invierte a: RawInput → Mode → { intents[], stop[] }
	  → Binds con Mode="Pressed" + StopMode="Released" generan
	    entradas en CONTINUOUS_HELD automáticamente.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local PlayerBindings = require(script.Parent.PlayerBindings)

local IntentMapper = {}
IntentMapper.__index = IntentMapper

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------

function IntentMapper.new(inputDetector, bindings)
	local self = setmetatable({}, IntentMapper)

	self._inputDetector = inputDetector

	-- Intenciones activas este frame: { [intentName] = { Active, Data, BatchId? } }
	self._activeIntents = {}

	-- Contador auto-incremental de batch: cada evento discreto genera un ID único
	self._nextBatchId = 1

	-- Mapa dinámico construido desde bindings
	-- Estructura: [RawName] = { [Mode] = { intents = {}, stop = {} } }
	self._intentMap = {}
	-- Intents continuos construidos desde bindings (polling cada frame)
	self._continuousHeld = {}

	self:RebuildBindings(bindings or PlayerBindings.DEFAULT.Intents)

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function IntentMapper:Destroy()
	table.clear(self._activeIntents)
end

------------------------------------------------------------------------
-- PUBLIC API: Rebuild
------------------------------------------------------------------------

--- Reconstruye el mapa de intenciones desde una tabla de bindings.
--- Formato de bindings: { [intentName] = bindInfo | { bindInfo, ... } }
---   bindInfo = { RawInput: string, Mode: string, StopMode: string? }
--- Llamar para cambiar controles en runtime sin tocar lógica del juego.
function IntentMapper:RebuildBindings(bindings)
	local intentMap = {}
	local continuousHeld = {}

	for intentName, bindValue in bindings do
		-- Normalizar: single bind → array de 1
		local bindList
		if bindValue.RawInput then
			bindList = { bindValue }
		else
			bindList = bindValue
		end

		for _, bind in bindList do
			local raw = bind.RawInput
			local mode = bind.Mode
			local stopMode = bind.StopMode

			-- Asegurar estructura: intentMap[raw][mode] = { intents = {}, stop = {} }
			if not intentMap[raw] then
				intentMap[raw] = {}
			end
			if not intentMap[raw][mode] then
				intentMap[raw][mode] = { intents = {}, stop = {} }
			end

			-- Inyectar la intención de inicio
			table.insert(intentMap[raw][mode].intents, intentName)

			-- Inyectar la intención de detención (si la acción requiere soltar el botón)
			if stopMode then
				if not intentMap[raw][stopMode] then
					intentMap[raw][stopMode] = { intents = {}, stop = {} }
				end
				table.insert(intentMap[raw][stopMode].stop, intentName)
			end

			-- Auto-detectar continuous held: Pressed/Released Y HoldStart/Release
			if mode == "Pressed" and stopMode == "Released" then
				table.insert(continuousHeld, { raw = raw, intent = intentName, holdSensitive = false })
			elseif mode == "HoldStart" and stopMode == "Release" then
				table.insert(continuousHeld, { raw = raw, intent = intentName, holdSensitive = true })
			end
		end
	end

	self._intentMap = intentMap
	self._continuousHeld = continuousHeld
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Procesa los eventos del frame y produce el set de intenciones activas.
--- Llamar una vez por frame DESPUÉS de InputDetector y EnvironmentSensor.
--- @return { [string]: { Active: boolean, Data: any?, BatchId: number? } }
function IntentMapper:Update(): { [string]: { Active: boolean, Data: any? } }
	-- Limpiar intenciones discretas del frame anterior
	-- (las continuas se re-evalúan abajo)
	self:_clearDiscreteIntents()

	-- 1) Procesar eventos discretos del InputDetector
	local events = self._inputDetector:DrainEvents()

	for _, event in events do
		self:_processEvent(event)
	end

	-- 2) Evaluar estados continuos (polling)
	self:_processContinuousState()

	return self._activeIntents
end

--- Retorna si una intención específica está activa este frame.
function IntentMapper:HasIntent(intentName: string): boolean
	local entry = self._activeIntents[intentName]
	return entry ~= nil and entry.Active
end

--- Retorna los datos asociados a una intención (ej: slot de arma).
function IntentMapper:GetIntentData(intentName: string): any?
	local entry = self._activeIntents[intentName]
	if entry then
		return entry.Data
	end
	return nil
end

--- Retorna la tabla completa de intenciones activas.
function IntentMapper:GetActiveIntents(): { [string]: { Active: boolean, Data: any? } }
	return self._activeIntents
end

------------------------------------------------------------------------
-- INTERNAL: Procesar un evento discreto (data-driven, sin funciones)
------------------------------------------------------------------------

function IntentMapper:_processEvent(event)
	local rawModes = self._intentMap[event.Name]
	if not rawModes then
		return
	end
	local mapping = rawModes[event.Mode]
	if not mapping then
		return
	end

	-- Intenciones positivas: activar con BatchId compartido
	if mapping.intents and #mapping.intents > 0 then
		local batchId = self._nextBatchId
		self._nextBatchId += 1

		for _, intentName in mapping.intents do
			self:_setIntent(intentName, true, event.Data, batchId)
		end
	end

	-- Intenciones stop: desactivar la continua + emitir el WantsStop* discreto
	if mapping.stop and #mapping.stop > 0 then
		for _, intentName in mapping.stop do
			self:_setIntent(intentName, false)
			self:_setIntent("WantsStop" .. string.sub(intentName, 6), true) -- "Wants" = 5 chars → "WantsStop" + resto
		end
	end
end

------------------------------------------------------------------------
-- INTERNAL: Estado continuo (polling cada frame, data-driven)
------------------------------------------------------------------------

function IntentMapper:_processContinuousState()
	local detector = self._inputDetector
	local moveDir = detector:GetMoveDirection()

	-- Movimiento (WASD) → intenciones de movimiento
	self:_setIntent("WantsMoveForward", moveDir.Y > Constants.MOVE_DIRECTION_THRESHOLD)
	self:_setIntent("WantsMoveBackward", moveDir.Y < -Constants.MOVE_DIRECTION_THRESHOLD)
	self:_setIntent("WantsMoveLeft", moveDir.X < -Constants.MOVE_DIRECTION_THRESHOLD)
	self:_setIntent("WantsMoveRight", moveDir.X > Constants.MOVE_DIRECTION_THRESHOLD)

	-- Paso 1: determinar qué intents continuos deben estar activos.
	-- Un intent es activo si AL MENOS UNO de sus bindings lo dice.
	local shouldBeActive = {} -- [intentName] = true

	for _, entry in self._continuousHeld do
		local isHeld = detector:IsRawHeld(entry.raw)
		if isHeld then
			if entry.holdSensitive then
				-- HoldStart/Release: solo re-afirmar si el evento HoldStart ya activó
				-- el intent. Evita que un TAP brevísimo active WantsRoadieRun solo
				-- porque IsRawHeld es true durante 1-2 frames.
				local current = self._activeIntents[entry.intent]
				if current and current.Active then
					shouldBeActive[entry.intent] = true
				end
			else
				-- Pressed/Released: activo siempre que esté held
				shouldBeActive[entry.intent] = true
			end
		end
	end

	-- Paso 2: aplicar. Activar los que deben estar activos,
	-- limpiar los que ningún binding sostiene (safety net para Release perdidos).
	local processed = {}
	for _, entry in self._continuousHeld do
		local intent = entry.intent
		if not processed[intent] then
			processed[intent] = true
			if shouldBeActive[intent] then
				self:_setIntent(intent, true)
			elseif self._activeIntents[intent] then
				self._activeIntents[intent] = nil
			end
		end
	end
end

------------------------------------------------------------------------
-- INTERNAL: Gestión de intenciones
------------------------------------------------------------------------

function IntentMapper:_setIntent(intentName: string, active: boolean, data: any?, batchId: number?)
	if active then
		self._activeIntents[intentName] = { Active = true, Data = data, BatchId = batchId }
	else
		if self._activeIntents[intentName] then
			self._activeIntents[intentName].Active = false
		end
	end
end

--- Limpiar intenciones discretas (one-shot) del frame anterior.
--- Las continuas se re-evalúan en _processContinuousState.
--- Usa Constants.DISCRETE_INTENTS como single source of truth.
function IntentMapper:_clearDiscreteIntents()
	for _, name in Constants.DISCRETE_INTENTS do
		self._activeIntents[name] = nil
	end
end

return IntentMapper
