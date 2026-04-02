--[[
	MovementController.luau
	═══════════════════════════════════════════════════════════════
	Ejecutor de Acciones Resueltas
	═══════════════════════════════════════════════════════════════
	
	Recibe la acción resuelta por ActionResolver y la ejecuta:
	- Ajusta WalkSpeed según el estado
	- Hace CFrame snap para cover
	- Controla rotación del personaje
	- Gestiona timers de estados temporales (Evade duration, etc.)
	
	NOTA: Esto es predicción del cliente. Las acciones que afectan
	gameplay (daño, inventario, HP) se validan en el servidor.
]]

local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local MovementController = {}
MovementController.__index = MovementController

function MovementController.new(stateMachine)
	local self = setmetatable({}, MovementController)

	self._stateMachine = stateMachine
	self._player = Players.LocalPlayer

	-- Cover state
	self._coverNormal = nil :: Vector3?
	self._coverPosition = nil :: Vector3?
	self._isSnappingToCover = false

	-- Timer para estados temporales
	self._stateTimer = 0
	self._stateTimerCallback = nil :: (() -> ())?

	-- Evade: impulso decreciente
	self._evadeSpeed = 0
	self._evadeDirection = nil :: Vector3?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Ejecuta una acción resuelta por ActionResolver.
--- @param action string — nombre de la acción
--- @param targetState string? — estado destino (o nil si no hay transición)
--- @param data any? — datos adicionales
function MovementController:ExecuteAction(action: string, targetState: string?, data: any?)
	if action == "NoAction" then
		return
	end

	-- Transicionar si hay target state
	if targetState then
		local success = self._stateMachine:TransitionTo(targetState)
		if not success then
			-- Si la transición falla, intentar ForceState para estados críticos
			if targetState == "DBNO" then
				self._stateMachine:ForceState(targetState)
			else
				return -- No se pudo transicionar, abortar acción
			end
		end
	end

	-- Ejecutar lógica específica de la acción
	local handler = self._actionHandlers[action]
	if handler then
		handler(self, data)
	end

	-- Aplicar velocidad al Humanoid según el nuevo estado
	self:_applyMovementSpeed()
end

--- Update cada frame. Maneja timers y lógica continua.
function MovementController:Update(dt: number)
	-- Timer de estados temporales
	if self._stateTimer > 0 then
		self._stateTimer -= dt
		if self._stateTimer <= 0 then
			self._stateTimer = 0
			if self._stateTimerCallback then
				self._stateTimerCallback()
				self._stateTimerCallback = nil
			end
		end
	end

	-- RoadieRun: velocidad constante hacia el input o look vector (auto-forward GoW)
	-- Se escribe AssemblyLinearVelocity directamente para no depender de humanoid:Move,
	-- que puede ser sobreescrito por el PlayerModule en el mismo Heartbeat.
	local currentState = self._stateMachine:GetCurrentState()
	if currentState == "RoadieRun" then
		local character = self._player.Character
		local humanoid = character and character:FindFirstChild("Humanoid") :: Humanoid?
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if humanoid and hrp then
			local moveDir = humanoid.MoveDirection
			local targetDir: Vector3
			if moveDir.Magnitude > 0.1 then
				targetDir = Vector3.new(moveDir.X, 0, moveDir.Z).Unit
			else
				local look = hrp.CFrame.LookVector
				targetDir = Vector3.new(look.X, 0, look.Z).Unit
			end
			hrp.AssemblyLinearVelocity = Vector3.new(
				targetDir.X * Constants.ROADIE_RUN_SPEED,
				hrp.AssemblyLinearVelocity.Y,
				targetDir.Z * Constants.ROADIE_RUN_SPEED
			)
		end
	end

	-- Evade: impulso decreciente via AssemblyLinearVelocity
	-- Estado 'Evading' tiene WalkSpeed=0 → el Humanoid no genera fuerzas horizontales,
	-- así que escribir la velocidad directamente no tiene contrafuerza.
	if self._evadeDirection and self._evadeSpeed > 0 then
		local character = self._player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			hrp.AssemblyLinearVelocity = Vector3.new(
				self._evadeDirection.X * self._evadeSpeed,
				hrp.AssemblyLinearVelocity.Y,
				self._evadeDirection.Z * self._evadeSpeed
			)
			self._evadeSpeed *= (1 - Constants.EVADE_DECELERATION * dt)
			if self._evadeSpeed < 0.5 then
				self._evadeSpeed = 0
			end
		end
	end

	-- Cover snap continuo
	if self._isSnappingToCover then
		self:_updateCoverSnap(dt)
	end

	-- Rotación del personaje
	self:_updateRotation(dt)
end

------------------------------------------------------------------------
-- ACTION HANDLERS
------------------------------------------------------------------------

MovementController._actionHandlers = {
	-- MOVIMIENTO
	StartWalking = function(self, _data)
		-- Walking aplica velocidad automáticamente
	end,

	StopWalking = function(self, _data)
		-- Idle aplica velocidad 0
	end,

	-- ROADIE RUN
	StartRoadieRun = function(self, _data)
		-- La cámara y FOV se manejarán en fase de cámara
		-- Por ahora solo la velocidad (gestionada por _applyMovementSpeed)
	end,

	StopRoadieRun = function(self, _data)
		-- Transición ya hecha, velocidad aplicada
	end,

	-- COVER
	EnterCover = function(self, data)
		if data then
			self._coverNormal = data.coverNormal
			self._coverPosition = data.coverPos
		end
		self._isSnappingToCover = true
	end,

	SlideIntoCover = function(self, data)
		-- Slide desde RoadieRun → la entrada más rápida
		if data then
			self._coverNormal = data.coverNormal
			self._coverPosition = data.coverPos
		end
		self._isSnappingToCover = true

		-- Timer: CoverSlide dura poco, luego transiciona a CoverIdle
		self:_startStateTimer(0.3, function()
			self._stateMachine:TransitionTo("CoverIdle")
			self:_applyMovementSpeed()
		end)
	end,

	ExitCover = function(self, _data)
		self._isSnappingToCover = false
		self._coverNormal = nil
		self._coverPosition = nil
	end,

	SwatTurn = function(self, _data)
		-- Timer: swat turn es un sprint corto expuesto
		self:_startStateTimer(0.4, function()
			self._stateMachine:TransitionTo("CoverIdle")
			self:_applyMovementSpeed()
		end)
	end,

	PopUpAim = function(self, _data)
		-- El personaje se levanta/asoma para apuntar
		-- Animaciones se manejarán en fase de animación
	end,

	ReturnToCover = function(self, _data)
		-- Volver a CoverIdle desde CoverAim
	end,

	BlindFire = function(self, _data)
		-- Disparar sin asomarse (impreciso, protegido)
	end,

	StopBlindFire = function(self, _data)
		-- Volver a CoverIdle
	end,

	-- EVADE
	Evade = function(self, _data)
		self._stateMachine:Lock()

		local character = self._player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChild("Humanoid") :: Humanoid?
		if hrp and humanoid then
			-- Dirección: hacia donde camina, o forward si está quieto
			if humanoid.MoveDirection.Magnitude > 0.1 then
				self._evadeDirection = humanoid.MoveDirection.Unit
			else
				local look = hrp.CFrame.LookVector
				self._evadeDirection = Vector3.new(look.X, 0, look.Z).Unit
			end
			self._evadeSpeed = Constants.EVADE_IMPULSE_SPEED
			-- Impulso inmediato — no esperar al primer tick de Update
			hrp.AssemblyLinearVelocity = Vector3.new(
				self._evadeDirection.X * self._evadeSpeed,
				hrp.AssemblyLinearVelocity.Y,
				self._evadeDirection.Z * self._evadeSpeed
			)
		end

		self:_startStateTimer(Constants.EVADE_DURATION, function()
			self._evadeSpeed = 0
			self._evadeDirection = nil
			self._stateMachine:Unlock()
			self._stateMachine:TransitionTo("Idle")
			self:_applyMovementSpeed()
		end)
	end,

	RollOutOfCover = function(self, _data)
		self._isSnappingToCover = false

		-- Dirección: alejarse de la pared (cover normal)
		if self._coverNormal then
			self._evadeDirection = Vector3.new(self._coverNormal.X, 0, self._coverNormal.Z).Unit
		else
			local character = self._player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				local look = hrp.CFrame.LookVector
				self._evadeDirection = Vector3.new(-look.X, 0, -look.Z).Unit
			end
		end
		self._evadeSpeed = Constants.EVADE_IMPULSE_SPEED
		-- Impulso inmediato al salir de cover
		local _char = self._player.Character
		local _hrp = _char and _char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if _hrp and self._evadeDirection then
			_hrp.AssemblyLinearVelocity = Vector3.new(
				self._evadeDirection.X * self._evadeSpeed,
				_hrp.AssemblyLinearVelocity.Y,
				self._evadeDirection.Z * self._evadeSpeed
			)
		end

		self._coverNormal = nil
		self._coverPosition = nil

		self._stateMachine:Lock()
		self:_startStateTimer(Constants.EVADE_DURATION, function()
			self._evadeSpeed = 0
			self._evadeDirection = nil
			self._stateMachine:Unlock()
			self._stateMachine:TransitionTo("Idle")
			self:_applyMovementSpeed()
		end)
	end,

	-- MANTLE / VAULT
	Mantle = function(self, _data)
		self._isSnappingToCover = false
		self._stateMachine:Lock()

		-- Timer: animación de mantle
		self:_startStateTimer(0.6, function()
			self._stateMachine:Unlock()
			self._stateMachine:TransitionTo("Idle")
			self:_applyMovementSpeed()
		end)
	end,

	Vault = function(self, _data)
		self._isSnappingToCover = false
		self._coverNormal = nil
		self._coverPosition = nil

		self._stateMachine:Lock()
		self:_startStateTimer(0.5, function()
			self._stateMachine:Unlock()
			self._stateMachine:TransitionTo("Idle")
			self:_applyMovementSpeed()
		end)
	end,

	-- COMBATE
	StartAim = function(self, _data)
		-- Reducir velocidad (aplicada por _applyMovementSpeed)
	end,

	StopAim = function(self, _data)
		-- Restaurar velocidad
	end,

	Shoot = function(self, _data)
		-- Disparo: RemoteEvent al servidor (futuras fases)
	end,

	StopShoot = function(self, _data)
		-- Dejar de disparar
	end,

	Reload = function(self, _data)
		-- Iniciar recarga — la barra de active reload es UI (futuras fases)
	end,

	ActiveReload = function(self, _data)
		-- Active reload exitoso — bonus damage (futuras fases)
	end,

	Melee = function(self, _data)
		-- Golpe melee (futuras fases)
	end,

	Chainsaw = function(self, _data)
		-- Chainsaw bayonet (futuras fases)
	end,

	Interact = function(self, _data)
		-- Interacción contextual: curb stomp, rescatar, activar (futuras fases)
	end,

	SwapWeapon = function(self, _data)
		-- Cambiar arma (futuras fases)
	end,

	-- COVER MOVEMENT
	CoverSlideLeft = function(self, _data)
		-- Deslizar a la izquierda en cover
	end,

	CoverSlideRight = function(self, _data)
		-- Deslizar a la derecha en cover
	end,

	PeekCornerLeft = function(self, _data)
		-- Asomarse por esquina izquierda
	end,

	PeekCornerRight = function(self, _data)
		-- Asomarse por esquina derecha
	end,

	-- DBNO
	Crawl = function(self, _data)
		-- Arrastrarse en DBNO
	end,
}

------------------------------------------------------------------------
-- INTERNAL: Movement Speed
------------------------------------------------------------------------

function MovementController:_applyMovementSpeed()
	local character = self._player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
	if not humanoid then
		return
	end

	local state = self._stateMachine:GetCurrentState()

	-- Tabla de velocidades por estado
	local speedMap = {
		Idle = 0,
		Walking = Constants.WALK_SPEED,
		RoadieRun = Constants.ROADIE_RUN_SPEED,
		CoverSlide = Constants.COVER_SLIDE_SPEED,
		Evading = 0, -- Controlado por impulso decreciente en Update
		CoverIdle = Constants.WALK_SPEED * 0.5,
		CoverAim = 0,
		CoverBlindFire = 0,
		Mantling = 0,
		DBNO = Constants.WALK_SPEED * 0.2,
		Executing = 0,
		Aiming = Constants.WALK_SPEED * 0.6,
		Firing = Constants.WALK_SPEED * 0.5,
		Reloading = Constants.WALK_SPEED * 0.8,
		ActiveReloading = Constants.WALK_SPEED * 0.8,
	}

	humanoid.WalkSpeed = speedMap[state] or Constants.WALK_SPEED
end

------------------------------------------------------------------------
-- INTERNAL: Cover Snap
------------------------------------------------------------------------

function MovementController:_updateCoverSnap(dt: number)
	if not self._coverPosition or not self._coverNormal then
		self._isSnappingToCover = false
		return
	end

	local character = self._player.Character
	if not character then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Calcular posición objetivo: offset desde la pared
	local offsetDistance = 2.5 -- studs de separación del personaje a la pared
	local targetPos = self._coverPosition + self._coverNormal * offsetDistance

	-- Solo snap horizontal (mantener Y actual)
	targetPos = Vector3.new(targetPos.X, hrp.Position.Y, targetPos.Z)

	-- Interpolar hacia la posición
	local currentPos = hrp.Position
	local diff = targetPos - currentPos
	local distance = diff.Magnitude

	if distance < 0.1 then
		-- Ya llegamos, mantener posición
		self._isSnappingToCover = false
		return
	end

	-- Mover hacia el cover con velocidad de snap
	local moveStep = math.min(Constants.COVER_SNAP_SPEED * dt, distance)
	local newPos = currentPos + diff.Unit * moveStep
	hrp.CFrame = CFrame.new(newPos) * CFrame.Angles(0, math.atan2(-self._coverNormal.X, -self._coverNormal.Z), 0)
end

------------------------------------------------------------------------
-- INTERNAL: Rotación
------------------------------------------------------------------------

function MovementController:_updateRotation(dt: number)
	local character = self._player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then
		return
	end

	local state = self._stateMachine:GetCurrentState()

	-- En cover: mirar paralelo a la pared
	if (state == "CoverIdle" or state == "CoverBlindFire") and self._coverNormal then
		-- Ya rotado por cover snap
		return
	end

	-- En CoverAim: mirar hacia donde apunta el mouse/camera
	if state == "CoverAim" or state == "Aiming" or state == "Firing" then
		-- La rotación hacia el mouse se implementará con la cámara
		return
	end

	-- En estados normales: rotar hacia la dirección de movimiento
	if humanoid.MoveDirection.Magnitude > 0.1 then
		local targetCFrame = CFrame.lookAt(hrp.Position, hrp.Position + humanoid.MoveDirection)
		hrp.CFrame = hrp.CFrame:Lerp(targetCFrame, math.min(10 * dt, 1))
	end
end

------------------------------------------------------------------------
-- INTERNAL: State Timer
------------------------------------------------------------------------

function MovementController:_startStateTimer(duration: number, callback: () -> ())
	self._stateTimer = duration
	self._stateTimerCallback = callback
end

return MovementController
