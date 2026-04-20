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
local Signal = require(Shared:WaitForChild("Signal"))

-- Sub-módulos (hijos del folder Cover/ — init.luau ES el folder)
local EnteringCover = require(script.EnteringCover)
local InCover = require(script.InCover)
local CoverRunning = require(script.CoverRunning)
local CornerCover = require(script.CornerCover)
local CoverSwapController = require(script.CoverSwapController)
local PeekHandler = require(script.PeekHandler)

local CoverMain = {}
CoverMain.__index = CoverMain

------------------------------------------------------------------------
-- Set de acciones que este handler puede manejar
------------------------------------------------------------------------

local COVER_ACTIONS: { [string]: boolean } = table.freeze({
	EnterCover = true,
	SlideIntoCover = true,
	ExitCover = true,
	StartCoverRunning = true,
	StopCoverRunning = true,
	CoverSwap = true,
	CancelSwapToRun = true,
	EnterPeek = true,
	ExitPeek = true,
	ReturnToCover = true,
})

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CoverMain.new(stateMachine, environmentSensor)
	local self = setmetatable({}, CoverMain)

	self._stateMachine = stateMachine

	-- Señales para desacoplar la cámara (Capa 5) del cover (Capa 4).
	-- ClientApp conecta estas señales a CameraController.
	self.CoverSettleChanged = Signal.new() -- (active: boolean)
	self.ShoulderSideChanged = Signal.new() -- (side: "Left"|"Right")
	self.InnerCornerTransition = Signal.new() -- (newNormal: Vector3)

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
		onCoverSettleChanged = self.CoverSettleChanged,
		onShoulderSideChanged = self.ShoulderSideChanged,
		onInnerCornerTransition = self.InnerCornerTransition,
	}

	-- Sub-módulos (orden importa: CornerCover primero, InCover lo usa)
	self._cornerCover = CornerCover.new(self._coverState)
	self._enteringCover = EnteringCover.new(self._coverState)
	self._inCover = InCover.new(self._coverState, self._cornerCover)
	self._coverRunning = CoverRunning.new(self._coverState, self._cornerCover, self._inCover)
	self._coverSwapController = CoverSwapController.new(self._coverState)
	self._peekHandler = PeekHandler.new(self._coverState)

	-- Flags de transición pendiente
	self._pendingCoverIdleTransition = false
	self._pendingIdleTransition = false

	-- Timer interno para estados con duración fija (CoverSlide, CoverExiting)
	self._timer = 0
	self._timerCallback = nil :: (() -> ())?

	-- Exit Collision Guard: impide traspasar la cover al salir rápido
	-- Se activa en ExitCover con los datos de la cover que se abandona.
	self._exitGuard = nil :: {
		coverInstance: BasePart,
		coverNormal: Vector3,
		coverPosition: Vector3,
		timer: number,
	}?

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
	-- ★ STALE COVER GUARD: si el estado salió de CoverGroup (ForceState a DBNO/Death/Idle)
	-- mientras había cover data activa, limpiar todo para evitar esquinas fantasma,
	-- peek residual, settle huérfano, y datos stale en EnvironmentSensor.
	-- Excluir estados de ActionGroup que necesitan cover data viva para completarse.
	local currentState = self._stateMachine:GetCurrentState()
	local isCoverRelated = self._stateMachine:IsInGroup("CoverGroup")
		or currentState == "CoverSlide"
		or currentState == "CoverEntering"
		or currentState == "CoverExiting"
		or currentState == "CoverSwap"
	if not isCoverRelated then
		if
			self._coverState.coverNormal
			or self._enteringCover:IsActive()
			or self._peekHandler:IsActive()
			or self._coverSwapController:IsActive()
			or self._coverRunning:IsActive()
			or self._pendingCoverIdleTransition
		then
			self._enteringCover:Cancel()
			self._coverSwapController:Cancel()
			self._peekHandler:Cancel()
			self._cornerCover:Reset()
			self._coverRunning:Stop()
			self._inCover:_cancelSettle(nil)
			self:_clearCoverState()
			self:_cancelTimer()
			self._pendingCoverIdleTransition = false
			self._pendingIdleTransition = false
			self._exitGuard = nil
			return
		end
	end

	-- ★ Validación de cover instance: si la part desapareció/fue destruida,
	-- cancelar cualquier estado de cover y volver a Idle.
	local coverInst = self._coverState.coverInstance
	if coverInst and not coverInst:IsDescendantOf(workspace) then
		self._enteringCover:Cancel()
		self._coverSwapController:Cancel()
		self._peekHandler:Cancel()
		self._cornerCover:Reset()
		self._coverRunning:Stop()
		self:_clearCoverState()
		self:_cancelTimer()
		self._pendingCoverIdleTransition = false
		if not self._stateMachine:TransitionTo("Idle") then
			self._pendingIdleTransition = true
		end
		return
	end

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

	-- EXIT COLLISION GUARD: impide traspasar la cover durante los frames
	-- posteriores a ExitCover. Si el personaje se acerca demasiado a la
	-- pared que acaba de abandonar, inyecta velocidad correctiva para
	-- empujarlo hacia fuera. Desactivar si re-entra en cover (enteringCover active).
	if self._exitGuard then
		self._exitGuard.timer -= dt
		local guard = self._exitGuard
		if guard.timer <= 0 or not guard.coverInstance:IsDescendantOf(workspace) or self._enteringCover:IsActive() then
			self._exitGuard = nil
		else
			self:_updateExitGuard(guard, dt)
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
			-- FIX: cancelar el timer del SlideIntoCover para que no llame
			-- NotifyEnterFromSnap() por segunda vez cuando el snap termina
			-- antes de que expire el timer fijo de COVER_SLIDE_DURATION.
			self:_cancelTimer()
			self._pendingCoverIdleTransition = true
		end
	end

	-- CORNER COVER: actualizar detección de esquinas (siempre, para que InCover y CoverRunning lo consulten)
	local currentState = self._stateMachine:GetCurrentState()

	-- RE-SONDEO DE PARED: actualizar coverInstance y coverType mientras nos
	-- desplazamos lateralmente. Covers compuestas por varias parts pueden cambiar
	-- de Low a High (o vice versa) sin que el jugador salga de cover.
	if
		self._coverState.coverNormal
		and (
			currentState == "CoverIdle"
			or currentState == "CoverWalking"
			or currentState == "CoverRunning"
			or currentState == "CoverAimHigh"
			or currentState == "CoverAimLow"
			or currentState == "CoverFiring"
			or currentState == "CoverPeek"
		)
	then
		local character = self._coverState.player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			local sensor = self._coverState.envSensor
			local hitInst, hitType = sensor:RecheckCoverWall(hrp.Position, self._coverState.coverNormal)
			if hitInst then
				-- Actualizar instancia y tipo si cambiaron
				if hitInst ~= self._coverState.coverInstance then
					self._coverState.coverInstance = hitInst
				end
				if hitType ~= self._coverState.coverType then
					self._coverState.coverType = hitType
				end
			end
		end
	end

	if
		currentState == "CoverIdle"
		or currentState == "CoverWalking"
		or currentState == "CoverRunning"
		or currentState == "CoverCorners"
		or currentState == "CoverAim"
		or currentState == "CoverAimHigh"
		or currentState == "CoverAimLow"
		or currentState == "CoverFiring"
		or currentState == "CoverPeek"
		or currentState == "CoverBlindFire"
		or currentState == "CoverEntering"
	then
		self._cornerCover:Update(envContext)
	end

	-- COVER IDLE (CoverIdle, CoverPeek): reposo total — velocidad=0, wall-glue
	if (currentState == "CoverIdle" or currentState == "CoverPeek") and self._coverState.coverNormal then
		self._inCover:UpdateIdle(dt, envContext)
	end

	-- COVER AIM (CoverAimHigh, CoverAimLow, CoverFiring): movimiento lateral a velocidad reducida.
	-- El aim NO bloquea el movimiento — solo reduce la velocidad con AIM_WALK_SPEED_MULTIPLIER.
	-- Sin movimiento: UpdateWalking ya zeroes la velocidad, comportamiento idéntico a UpdateIdle.
	-- Excepción: durante CoverFiring con peek activo, el peek handler controla la posición.
	if
		(currentState == "CoverAimHigh" or currentState == "CoverAimLow" or currentState == "CoverFiring")
		and self._coverState.coverNormal
		and not (currentState == "CoverFiring" and self._peekHandler:IsActive())
	then
		self._inCover:UpdateWalking(dt, envContext, Constants.COVER_WALK_SPEED * Constants.AIM_WALK_SPEED_MULTIPLIER)
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

	-- PEEK: desplazamiento lateral en esquina durante aim
	if self._peekHandler:IsActive() then
		-- El peek handler puede estar activo en CoverPeek o CoverFiring
		-- (disparo desde peek mantiene la posición desplazada).
		-- También durante _returning (End() fue llamado, volviendo a startPos).
		self._peekHandler:Update(dt)
	end

	-- Sincronizar estado con EnvironmentSensor para que ActionResolver
	-- pueda leer los datos sin depender directamente de CoverHandler.
	self:_syncToEnvironmentSensor()
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

--- Retorna el PeekHandler (para wiring externo si necesario).
function CoverMain:GetPeekHandler()
	return self._peekHandler
end

--- Limpia todo el estado de cover (usado por EvadeHandler al hacer RollOutOfCover).
function CoverMain:ResetCover()
	self._enteringCover:Cancel()
	self._coverSwapController:Cancel()
	self._peekHandler:Cancel()
	self._pendingCoverIdleTransition = false
	self._pendingIdleTransition = false
	self._cornerCover:Reset()
	self._coverRunning:Stop()

	-- FIX: cancelar settle de InCover (misma razón que ExitCover)
	self._inCover:_cancelSettle(nil)

	-- Activar exit guard anti-clip antes de limpiar
	local exitNormal = self._coverState.coverNormal
	local exitPosition = self._coverState.coverPosition
	local exitInstance = self._coverState.coverInstance
	if exitNormal and exitPosition and exitInstance and exitInstance:IsDescendantOf(workspace) then
		self._exitGuard = {
			coverInstance = exitInstance,
			coverNormal = exitNormal,
			coverPosition = exitPosition,
			timer = Constants.COVER_EXIT_GUARD_DURATION,
		}
	end

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

		-- Cancelar exit guard si existe (re-entrada cancela anti-clip)
		self._exitGuard = nil

		-- Escribir estado compartido
		self._coverState.coverNormal = data.coverNormal
		self._coverState.coverPosition = data.coverPos
		self._coverState.coverInstance = data.coverInstance
		self._coverState.coverType = data.coverType

		-- Publicar al EnvironmentSensor (desacopla ActionResolver de CoverHandler)
		local envSensor = self._coverState.envSensor
		if envSensor then
			envSensor:SetActiveCoverData(
				data.coverNormal,
				data.coverType,
				data.coverInstance,
				nil -- wallRight se calcula después en InCover
			)
		end

		-- NO activar Dynamic Framing aquí — durante CoverEntering el HRP se
		-- mueve y rota activamente, lo que hace oscilar el target del framing
		-- y provoca que la cámara gire sin control. La normal se inyecta en
		-- _cleanupSettle (cuando InCover termina el settle) via _onSettleComplete.
		-- Bloquear Dynamic Framing preventivamente durante entering + settle:
		self.CoverSettleChanged:Fire(true)

		-- Delegar entering al sub-módulo
		self._enteringCover:Begin(data)
	end,

	--- Slide rápido desde RoadieRun. Estado: CoverSlide.
	SlideIntoCover = function(self, data)
		if not data then
			return
		end

		-- Cancelar exit guard si existe (re-entrada cancela anti-clip)
		self._exitGuard = nil

		self._coverState.coverNormal = data.coverNormal
		self._coverState.coverPosition = data.coverPos
		self._coverState.coverInstance = data.coverInstance
		self._coverState.coverType = data.coverType

		-- Publicar al EnvironmentSensor (desacopla ActionResolver de CoverHandler)
		local envSensor = self._coverState.envSensor
		if envSensor then
			envSensor:SetActiveCoverData(
				data.coverNormal,
				data.coverType,
				data.coverInstance,
				nil -- wallRight se calcula después en InCover
			)
		end

		-- NO activar Dynamic Framing aquí — misma razón que EnterCover.
		-- Se activa al completar el settle en InCover._cleanupSettle.
		self.CoverSettleChanged:Fire(true)

		self._enteringCover:BeginSlide(data)

		-- CoverSlide dura COVER_SLIDE_DURATION, luego transiciona a CoverIdle
		self:_startTimer(Constants.COVER_SLIDE_DURATION, function()
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
		self._peekHandler:Cancel()
		self._cornerCover:Reset()
		self._coverRunning:Stop()

		-- FIX: cancelar settle de InCover para destruir CoverSettleNoCollision
		-- que de otro modo quedaría huérfana y deshabilitaría colisiones post-exit.
		self._inCover:_cancelSettle(nil)

		-- Guardar datos de la cover ANTES de limpiar para el exit guard anti-clip
		local exitNormal = self._coverState.coverNormal
		local exitPosition = self._coverState.coverPosition
		local exitInstance = self._coverState.coverInstance

		self:_clearCoverState()

		-- Activar exit collision guard si tenemos datos válidos
		if exitNormal and exitPosition and exitInstance and exitInstance:IsDescendantOf(workspace) then
			self._exitGuard = {
				coverInstance = exitInstance,
				coverNormal = exitNormal,
				coverPosition = exitPosition,
				timer = Constants.COVER_EXIT_GUARD_DURATION,
			}
		end

		self:_startTimer(Constants.COVER_EXIT_DURATION, function()
			-- Transicionar al estado correcto según si el jugador se está moviendo.
			-- Evita el parpadeo Idle→Walking que ocurría al hardcodear siempre Idle.
			local character = self._coverState.player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local isMoving = humanoid and humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD
			local targetState = if isMoving then "Walking" else "Idle"
			if not self._stateMachine:TransitionTo(targetState) then
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

	--- Inicia peek: desplazamiento lateral hacia esquina.
	EnterPeek = function(self, data)
		if data and data.side then
			self._peekHandler:Begin(data.side)
		end
	end,

	--- Finaliza peek: retorno a posición original.
	ExitPeek = function(self, _data)
		self._peekHandler:End()
	end,

	--- ReturnToCover: finaliza peek si estaba activo (CoverFiring → CoverIdle).
	ReturnToCover = function(self, _data)
		if self._peekHandler:IsActive() then
			self._peekHandler:End()
		end
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

	-- Notificar al EnvironmentSensor que ya no estamos en cover
	local envSensor = self._coverState.envSensor
	if envSensor then
		envSensor:ClearActiveCoverData()
	end
end

------------------------------------------------------------------------
-- EXIT COLLISION GUARD — barrera suave post-exit cover
-- Impide traspasar la cover recién abandonada usando solo velocidad
-- correctiva (sin CFrame snap). Patrón: damping exponencial de la
-- componente de velocidad hacia la pared + empuje suave hacia fuera
-- proporcional a la cercanía. Invisible para el jugador, se siente
-- como si la pared simplemente tuviera colisión sólida.
------------------------------------------------------------------------

--- Cada frame: amortigua velocidad hacia la pared y añade empuje
--- correctivo proporcional a la cercanía. Sin teleportaciones.
function CoverMain:_updateExitGuard(guard, dt: number)
	local character = self._coverState.player.Character
	if not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local coverNormal = guard.coverNormal
	local coverPosition = guard.coverPosition

	-- Distancia del jugador al plano de la pared (positivo = lado correcto)
	local toPlayer = hrp.Position - coverPosition
	local perpDist = toPlayer:Dot(coverNormal)

	local safeDist = Constants.COVER_EXIT_GUARD_SAFE_DIST

	-- Solo actuar si el personaje está más cerca de la pared que safeDist
	if perpDist >= safeDist then
		return
	end

	local vel = hrp.AssemblyLinearVelocity
	local perpVel = coverNormal:Dot(vel)

	-- 1. DAMPING: amortiguar componente de velocidad HACIA la pared
	--    Exponencial frame-rate independent: factor = 1 - e^(-rate * dt)
	--    Solo actúa cuando perpVel < 0 (moviéndose hacia la pared).
	if perpVel < 0 then
		local dampFactor = 1 - math.exp(-Constants.COVER_EXIT_GUARD_DAMP_RATE * dt)
		-- Reducir la componente negativa suavemente en vez de eliminarla de golpe
		local correction = coverNormal * (-perpVel * dampFactor)
		vel = vel + correction
	end

	-- 2. PUSH SUAVE: empuje correctivo proporcional a cuánto falta para safeDist.
	--    err normalizado 0…1 (0 = en safeDist, 1 = dentro de la pared).
	--    La fuerza crece suavemente con el cuadrado del error (ease-in).
	local err = math.clamp((safeDist - perpDist) / safeDist, 0, 1)
	local pushStrength = err * err * Constants.COVER_EXIT_GUARD_PUSH_SPEED
	vel = vel + coverNormal * pushStrength * dt

	hrp.AssemblyLinearVelocity = Vector3.new(vel.X, hrp.AssemblyLinearVelocity.Y, vel.Z)
end

function CoverMain:_startTimer(duration: number, callback: () -> ())
	self._timer = duration
	self._timerCallback = callback
end

function CoverMain:_cancelTimer()
	self._timer = 0
	self._timerCallback = nil
end

--- Sincroniza el estado actual de cover con el EnvironmentSensor.
--- Llamar cada frame desde Update() para que ActionResolver tenga datos frescos.
function CoverMain:_syncToEnvironmentSensor()
	local envSensor = self._coverState.envSensor
	if not envSensor then
		return
	end

	-- Si no estamos en cover, limpiar datos
	if not self._coverState.coverNormal then
		envSensor:ClearActiveCoverData()
		return
	end

	-- Calcular wallRight igual que InCover
	local coverNormal = self._coverState.coverNormal
	local wallRight = Vector3.yAxis:Cross(coverNormal)
	if wallRight.Magnitude < 0.001 then
		wallRight = Vector3.xAxis
	else
		wallRight = wallRight.Unit
	end
	self._coverState.wallRight = wallRight

	-- Sincronizar datos de cover
	envSensor:SetActiveCoverData(
		self._coverState.coverNormal,
		self._coverState.coverType,
		self._coverState.coverInstance,
		wallRight
	)

	-- Sincronizar estado de esquinas (desde CornerCover con histéresis)
	envSensor:SetActiveCornerState(self._cornerCover:IsAtLeft(), self._cornerCover:IsAtRight())

	-- Sincronizar estado de peek (incluir posición de origen para que el recheck de pared no falle)
	envSensor:SetPeekActive(self._peekHandler:IsActive(), self._peekHandler:GetStartPos())
end

function CoverMain:Destroy()
	-- Limpiar sub-módulos
	self._enteringCover:Cancel()
	self._coverSwapController:Cancel()
	self._peekHandler:Cancel()
	self._cornerCover:Reset()
	self._coverRunning:Stop()
	self:_clearCoverState()
	self:_cancelTimer()
	self._exitGuard = nil

	-- Destruir señales
	self.CoverSettleChanged:Destroy()
	self.ShoulderSideChanged:Destroy()
	self.InnerCornerTransition:Destroy()
end

return CoverMain
