--[[
	AnimationController.luau
	═══════════════════════════════════════════════════════════════
	Controlador de animaciones por estado FSM.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades futuras (Fase 4):
	- Cargar AnimationTracks al spawn del personaje
	- Reproducir animación correcta según el estado FSM
	- Transiciones suaves entre animaciones (crossfade)
	- Animaciones de acción: evade roll, mantle, cover slide, melee
	
	Escuchará signals:
	- StateMachine.StateChanged → cambiar animación base (idle, walk, run, cover)
	- ActionResolver.ActionResolved → reproducir animaciones puntuales
	
	ESTADO: Stub — se implementará en Fase 4.
]]

local AnimationController = {}
AnimationController.__index = AnimationController

function AnimationController.new()
	local self = setmetatable({}, AnimationController)
	self._connections = {}
	self._tracks = {} -- { [stateName] = AnimationTrack }
	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function AnimationController:Init()
	-- Sin side-effects
end

function AnimationController:Start()
	-- TODO (Fase 4): Conectar a signals
	-- local locator = require(script.Parent.Parent.Core.ServiceLocator).new()
	-- local stateMachine = locator:Get("StateMachine")
	-- local actionResolver = locator:Get("ActionResolver")
	--
	-- self._connections.stateChanged = stateMachine.StateChanged:Connect(function(newState, oldState)
	--     self:_onStateChanged(newState, oldState)
	-- end)
	--
	-- self._connections.actionResolved = actionResolver.ActionResolved:Connect(function(action, targetState, data)
	--     self:_onActionResolved(action, targetState, data)
	-- end)
end

function AnimationController:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
	table.clear(self._tracks)
end

return AnimationController
