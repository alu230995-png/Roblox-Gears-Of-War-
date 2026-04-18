--[[
	DBNOHandler.luau
	═══════════════════════════════════════════════════════════════
	Client-side DBNO (Down But Not Out) handler.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	- Exponer hooks de UI para countdown y puntos de revive
	- Enviar solicitud de auto-revive al servidor via RemoteEvent
	- Leer atributos replicados (DBNOTimeRemaining, DBNORevivePoints)

	Hooks de UI (Signals públicas):
	  - CountdownUpdated(timeRemaining: number, maxTime: number)
	  - ReviveProgressUpdated(points: number, threshold: number)
	  - DBNOStarted()
	  - DBNOEnded(reason: string) — "Revived" | "Died"

	El servidor es AUTORITATIVO: el cliente solo lee atributos y envía
	solicitudes de auto-revive. Nunca modifica HP, puntos ni LifeState.

	Capa: Handler de acción (Capa 4)
	Depende de: StateMachine, ActionExecuted signal
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Signal = require(Shared:WaitForChild("Signal"))

local DBNOHandler = {}
DBNOHandler.__index = DBNOHandler

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function DBNOHandler.new(stateMachine, actionExecutedSignal)
	local self = setmetatable({}, DBNOHandler)

	self._stateMachine = stateMachine
	self._actionExecutedSignal = actionExecutedSignal
	self._connections = {} :: { any }
	self._attrConnections = {} :: { RBXScriptConnection }
	self._selfReviveRemote = nil :: RemoteEvent?
	self._isInDBNO = false
	self._lastReviveAttempt = 0

	--- Hook: countdown del DBNO actualizado.
	--- Payload: (timeRemaining: number, maxTime: number)
	self.CountdownUpdated = Signal.new()

	--- Hook: progreso de auto-revive actualizado.
	--- Payload: (points: number, threshold: number)
	self.ReviveProgressUpdated = Signal.new()

	--- Hook: jugador entró en DBNO.
	self.DBNOStarted = Signal.new()

	--- Hook: jugador salió de DBNO.
	--- Payload: (reason: string) — "Revived" | "Died"
	self.DBNOEnded = Signal.new()

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function DBNOHandler:Init()
	-- Sin side-effects
end

function DBNOHandler:Start()
	-- Buscar RemoteEvent (creado por DBNOService en el servidor)
	task.spawn(function()
		local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if remotesFolder then
			self._selfReviveRemote = remotesFolder:WaitForChild("DBNOSelfRevive", 10) :: RemoteEvent?
		end
	end)

	-- Escuchar cambios de estado
	table.insert(
		self._connections,
		self._stateMachine.StateChanged:Connect(function(newState: string, oldState: string)
			if newState == "DBNO" then
				self:_onEnterDBNO()
			elseif oldState == "DBNO" then
				self:_onExitDBNO(newState)
			end
		end)
	)

	-- Escuchar acción SelfReviveAttempt desde MovementController
	table.insert(
		self._connections,
		self._actionExecutedSignal:Connect(function(action: string)
			if action == "SelfReviveAttempt" and self._isInDBNO then
				self:_sendReviveAttempt()
			end
		end)
	)
end

function DBNOHandler:Destroy()
	self:_cleanAttributeConnections()
	for _, conn in self._connections do
		if type(conn) == "table" and type(conn.Disconnect) == "function" then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)
	self.CountdownUpdated:Destroy()
	self.ReviveProgressUpdated:Destroy()
	self.DBNOStarted:Destroy()
	self.DBNOEnded:Destroy()
end

------------------------------------------------------------------------
-- PRIVATE: State transitions
------------------------------------------------------------------------

function DBNOHandler:_onEnterDBNO()
	self._isInDBNO = true
	self._lastReviveAttempt = 0
	self.DBNOStarted:Fire()

	local player = Players.LocalPlayer
	local character = player.Character
	if not character then
		return
	end

	-- Bind attribute listeners para UI hooks
	self:_cleanAttributeConnections()

	table.insert(
		self._attrConnections,
		character:GetAttributeChangedSignal("DBNOTimeRemaining"):Connect(function()
			local remaining = character:GetAttribute("DBNOTimeRemaining") or 0
			self.CountdownUpdated:Fire(remaining, Constants.DBNO_COUNTDOWN_TIME)
		end)
	)

	table.insert(
		self._attrConnections,
		character:GetAttributeChangedSignal("DBNORevivePoints"):Connect(function()
			local points = character:GetAttribute("DBNORevivePoints") or 0
			self.ReviveProgressUpdated:Fire(points, Constants.DBNO_REVIVE_THRESHOLD)
		end)
	)

	-- Emitir valores iniciales
	local initialRemaining = character:GetAttribute("DBNOTimeRemaining") or Constants.DBNO_COUNTDOWN_TIME
	self.CountdownUpdated:Fire(initialRemaining, Constants.DBNO_COUNTDOWN_TIME)
	self.ReviveProgressUpdated:Fire(0, Constants.DBNO_REVIVE_THRESHOLD)
end

function DBNOHandler:_onExitDBNO(newState: string)
	self._isInDBNO = false
	self:_cleanAttributeConnections()

	local reason = (newState == "Death") and "Died" or "Revived"
	self.DBNOEnded:Fire(reason)
end

------------------------------------------------------------------------
-- PRIVATE: Self-revive request
------------------------------------------------------------------------

function DBNOHandler:_sendReviveAttempt()
	-- Cooldown client-side para prevenir spam de RemoteEvents
	local now = os.clock()
	if now - self._lastReviveAttempt < Constants.DBNO_REVIVE_COOLDOWN then
		return
	end
	self._lastReviveAttempt = now

	if self._selfReviveRemote then
		self._selfReviveRemote:FireServer()
	end
end

------------------------------------------------------------------------
-- PRIVATE: Cleanup
------------------------------------------------------------------------

function DBNOHandler:_cleanAttributeConnections()
	for _, conn in self._attrConnections do
		conn:Disconnect()
	end
	table.clear(self._attrConnections)
end

return DBNOHandler
