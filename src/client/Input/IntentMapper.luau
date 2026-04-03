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

local IntentMapper = {}
IntentMapper.__index = IntentMapper

function IntentMapper.new(inputDetector, environmentSensor)
	local self = setmetatable({}, IntentMapper)

	self._inputDetector = inputDetector
	self._envSensor = environmentSensor

	-- Intenciones activas este frame: { [intentName] = { active, data } }
	self._activeIntents = {}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function IntentMapper:Init()
	-- Configuración realizada en constructor
end

function IntentMapper:Start()
	-- Sin conexiones propias — Update() es llamado por el heartbeat
end

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
	local env = self._envSensor:GetContext()

	for _, event in events do
		self:_processEvent(event, env)
	end

	-- 2) Evaluar estados continuos (polling)
	self:_processContinuousState(env)

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
-- INTERNAL: Procesar un evento discreto
------------------------------------------------------------------------

function IntentMapper:_processEvent(event, env)
	local name = event.Name
	local mode = event.Mode

	-- CoverButton (Space / A) — el corazón contexto-sensitivo de GoW
	if name == "CoverButton" then
		if mode == "Tap" then
			-- ¿Hay cover cerca? → WantsCover. ¿No? → WantsEvade
			if env.HasCoverNearby then
				-- ¿Es cover bajo y estamos moviendos hacia él? → WantsMantle (vault)
				if env.CoverType == "Low" and env.HasLowCoverAhead and env.MoveDirection.Y > 0.5 then
					self:_setIntent("WantsMantle", true)
				else
					self:_setIntent("WantsCover", true)
				end
			else
				self:_setIntent("WantsEvade", true)
			end
		elseif mode == "HoldStart" then
			-- Hold = RoadieRun
			self:_setIntent("WantsRoadieRun", true)
		elseif mode == "Release" then
			-- Release después de hold = parar RoadieRun
			self:_setIntent("WantsStopRoadieRun", true)
			self:_setIntent("WantsRoadieRun", false)
		end

	-- SprintModifier (Shift) — RoadieRun separado en PC
	elseif name == "SprintModifier" then
		if mode == "Pressed" then
			self:_setIntent("WantsRoadieRun", true)
		elseif mode == "Released" then
			self:_setIntent("WantsStopRoadieRun", true)
			self:_setIntent("WantsRoadieRun", false)
		end

	-- EvadeButton (Alt) — Roll/Evade separado en PC
	elseif name == "EvadeButton" then
		if mode == "Pressed" then
			self:_setIntent("WantsEvade", true)
		end

	-- FireButton (LMB / RT)
	elseif name == "FireButton" then
		if mode == "Pressed" then
			self:_setIntent("WantsShoot", true)
		elseif mode == "Released" then
			self:_setIntent("WantsStopShoot", true)
			self:_setIntent("WantsShoot", false)
		end

	-- AimButton (RMB / LT)
	elseif name == "AimButton" then
		if mode == "Pressed" then
			self:_setIntent("WantsAim", true)
		elseif mode == "Released" then
			self:_setIntent("WantsStopAim", true)
			self:_setIntent("WantsAim", false)
		end

	-- ReloadButton (R / RB)
	elseif name == "ReloadButton" then
		if mode == "Pressed" then
			self:_setIntent("WantsReload", true)
		end

	-- BlindFireButton (Q)
	elseif name == "BlindFireButton" then
		if mode == "Pressed" then
			self:_setIntent("WantsBlindFire", true)
		elseif mode == "Released" then
			self:_setIntent("WantsStopBlindFire", true)
			self:_setIntent("WantsBlindFire", false)
		end

	-- MeleeButton (V / B) — tap vs hold
	elseif name == "MeleeButton" then
		if mode == "Tap" then
			self:_setIntent("WantsMelee", true)
		elseif mode == "HoldStart" then
			self:_setIntent("WantsChainsaw", true)
		elseif mode == "Release" then
			self:_setIntent("WantsChainsaw", false)
		end

	-- InteractButton (E/F / X)
	elseif name == "InteractButton" then
		if mode == "Pressed" then
			self:_setIntent("WantsInteract", true)
		end

	-- SwapWeapon (1/2/3 / Y)
	elseif name == "SwapWeapon" then
		if mode == "Pressed" then
			self:_setIntent("WantsSwapWeapon", true, event.Data)
		end
	end
end

------------------------------------------------------------------------
-- INTERNAL: Estado continuo (polling cada frame)
------------------------------------------------------------------------

function IntentMapper:_processContinuousState(env)
	local detector = self._inputDetector
	local moveDir = detector:GetMoveDirection()

	-- Movimiento (WASD) → intenciones de movimiento
	self:_setIntent("WantsMoveForward", moveDir.Y > 0.1)
	self:_setIntent("WantsMoveBackward", moveDir.Y < -0.1)
	self:_setIntent("WantsMoveLeft", moveDir.X < -0.1)
	self:_setIntent("WantsMoveRight", moveDir.X > 0.1)

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

	-- Exit cover: si estamos en cover y moveDirection es "hacia atrás" (alejarse)
	-- El ActionResolver evaluará esto junto al estado actual
	if env.HasCoverNearby and moveDir.Y < -0.5 then
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
function IntentMapper:_clearDiscreteIntents()
	local discreteIntents = {
		"WantsCover",
		"WantsEvade",
		"WantsMantle",
		"WantsReload",
		"WantsMelee",
		"WantsChainsaw",
		"WantsInteract",
		"WantsSwapWeapon",
		"WantsStopRoadieRun",
		"WantsStopShoot",
		"WantsStopAim",
		"WantsStopBlindFire",
		"WantsExitCover",
	}

	for _, name in discreteIntents do
		self._activeIntents[name] = nil
	end
end

return IntentMapper
