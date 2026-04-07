--[[
	IntentMapper.luau
	═══════════════════════════════════════════════════════════════
	CAPA 2: Raw Inputs → Intenciones Semánticas
	═══════════════════════════════════════════════════════════════
	
	Arquitectura AAA: Action-Based Input Mapping.
	
	El hardware JAMÁS habla directamente con el personaje.
	Esta capa es un DICCIONARIO PURO DE DATOS que traduce eventos
	físicos (Tap, Hold, Pressed, Released) en intenciones abstractas.
	
	Filosofía clave:
	  - Un solo botón puede inyectar MÚLTIPLES intenciones simultáneas.
	    ej: CoverButton.Tap → { WantsCover, WantsMantle, WantsEvade }
	  - El Árbitro Contextual (ActionResolver, Capa 4) decide cuál gana
	    usando prioridad + estado + entorno.
	  - Todas las intenciones del mismo evento comparten un BatchId.
	    Cuando el buffer consume una, las demás del batch se descartan
	    automáticamente (batch consumption).
	  - Para rebind de controles, solo se modifica INTENT_MAP.
	    La lógica del personaje permanece intacta.
	
	Tabla de inyección (INTENT_MAP):
	  CoverButton   Tap       → WantsCover, WantsMantle, WantsEvade
	  CoverButton   HoldStart → WantsRoadieRun
	  CoverButton   Release   → stop WantsRoadieRun
	  SprintModifier Pressed  → WantsRoadieRun
	  SprintModifier Released → stop WantsRoadieRun
	  EvadeButton   Pressed   → WantsEvade
	  FireButton    Pressed   → WantsShoot
	  FireButton    Released  → stop WantsShoot
	  AimButton     Pressed   → WantsAim
	  AimButton     Released  → stop WantsAim
	  ReloadButton  Pressed   → WantsReload
	  BlindFireButton Pressed → WantsBlindFire
	  BlindFireButton Released→ stop WantsBlindFire
	  MeleeButton   Tap       → WantsMelee
	  MeleeButton   HoldStart → WantsChainsaw
	  MeleeButton   Release   → stop WantsChainsaw
	  InteractButton Pressed  → WantsInteract
	  SwapWeapon    Pressed   → WantsSwapWeapon
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local IntentMapper = {}
IntentMapper.__index = IntentMapper

------------------------------------------------------------------------
-- INTENT_MAP — Diccionario puro de datos (sin funciones, sin lógica)
--
-- Estructura: [RawName] = { [Mode] = mapping }
-- mapping.intents = { "Intent1", "Intent2", ... }  → se activan con BatchId
-- mapping.stop    = { "IntentToStop", ... }         → se desactivan + emiten WantsStop*
--
-- Para rebind: solo mover/copiar entries. Nada más cambia.
------------------------------------------------------------------------

local INTENT_MAP = {
	CoverButton = {
		Tap = { intents = { "WantsCover", "WantsMantle", "WantsEvade" } },
		HoldStart = { intents = { "WantsRoadieRun" } },
		Release = { stop = { "WantsRoadieRun" } },
	},

	SprintModifier = {
		Pressed = { intents = { "WantsRoadieRun" } },
		Released = { stop = { "WantsRoadieRun" } },
	},

	EvadeButton = {
		Pressed = { intents = { "WantsEvade" } },
	},

	FireButton = {
		Pressed = { intents = { "WantsShoot" } },
		Released = { stop = { "WantsShoot" } },
	},

	AimButton = {
		Pressed = { intents = { "WantsAim" } },
		Released = { stop = { "WantsAim" } },
	},

	ReloadButton = {
		Pressed = { intents = { "WantsReload" } },
	},

	BlindFireButton = {
		Pressed = { intents = { "WantsBlindFire" } },
		Released = { stop = { "WantsBlindFire" } },
	},

	MeleeButton = {
		Tap = { intents = { "WantsMelee" } },
		HoldStart = { intents = { "WantsChainsaw" } },
		Release = { stop = { "WantsChainsaw" } },
	},

	InteractButton = {
		Pressed = { intents = { "WantsInteract" } },
	},

	SwapWeapon = {
		Pressed = { intents = { "WantsSwapWeapon" } },
	},
}

------------------------------------------------------------------------
-- CONTINUOUS_HELD — Intents re-evaluados cada frame por polling.
-- Si el raw input está held, la intención se activa.
-- Movement direction y WantsExitCover son especiales (calculados aparte).
------------------------------------------------------------------------

local CONTINUOUS_HELD = {
	{ raw = "SprintModifier", intent = "WantsRoadieRun" },
	{ raw = "AimButton", intent = "WantsAim" },
	{ raw = "FireButton", intent = "WantsShoot" },
	{ raw = "BlindFireButton", intent = "WantsBlindFire" },
}

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------

function IntentMapper.new(inputDetector)
	local self = setmetatable({}, IntentMapper)

	self._inputDetector = inputDetector

	-- Intenciones activas este frame: { [intentName] = { Active, Data, BatchId? } }
	self._activeIntents = {}

	-- Contador auto-incremental de batch: cada evento discreto genera un ID único
	self._nextBatchId = 1

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function IntentMapper:Destroy()
	table.clear(self._activeIntents)
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
	local rawModes = INTENT_MAP[event.Name]
	if not rawModes then
		return
	end
	local mapping = rawModes[event.Mode]
	if not mapping then
		return
	end

	-- Intenciones positivas: activar con BatchId compartido
	if mapping.intents then
		local batchId = self._nextBatchId
		self._nextBatchId += 1

		for _, intentName in mapping.intents do
			self:_setIntent(intentName, true, event.Data, batchId)
		end
	end

	-- Intenciones stop: desactivar la continua + emitir el WantsStop* discreto
	if mapping.stop then
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

	-- Held-based continuous intents (data-driven loop)
	for _, entry in CONTINUOUS_HELD do
		if detector:IsRawHeld(entry.raw) then
			self:_setIntent(entry.intent, true)
		end
	end

	-- Exit cover: moveDirection "hacia atrás" = quiere salir de cover.
	if moveDir.Y < -Constants.EXIT_COVER_BACK_THRESHOLD then
		self:_setIntent("WantsExitCover", true)
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
