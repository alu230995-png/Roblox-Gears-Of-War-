--[[
	CameraController.luau
	═══════════════════════════════════════════════════════════════
	Control de cámara estilo Gears of War.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades futuras (Fase 5):
	- FOV dinámico (ROADIE_RUN_FOV = 80, DEFAULT_FOV = 70)
	- Camera bob (frecuencia, amplitud, multiplicadores walk/roadie)
	- ADS zoom al apuntar
	- Cover lean / peek
	- Shake en explosiones y melee
	
	Escuchará signals:
	- StateMachine.StateChanged → ajustar FOV y bob según estado
	- ActionResolver.ActionResolved → efectos de cámara por acción
	
	ESTADO: Stub — se implementará en Fase 5.
	
	Valores de referencia:
	- DEFAULT_FOV = 70
	- ROADIE_RUN_FOV = 80
	- CAMERA_BOB_FREQUENCY = 8
	- CAMERA_BOB_AMPLITUDE_X = 0.3
	- CAMERA_BOB_AMPLITUDE_Y = 0.5
	- CAMERA_BOB_ROADIE_MULTIPLIER = 2.5
]]

local CameraController = {}
CameraController.__index = CameraController

function CameraController.new()
	local self = setmetatable({}, CameraController)
	self._connections = {}
	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function CameraController:Init()
	-- Sin side-effects
end

function CameraController:Start()
	-- TODO (Fase 5): Conectar a signals
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

function CameraController:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

return CameraController
