--[[
	CoverMain.luau
	═══════════════════════════════════════════════════════════════
	Cover System — Orquestador principal
	═══════════════════════════════════════════════════════════════
	
	Reemplaza al monolítico CoverHandler.luau, delegando a sub-módulos:
	  - EnteringCover: snap magnético, entrada walk/slide, chaining
	  - InCover: CoverIdle + CoverWalking (lateral constrañido)
	  - CoverRunning: movimiento rápido lateral (stub)
	  - CornerCover: detección de esquinas, bloqueo de movimiento
	
	CoverMain mantiene el estado compartido (coverNormal, coverPosition,
	coverInstance, coverType, wallRight) y lo expone a los sub-módulos
	via una tabla `coverState` pasada por referencia.
	
	Las mecánicas de InCover pueden estar activas simultáneamente
	con CoverWalking o CoverRunning (capas combinables).
	
	API PÚBLICA es idéntica al antiguo CoverHandler para que
	MovementController no necesite cambiar su interfaz.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

-- Sub-módulos (hijos del folder Cover/ — init.luau ES el folder)
local EnteringCover = require(script.EnteringCover)
local InCover = require(script.InCover)
local CoverRunning = require(script.CoverRunning)
local CornerCover = require(script.CornerCover)
local CoverSwapController = require(script.CoverSwapController)

-- Duración del CoverSlide antes de pasar a CoverIdle.
-- TODO: mover a Constants cuando se añada tuning de balance.
local COVER_SLIDE_DURATION = 0.3

local CoverMain = {}
CoverMain.__index = CoverMain

------------------------------------------------------------------------
-- Set de acciones que este handler puede manejar
------------------------------------------------------------------------

local COVER_ACTIONS: { [string]: boolean } = {
	EnterCover = true,
	SlideIntoCover = true,
	ExitCover = true,
	StartCoverRunning = true,
	StopCoverRunning = true,
	CoverSwap = true,
	CancelSwapToRun = true,
}

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CoverMain.new(stateMachine, environmentSensor, cameraController)
	local self = setmetatable({}, CoverMain)

	self._stateMachine = stateMachine
	self._cameraController = cameraController

	-- Estado compartido: todos los sub-módulos leen/escriben vía esta tabla
	self._coverState = {
		coverNormal = nil :: Vector3?,
		coverPosition = nil :: Vector3?,
		coverInstance = nil :: BasePart?,
		coverType = nil :: string?, -- "Low" | "High"
		wallRight = nil :: Vector3?,
		stateMachine = stateMachine,
		player = Players.LocalPlayer,
		envSensor = environmentSensor, -- referencia al EnvironmentSensor para CheckInnerCorner
		cameraController = cameraController, -- referencia para shoulder swap en InCover
	}

	-- Sub-módulos (orden importa: CornerCover primero, InCover lo usa)
	self._cornerCover = CornerCover.new(self._coverState)
	self._enteringCover = EnteringCover.new(self._coverState)
	self._inCover = InCover.new(self._coverState, self._cornerCover)
	self._coverRunning = CoverRunning.new(self._coverState, self._cornerCover)
	self._coverSwapController = CoverSwapController.new(self._coverState)

	-- Flags de transición pendiente
	self._pendingCoverIdleTransition = false
	self._pendingIdleTransition = false

	-- Timer interno para estados con duración fija (CoverSlide, CoverExiting)
	self._timer = 0
	self._timerCallback = nil :: (() -> ())?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Intenta manejar una acción de cover.
--- Retorna true si la acción fue manejada, false si no.
function CoverMain:HandleAction(action: string, data: any?): boolean
	if not COVER_ACTIONS[action] then
		return false
	end

	local handler = self._handlers[action]
	if not handler then
		-- Acción reconocida pero sin handler implementado — no bloquear el fallback
		return false
	end

	handler(self, data)
	return true
end

--- Actualiza entering snap, InCover, CornerCover, timers cada frame.
--- @param dt number — delta time
--- @param envContext table? — EnvironmentContext del EnvironmentSensor
--- @param wantsCoverRedirect boolean? — true si el jugador pulsó cover de nuevo
function CoverMain:Update(dt: number, envContext: any?, wantsCoverRedirect: boolean?)
	-- Reintentar transición a CoverIdle si el snap terminó pero STATE_MIN_DURATION la bloqueó
	-- Reintentar transición a Idle si cancel/ExitCover fue bloqueado.
	-- ELSEIF: ambos flags nunca deben disparar en el mismo frame — son mutuamente excluyentes.
	if self._pendingCoverIdleTransition then
		if self._stateMachine:TransitionTo("CoverIdle") then
			self._pendingCoverIdleTransition = false
			self._pendingIdleTransition = false
			self._inCover:NotifyEnterFromSnap()
		end
	elseif self._pendingIdleTransition then
		if self._stateMachine:TransitionTo("Idle") then
			self._pendingIdleTransition = false
		end
	end

	-- Timer de estados temporales (CoverSlide duration, CoverExiting)
	if self._timer > 0 then
		self._timer -= dt
		if self._timer <= 0 then
			self._timer = 0
			if self._timerCallback then
				self._timerCallback()
				self._timerCallback = nil
			end
		end
	end

	-- ENTERING: delegar al sub-módulo
	if self._enteringCover:IsActive() then
		local result = self._enteringCover:Update(dt, envContext, wantsCoverRedirect)

		if result == "cancel" then
			self:_clearCoverState()
			self:_cancelTimer()
			if not self._stateMachine:TransitionTo("Idle") then
				self._pendingIdleTransition = true
			end
		elseif result == "complete" then
			self._pendingCoverIdleTransition = true
		end
	end

	-- CORNER COVER: actualizar detección de esquinas (siempre, para que InCover y CoverRunning lo consulten)
	local currentState = self._stateMachine:GetCurrentState()
	if
		currentState == "CoverIdle"
		or currentState == "CoverWalking"
		or currentState == "CoverRunning"
		or currentState == "CoverCorners"
		or currentState == "CoverAim"
		or currentState == "CoverBlindFire"
	then
		self._cornerCover:Update(envContext)
	end

	-- IN COVER (CoverIdle): reposo total — velocidad=0, wall-glue
	if currentState == "CoverIdle" and self._coverState.coverNormal then
		self._inCover:UpdateIdle(dt, envContext)
	end

	-- IN COVER (CoverWalking): movimiento lateral sobre el Tangente T = Up × N
	if currentState == "CoverWalking" and self._coverState.coverNormal and self._coverState.wallRight then
		self._inCover:UpdateWalking(dt, envContext)
	end

	-- COVER RUNNING: stub, se activará cuando se implemente
	if self._coverRunning:IsActive() then
		self._coverRunning:Update(dt, envContext)
	end

	-- COVER SWAP: movimiento Bézier entre coberturas adyacentes
	if self._coverSwapController:IsActive() then
		local swapResult = self._coverSwapController:Update(dt)
		if swapResult == "complete" then
			-- coverState ya está actualizado por el controller (orden crítico)
			self._inCover:NotifyEnterFromSnap()
			if not self._stateMachine:TransitionTo("CoverIdle") then
				self._pendingCoverIdleTransition = true
			end
		end
	end
end

--- Retorna la normal de la pared de cover actual (nil si no está en cover).
function CoverMain:GetNormal(): Vector3?
	return self._coverState.coverNormal
end

--- Retorna la posición de contacto con la pared de cover (nil si no está en cover).
function CoverMain:GetPosition(): Vector3?
	return self._coverState.coverPosition
end

--- Retorna el tipo de cover actual: "Low", "High", o nil.
function CoverMain:GetCoverType(): string?
	return self._coverState.coverType
end

--- Retorna el vector lateral de la pared.
function CoverMain:GetWallRight(): Vector3?
	return self._coverState.wallRight
end

--- Retorna la instancia del cover actual (nil si no está en cover).
function CoverMain:GetCoverInstance(): BasePart?
	return self._coverState.coverInstance
end

--- Retorna true si el entering está en progreso.
function CoverMain:IsSnapping(): boolean
	return self._enteringCover:IsActive()
end

--- Retorna true si está en esquina derecha (con histéresis).
function CoverMain:IsAtCornerRight(): boolean
	return self._cornerCover:IsAtRight()
end

--- Retorna true si está en esquina izquierda (con histéresis).
function CoverMain:IsAtCornerLeft(): boolean
	return self._cornerCover:IsAtLeft()
end

--- Limpia todo el estado de cover (usado por EvadeHandler al hacer RollOutOfCover).
function CoverMain:ResetCover()
	self._enteringCover:Cancel()
	self._coverSwapController:Cancel()
	self._pendingCoverIdleTransition = false
	self._pendingIdleTransition = false
	self._cornerCover:Reset()
	self._coverRunning:Stop()
	self:_clearCoverState()
	self:_cancelTimer()
end

------------------------------------------------------------------------
-- ACTION HANDLERS
------------------------------------------------------------------------

CoverMain._handlers = {
	--- Entrada a cover caminando. Estado: CoverEntering.
	EnterCover = function(self, data)
	if not data then
		return
	end

	-- Escribir estado compartido
	self._coverState.coverNormal = data.coverNormal
	self._coverState.coverPosition = data.coverPos
	self._coverState.coverInstance = data.coverInstance
	self._coverState.coverType = data.coverType

	-- NO activar Dynamic Framing aquí — durante CoverEntering el HRP se
	-- mueve y rota activamente, lo que hace oscilar el target del framing
	-- y provoca que la cámara gire sin control. La normal se inyecta en
	-- _cleanupSettle (cuando InCover termina el settle) via _onSettleComplete.
	-- Bloquear Dynamic Framing preventivamente durante entering + settle:
	if self._cameraController and self._cameraController.SetCoverSettleActive then
		self._cameraController:SetCoverSettleActive(true)
	end

	-- Delegar entering al sub-módulo
	self._enteringCover:Begin(data)
	end,

	--- Slide rápido desde RoadieRun. Estado: CoverSlide.
	SlideIntoCover = function(self, data)
	if not data then
		return
	end

	self._coverState.coverNormal = data.coverNormal
	self._coverState.coverPosition = data.coverPos
	self._coverState.coverInstance = data.coverInstance
	self._coverState.coverType = data.coverType

	-- NO activar Dynamic Framing aquí — misma razón que EnterCover.
	-- Se activa al completar el settle en InCover._cleanupSettle.
	if self._cameraController and self._cameraController.SetCoverSettleActive then
		self._cameraController:SetCoverSettleActive(true)
	end

	self._enteringCover:BeginSlide(data)

	-- CoverSlide dura COVER_SLIDE_DURATION, luego transiciona a CoverIdle
	self:_startTimer(COVER_SLIDE_DURATION, function()
		self._enteringCover:Cancel()
		self._inCover:NotifyEnterFromSnap()
		if not self._stateMachine:TransitionTo("CoverIdle") then
			self._pendingCoverIdleTransition = true
		end
	end)
	end,

	--- Salida de cover. Estado: CoverExiting.
	ExitCover = function(self, _data)
	self._enteringCover:Cancel()
	self._coverSwapController:Cancel()
	self._cornerCover:Reset()
	self._coverRunning:Stop()
	self:_clearCoverState()

	self:_startTimer(Constants.COVER_EXIT_DURATION, function()
		if not self._stateMachine:TransitionTo("Idle") then
			self._pendingIdleTransition = true
		end
	end)
	end,

	--- Inicia CoverRunning (sprint en cover).
	StartCoverRunning = function(self, _data)
	-- Cancelar swap en progreso si se activa CoverRunning (hold Space durante swap)
	self._coverSwapController:Cancel()
	self._coverRunning:Begin()
	end,

	--- Detiene CoverRunning (suelta sprint o deja de moverse).
	StopCoverRunning = function(self, _data)
	self._coverRunning:Stop()
	end,

	--- Cover Swap: salto entre coberturas adyacentes desde esquina.
	CoverSwap = function(self, data)
	if not data then
		return
	end
	self._coverSwapController:Begin(data)
	end,

	--- Cancela CoverSwap y sale a RoadieRun (hold Space durante swap).
	CancelSwapToRun = function(self, _data)
	self._coverSwapController:Cancel()
	self:_clearCoverState()
	end,
}

------------------------------------------------------------------------
-- INTERNAL: Helpers
------------------------------------------------------------------------

--- Limpia las propiedades compartidas de cover.
function CoverMain:_clearCoverState()
	self._coverState.coverNormal = nil
	self._coverState.coverPosition = nil
	self._coverState.coverInstance = nil
	self._coverState.coverType = nil
	self._coverState.wallRight = nil
end

function CoverMain:_startTimer(duration: number, callback: () -> ())
	self._timer = duration
	self._timerCallback = callback
end

function CoverMain:_cancelTimer()
	self._timer = 0
	self._timerCallback = nil
end

return CoverMain
