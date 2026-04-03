--[[
	ClientNetwork.luau
	═══════════════════════════════════════════════════════════════
	Capa de red del cliente.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades futuras (Fase 6):
	- Encapsular todos los RemoteEvent:FireServer()
	- Recibir confirmaciones/correcciones del servidor
	- El cliente NUNCA modifica HP, ammo, inventario directamente
	  — solo envía requests y espera confirmación
	
	Contrato de validación (servidor decide):
	  ClientNetwork:RequestFire(weaponId) ──► ServerNetwork
	    → WeaponService:ValidateFire()
	    → CombatService:ProcessHit()
	  ◄── ClientNetwork:OnHitConfirmed(result)
	
	REGLA 05: El cliente predice. El servidor decide.
	
	ESTADO: Stub — se implementará en Fase 6.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal"))

local ClientNetwork = {}
ClientNetwork.__index = ClientNetwork

function ClientNetwork.new()
	local self = setmetatable({}, ClientNetwork)
	self._connections = {}

	-- Signals de salida (para que otros sistemas reaccionen a respuestas del servidor)
	self.HitConfirmed = Signal.new()
	self.StateCorrection = Signal.new()

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function ClientNetwork:Init()
	-- Sin side-effects
end

function ClientNetwork:Start()
	-- TODO (Fase 6): Conectar a RemoteEvents del servidor
	-- local remotes = ReplicatedStorage:WaitForChild("Remotes")
	-- self._connections.hitConfirmed = remotes.HitConfirmed.OnClientEvent:Connect(function(result)
	--     self.HitConfirmed:Fire(result)
	-- end)
	--
	-- self._connections.stateCorrection = remotes.StateCorrection.OnClientEvent:Connect(function(correctedState)
	--     self.StateCorrection:Fire(correctedState)
	-- end)
end

function ClientNetwork:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
	self.HitConfirmed:Destroy()
	self.StateCorrection:Destroy()
end

------------------------------------------------------------------------
-- PUBLIC API (stubs)
------------------------------------------------------------------------

--- Solicita disparo al servidor. El servidor valida y responde.
function ClientNetwork:RequestFire(_weaponId: string)
	-- TODO (Fase 6):
	-- local remotes = ReplicatedStorage:WaitForChild("Remotes")
	-- remotes.FireRequest:FireServer(weaponId)
end

--- Solicita recarga al servidor.
function ClientNetwork:RequestReload(_weaponId: string)
	-- TODO (Fase 6)
end

--- Notifica estado del cliente al servidor para validación.
function ClientNetwork:SendStateUpdate(_stateName: string)
	-- TODO (Fase 6)
end

return ClientNetwork
