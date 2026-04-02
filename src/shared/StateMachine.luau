--[[
	StateMachine.luau
	State Machine genérica con validación de transiciones.
	
	Patrón: State Machine finita con callbacks de entrada/salida.
	Uso principal: manejar el estado del jugador (Idle → Walking → RoadieRun → Cover, etc.)
	
	Diseño:
	- Cada estado tiene callbacks OnEnter y OnExit opcionales.
	- Las transiciones se validan contra una tabla de transiciones válidas.
	- Soporte para "estado mínimo" — tiempo mínimo antes de poder cambiar.
	- Historial del último estado para lógica de contexto.
]]

local Constants = require(script.Parent.Constants)

local StateMachine = {}
StateMachine.__index = StateMachine

export type StateCallbacks = {
	OnEnter: ((oldState: string) -> ())?,
	OnExit: ((newState: string) -> ())?,
	OnUpdate: ((dt: number) -> ())?,
}

--- Crea una nueva StateMachine.
--- @param initialState string — Estado inicial.
--- @param transitions {[string]: {string}} — Tabla de transiciones válidas.
--- @return StateMachine
function StateMachine.new(initialState: string, transitions: { [string]: { string } })
	local self = setmetatable({}, StateMachine)

	self._currentState = initialState
	self._previousState = nil :: string?
	self._transitions = transitions
	self._stateCallbacks = {} :: { [string]: StateCallbacks }
	self._stateEnteredAt = os.clock()
	self._locked = false

	return self
end

--- Registra callbacks para un estado.
function StateMachine:RegisterState(stateName: string, callbacks: StateCallbacks)
	self._stateCallbacks[stateName] = callbacks
end

--- Intenta transicionar a un nuevo estado.
--- Retorna true si la transición fue exitosa.
function StateMachine:TransitionTo(newState: string): boolean
	if self._locked then
		return false
	end

	if newState == self._currentState then
		return false
	end

	-- Verificar tiempo mínimo en estado actual
	local elapsed = os.clock() - self._stateEnteredAt
	if elapsed < Constants.STATE_MIN_DURATION then
		return false
	end

	-- Verificar transición válida
	local validTargets = self._transitions[self._currentState]
	if not validTargets then
		warn(`[StateMachine] No hay transiciones definidas para: {self._currentState}`)
		return false
	end

	local isValid = false
	for _, target in validTargets do
		if target == newState then
			isValid = true
			break
		end
	end

	if not isValid then
		return false
	end

	-- Ejecutar transición
	local oldState = self._currentState

	-- OnExit del estado anterior
	local oldCallbacks = self._stateCallbacks[oldState]
	if oldCallbacks and oldCallbacks.OnExit then
		oldCallbacks.OnExit(newState)
	end

	-- Cambiar estado
	self._previousState = oldState
	self._currentState = newState
	self._stateEnteredAt = os.clock()

	-- OnEnter del nuevo estado
	local newCallbacks = self._stateCallbacks[newState]
	if newCallbacks and newCallbacks.OnEnter then
		newCallbacks.OnEnter(oldState)
	end

	return true
end

--- Fuerza un cambio de estado sin validar transiciones.
--- Usar solo para DBNO u otros estados forzados por el servidor.
function StateMachine:ForceState(newState: string)
	local oldState = self._currentState

	local oldCallbacks = self._stateCallbacks[oldState]
	if oldCallbacks and oldCallbacks.OnExit then
		oldCallbacks.OnExit(newState)
	end

	self._previousState = oldState
	self._currentState = newState
	self._stateEnteredAt = os.clock()

	local newCallbacks = self._stateCallbacks[newState]
	if newCallbacks and newCallbacks.OnEnter then
		newCallbacks.OnEnter(oldState)
	end
end

--- Llama el OnUpdate del estado actual. Llamar cada frame desde RenderStepped o Heartbeat.
function StateMachine:Update(dt: number)
	local callbacks = self._stateCallbacks[self._currentState]
	if callbacks and callbacks.OnUpdate then
		callbacks.OnUpdate(dt)
	end
end

--- Bloquea la state machine (no permite transiciones).
function StateMachine:Lock()
	self._locked = true
end

--- Desbloquea la state machine.
function StateMachine:Unlock()
	self._locked = false
end

--- Retorna el estado actual.
function StateMachine:GetCurrentState(): string
	return self._currentState
end

--- Retorna el estado anterior.
function StateMachine:GetPreviousState(): string?
	return self._previousState
end

--- Retorna cuánto tiempo lleva en el estado actual (segundos).
function StateMachine:GetTimeInState(): number
	return os.clock() - self._stateEnteredAt
end

--- Verifica si una transición directa es posible.
function StateMachine:CanTransitionTo(targetState: string): boolean
	if self._locked then
		return false
	end

	local validTargets = self._transitions[self._currentState]
	if not validTargets then
		return false
	end

	for _, target in validTargets do
		if target == targetState then
			return true
		end
	end

	return false
end

return StateMachine
