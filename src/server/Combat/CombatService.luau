--[[
	CombatService.luau
	═══════════════════════════════════════════════════════════════
	Servicio AUTORITATIVO de combate en el servidor.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	- Configurar MaxHealth al spawn
	- Detectar transición Alive → DBNO cuando HP ≤ DBNO_HEALTH
	- Ejecutar bleedout gradual durante DBNO (drena HP en 30s)
	- Matar al jugador cuando HP llega a 0 o bleedout expira
	- Resetear estado al respawn (CharacterAdded)

	Replicación:
	- Usa Attribute "LifeState" en el Character Model.
	- Roblox replica atributos automáticamente a todos los clientes.
	- Valores posibles: "Alive", "DBNO", "Dead"

	REGLA 05: El servidor es AUTORITATIVO sobre HP, DBNO y muerte.
	El cliente NUNCA modifica estos valores — solo los observa.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local CombatService = {}

--- Timers de bleedout activos por jugador.
--- key = Player, value = thread (task.spawn)
local _bleedoutTimers: { [Player]: thread } = {}

--- Conexiones de HealthChanged por jugador (para desconectar al respawn).
local _healthConnections: { [Player]: RBXScriptConnection } = {}

------------------------------------------------------------------------
-- PRIVATE: Kill player
------------------------------------------------------------------------

local function _cancelBleedout(player: Player)
	local timer = _bleedoutTimers[player]
	if timer then
		task.cancel(timer)
		_bleedoutTimers[player] = nil
	end
end

local function _killPlayer(player: Player, character: Model, humanoid: Humanoid)
	_cancelBleedout(player)
	character:SetAttribute("LifeState", "Dead")
	humanoid.Health = 0
end

------------------------------------------------------------------------
-- PRIVATE: Bleedout (gradual HP drain during DBNO)
------------------------------------------------------------------------

local function _startBleedout(player: Player, character: Model, humanoid: Humanoid)
	_cancelBleedout(player)

	local drainPerSecond = Constants.DBNO_HEALTH / Constants.DBNO_BLEEDOUT_TIME
	local TICK_RATE = 0.5 -- drain every 0.5s for smooth visual feedback
	local drainPerTick = drainPerSecond * TICK_RATE
	local elapsed = 0

	_bleedoutTimers[player] = task.spawn(function()
		while elapsed < Constants.DBNO_BLEEDOUT_TIME do
			task.wait(TICK_RATE)
			elapsed += TICK_RATE

			-- Guard: character may have been destroyed (disconnect, etc.)
			if not character.Parent or not humanoid.Parent then
				_cancelBleedout(player)
				return
			end

			-- Guard: LifeState may have changed (revived in future)
			if character:GetAttribute("LifeState") ~= "DBNO" then
				return
			end

			humanoid.Health = math.max(0, humanoid.Health - drainPerTick)

			if humanoid.Health <= 0 then
				_killPlayer(player, character, humanoid)
				return
			end
		end

		-- Bleedout expired — kill
		if character.Parent and humanoid.Parent then
			_killPlayer(player, character, humanoid)
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Health changed handler
------------------------------------------------------------------------

local function _onHealthChanged(player: Player, character: Model, humanoid: Humanoid)
	local newHealth = humanoid.Health
	local lifeState = character:GetAttribute("LifeState")

	if lifeState == "Alive" and newHealth <= Constants.DBNO_HEALTH and newHealth > 0 then
		-- Transition to DBNO
		character:SetAttribute("LifeState", "DBNO")
		-- Clamp health to DBNO threshold (prevent one-shot skip from Alive to Dead)
		humanoid.Health = math.min(newHealth, Constants.DBNO_HEALTH)
		_startBleedout(player, character, humanoid)
	elseif lifeState == "DBNO" and newHealth <= 0 then
		_killPlayer(player, character, humanoid)
	elseif lifeState == "Alive" and newHealth <= 0 then
		-- Edge case: massive damage skips DBNO entirely → still kill
		_killPlayer(player, character, humanoid)
	end
end

------------------------------------------------------------------------
-- PRIVATE: Bind character (on spawn/respawn)
------------------------------------------------------------------------

local function _bindCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	-- Configure health
	humanoid.MaxHealth = Constants.MAX_HEALTH
	humanoid.Health = Constants.MAX_HEALTH

	-- Set initial LifeState attribute (replicated to clients automatically)
	character:SetAttribute("LifeState", "Alive")

	-- Disconnect previous HealthChanged connection (if any from previous character)
	if _healthConnections[player] then
		_healthConnections[player]:Disconnect()
		_healthConnections[player] = nil
	end

	-- Listen for health changes
	_healthConnections[player] = humanoid.HealthChanged:Connect(function()
		_onHealthChanged(player, character, humanoid)
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Player lifecycle
------------------------------------------------------------------------

local function _onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		-- Cancel any leftover bleedout from previous life
		_cancelBleedout(player)
		_bindCharacter(player, character)
	end)

	-- If character already exists (late join / rejoin)
	if player.Character then
		_bindCharacter(player, player.Character)
	end
end

local function _onPlayerRemoving(player: Player)
	_cancelBleedout(player)
	if _healthConnections[player] then
		_healthConnections[player]:Disconnect()
		_healthConnections[player] = nil
	end
end

------------------------------------------------------------------------
-- PUBLIC API (Init / Start / Destroy)
------------------------------------------------------------------------

function CombatService:Init()
	-- No side-effects
end

function CombatService:Start()
	Players.PlayerAdded:Connect(_onPlayerAdded)
	Players.PlayerRemoving:Connect(_onPlayerRemoving)

	-- Handle players already in game (Studio quick-start)
	for _, player in Players:GetPlayers() do
		task.spawn(_onPlayerAdded, player)
	end
end

function CombatService:Destroy()
	-- Cleanup all bleedout timers
	for player, _ in _bleedoutTimers do
		_cancelBleedout(player)
	end
	for player, conn in _healthConnections do
		conn:Disconnect()
		_healthConnections[player] = nil
	end
end

return CombatService
