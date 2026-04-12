--[[
	HealthObserver.luau
	═══════════════════════════════════════════════════════════════
	Observador de salud del lado del cliente.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	- Escuchar el atributo "LifeState" del Character (replicado por el server)
	- Traducir cambios a transiciones del StateMachine local:
	    "Alive" → ForceState("Idle")
	    "DBNO"  → ForceState("DBNO")
	    "Dead"  → ForceState("Death")
	- Manejar respawn: re-bind al nuevo Character, resetear estado
	- Exponer señal Respawned para que otros sistemas se reseteen

	Filosofía:
	- El cliente NUNCA decide HP, DBNO o muerte — solo reacciona.
	- Usa ForceState() porque estas transiciones son autoritativas del servidor
	  y deben ignorar la validación normal de la StateMachine.
	- Safety fallback: Humanoid.Died como respaldo si el atributo no llega.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal"))

local HealthObserver = {}
HealthObserver.__index = HealthObserver

function HealthObserver.new(stateMachine)
	local self = setmetatable({}, HealthObserver)
	self._stateMachine = stateMachine
	self._characterConnections = {} :: { RBXScriptConnection }
	self._permanentConnections = {} :: { RBXScriptConnection }

	--- Señal pública: se dispara cuando el jugador respawnea.
	--- Otros sistemas (MovementController, CoverHandler, etc.) pueden
	--- conectarse para resetear su estado interno.
	self.Respawned = Signal.new()

	return self
end

function HealthObserver:Init()
	-- No side-effects
end

function HealthObserver:Start()
	local player = Players.LocalPlayer

	-- Bind al character actual (si ya existe)
	if player.Character then
		self:_bindCharacter(player.Character)
	end

	-- Escuchar futuros spawns/respawns (conexión permanente, NO se limpia en _cleanCharacterConnections)
	table.insert(
		self._permanentConnections,
		player.CharacterAdded:Connect(function(character)
			self:_bindCharacter(character)
			-- Respawn: resetear StateMachine a Idle y notificar sistemas
			self._stateMachine:ForceState("Idle")
			self.Respawned:Fire()
		end)
	)
end

------------------------------------------------------------------------
-- PRIVATE: Bind to a character's LifeState attribute
------------------------------------------------------------------------

function HealthObserver:_bindCharacter(character: Model)
	-- Limpiar conexiones del character anterior
	self:_cleanCharacterConnections()

	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid then
		return
	end

	-- Leer estado inicial (puede que el atributo ya esté seteado)
	local initialState = character:GetAttribute("LifeState")
	if initialState then
		self:_applyLifeState(initialState)
	end

	-- Escuchar cambios del atributo LifeState (replicado por CombatService)
	table.insert(
		self._characterConnections,
		character:GetAttributeChangedSignal("LifeState"):Connect(function()
			local lifeState = character:GetAttribute("LifeState")
			if lifeState then
				self:_applyLifeState(lifeState)
			end
		end)
	)

	-- Safety fallback: Humanoid.Died por si el atributo no llegó a tiempo
	table.insert(
		self._characterConnections,
		humanoid.Died:Connect(function()
			local currentState = self._stateMachine:GetCurrentState()
			if currentState ~= "Death" then
				self._stateMachine:ForceState("Death")
			end
		end)
	)
end

------------------------------------------------------------------------
-- PRIVATE: Translate LifeState → StateMachine transition
------------------------------------------------------------------------

function HealthObserver:_applyLifeState(lifeState: string)
	local currentState = self._stateMachine:GetCurrentState()

	if lifeState == "DBNO" then
		if currentState ~= "DBNO" then
			self._stateMachine:ForceState("DBNO")
		end
	elseif lifeState == "Dead" then
		if currentState ~= "Death" then
			self._stateMachine:ForceState("Death")
		end
	elseif lifeState == "Alive" then
		if currentState == "Death" or currentState == "DBNO" or currentState == "Lobby" then
			self._stateMachine:ForceState("Idle")
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Cleanup
------------------------------------------------------------------------

function HealthObserver:_cleanCharacterConnections()
	for _, conn in self._characterConnections do
		conn:Disconnect()
	end
	self._characterConnections = {}
end

function HealthObserver:Destroy()
	self:_cleanCharacterConnections()
	for _, conn in self._permanentConnections do
		conn:Disconnect()
	end
	self._permanentConnections = {}
end

return HealthObserver
