--[[
	CharacterController.luau
	═══════════════════════════════════════════════════════════════
	Owner de todos los subsistemas del personaje en el cliente.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades futuras (Fase 3 refactor):
	- Escuchar CharacterAdded/CharacterRemoving
	- Crear/destruir subsistemas: MovementSystem, RotationSystem, CoverSystem
	- Garantizar cleanup de conexiones al respawn
	- Ser el ÚNICO dueño de referencias al Model del personaje (ARQREG 05)
	
	ESTADO: Stub — se implementará cuando MovementController se divida.
]]

local Players = game:GetService("Players")

local CharacterController = {}
CharacterController.__index = CharacterController

function CharacterController.new()
	local self = setmetatable({}, CharacterController)

	self._player = Players.LocalPlayer
	self._character = nil :: Model?
	self._connections = {}

	-- Subsistemas (se crearán aquí cuando se divida MovementController)
	-- self._movementSystem = nil
	-- self._rotationSystem = nil
	-- self._coverSystem = nil

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function CharacterController:Init()
	-- Sin side-effects
end

function CharacterController:Start()
	-- TODO (Fase 3): Escuchar CharacterAdded/Removing
	-- self._connections.charAdded = self._player.CharacterAdded:Connect(function(character)
	--     self:_destroySubsystems()
	--     self:_createSubsystems(character)
	-- end)
	--
	-- self._connections.charRemoving = self._player.CharacterRemoving:Connect(function()
	--     self:_destroySubsystems()
	-- end)
	--
	-- if self._player.Character then
	--     self:_createSubsystems(self._player.Character)
	-- end
end

function CharacterController:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
	self:_destroySubsystems()
end

------------------------------------------------------------------------
-- INTERNAL
------------------------------------------------------------------------

function CharacterController:_createSubsystems(_character: Model)
	-- TODO (Fase 3): Crear MovementSystem, RotationSystem, CoverSystem
	-- Cada subsistema recibe el character como argumento
end

function CharacterController:_destroySubsystems()
	-- TODO (Fase 3): Destruir subsistemas del personaje anterior
end

return CharacterController
