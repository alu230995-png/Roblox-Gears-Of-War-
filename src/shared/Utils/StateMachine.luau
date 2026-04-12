--[[
	StateMachine.luau
	Hierarchical State Machine (HSM) con herencia de transiciones,
	callbacks jerárquicos, history states, y soporte para regiones paralelas.
	
	Evolución de la FSM plana original. Mantiene API backward-compatible:
	  - TransitionTo(state) sigue igual (estado hoja)
	  - ForceState(state) sigue igual
	  - GetCurrentState() devuelve estado hoja (string)
	  - RegisterState(name, callbacks) sigue igual
	  - StateChanged signal sigue disparándose igual
	
	Nuevo API (HSM):
	  - RegisterGroup(name, config) — registrar grupo con jerarquía
	  - IsInGroup(groupName) — check rápido de pertenencia
	  - GetCurrentGroup(level?) — grupo activo en nivel de jerarquía
	  - GetHistory(groupName) — último subestado activo de un grupo
	
	Diseño:
	  - Grupos definen jerarquía padre-hijo sobre estados hoja.
	  - Las transiciones se heredan: si AliveGroup→DBNO, todos los hijos heredan.
	  - Al transicionar entre grupos, se ejecutan callbacks en orden jerárquico:
	    Exit(leaf) → Exit(groups child→root hasta ancestro común) →
	    Enter(groups root→child hasta destino) → Enter(leaf)
	  - History state por grupo recuerda último subestado activo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Signal = require(Shared:WaitForChild("Signal"))

local StateMachine = {}
StateMachine.__index = StateMachine

export type StateCallbacks = {
	OnEnter: ((oldState: string) -> ())?,
	OnExit: ((newState: string) -> ())?,
	OnUpdate: ((dt: number) -> ())?,
}

export type GroupConfig = {
	Parent: string?,
	States: { string },
	OnEnter: ((fromState: string) -> ())?,
	OnExit: ((toState: string) -> ())?,
}

--- Crea una nueva StateMachine.
--- @param initialState string — Estado hoja inicial.
--- @param transitions {[string]: {string}} — Tabla de transiciones válidas (hoja y/o grupo).
--- @return StateMachine
function StateMachine.new(initialState: string, transitions: { [string]: { string } })
	local self = setmetatable({}, StateMachine)

	self._currentState = initialState
	self._previousState = nil :: string?
	self._transitions = transitions
	self._stateCallbacks = {} :: { [string]: StateCallbacks }
	self._stateEnteredAt = os.clock()
	self._locked = false

	-- HSM: Grupos jerárquicos
	self._groups = {} :: { [string]: GroupConfig } -- groupName → config
	self._stateToGroups = {} :: { [string]: { string } } -- leafState → {group1, group2, ...} (child→root)
	self._groupChildren = {} :: { [string]: { string } } -- groupName → {childGroups}
	self._history = {} :: { [string]: string } -- groupName → last active leaf state

	-- O(1) lookups (populated in BuildGroupHierarchy)
	self._stateToGroupSet = {} :: { [string]: { [string]: boolean } } -- leafState → { groupName → true }
	self._validTransitionSet = {} :: { [string]: { [string]: boolean } } -- leafState → { targetState → true }

	-- Signal: se dispara en cada transición exitosa (newState, oldState)
	self.StateChanged = Signal.new()

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function StateMachine:Destroy()
	if self.StateChanged then
		self.StateChanged:Destroy()
	end
	table.clear(self._stateCallbacks)
	table.clear(self._groups)
	table.clear(self._stateToGroups)
	table.clear(self._groupChildren)
	table.clear(self._history)
	table.clear(self._stateToGroupSet)
	table.clear(self._validTransitionSet)
end

------------------------------------------------------------------------
-- GROUP REGISTRATION (HSM)
------------------------------------------------------------------------

--- Registra un grupo jerárquico.
--- @param groupName string — nombre único del grupo
--- @param config GroupConfig — { Parent: string?, States: {string}, OnEnter?, OnExit? }
function StateMachine:RegisterGroup(groupName: string, config: GroupConfig)
	self._groups[groupName] = config

	-- Registrar relación padre→hijo
	if config.Parent then
		if not self._groupChildren[config.Parent] then
			self._groupChildren[config.Parent] = {}
		end
		table.insert(self._groupChildren[config.Parent], groupName)
	end

	-- Mapear cada estado hoja a su cadena de grupos (child→root)
	for _, stateName in config.States do
		if not self._stateToGroups[stateName] then
			self._stateToGroups[stateName] = {}
		end
		-- Insertar al inicio para mantener orden child→root
		table.insert(self._stateToGroups[stateName], 1, groupName)
	end

	-- Inicializar history con el primer estado del grupo
	if #config.States > 0 then
		self._history[groupName] = config.States[1]
	end
end

--- Reconstruye las cadenas _stateToGroups tras registrar todos los grupos.
--- También pre-computa O(1) lookup tables para IsInGroup y transiciones.
--- Llamar una vez después de registrar todos los grupos.
function StateMachine:BuildGroupHierarchy()
	-- Limpiar y reconstruir stateToGroups con cadena completa child→root
	table.clear(self._stateToGroups)

	for groupName, config in self._groups do
		for _, stateName in config.States do
			if not self._stateToGroups[stateName] then
				self._stateToGroups[stateName] = {}
			end
		end
	end

	-- Para cada estado hoja, construir la cadena de grupos de más específico a raíz
	for stateName, _ in self._stateToGroups do
		local chain = {}
		-- Encontrar el grupo más específico que contiene este estado directamente
		for groupName, config in self._groups do
			local isDirect = false
			for _, s in config.States do
				if s == stateName then
					isDirect = true
					break
				end
			end
			if isDirect then
				-- Solo añadir si este grupo no tiene subgrupos que también contengan el estado
				-- (los subgrupos son más específicos)
				local hasChildWithState = false
				local children = self._groupChildren[groupName]
				if children then
					for _, childGroup in children do
						local childConfig = self._groups[childGroup]
						if childConfig then
							for _, cs in childConfig.States do
								if cs == stateName then
									hasChildWithState = true
									break
								end
							end
						end
						if hasChildWithState then
							break
						end
					end
				end
				if not hasChildWithState then
					table.insert(chain, groupName)
				end
			end
		end
		local visited = {}
		for _, g in chain do
			visited[g] = true
		end
		for _, g in chain do
			local parent = self._groups[g] and self._groups[g].Parent
			while parent and not visited[parent] do
				visited[parent] = true
				table.insert(chain, parent)
				parent = self._groups[parent] and self._groups[parent].Parent
			end
		end

		self._stateToGroups[stateName] = chain
	end

	-- Construir O(1) group membership set per state
	self:_buildGroupSets()

	-- Pre-computar O(1) valid transitions per state
	self:_buildValidTransitionSets()

	-- Inicializar history del estado actual
	self:_updateHistory(self._currentState)
end

------------------------------------------------------------------------
-- PUBLIC API (backward-compatible)
------------------------------------------------------------------------

--- Registra callbacks para un estado hoja.
function StateMachine:RegisterState(stateName: string, callbacks: StateCallbacks)
	self._stateCallbacks[stateName] = callbacks
end

--- Intenta transicionar a un nuevo estado hoja.
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

	-- Verificar transición válida (directa + heredada por grupos)
	if not self:_isTransitionValid(self._currentState, newState) then
		return false
	end

	-- Ejecutar transición jerárquica
	self:_executeTransition(newState)

	return true
end

--- Fuerza un cambio de estado sin validar transiciones.
--- Usar solo para DBNO u otros estados forzados por el servidor.
function StateMachine:ForceState(newState: string)
	self:_executeTransition(newState)
end

--- Llama el OnUpdate del estado actual. Llamar cada frame desde Heartbeat.
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

--- Retorna el estado hoja actual.
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

--- Verifica si una transición directa o heredada es posible.
function StateMachine:CanTransitionTo(targetState: string): boolean
	if self._locked then
		return false
	end

	return self:_isTransitionValid(self._currentState, targetState)
end

------------------------------------------------------------------------
-- PUBLIC API (HSM — nuevo)
------------------------------------------------------------------------

--- Verifica si el estado actual pertenece a un grupo dado. O(1).
--- @param groupName string — nombre del grupo a verificar
--- @return boolean
function StateMachine:IsInGroup(groupName: string): boolean
	local groupSet = self._stateToGroupSet[self._currentState]
	return groupSet ~= nil and groupSet[groupName] == true
end

--- Retorna el grupo activo en un nivel de jerarquía.
--- level 1 = grupo más específico (ej: CoverGroup), level 2 = padre (ej: AliveGroup)
--- @param level number? — nivel (default 1)
--- @return string? — nombre del grupo o nil
function StateMachine:GetCurrentGroup(level: number?): string?
	local chain = self._stateToGroups[self._currentState]
	if not chain then
		return nil
	end

	local idx = level or 1
	return chain[idx]
end

--- Retorna el último estado hoja activo de un grupo (history state).
--- @param groupName string
--- @return string?
function StateMachine:GetHistory(groupName: string): string?
	return self._history[groupName]
end

------------------------------------------------------------------------
-- INTERNAL: Validación de transiciones con herencia
------------------------------------------------------------------------

--- Verifica si existe una transición válida (directa o heredada) entre dos estados. O(1).
function StateMachine:_isTransitionValid(fromState: string, toState: string): boolean
	local validSet = self._validTransitionSet[fromState]
	return validSet ~= nil and validSet[toState] == true
end

------------------------------------------------------------------------
-- INTERNAL: Ejecución de transición jerárquica
------------------------------------------------------------------------

--- Ejecuta la transición completa con callbacks jerárquicos.
function StateMachine:_executeTransition(newState: string)
	local oldState = self._currentState

	-- Determinar cadenas de grupos
	local oldChain = self._stateToGroups[oldState] or {}
	local newChain = self._stateToGroups[newState] or {}

	-- Encontrar ancestro común más profundo (retorna índice en CADA cadena)
	local oldAncestorIdx, newAncestorIdx = self:_findCommonAncestor(oldChain, newChain)

	-- 1. OnExit del estado hoja origen
	local oldCallbacks = self._stateCallbacks[oldState]
	if oldCallbacks and oldCallbacks.OnExit then
		oldCallbacks.OnExit(newState)
	end

	-- 2. OnExit de grupos (child → root) hasta ancestro común
	for i = 1, #oldChain do
		-- No salir del ancestro común ni de sus padres
		if oldAncestorIdx and i >= oldAncestorIdx then
			break
		end
		local groupName = oldChain[i]
		local groupConfig = self._groups[groupName]
		if groupConfig and groupConfig.OnExit then
			groupConfig.OnExit(newState)
		end
	end

	-- Cambiar estado
	self._previousState = oldState
	self._currentState = newState
	self._stateEnteredAt = os.clock()

	-- Actualizar history: registrar oldState para los grupos que se abandonan
	self:_updateHistory(oldState)
	-- Actualizar history: registrar newState para los grupos que se activan
	self:_updateHistory(newState)

	-- 3. OnEnter de grupos (root → child) desde ancestro común
	-- Recolectar grupos que necesitan Enter (en orden root→child)
	local groupsToEnter = {}
	for i = 1, #newChain do
		if newAncestorIdx and i >= newAncestorIdx then
			break
		end
		table.insert(groupsToEnter, 1, newChain[i])
	end

	for _, groupName in groupsToEnter do
		local groupConfig = self._groups[groupName]
		if groupConfig and groupConfig.OnEnter then
			groupConfig.OnEnter(oldState)
		end
	end

	-- 4. OnEnter del estado hoja destino
	local newCallbacks = self._stateCallbacks[newState]
	if newCallbacks and newCallbacks.OnEnter then
		newCallbacks.OnEnter(oldState)
	end

	-- Notificar a todos los listeners
	self.StateChanged:Fire(newState, oldState)
end

--- Encuentra el ancestro común más profundo entre dos cadenas de grupos.
--- Retorna (índice en oldChain, índice en newChain), o (nil, nil) si no hay ancestro común.
--- Las cadenas van de child→root.
function StateMachine:_findCommonAncestor(oldChain: { string }, newChain: { string }): (number?, number?)
	-- Build set from newChain for O(n) lookup (instead of O(n²))
	local newChainIndex: { [string]: number } = {}
	for i, group in newChain do
		newChainIndex[group] = i
	end

	-- Find first group in oldChain that also exists in newChain
	for i, oldGroup in oldChain do
		local newIdx = newChainIndex[oldGroup]
		if newIdx then
			return i, newIdx
		end
	end
	return nil, nil
end

--- Actualiza el history state de cada grupo al que pertenece un estado.
function StateMachine:_updateHistory(state: string)
	local chain = self._stateToGroups[state]
	if not chain then
		return
	end

	for _, groupName in chain do
		self._history[groupName] = state
	end
end

------------------------------------------------------------------------
-- INTERNAL: Pre-computed O(1) lookup builders
------------------------------------------------------------------------

--- Construye _stateToGroupSet para O(1) IsInGroup.
function StateMachine:_buildGroupSets()
	table.clear(self._stateToGroupSet)
	for stateName, chain in self._stateToGroups do
		local groupSet = {}
		for _, g in chain do
			groupSet[g] = true
		end
		self._stateToGroupSet[stateName] = groupSet
	end
end

--- Construye _validTransitionSet para O(1) _isTransitionValid.
--- Resuelve transiciones directas + heredadas por grupo + expansión de group targets.
function StateMachine:_buildValidTransitionSets()
	table.clear(self._validTransitionSet)

	for stateName, chain in self._stateToGroups do
		local validSet = {}

		-- 1. Transiciones directas del estado hoja
		local directTargets = self._transitions[stateName]
		if directTargets then
			for _, target in directTargets do
				self:_addTargetToSet(validSet, target)
			end
		end

		-- 2. Transiciones heredadas de cada grupo en la cadena (child→root)
		for _, groupName in chain do
			local groupTargets = self._transitions[groupName]
			if groupTargets then
				for _, target in groupTargets do
					self:_addTargetToSet(validSet, target)
				end
			end
		end

		self._validTransitionSet[stateName] = validSet
	end
end

--- Helper: añade un target al set de transiciones válidas.
--- Si el target es un grupo, también añade todos sus estados miembro.
function StateMachine:_addTargetToSet(validSet: { [string]: boolean }, target: string)
	validSet[target] = true
	local groupConfig = self._groups[target]
	if groupConfig then
		for _, s in groupConfig.States do
			validSet[s] = true
		end
	end
end

return StateMachine
