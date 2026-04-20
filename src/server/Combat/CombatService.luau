--[[
	CombatService.luau
	═══════════════════════════════════════════════════════════════
	Servicio de combate — setup de personaje, bleedout y regeneración.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	- Configurar MaxHealth al spawn
	- Desactivar la regeneración nativa de Roblox (Health script)
	- Regenerar HP estilo GoW: tras HEALTH_REGEN_DELAY sin recibir daño
	    Fuera de cover: HEALTH_REGEN_RATE  hp/s (rápido)
	    En cover:       HEALTH_REGEN_RATE_COVER hp/s (un poco más lento)
	- Escuchar cambios de LifeState (set por HealthStateManager):
	    "DBNO" → iniciar bleedout gradual (drena HP en countdown)
	    "Dead" → cancelar bleedout
	    "Alive" → cancelar bleedout (revive)
	- Matar por bleedout cuando HP llega a 0 (DeathType="Bleedout")
	- Resetear estado al respawn (CharacterAdded)

	Regeneración de vida:
	  Solo en LifeState == "Alive" y HP < MAX_HEALTH.
	  Si el jugador recibió daño hace menos de HEALTH_REGEN_DELAY → no regenera.
	  En DBNO: NO regenera, solo pierde vida por bleedout o ataques.

	Cover state:
	  El cliente envía su estado de cover via RemoteEvent "CoverStateChanged".
	  El servidor lo usa SOLO para elegir la tasa de regen (no confía en el cliente
	  para nada de HP/daño).

	REGLA 05: El servidor es AUTORITATIVO sobre HP, DBNO y muerte.
	El cliente NUNCA modifica estos valores — solo los observa.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local CombatService = {}

local _bleedoutTimers: { [Player]: thread } = {}
local _lifeStateConnections: { [Player]: RBXScriptConnection } = {}
local _healthConnections: { [Player]: RBXScriptConnection } = {}

-- Regen state per player
local _lastDamageTime: { [Player]: number } = {}
local _previousHealth: { [Player]: number } = {}
local _inCover: { [Player]: boolean } = {}

-- RemoteEvent para cover state del cliente
local _coverStateRemote: RemoteEvent = nil :: any

-- Heartbeat connection
local _heartbeatConn: RBXScriptConnection? = nil

------------------------------------------------------------------------
-- PRIVATE: Kill player (bleedout death only)
------------------------------------------------------------------------

local function _cancelBleedout(player: Player)
	local timer = _bleedoutTimers[player]
	if timer then
		_bleedoutTimers[player] = nil
		if coroutine.status(timer) == "suspended" then
			task.cancel(timer)
		end
	end
end

local function _killFromBleedout(player: Player, character: Model, humanoid: Humanoid)
	_bleedoutTimers[player] = nil
	character:SetAttribute("LifeState", "Dead")
	character:SetAttribute("DeathType", "Bleedout")
	humanoid.Health = 0
end

------------------------------------------------------------------------
-- PRIVATE: Bleedout (gradual HP drain during DBNO)
------------------------------------------------------------------------

local function _startBleedout(player: Player, character: Model, humanoid: Humanoid)
	_cancelBleedout(player)

	local countdownTime = Constants.DBNO_COUNTDOWN_TIME
	local drainPerSecond = Constants.DBNO_HEALTH / countdownTime
	local TICK_RATE = 0.5
	local drainPerTick = drainPerSecond * TICK_RATE
	local elapsed = 0

	character:SetAttribute("DBNOTimeRemaining", countdownTime)
	character:SetAttribute("DBNORevivePoints", 0)

	_bleedoutTimers[player] = task.spawn(function()
		while elapsed < countdownTime do
			task.wait(TICK_RATE)
			elapsed += TICK_RATE

			if not character or not humanoid or not character.Parent or not humanoid.Parent then
				_bleedoutTimers[player] = nil
				return
			end

			if character:GetAttribute("LifeState") ~= "DBNO" then
				return
			end

			humanoid.Health = math.max(0, humanoid.Health - drainPerTick)

			local remaining = math.max(0, countdownTime - elapsed)
			character:SetAttribute("DBNOTimeRemaining", remaining)

			if humanoid.Health <= 0 then
				_killFromBleedout(player, character, humanoid)
				return
			end
		end

		if character.Parent and humanoid.Parent then
			_killFromBleedout(player, character, humanoid)
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE: LifeState attribute change handler
------------------------------------------------------------------------

local function _onLifeStateChanged(player: Player, character: Model, humanoid: Humanoid)
	local lifeState = character:GetAttribute("LifeState")

	if lifeState == "DBNO" then
		_startBleedout(player, character, humanoid)
	elseif lifeState == "Dead" or lifeState == "Alive" then
		_cancelBleedout(player)
		character:SetAttribute("DBNOTimeRemaining", nil)
		character:SetAttribute("DBNORevivePoints", nil)

		-- Al revivir, restaurar MaxHealth a MAX_HEALTH (DBNO lo sube a DBNO_HEALTH)
		if lifeState == "Alive" and humanoid.MaxHealth ~= Constants.MAX_HEALTH then
			humanoid.MaxHealth = Constants.MAX_HEALTH
			humanoid.Health = Constants.MAX_HEALTH
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Disable Roblox built-in health regen
------------------------------------------------------------------------

local function _disableDefaultHealthRegen(character: Model)
	-- Roblox coloca un LocalScript "Health" en StarterCharacterScripts
	-- que regenera 1% MaxHealth/s. Destruirlo para usar nuestro sistema.
	local healthScript = character:FindFirstChild("Health")
	if healthScript and healthScript:IsA("Script") or (healthScript and healthScript:IsA("LocalScript")) then
		healthScript:Destroy()
	end
end

------------------------------------------------------------------------
-- PRIVATE: Damage detection (for regen delay)
------------------------------------------------------------------------

local function _watchHealthChanges(player: Player, humanoid: Humanoid)
	-- Desconectar watcher anterior
	if _healthConnections[player] then
		_healthConnections[player]:Disconnect()
		_healthConnections[player] = nil
	end

	_previousHealth[player] = humanoid.Health

	_healthConnections[player] = humanoid:GetPropertyChangedSignal("Health"):Connect(function()
		local current = humanoid.Health
		local prev = _previousHealth[player] or current

		-- Si la vida bajó → recibió daño → registrar timestamp
		if current < prev then
			_lastDamageTime[player] = os.clock()
		end

		_previousHealth[player] = current
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Health regen (Heartbeat loop)
------------------------------------------------------------------------

local function _regenTick(dt: number)
	local now = os.clock()
	local regenDelay = Constants.HEALTH_REGEN_DELAY
	local regenRate = Constants.HEALTH_REGEN_RATE
	local regenRateCover = Constants.HEALTH_REGEN_RATE_COVER
	local maxHP = Constants.MAX_HEALTH

	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then
			continue
		end

		local lifeState = character:GetAttribute("LifeState")
		if lifeState ~= "Alive" then
			continue
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			continue
		end

		-- No regenerar si ya está al máximo
		if humanoid.Health >= maxHP then
			continue
		end

		-- No regenerar si recibió daño recientemente
		local lastDmg = _lastDamageTime[player] or 0
		if now - lastDmg < regenDelay then
			continue
		end

		-- Elegir tasa de regen según cover state
		local rate = if _inCover[player] then regenRateCover else regenRate
		local newHP = math.min(humanoid.Health + rate * dt, maxHP)
		humanoid.Health = newHP
	end
end

------------------------------------------------------------------------
-- PRIVATE: Bind character (on spawn/respawn)
------------------------------------------------------------------------

local function _bindCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	-- Desactivar regen nativa de Roblox
	_disableDefaultHealthRegen(character)

	-- Configurar salud
	humanoid.MaxHealth = Constants.MAX_HEALTH
	humanoid.Health = Constants.MAX_HEALTH

	-- Resetear tracking de regen
	_lastDamageTime[player] = 0
	_previousHealth[player] = Constants.MAX_HEALTH
	_inCover[player] = false

	character:SetAttribute("LifeState", "Alive")

	-- Watcher de daño (para regen delay)
	_watchHealthChanges(player, humanoid)

	if _lifeStateConnections[player] then
		_lifeStateConnections[player]:Disconnect()
		_lifeStateConnections[player] = nil
	end

	_lifeStateConnections[player] = character:GetAttributeChangedSignal("LifeState"):Connect(function()
		_onLifeStateChanged(player, character, humanoid)
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Player lifecycle
------------------------------------------------------------------------

local function _onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		_cancelBleedout(player)
		_bindCharacter(player, character)
	end)

	if player.Character then
		_bindCharacter(player, player.Character)
	end
end

local function _onPlayerRemoving(player: Player)
	_cancelBleedout(player)
	if _lifeStateConnections[player] then
		_lifeStateConnections[player]:Disconnect()
		_lifeStateConnections[player] = nil
	end
	if _healthConnections[player] then
		_healthConnections[player]:Disconnect()
		_healthConnections[player] = nil
	end
	_lastDamageTime[player] = nil
	_previousHealth[player] = nil
	_inCover[player] = nil
end

------------------------------------------------------------------------
-- PUBLIC API (Init / Start / Destroy)
------------------------------------------------------------------------

function CombatService:Init()
	-- Crear RemoteEvent para recibir cover state del cliente
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	_coverStateRemote = Instance.new("RemoteEvent")
	_coverStateRemote.Name = "CoverStateChanged"
	_coverStateRemote.Parent = remotesFolder
end

function CombatService:Start()
	Players.PlayerAdded:Connect(_onPlayerAdded)
	Players.PlayerRemoving:Connect(_onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(_onPlayerAdded, player)
	end

	-- Escuchar cover state del cliente (solo afecta tasa de regen, no HP)
	_coverStateRemote.OnServerEvent:Connect(function(player: Player, inCover: any)
		if typeof(inCover) == "boolean" then
			_inCover[player] = inCover
		end
	end)

	-- Heartbeat: health regen tick
	_heartbeatConn = RunService.Heartbeat:Connect(_regenTick)
end

function CombatService:Destroy()
	if _heartbeatConn then
		_heartbeatConn:Disconnect()
		_heartbeatConn = nil
	end
	for player, _ in _bleedoutTimers do
		_cancelBleedout(player)
	end
	for _, conn in _lifeStateConnections do
		conn:Disconnect()
	end
	for _, conn in _healthConnections do
		conn:Disconnect()
	end
	table.clear(_lifeStateConnections)
	table.clear(_healthConnections)
	table.clear(_lastDamageTime)
	table.clear(_previousHealth)
	table.clear(_inCover)
end

return CombatService
