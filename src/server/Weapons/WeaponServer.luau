--[[
	WeaponServer.luau
	═══════════════════════════════════════════════════════════════
	Servicio AUTORITATIVO de armas — ORQUESTADOR DELGADO.
	═══════════════════════════════════════════════════════════════

	Responsabilidades (solo delegación + lifecycle):
	  - Crear el RemoteEvent "WeaponRemote"
	  - Gestionar estado compartido (equip, ammo, fire rate, reloading)
	  - Inyectar estado en sub-módulos
	  - Delegar cada acción al sub-módulo correspondiente:
	      ProcessShot → ShotValidator → ServerRaycast → DamageHandler → HealthStateManager
	      Reload      → ReloadHandler
	  - Escuchar Humanoid.Died → weapon drop
	  - Player lifecycle (connect/disconnect/respawn)

	Sub-módulos:
	  ShotValidator      — valida que el disparo es legítimo
	  ServerRaycast      — re-raycast server-side + debug visuals
	  DamageHandler      — calcula daño acumulado por víctima (team check, zones, falloff)
	  HealthStateManager — aplica daño → DBNO / muerte estándar / desmembramiento / headshot
	  ReloadHandler      — recarga de armas y actualización de munición

	REGLA 05: El servidor es AUTORITATIVO.
	El cliente informa intenciones, el servidor decide.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConstants = require(Shared:WaitForChild("WeaponConstants"))
local Constants = require(Shared:WaitForChild("Constants"))

-- Sub-módulos
local ServerWeapons = script.Parent
local ShotValidator = require(ServerWeapons:WaitForChild("ShotValidator"))
local ServerRaycast = require(ServerWeapons:WaitForChild("ServerRaycast"))
local DamageHandler = require(ServerWeapons:WaitForChild("DamageHandler"))
local HealthStateManager = require(ServerWeapons:WaitForChild("HealthStateManager"))
local ReloadHandler = require(ServerWeapons:WaitForChild("ReloadHandler"))

local WeaponServer = {}

------------------------------------------------------------------------
-- SHARED STATE — inyectado en sub-módulos via SetState()
------------------------------------------------------------------------

--- Arma equipada por cada jugador: Player → weaponName
local _equippedWeapons: { [Player]: string } = {}

--- Munición server-side por jugador: Player → { current: number, reserve: number }
local _ammoState: { [Player]: { current: number, reserve: number } } = {}

--- Último tiempo de disparo por jugador (anti rapid-fire)
local _lastFireTime: { [Player]: number } = {}

--- Set de jugadores recargando actualmente
local _reloadingPlayers: { [Player]: true? } = {}

--- Conexiones por jugador para cleanup al salir
local _playerConnections: { [Player]: { RBXScriptConnection } } = {}

--- RemoteEvent compartido para todas las acciones de arma
local _weaponRemote: RemoteEvent = nil :: any

--- RemoteEvent para replicar efectos visuales de disparo a otros clientes
local _weaponEffectsRemote: RemoteEvent = nil :: any

--- RemoteEvent para confirmar disparo al tirador (posiciones validadas + daño por pellet)
local _shotConfirmedRemote: RemoteEvent = nil :: any

--- Rate limiting por acción (anti-spam)
local _lastActionTime: { [Player]: { [string]: number } } = {}

------------------------------------------------------------------------
-- PRIVATE: Inyectar estado en sub-módulos
------------------------------------------------------------------------

local function _injectState()
	ShotValidator.SetState(_equippedWeapons, _ammoState, _lastFireTime, _reloadingPlayers)
	ReloadHandler.SetState(_equippedWeapons, _ammoState, _reloadingPlayers)
end

------------------------------------------------------------------------
-- PRIVATE: Replicate shot effects to other clients
------------------------------------------------------------------------

--- Envía datos de efectos visuales a todos los clientes EXCEPTO el tirador.
--- El tirador ya renderiza sus propios efectos localmente.
local function _replicateShotEffects(shooter: Player, shotData: any, validation: any)
	if not _weaponEffectsRemote then
		return
	end

	local effectsData = {
		WeaponName = validation.Config.Name or shotData.WeaponName,
		Origin = validation.MuzzlePosition,
		HitPositions = shotData.HitPositions,
		HitParts = shotData.HitParts,
		ShooterCharacter = validation.Character,
	}

	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer ~= shooter then
			_weaponEffectsRemote:FireClient(otherPlayer, effectsData)
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Send shot confirmation to the shooter
------------------------------------------------------------------------

--- Envía datos validados del disparo al tirador para efectos
--- diferidos (trails, blood scalado, hitmarkers).
local function _sendShotConfirmed(shooter: Player, damageReport: any, validation: any)
	if not _shotConfirmedRemote then
		return
	end

	-- Construir ValidatedHits desde PelletDetails
	local validatedHits = {}
	for _, detail in damageReport.PelletDetails do
		local pelletIndex = tonumber(string.match(detail.PelletName, "(%d+)")) or 0
		table.insert(validatedHits, {
			PelletIndex = pelletIndex,
			HitPosition = detail.HitPosition,
			HitPartName = detail.HitPartName,
			Damage = detail.Damage,
			IsFlesh = detail.IsFlesh,
		})
	end

	-- Detectar kills/DBNOs leyendo LifeState de cada víctima
	local kills = {}
	for _, victim in damageReport.Victims do
		local character = victim.Character
		if character then
			local lifeState = character:GetAttribute("LifeState")
			if lifeState == "Dead" or lifeState == "DBNO" then
				table.insert(kills, {
					CharacterName = character.Name,
					IsDBNO = lifeState == "DBNO",
				})
			end
		end
	end

	_shotConfirmedRemote:FireClient(shooter, {
		WeaponName = validation.Config.Name or validation.WeaponName,
		MuzzlePosition = validation.MuzzlePosition,
		ValidatedHits = validatedHits,
		Kills = kills,
	})
end

------------------------------------------------------------------------
-- PRIVATE: Shot pipeline (orquestación)
------------------------------------------------------------------------

--- Pipeline completo de un disparo:
---   1. ShotValidator.Validate  → ¿el disparo es legítimo?
---   2. ServerRaycast.CastPellets → re-raycast desde Muzzle
---   3. DamageHandler.CalculateDamage → daño acumulado por víctima
---   4. HealthStateManager.ApplyDamage → aplicar al Humanoid
local function _processShot(player: Player, shotData: any)
	-- 1. Validación
	local validation = ShotValidator.Validate(player, shotData)
	if not validation then
		return
	end

	-- 2. Raycasting
	local rayResult = ServerRaycast.CastPellets(
		validation.MuzzlePosition,
		validation.HitPositions,
		validation.Character,
		validation.Config
	)

	-- 3. Cálculo de daño
	local damageReport = DamageHandler.CalculateDamage(
		rayResult.Hits,
		validation.Character,
		validation.MuzzlePosition,
		validation.Config
	)

	-- 3b. Aplicar buff de recarga activa (x1.5 daño)
	if ReloadHandler.HasActiveBuff(player) then
		for _, victim in damageReport.Victims do
			victim.TotalDamage = victim.TotalDamage * Constants.ACTIVE_RELOAD_BONUS_DAMAGE
		end
		if Constants.DEBUG_MODE then
			print(
				`[WeaponServer] BUFF ACTIVO: Daño multiplicado x{Constants.ACTIVE_RELOAD_BONUS_DAMAGE} para {player.Name}`
			)
		end
	end

	-- 4. Aplicar daño (salud, DBNO, muerte)
	HealthStateManager.ApplyDamage(damageReport)

	-- 5. Replicar efectos visuales a otros clientes
	_replicateShotEffects(player, shotData, validation)

	-- 6. Confirmar disparo al tirador (posiciones validadas + daño por pellet)
	_sendShotConfirmed(player, damageReport, validation)
end

------------------------------------------------------------------------
-- PRIVATE: Remote handler
------------------------------------------------------------------------

--- Verifica rate limiting por acción. Retorna true si la acción está permitida.
local function _isActionAllowed(player: Player, action: string, cooldown: number): boolean
	local now = os.clock()
	if not _lastActionTime[player] then
		_lastActionTime[player] = {}
	end
	local last = _lastActionTime[player][action] or 0
	if (now - last) < cooldown then
		return false
	end
	_lastActionTime[player][action] = now
	return true
end

local function _onWeaponRemote(player: Player, action: string, data: any?)
	if typeof(action) ~= "string" then
		return
	end

	if action == "Equip" then
		-- Rate limit: máximo 1 equip cada 0.4s (EQUIP_TIME)
		if not _isActionAllowed(player, "Equip", WeaponConstants.EQUIP_TIME) then
			return
		end
		local weaponName = data
		if typeof(weaponName) == "string" and #weaponName <= 50 then
			local config = WeaponConstants.WEAPONS[weaponName]
			if not config then
				warn("[WeaponServer] Arma desconocida reportada por " .. player.Name .. ": " .. weaponName)
				return
			end

			-- Solo resetear munición si cambia de arma (no re-equip de la misma)
			if _equippedWeapons[player] ~= weaponName then
				_equippedWeapons[player] = weaponName
				-- Solo inicializar ammo si no hay estado previo para esta arma
				if not _ammoState[player] then
					local ammo = config.Ammo
					_ammoState[player] = {
						current = ammo.ClipSize,
						reserve = ammo.CurrentAmmo - ammo.ClipSize,
					}
				end
				_lastFireTime[player] = 0
				ReloadHandler.CancelReload(player)
			end
		end
	elseif action == "Unequip" then
		if not _isActionAllowed(player, "Unequip", 0.2) then
			return
		end
		_equippedWeapons[player] = nil
		ReloadHandler.CancelReload(player)
	elseif action == "ProcessShot" then
		_processShot(player, data)
	elseif action == "Reload" then
		if not _isActionAllowed(player, "Reload", 0.3) then
			return
		end
		ReloadHandler.ProcessReload(player, data)
	elseif action == "ActiveReload" then
		if typeof(data) == "table" then
			local arWpn = data.WeaponName
			local arProgress = data.Progress
			if typeof(arWpn) == "string" and typeof(arProgress) == "number" then
				ReloadHandler.ProcessActiveReload(player, arWpn, arProgress)
			end
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Weapon drop & backpack cleanup
------------------------------------------------------------------------

--- Limpia todas las tools del Backpack del jugador
local function _clearBackpack(player: Player)
	local backpack = player:FindFirstChild("Backpack")
	if not backpack then
		return
	end

	for _, item in backpack:GetChildren() do
		if item:IsA("Tool") then
			item:Destroy()
		end
	end
end

--- Dropea el arma equipada actualmente en el mundo
local function _dropEquippedWeapon(player: Player, character: Model)
	-- Buscar el Tool equipado en el character
	local equippedTool: Tool? = nil
	for _, child in character:GetChildren() do
		if child:IsA("Tool") then
			equippedTool = child
			break
		end
	end

	if not equippedTool then
		return
	end

	-- Obtener posición de drop (HumanoidRootPart o fallback al character)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local dropPosition = if hrp then hrp.Position + Vector3.new(0, 2, 0) else character:GetPivot().Position

	-- Clonar el Tool para crear el drop
	local droppedTool = equippedTool:Clone()

	-- Desparentar el original para que no siga en el character
	equippedTool:Destroy()

	-- Configurar el handle del drop
	local handle = droppedTool:FindFirstChild("Handle") :: BasePart?
	if handle then
		handle.Anchored = false
		handle.CanCollide = true
		handle.CFrame = CFrame.new(dropPosition)

		-- Aplicar una pequeña fuerza hacia arriba y lateral
		local randomDir = Vector3.new(math.random() - 0.5, 0.5, math.random() - 0.5).Unit
		handle.AssemblyLinearVelocity = randomDir * 15 + Vector3.new(0, 10, 0)
		handle.AssemblyAngularVelocity =
			Vector3.new((math.random() - 0.5) * 10, (math.random() - 0.5) * 10, (math.random() - 0.5) * 10)
	end

	-- Colocar en Workspace
	droppedTool.Parent = workspace

	-- Auto-destruir después de 30 segundos
	Debris:AddItem(droppedTool, 30)
end

------------------------------------------------------------------------
-- PRIVATE: Player lifecycle
------------------------------------------------------------------------

local function _bindCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local charConnections: { RBXScriptConnection } = {}

	table.insert(
		charConnections,
		humanoid.Died:Connect(function()
			-- Drop del arma equipada
			_dropEquippedWeapon(player, character)

			-- Limpiar todas las tools del backpack
			_clearBackpack(player)

			-- Limpiar estado del servidor
			_equippedWeapons[player] = nil
			ReloadHandler.CancelReload(player)

			for _, conn in charConnections do
				conn:Disconnect()
			end
			table.clear(charConnections)
		end)
	)

	_playerConnections[player] = charConnections
end

local function _onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		if _playerConnections[player] then
			for _, conn in _playerConnections[player] do
				conn:Disconnect()
			end
		end
		_bindCharacter(player, character)
	end)

	if player.Character then
		_bindCharacter(player, player.Character)
	end
end

local function _onPlayerRemoving(player: Player)
	if _playerConnections[player] then
		for _, conn in _playerConnections[player] do
			conn:Disconnect()
		end
		_playerConnections[player] = nil
	end
	_equippedWeapons[player] = nil
	_ammoState[player] = nil
	_lastFireTime[player] = nil
	_reloadingPlayers[player] = nil
	_lastActionTime[player] = nil
	ReloadHandler.CleanupPlayer(player)
end

------------------------------------------------------------------------
-- PUBLIC API (Init / Start / Destroy)
------------------------------------------------------------------------

function WeaponServer:Init()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		remotes = Instance.new("Folder")
		remotes.Name = "Remotes"
		remotes.Parent = ReplicatedStorage
	end

	local existing = remotes:FindFirstChild("WeaponRemote")
	if existing then
		existing:Destroy()
	end
	_weaponRemote = Instance.new("RemoteEvent")
	_weaponRemote.Name = "WeaponRemote"
	_weaponRemote.Parent = remotes

	-- RemoteEvent para replicar efectos de disparo a otros clientes
	local existingEffects = remotes:FindFirstChild("WeaponEffects")
	if existingEffects then
		existingEffects:Destroy()
	end
	_weaponEffectsRemote = Instance.new("RemoteEvent")
	_weaponEffectsRemote.Name = "WeaponEffects"
	_weaponEffectsRemote.Parent = remotes

	-- RemoteEvent para confirmar disparo al tirador
	local existingConfirmed = remotes:FindFirstChild("ShotConfirmed")
	if existingConfirmed then
		existingConfirmed:Destroy()
	end
	_shotConfirmedRemote = Instance.new("RemoteEvent")
	_shotConfirmedRemote.Name = "ShotConfirmed"
	_shotConfirmedRemote.Parent = remotes

	-- Inyectar estado compartido en sub-módulos
	_injectState()
end

function WeaponServer:Start()
	_weaponRemote.OnServerEvent:Connect(_onWeaponRemote)

	Players.PlayerAdded:Connect(_onPlayerAdded)
	Players.PlayerRemoving:Connect(_onPlayerRemoving)

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
	table.clear(_ammoState)
	table.clear(_lastFireTime)
	table.clear(_reloadingPlayers)

	if _weaponRemote then
		_weaponRemote:Destroy()
	end
	if _weaponEffectsRemote then
		_weaponEffectsRemote:Destroy()
	end
	if _shotConfirmedRemote then
		_shotConfirmedRemote:Destroy()
	end
end

function WeaponServer:GetEquippedWeapon(player: Player): string?
	return _equippedWeapons[player]
end

return WeaponServer
