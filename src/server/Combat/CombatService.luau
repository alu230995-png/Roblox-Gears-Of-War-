--[[
	CombatService.luau
	═══════════════════════════════════════════════════════════════
	Servicio de combate — setup de personaje y bleedout.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	- Configurar MaxHealth al spawn
	- Escuchar cambios de LifeState (set por HealthStateManager):
	    "DBNO" → iniciar bleedout gradual (drena HP en 30s)
	    "Dead" → cancelar bleedout
	    "Alive" → cancelar bleedout (revive futuro)
	- Matar por bleedout cuando HP llega a 0 (DeathType="Bleedout")
	- Resetear estado al respawn (CharacterAdded)

	Separación de autoridad:
	- HealthStateManager: autoridad sobre daño → DBNO / muerte por arma
	- CombatService: autoridad sobre setup HP y bleedout
	- Comunicación: via Attribute "LifeState" en el Character Model

	Replicación:
	- Roblox replica atributos automáticamente a todos los clientes.
	- Valores: "Alive", "DBNO", "Dead"
	- DeathType: "Standard", "Dismember", "Headshot", "Bleedout"

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

--- Conexiones de LifeState watcher por jugador (para desconectar al respawn).
local _lifeStateConnections: { [Player]: RBXScriptConnection } = {}

------------------------------------------------------------------------
-- PRIVATE: Kill player (bleedout death only)
------------------------------------------------------------------------

local function _cancelBleedout(player: Player)
	local timer = _bleedoutTimers[player]
	if timer then
		task.cancel(timer)
		_bleedoutTimers[player] = nil
	end
end

--- Muerte por bleedout: CombatService es el único que llama esto.
--- HealthStateManager maneja las muertes por daño de armas.
local function _killFromBleedout(player: Player, character: Model, humanoid: Humanoid)
	_cancelBleedout(player)
	character:SetAttribute("LifeState", "Dead")
	character:SetAttribute("DeathType", "Bleedout")
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
				_bleedoutTimers[player] = nil
				return
			end

			-- Guard: LifeState may have changed (killed by weapon or revived)
			if character:GetAttribute("LifeState") ~= "DBNO" then
				return
			end

			humanoid.Health = math.max(0, humanoid.Health - drainPerTick)

			if humanoid.Health <= 0 then
				_killFromBleedout(player, character, humanoid)
				return
			end
		end

		-- Bleedout expired — kill
		if character.Parent and humanoid.Parent then
			_killFromBleedout(player, character, humanoid)
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE: LifeState attribute change handler
------------------------------------------------------------------------
-- HealthStateManager es la autoridad para transiciones de daño:
--   Alive → DBNO, Alive → Dead, DBNO → Dead
-- CombatService SOLO reacciona al cambio de LifeState para:
--   "DBNO" → iniciar bleedout
--   "Dead" / "Alive" → cancelar bleedout

local function _onLifeStateChanged(player: Player, character: Model, humanoid: Humanoid)
	local lifeState = character:GetAttribute("LifeState")

	if lifeState == "DBNO" then
		_startBleedout(player, character, humanoid)
	elseif lifeState == "Dead" or lifeState == "Alive" then
		_cancelBleedout(player)
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

	-- Disconnect previous LifeState watcher (if any from previous character)
	if _lifeStateConnections[player] then
		_lifeStateConnections[player]:Disconnect()
		_lifeStateConnections[player] = nil
	end

	-- Watch LifeState attribute changes (set by HealthStateManager or this module)
	_lifeStateConnections[player] = character:GetAttributeChangedSignal("LifeState"):Connect(function()
		_onLifeStateChanged(player, character, humanoid)
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
	if _lifeStateConnections[player] then
		_lifeStateConnections[player]:Disconnect()
		_lifeStateConnections[player] = nil
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
	for player, conn in _lifeStateConnections do
		conn:Disconnect()
		_lifeStateConnections[player] = nil
	end
end

return CombatService
