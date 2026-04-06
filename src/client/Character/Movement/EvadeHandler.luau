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

local EVADE_ACTIONS: { [string]: boolean } = {
	Evade = true,
	RollOutOfCover = true,
	Mantle = true,
	Vault = true,
}

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

	-- Timer interno
	self._timer = 0
	self._timerCallback = nil :: (() -> ())?

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
	if handler then
		handler(self, data)
	end
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
		local character = self._player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			hrp.AssemblyLinearVelocity = Vector3.new(
				self._evadeDirection.X * self._evadeSpeed,
				hrp.AssemblyLinearVelocity.Y,
				self._evadeDirection.Z * self._evadeSpeed
			)
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
	self._stateMachine:Lock()

	local character = self._player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChild("Humanoid") :: Humanoid?
	if hrp and humanoid then
		-- Dirección: hacia donde camina, o forward si está quieto
		if humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD then
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

	self:_startTimer(Constants.EVADE_DURATION, function()
		self._evadeSpeed = 0
		self._evadeDirection = nil
		self._stateMachine:Unlock()
		self._stateMachine:TransitionTo("Idle")
	end)
	end,

	RollOutOfCover = function(self, _data)
	-- Limpiar estado de cover antes del roll
	local coverNormal = self._coverHandler:GetNormal()
	self._coverHandler:ResetCover()

	-- Dirección: alejarse de la pared (cover normal)
	if coverNormal then
		self._evadeDirection = Vector3.new(coverNormal.X, 0, coverNormal.Z).Unit
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
	local character = self._player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp and self._evadeDirection then
		hrp.AssemblyLinearVelocity = Vector3.new(
			self._evadeDirection.X * self._evadeSpeed,
			hrp.AssemblyLinearVelocity.Y,
			self._evadeDirection.Z * self._evadeSpeed
		)
	end

	self._stateMachine:Lock()
	self:_startTimer(Constants.EVADE_DURATION, function()
		self._evadeSpeed = 0
		self._evadeDirection = nil
		self._stateMachine:Unlock()
		self._stateMachine:TransitionTo("Idle")
	end)
	end,

	Mantle = function(self, _data)
	self._coverHandler:ResetCover()
	self._stateMachine:Lock()

	-- Timer: animación de mantle
	self:_startTimer(Constants.MANTLE_DURATION, function()
		self._stateMachine:Unlock()
		self._stateMachine:TransitionTo("Idle")
	end)
	end,

	Vault = function(self, _data)
	self._coverHandler:ResetCover()
	self._stateMachine:Lock()

		-- Timer: animación de vault (más corto que mantle)
		self:_startTimer(Constants.VAULT_DURATION, function()
			self._stateMachine:Unlock()
			self._stateMachine:TransitionTo("Idle")
		end)
	end,
}

------------------------------------------------------------------------
-- INTERNAL: Timer
------------------------------------------------------------------------

function EvadeHandler:_startTimer(duration: number, callback: () -> ())
	self._timer = duration
	self._timerCallback = callback
end

return EvadeHandler
