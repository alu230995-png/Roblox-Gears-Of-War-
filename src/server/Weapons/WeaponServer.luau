--[[
	WeaponServer.luau
	═══════════════════════════════════════════════════════════════
	Servicio AUTORITATIVO de armas en el servidor.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	  - Crear el RemoteEvent "WeaponRemote" para comunicación C↔S
	  - Escuchar Humanoid.Died → ejecutar weapon drop
	  - Drop: clonar el modelo del arma en el mundo y destruir el Tool original
	  - Validar acciones de arma reportadas por el cliente (Equip/Unequip)
	  - Registrar el arma equipada por jugador (inventario server-side)

	NO hace (aún):
	  - Validación de disparo (Fase siguiente)
	  - Aplicar daño (vive en CombatService)
	  - Sistema de munición autoritativo
	  - Pick-up de armas del suelo (futuro)

	REGLA 05: El servidor es AUTORITATIVO.
	El cliente informa intenciones, el servidor decide.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConstants = require(Shared:WaitForChild("WeaponConstants"))

local WeaponServer = {}

--- Arma equipada por cada jugador: Player → weaponName
local _equippedWeapons: { [Player]: string } = {}

--- Conexiones por jugador para cleanup al salir
local _playerConnections: { [Player]: { RBXScriptConnection } } = {}

--- RemoteEvent compartido para todas las acciones de arma
local _weaponRemote: RemoteEvent = nil :: any

------------------------------------------------------------------------
-- PRIVATE: Weapon Drop (al morir)
------------------------------------------------------------------------

--- Crea una copia física del arma en el mundo cuando el jugador muere.
--- El modelo se dropea con un impulso leve y se destruye tras WEAPON_DROP_LIFETIME.
local function _dropWeapon(player: Player, character: Model)
	-- Iterar sobre la backpack para eliminar todas las tools
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, item in backpack:GetChildren() do
			if item:IsA("Tool") then
				item:Destroy()
			end
		end
	end

	-- Buscar el Tool equipado en el Character
	local tool: Tool? = nil
	for _, child in character:GetChildren() do
		if child:IsA("Tool") then
			tool = child :: Tool
			break
		end
	end

	if not tool then
		return
	end

	-- Buscar Handle (Part principal del Tool)
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if not handle then
		return
	end

	-- Obtener posición de drop desde el HRP (más fiable que Handle.Position)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local dropPosition = if hrp then hrp.Position else handle.Position
	local dropCFrame = if hrp then hrp.CFrame else handle.CFrame

	-- Clonar el Tool completo para el drop (mantiene modelo interno + scripts)
	local dropTool = tool:Clone()
	dropTool.Name = tool.Name

	-- Asegurar que el Handle del drop tenga física correcta
	local dropHandle = dropTool:FindFirstChild("Handle") :: BasePart?
	if dropHandle then
		dropHandle.Anchored = false
		dropHandle.CanCollide = true
	end

	-- Posicionar el drop ligeramente elevado
	local upOffset = Vector3.new(0, WeaponConstants.DROP_HEIGHT_OFFSET, 0)
	dropTool:PivotTo(CFrame.new(dropPosition + upOffset))

	-- Etiquetar el drop para futuros sistemas de pick-up
	dropTool:SetAttribute("WeaponName", tool.Name)
	dropTool:SetAttribute("DroppedBy", player.Name)

	dropTool.Parent = workspace

	-- Aplicar impulso leve hacia adelante
	if dropHandle then
		local forwardDir = dropCFrame.LookVector
		dropHandle.AssemblyLinearVelocity = forwardDir * WeaponConstants.DROP_IMPULSE
			+ Vector3.new(0, WeaponConstants.DROP_IMPULSE * 0.5, 0)
	end

	-- Auto-destruir tras el lifetime configurado
	if WeaponConstants.DROP_LIFETIME > 0 then
		Debris:AddItem(dropTool, WeaponConstants.DROP_LIFETIME)
	end

	-- Destruir el Tool original del jugador
	tool:Destroy()

	-- Limpiar inventario server-side
	_equippedWeapons[player] = nil
end

------------------------------------------------------------------------
-- PRIVATE: Remote handler
------------------------------------------------------------------------

local function _onWeaponRemote(player: Player, action: string, weaponName: string?)
	-- Sanitizar inputs
	if typeof(action) ~= "string" then
		return
	end
	if weaponName ~= nil and typeof(weaponName) ~= "string" then
		return
	end

	if action == "Equip" then
		if typeof(weaponName) == "string" and #weaponName <= 50 then
			-- Validar que el arma existe en WeaponConstants
			if not WeaponConstants.STATS[weaponName] then
				warn("[WeaponServer] Arma desconocida reportada por " .. player.Name .. ": " .. weaponName)
				return
			end
			_equippedWeapons[player] = weaponName
		end
	elseif action == "Unequip" then
		_equippedWeapons[player] = nil
	end
	-- Las demás acciones (Fire, Reload, etc.) se implementarán en fases siguientes
end

------------------------------------------------------------------------
-- PRIVATE: Player lifecycle
------------------------------------------------------------------------

local function _bindCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	-- Conexiones por personaje (se limpian al respawn)
	local charConnections: { RBXScriptConnection } = {}

	-- Al morir: drop del arma
	table.insert(
		charConnections,
		humanoid.Died:Connect(function()
			_dropWeapon(player, character)

			-- Desconectar conexiones de este personaje
			for _, conn in charConnections do
				conn:Disconnect()
			end
			table.clear(charConnections)
		end)
	)

	-- Guardar referencia para cleanup al salir
	_playerConnections[player] = charConnections
end

local function _onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		-- Limpiar conexiones de personaje anterior
		if _playerConnections[player] then
			for _, conn in _playerConnections[player] do
				conn:Disconnect()
			end
		end
		_bindCharacter(player, character)
	end)

	-- Si ya tiene personaje (late join)
	if player.Character then
		_bindCharacter(player, player.Character)
	end
end

local function _onPlayerRemoving(player: Player)
	-- Cleanup conexiones
	if _playerConnections[player] then
		for _, conn in _playerConnections[player] do
			conn:Disconnect()
		end
		_playerConnections[player] = nil
	end
	_equippedWeapons[player] = nil
end

------------------------------------------------------------------------
-- PUBLIC API (Init / Start / Destroy)
------------------------------------------------------------------------

function WeaponServer:Init()
	-- Crear carpeta de Remotes si no existe
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	-- Crear RemoteEvent para armas
	local existing = remotes:FindFirstChild("WeaponRemote")
	if existing then
		existing:Destroy()
	end
	_weaponRemote = Instance.new("RemoteEvent")
	_weaponRemote.Name = "WeaponRemote"
	_weaponRemote.Parent = remotes
end

function WeaponServer:Start()
	-- Escuchar acciones del cliente
	_weaponRemote.OnServerEvent:Connect(_onWeaponRemote)

	-- Player lifecycle
	Players.PlayerAdded:Connect(_onPlayerAdded)
	Players.PlayerRemoving:Connect(_onPlayerRemoving)

	-- Handle jugadores ya conectados (Studio)
	for _, player in Players:GetPlayers() do
		task.spawn(_onPlayerAdded, player)
	end
end

function WeaponServer:Destroy()
	for player, connections in _playerConnections do
		for _, conn in connections do
			conn:Disconnect()
		end
		_playerConnections[player] = nil
	end
	table.clear(_equippedWeapons)

	if _weaponRemote then
		_weaponRemote:Destroy()
	end
end

--- Obtiene el nombre del arma equipada por un jugador (nil si no tiene).
function WeaponServer:GetEquippedWeapon(player: Player): string?
	return _equippedWeapons[player]
end

return WeaponServer
