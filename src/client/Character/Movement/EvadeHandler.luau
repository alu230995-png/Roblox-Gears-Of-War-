--[[
	EvadeHandler.luau
	═══════════════════════════════════════════════════════════════
	Evade impulso + decay, RollOutOfCover, Mantle timers
	═══════════════════════════════════════════════════════════════
	
	Gestiona acciones de evasión y mantle:
	  - Evade: Lock SM → impulso decreciente via AssemblyLinearVelocity → Unlock → Idle
	  - RollOutOfCover: igual que Evade pero dirección = coverNormal opuesta
	  - Mantle: Lock SM → timer de animación → Unlock → Idle
	
	Necesita referencia a CoverMain para:
	  - RollOutOfCover: leer GetNormal() como dirección de salida
	  - Mantle/Vault: limpiar cover state via ResetCover()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local EvadeHandler = {}
EvadeHandler.__index = EvadeHandler

------------------------------------------------------------------------
-- Set de acciones que este handler puede manejar
------------------------------------------------------------------------

local EVADE_ACTIONS: { [string]: boolean } = table.freeze({
	Evade = true,
	RollOutOfCover = true,
	CornerRollOut = true,
	ExitCorner = true,
	Mantle = true,
})

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function EvadeHandler.new(stateMachine, coverHandler)
	local self = setmetatable({}, EvadeHandler)

	self._stateMachine = stateMachine
	self._coverHandler = coverHandler
	self._player = Players.LocalPlayer

	-- Evade state
	self._evadeSpeed = 0
	self._evadeDirection = nil :: Vector3?

	-- ExitCorner curva state
	self._isExitCornerCurve = false
	self._exitCornerTangent = nil :: Vector3?
	self._exitCornerNormal = nil :: Vector3?
	self._exitCornerElapsed = 0
	self._exitCornerDuration = 0

	-- Timer interno
	self._timer = 0
	self._timerCallback = nil :: (() -> ())?

	-- Cache de character refs (evita FindFirstChild cada frame)
	self._cachedCharacter = nil :: Model?
	self._cachedHumanoid = nil :: Humanoid?
	self._cachedHRP = nil :: BasePart?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Intenta manejar una acción de evade/mantle.
--- Retorna true si fue manejada, false si no.
function EvadeHandler:HandleAction(action: string, data: any?): boolean
	if not EVADE_ACTIONS[action] then
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

--- Actualiza el impulso decreciente de evade y timers cada frame.
function EvadeHandler:Update(dt: number)
	-- Timer de estados temporales
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

	-- Evade: impulso decreciente via AssemblyLinearVelocity
	if self._evadeDirection and self._evadeSpeed > 0 then
		-- Si el jugador encadenó a otro estado (Walking, Cover, RoadieRun, etc.),
		-- detener el impulso inmediatamente para que la nueva acción tome control.
		local currentState = self._stateMachine:GetCurrentState()
		if currentState ~= "Evading" and currentState ~= "ExitCorner" then
			self._evadeSpeed = 0
			self._evadeDirection = nil
			self._isExitCornerCurve = false
			self._exitCornerTangent = nil
			self._exitCornerNormal = nil
			-- Flush timer para evitar callbacks obsoletos
			if self._timerCallback then
				self._timer = 0
				self._timerCallback = nil
			end
			return
		end

		-- ExitCorner curva: interpolar dirección tangent → normal
		if self._isExitCornerCurve then
			self._exitCornerElapsed += dt
			local alpha = math.clamp(self._exitCornerElapsed / self._exitCornerDuration, 0, 1)
			-- Smoothstep: transición suave inicio→fin, bordea la esquina naturalmente
			local easedAlpha = alpha * alpha * (3 - 2 * alpha)
			local blended = self._exitCornerTangent * (1 - easedAlpha) + self._exitCornerNormal * easedAlpha
			if blended.Magnitude > Constants.ZERO_MAGNITUDE then
				self._evadeDirection = blended.Unit
			end
		end

		local hrp = self:_getCachedHRP()
		if hrp then
			self:_applyImpulseToHRP(hrp)
			self._evadeSpeed *= (1 - Constants.EVADE_DECELERATION * dt)
			if self._evadeSpeed < Constants.EVADE_MIN_SPEED then
				self._evadeSpeed = 0
			end
		end
	end
end

--- Retorna true si hay un impulso de evade activo.
function EvadeHandler:IsEvading(): boolean
	return self._evadeSpeed > 0
end

------------------------------------------------------------------------
-- ACTION HANDLERS
------------------------------------------------------------------------

EvadeHandler._handlers = {
	Evade = function(self, _data)
		self:_refreshCache()
		local hrp = self._cachedHRP
		local humanoid = self._cachedHumanoid
		if not hrp or not humanoid then
			return
		end

		-- NO Lock(): Evade es encadenable — el ActionResolver puede resolver
		-- Walking/Idle/RoadieRun/Evade/Cover durante la animación.
		-- EVADE_CHAIN_WINDOW (0.2s) del ActionResolver provee la ventana de compromiso mínima.

		-- Dirección: hacia donde camina, o forward si está quieto
		if humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD then
			self._evadeDirection = humanoid.MoveDirection.Unit
		else
			local look = hrp.CFrame.LookVector
			self._evadeDirection = Vector3.new(look.X, 0, look.Z).Unit
		end
		self._evadeSpeed = Constants.EVADE_IMPULSE_SPEED
		self:_applyImpulseToHRP(hrp)

		self:_startTimer(Constants.EVADE_DURATION, function()
			self._evadeSpeed = 0
			self._evadeDirection = nil
			-- Transición fluida: si hay input, ir directo a Walking sin detenerse
			if self._stateMachine:GetCurrentState() == "Evading" then
				local hum = self:_getCachedHumanoid()
				local isMoving = hum and hum.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD
				if isMoving then
					if not self._stateMachine:TransitionTo("Walking") then
						self._stateMachine:TransitionTo("Idle")
					end
				else
					self._stateMachine:TransitionTo("Idle")
				end
			end
		end)
	end,

	RollOutOfCover = function(self, _data)
		local hrp = self:_getCachedHRP()
		if not hrp then
			return
		end

		local coverNormal = self._coverHandler:GetNormal()
		self._coverHandler:ResetCover()

		-- NO Lock(): misma filosofía encadenable que Evade.

		-- Dirección: usar vector del input (CornerEvade) si presente,
		-- sino alejarse de la pared (cover normal) o backward como fallback
		if _data and _data.direction and typeof(_data.direction) == "Vector3" and _data.direction.Magnitude > 0.01 then
			local flat = Vector3.new(_data.direction.X, 0, _data.direction.Z)
			if flat.Magnitude > Constants.ZERO_MAGNITUDE then
				self._evadeDirection = flat.Unit
			else
				self._evadeDirection = Vector3.new(0, 0, -1)
			end
		elseif coverNormal then
			self._evadeDirection = Vector3.new(coverNormal.X, 0, coverNormal.Z).Unit
		else
			local look = hrp.CFrame.LookVector
			self._evadeDirection = Vector3.new(-look.X, 0, -look.Z).Unit
		end

		self._evadeSpeed = Constants.EVADE_IMPULSE_SPEED
		self:_applyImpulseToHRP(hrp)

		self:_startTimer(Constants.EVADE_DURATION, function()
			self._evadeSpeed = 0
			self._evadeDirection = nil
			if self._stateMachine:GetCurrentState() == "Evading" then
				local hum = self:_getCachedHumanoid()
				local isMoving = hum and hum.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD
				if isMoving then
					if not self._stateMachine:TransitionTo("Walking") then
						self._stateMachine:TransitionTo("Idle")
					end
				else
					self._stateMachine:TransitionTo("Idle")
				end
			end
		end)
	end,

	Mantle = function(self, _data)
		self._coverHandler:ResetCover()
		self._stateMachine:Lock()

		self:_startTimer(Constants.MANTLE_DURATION, function()
			self._stateMachine:Unlock()
			self._stateMachine:TransitionTo("Idle")
		end)
	end,

	--- CornerRollOut: salida direccional desde esquina exterior.
	--- Misma física que RollOutOfCover (impulso + decay) pero nombre propio
	--- para que el sistema de animaciones pueda diferenciarla.
	CornerRollOut = function(self, _data)
		local hrp = self:_getCachedHRP()
		if not hrp then
			return
		end

		-- Leer normal ANTES de ResetCover (ResetCover la establece a nil)
		local coverNormal = self._coverHandler:GetNormal()
		self._coverHandler:ResetCover()

		-- NO Lock(): encadenable.

		if _data and _data.direction and typeof(_data.direction) == "Vector3" and _data.direction.Magnitude > 0.01 then
			local flat = Vector3.new(_data.direction.X, 0, _data.direction.Z)
			if flat.Magnitude > Constants.ZERO_MAGNITUDE then
				self._evadeDirection = flat.Unit
			else
				self._evadeDirection = Vector3.new(0, 0, -1)
			end
		elseif coverNormal then
			self._evadeDirection = Vector3.new(coverNormal.X, 0, coverNormal.Z).Unit
		else
			local look = hrp.CFrame.LookVector
			self._evadeDirection = Vector3.new(-look.X, 0, -look.Z).Unit
		end

		self._evadeSpeed = Constants.EVADE_IMPULSE_SPEED
		self:_applyImpulseToHRP(hrp)

		self:_startTimer(Constants.EVADE_DURATION, function()
			self._evadeSpeed = 0
			self._evadeDirection = nil
			if self._stateMachine:GetCurrentState() == "Evading" then
				local hum = self:_getCachedHumanoid()
				local isMoving = hum and hum.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD
				if isMoving then
					if not self._stateMachine:TransitionTo("Walking") then
						self._stateMachine:TransitionTo("Idle")
					end
				else
					self._stateMachine:TransitionTo("Idle")
				end
			end
		end)
	end,

	--- ExitCorner: salida curva desde esquina exterior.
	--- Trayectoria que "abraza" la esquina: inicia lateral (coverTangent)
	--- y gradualmente rota hacia la coverNormal opuesta durante EXIT_CORNER_DURATION.
	--- Al terminar, transiciona a Idle; ActionResolver resuelve el siguiente estado
	--- en el frame siguiente basándose en los intents activos (Walking/RoadieRun).
	ExitCorner = function(self, _data)
		local hrp = self:_getCachedHRP()
		if not hrp then
			return
		end

		-- Leer normal y wallRight ANTES de ResetCover (ResetCover los establece a nil)
		local coverNormal = self._coverHandler:GetNormal()
		local wallRight = self._coverHandler:GetWallRight()
		self._coverHandler:ResetCover()

		-- NO Lock(): ExitCorner es encadenable — el ActionResolver puede resolver
		-- Walking/Idle/RoadieRun/Evade durante la curva para transición fluida.
		-- STATE_MIN_DURATION (0.1s) del SM provee la ventana de compromiso mínima.

		-- Determinar el tangente de salida: el lado de la esquina por donde sale
		if coverNormal and wallRight then
			-- Determinar dirección lateral: usar input o inferir del lado de la esquina
			local tangent = wallRight
			if
				_data
				and _data.direction
				and typeof(_data.direction) == "Vector3"
				and _data.direction.Magnitude > 0.01
			then
				-- Si el input apunta hacia wallLeft (dot negativo), invertir el tangente
				if _data.direction:Dot(wallRight) < 0 then
					tangent = -wallRight
				end
			end

			-- Configurar curva: tangent → normal durante EXIT_CORNER_DURATION
			local flatNormal = Vector3.new(coverNormal.X, 0, coverNormal.Z)
			if flatNormal.Magnitude > Constants.ZERO_MAGNITUDE then
				flatNormal = -flatNormal.Unit
			else
				flatNormal = Vector3.new(0, 0, -1)
			end

			self._isExitCornerCurve = true
			self._exitCornerTangent = Vector3.new(tangent.X, 0, tangent.Z).Unit
			self._exitCornerNormal = flatNormal
			self._exitCornerElapsed = 0
			self._exitCornerDuration = Constants.EXIT_CORNER_DURATION

			-- Dirección inicial: diagonal (tangente + componente forward hacia la normal)
			-- EXIT_CORNER_FORWARD_BIAS controla cuánto "forward" tiene desde el inicio
			local initialDir = self._exitCornerTangent * (1 - Constants.EXIT_CORNER_FORWARD_BIAS)
				+ self._exitCornerNormal * Constants.EXIT_CORNER_FORWARD_BIAS
			if initialDir.Magnitude > Constants.ZERO_MAGNITUDE then
				self._evadeDirection = initialDir.Unit
			else
				self._evadeDirection = self._exitCornerTangent
			end
		else
			-- Fallback sin curva: comportamiento recto original
			self._isExitCornerCurve = false
			if
				_data
				and _data.direction
				and typeof(_data.direction) == "Vector3"
				and _data.direction.Magnitude > 0.01
			then
				local flat = Vector3.new(_data.direction.X, 0, _data.direction.Z)
				if flat.Magnitude > Constants.ZERO_MAGNITUDE then
					self._evadeDirection = flat.Unit
				else
					self._evadeDirection = Vector3.new(0, 0, -1)
				end
			elseif coverNormal then
				self._evadeDirection = Vector3.new(coverNormal.X, 0, coverNormal.Z).Unit
			else
				local look = hrp.CFrame.LookVector
				self._evadeDirection = Vector3.new(-look.X, 0, -look.Z).Unit
			end
		end

		self._evadeSpeed = Constants.EVADE_IMPULSE_SPEED
		self:_applyImpulseToHRP(hrp)

		self:_startTimer(Constants.EXIT_CORNER_DURATION, function()
			self._evadeSpeed = 0
			self._evadeDirection = nil
			self._isExitCornerCurve = false
			self._exitCornerTangent = nil
			self._exitCornerNormal = nil
			-- Transición fluida: si hay input de movimiento, ir directo a Walking
			-- (sin pasar por Idle) para que el impulso se funda con la caminata
			if self._stateMachine:GetCurrentState() == "ExitCorner" then
				local humanoid = self:_getCachedHumanoid()
				local isMoving = humanoid and humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD
				if isMoving then
					if not self._stateMachine:TransitionTo("Walking") then
						self._stateMachine:TransitionTo("Idle")
					end
				else
					self._stateMachine:TransitionTo("Idle")
				end
			end
		end)
	end,
}

------------------------------------------------------------------------
-- INTERNAL: Timer
------------------------------------------------------------------------

function EvadeHandler:_startTimer(duration: number, callback: () -> ())
	-- Flush del timer anterior: garantiza que el SM nunca quede bloqueado
	-- si se lanza una nueva acción antes de que expire la primera.
	if self._timerCallback then
		local flush = self._timerCallback
		self._timer = 0
		self._timerCallback = nil
		flush()
	end
	self._timer = duration
	self._timerCallback = callback
end

--- Aplica el impulso de evade actual al HumanoidRootPart.
--- Precondición: self._evadeDirection ~= nil, self._evadeSpeed > 0
function EvadeHandler:_applyImpulseToHRP(hrp: BasePart)
	hrp.AssemblyLinearVelocity = Vector3.new(
		self._evadeDirection.X * self._evadeSpeed,
		hrp.AssemblyLinearVelocity.Y,
		self._evadeDirection.Z * self._evadeSpeed
	)
end

--- Refresca la cache de character/humanoid/hrp si el character cambió.
function EvadeHandler:_refreshCache()
	local character = self._player.Character
	if character ~= self._cachedCharacter then
		self._cachedCharacter = character
		self._cachedHumanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
		self._cachedHRP = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
end

--- Obtiene el HRP con cache refresh.
function EvadeHandler:_getCachedHRP(): BasePart?
	self:_refreshCache()
	return self._cachedHRP
end

--- Obtiene el Humanoid con cache refresh.
function EvadeHandler:_getCachedHumanoid(): Humanoid?
	self:_refreshCache()
	return self._cachedHumanoid
end

return EvadeHandler
