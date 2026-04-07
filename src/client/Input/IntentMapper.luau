--[[
	IntentMapper.luau
	═══════════════════════════════════════════════════════════════
	CAPA 2: Raw Inputs → Intenciones Semánticas
	═══════════════════════════════════════════════════════════════
	
	Traduce inputs crudos del InputDetector a intenciones de alto nivel.
	Una intención describe QUÉ quiere hacer el jugador, no CÓMO lo solicitó.
	
	Tabla de traducción:
	  CoverButton Tap + cover cerca    → WantsCover
	  CoverButton Tap + sin cover      → WantsEvade
	  CoverButton HoldStart            → WantsRoadieRun
	  CoverButton Release              → WantsStopRoadieRun
	  SprintModifier Pressed           → WantsRoadieRun
	  SprintModifier Released           → WantsStopRoadieRun
	  EvadeButton Pressed              → WantsEvade
	  FireButton Pressed               → WantsShoot
	  FireButton Released              → WantsStopShoot
	  AimButton Pressed                → WantsAim
	  AimButton Released               → WantsStopAim
	  ReloadButton Pressed             → WantsReload
	  BlindFireButton Pressed          → WantsBlindFire
	  BlindFireButton Released         → WantsStopBlindFire
	  MeleeButton Tap                  → WantsMelee
	  MeleeButton HoldStart            → WantsChainsaw
	  InteractButton Pressed           → WantsInteract
	  SwapWeapon Pressed               → WantsSwapWeapon
	
	Soporte multi-intent: el jugador puede tener múltiples intenciones simultáneas.
	  ej: WantsMoveForward + WantsCover = el resolver decide qué hacer
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local IntentMapper = {}
IntentMapper.__index = IntentMapper

------------------------------------------------------------------------
-- TABLE-DRIVEN EVENT DISPATCH
-- Cada entrada: [RawName] = { [Mode] = handler(self, event) }
-- O(1) lookup en vez de if/elseif chain.
------------------------------------------------------------------------

local EVENT_DISPATCH = {
	CoverButton = {
		Tap = function(self, _event)
			self:_setIntent("WantsCover", true)
			local moveDir = self._inputDetector:GetMoveDirection()
			if moveDir.Y > Constants.FORWARD_INPUT_THRESHOLD then
				self:_setIntent("WantsMantle", true)
			end
		end,
		HoldStart = function(self, _event)
			self:_setIntent("WantsRoadieRun", true)
		end,
		Release = function(self, _event)
			self:_setIntent("WantsStopRoadieRun", true)
			self:_setIntent("WantsRoadieRun", false)
		end,
	},

	SprintModifier = {
		Pressed = function(self, _event)
			self:_setIntent("WantsRoadieRun", true)
		end,
		Released = function(self, _event)
			self:_setIntent("WantsStopRoadieRun", true)
			self:_setIntent("WantsRoadieRun", false)
		end,
	},

	EvadeButton = {
		Pressed = function(self, _event)
			self:_setIntent("WantsEvade", true)
		end,
	},

	FireButton = {
		Pressed = function(self, _event)
			self:_setIntent("WantsShoot", true)
		end,
		Released = function(self, _event)
			self:_setIntent("WantsStopShoot", true)
			self:_setIntent("WantsShoot", false)
		end,
	},

	AimButton = {
		Pressed = function(self, _event)
			self:_setIntent("WantsAim", true)
		end,
		Released = function(self, _event)
			self:_setIntent("WantsStopAim", true)
			self:_setIntent("WantsAim", false)
		end,
	},

	ReloadButton = {
		Pressed = function(self, _event)
			self:_setIntent("WantsReload", true)
		end,
	},

	BlindFireButton = {
		Pressed = function(self, _event)
			self:_setIntent("WantsBlindFire", true)
		end,
		Released = function(self, _event)
			self:_setIntent("WantsStopBlindFire", true)
			self:_setIntent("WantsBlindFire", false)
		end,
	},

	MeleeButton = {
		Tap = function(self, _event)
			self:_setIntent("WantsMelee", true)
		end,
		HoldStart = function(self, _event)
			self:_setIntent("WantsChainsaw", true)
		end,
		Release = function(self, _event)
			self:_setIntent("WantsChainsaw", false)
		end,
	},

	InteractButton = {
		Pressed = function(self, _event)
			self:_setIntent("WantsInteract", true)
		end,
	},

	SwapWeapon = {
		Pressed = function(self, event)
			self:_setIntent("WantsSwapWeapon", true, event.Data)
		end,
	},
}

function IntentMapper.new(inputDetector)
	local self = setmetatable({}, IntentMapper)

	self._inputDetector = inputDetector

	-- Intenciones activas este frame: { [intentName] = { active, data } }
	self._activeIntents = {}

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
--- @return { [string]: { Active: boolean, Data: any? } }
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
-- INTERNAL: Procesar un evento discreto (table-driven dispatch)
------------------------------------------------------------------------

function IntentMapper:_processEvent(event)
	local handlers = EVENT_DISPATCH[event.Name]
	if not handlers then
		return
	end
	local handler = handlers[event.Mode]
	if handler then
		handler(self, event)
	end
end

------------------------------------------------------------------------
-- INTERNAL: Estado continuo (polling cada frame)
------------------------------------------------------------------------

function IntentMapper:_processContinuousState()
	local detector = self._inputDetector
	local moveDir = detector:GetMoveDirection()

	-- Movimiento (WASD) → intenciones de movimiento
	self:_setIntent("WantsMoveForward", moveDir.Y > Constants.MOVE_DIRECTION_THRESHOLD)
	self:_setIntent("WantsMoveBackward", moveDir.Y < -Constants.MOVE_DIRECTION_THRESHOLD)
	self:_setIntent("WantsMoveLeft", moveDir.X < -Constants.MOVE_DIRECTION_THRESHOLD)
	self:_setIntent("WantsMoveRight", moveDir.X > Constants.MOVE_DIRECTION_THRESHOLD)

	-- Sprint continuo: si Shift está held O CoverButton está held (pasado threshold)
	if detector:IsRawHeld("SprintModifier") then
		self:_setIntent("WantsRoadieRun", true)
	end

	-- Aim continuo: si RMB está held
	if detector:IsRawHeld("AimButton") then
		self:_setIntent("WantsAim", true)
	end

	-- Fire continuo: si LMB está held (armas automáticas)
	if detector:IsRawHeld("FireButton") then
		self:_setIntent("WantsShoot", true)
	end

	-- BlindFire continuo: si Q está held
	if detector:IsRawHeld("BlindFireButton") then
		self:_setIntent("WantsBlindFire", true)
	end

	-- Exit cover: moveDirection "hacia atrás" = quiere salir de cover.
	if moveDir.Y < -Constants.EXIT_COVER_BACK_THRESHOLD then
		self:_setIntent("WantsExitCover", true)
	end
end

------------------------------------------------------------------------
-- INTERNAL: Gestión de intenciones
------------------------------------------------------------------------

function IntentMapper:_setIntent(intentName: string, active: boolean, data: any?)
	if active then
		self._activeIntents[intentName] = { Active = true, Data = data }
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
