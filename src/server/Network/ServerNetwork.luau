--[[
	ServerNetwork.luau
	═══════════════════════════════════════════════════════════════
	Capa de red del servidor — Handlers de RemoteEvents.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades futuras (Fase 6):
	- Crear RemoteEvents en ReplicatedStorage/Remotes
	- Escuchar requests del cliente con validación completa
	- REGLA 05: Todo RemoteEvent se valida: tipo, rango, rate, ownership
	- El cliente NUNCA recibe información que no le corresponde
	
	Contrato de validación:
	  ClientNetwork:RequestFire(weaponId) ──► ServerNetwork:_onFireRequest(player, weaponId)
	    WeaponService:ValidateFire(player, weaponId)
	      ✓ ¿tiene esa arma?
	      ✓ ¿tiene munición?
	      ✓ ¿rate of fire respetado?
	      ✓ ¿jugador está vivo?
	    CombatService:ProcessHit(...)
	      → Authoritative damage
	  ◄── ClientNetwork:OnHitConfirmed(result)
	
	ESTADO: Stub — se implementará en Fase 6.
]]

local ServerNetwork = {}

function ServerNetwork:Init()
	-- TODO (Fase 6): Crear RemoteEvents en ReplicatedStorage
	-- local remotes = Instance.new("Folder")
	-- remotes.Name = "Remotes"
	-- remotes.Parent = ReplicatedStorage
	--
	-- local fireRequest = Instance.new("RemoteEvent")
	-- fireRequest.Name = "FireRequest"
	-- fireRequest.Parent = remotes
	--
	-- local hitConfirmed = Instance.new("RemoteEvent")
	-- hitConfirmed.Name = "HitConfirmed"
	-- hitConfirmed.Parent = remotes
	--
	-- local stateCorrection = Instance.new("RemoteEvent")
	-- stateCorrection.Name = "StateCorrection"
	-- stateCorrection.Parent = remotes
end

function ServerNetwork:Start()
	-- TODO (Fase 6): Conectar handlers con validación
	-- local remotes = ReplicatedStorage:WaitForChild("Remotes")
	-- remotes.FireRequest.OnServerEvent:Connect(function(player, weaponId)
	--     self:_onFireRequest(player, weaponId)
	-- end)
end

function ServerNetwork:Destroy()
	-- Sin conexiones que limpiar
end

return ServerNetwork
