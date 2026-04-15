--[[
	RespawnService.luau
	═══════════════════════════════════════════════════════════════
	Servicio autoritativo de respawn en el servidor.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	- Escuchar LifeState = "Dead" en todos los characters
	- Calcular tiempo de respawn basado en equipo:
	    Con equipo: si nadie del equipo está muerto → countdown global 10s
	                si alguien está muerto → usar su tiempo restante (min 2s)
	    Sin equipo / Neutral: countdown global por "equipo neutral" 10s
	- Enviar countdown al cliente via RemoteEvent (para UI)
	- Llamar player:LoadCharacter() cuando el countdown llega a 0

	Comunicación:
	- Escribe atributos en el Character para que el cliente lea
	- RemoteEvent "RespawnCountdown" → {TimeRemaining, IsGlobalCountdown}

	REGLA 05: El servidor es AUTORITATIVO sobre cuándo respawnear.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local RespawnService = {}

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------

--- Countdown global por equipo: Team → { timeRemaining, thread }
local _teamCountdowns: { [any]: { timeRemaining: number, thread: thread? } } = {}

--- Countdown global para jugadores sin equipo (Neutral)
local _neutralCountdown: { timeRemaining: number, thread: thread? } = { timeRemaining = 0, thread = nil }

--- Jugadores muertos pendientes de respawn: Player → { thread, character }
local _deadPlayers: { [Player]: { thread: thread?, character: Model? } } = {}

--- Conexiones por jugador
local _playerConnections: { [Player]: { RBXScriptConnection } } = {}

--- RemoteEvent para enviar countdown al cliente
local _respawnRemote: RemoteEvent = nil :: any

------------------------------------------------------------------------
-- PRIVATE: Team helpers
------------------------------------------------------------------------

--- Obtiene el Team del jugador, o nil si no tiene.
local function _getTeam(player: Player): Team?
	return player.Team
end

--- Obtiene todos los jugadores del mismo equipo que estén muertos.
local function _getDeadTeammates(player: Player): { Player }
	local team = _getTeam(player)
	local dead = {}

	for deadPlayer, _ in _deadPlayers do
		if deadPlayer ~= player and deadPlayer.Parent then
			if team then
				if deadPlayer.Team == team then
					table.insert(dead, deadPlayer)
				end
			else
				-- Sin equipo: agrupa con otros sin equipo
				if not deadPlayer.Team then
					table.insert(dead, deadPlayer)
				end
			end
		end
	end

	return dead
end

--- Obtiene la key del countdown global (Team instance o "Neutral").
local function _getCountdownKey(player: Player): any
	local team = _getTeam(player)
	return team or "Neutral"
end

--- Obtiene o crea el countdown state para un equipo/neutral.
local function _getCountdownState(key: any): { timeRemaining: number, thread: thread? }
	if key == "Neutral" then
		return _neutralCountdown
	end

	if not _teamCountdowns[key] then
		_teamCountdowns[key] = { timeRemaining = 0, thread = nil }
	end
	return _teamCountdowns[key]
end

------------------------------------------------------------------------
-- PRIVATE: Countdown logic
------------------------------------------------------------------------

--- Inicia el 10s countdown global para el equipo.
--- Solo se crea si no hay uno activo.
local function _startGlobalCountdown(key: any)
	local state = _getCountdownState(key)

	-- Si ya hay un countdown activo, no crear otro
	if state.thread then
		return
	end

	state.timeRemaining = Constants.RESPAWN_TEAM_COUNTDOWN

	state.thread = task.spawn(function()
		local TICK = 1.0
		while state.timeRemaining > 0 do
			task.wait(TICK)
			state.timeRemaining = math.max(0, state.timeRemaining - TICK)

			-- Notificar a todos los jugadores muertos de este equipo
			for deadPlayer, _ in _deadPlayers do
				if deadPlayer.Parent and _getCountdownKey(deadPlayer) == key then
					if _respawnRemote then
						_respawnRemote:FireClient(deadPlayer, {
							TimeRemaining = state.timeRemaining,
							IsGlobalCountdown = true,
						})
					end
				end
			end
		end

		-- Countdown terminó: respawnear a todos los muertos de este equipo
		state.thread = nil
		local toRespawn = {}
		for deadPlayer, _ in _deadPlayers do
			if deadPlayer.Parent and _getCountdownKey(deadPlayer) == key then
				table.insert(toRespawn, deadPlayer)
			end
		end
		for _, p in toRespawn do
			_deadPlayers[p] = nil
			pcall(function()
				p:LoadCharacter()
			end)
		end
	end)
end

--- Programa el respawn individual para un jugador (cuando un teammate ya está muerto).
local function _scheduleIndividualRespawn(player: Player, respawnTime: number)
	local data = _deadPlayers[player]
	if not data then
		return
	end

	-- Cancelar thread anterior si existe
	if data.thread then
		task.cancel(data.thread)
		data.thread = nil
	end

	data.thread = task.spawn(function()
		local remaining = respawnTime
		local TICK = 1.0
		while remaining > 0 do
			task.wait(TICK)
			remaining = math.max(0, remaining - TICK)

			if _respawnRemote and player.Parent then
				_respawnRemote:FireClient(player, {
					TimeRemaining = remaining,
					IsGlobalCountdown = false,
				})
			end
		end

		-- Respawnear
		if player.Parent then
			_deadPlayers[player] = nil
			pcall(function()
				player:LoadCharacter()
			end)
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Death handler
------------------------------------------------------------------------

local function _onPlayerDied(player: Player, character: Model)
	-- Registrar como muerto
	_deadPlayers[player] = { thread = nil, character = character }

	local key = _getCountdownKey(player)
	local deadTeammates = _getDeadTeammates(player)

	if #deadTeammates == 0 then
		-- Nadie más muerto en el equipo → iniciar countdown global
		_startGlobalCountdown(key)
	else
		-- Hay compañeros muertos → verificar tiempo restante del equipo
		local countdownState = _getCountdownState(key)
		local teamTimeRemaining = countdownState.timeRemaining

		local respawnTime: number
		if teamTimeRemaining > Constants.RESPAWN_MIN_TIME then
			-- Asignar el tiempo restante del equipo
			respawnTime = teamTimeRemaining
		else
			-- Mínimo 2 segundos
			respawnTime = Constants.RESPAWN_MIN_TIME
		end

		-- Respawn individual (no global)
		_scheduleIndividualRespawn(player, respawnTime)
	end

	-- Enviar estado inicial al cliente
	if _respawnRemote then
		local state = _getCountdownState(key)
		_respawnRemote:FireClient(player, {
			TimeRemaining = state.timeRemaining,
			IsGlobalCountdown = (#deadTeammates == 0),
		})
	end
end

------------------------------------------------------------------------
-- PRIVATE: LifeState watcher
------------------------------------------------------------------------

local function _bindCharacter(player: Player, character: Model)
	-- Limpiar conexiones anteriores
	if _playerConnections[player] then
		for _, conn in _playerConnections[player] do
			conn:Disconnect()
		end
	end
	_playerConnections[player] = {}

	-- Cancel pending respawn (fresh spawn)
	if _deadPlayers[player] then
		if _deadPlayers[player].thread then
			task.cancel(_deadPlayers[player].thread)
		end
		_deadPlayers[player] = nil
	end

	-- Escuchar LifeState
	table.insert(
		_playerConnections[player],
		character:GetAttributeChangedSignal("LifeState"):Connect(function()
			local lifeState = character:GetAttribute("LifeState")
			if lifeState == "Dead" then
				_onPlayerDied(player, character)
			end
		end)
	)

	-- Fallback: Humanoid.Died
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		table.insert(
			_playerConnections[player],
			humanoid.Died:Connect(function()
				if not _deadPlayers[player] then
					_onPlayerDied(player, character)
				end
			end)
		)
	end
end

------------------------------------------------------------------------
-- PRIVATE: Player lifecycle
------------------------------------------------------------------------

local function _onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		_bindCharacter(player, character)
	end)

	if player.Character then
		_bindCharacter(player, player.Character)
	end
end

local function _onPlayerRemoving(player: Player)
	-- Limpiar
	if _deadPlayers[player] then
		if _deadPlayers[player].thread then
			task.cancel(_deadPlayers[player].thread)
		end
		_deadPlayers[player] = nil
	end

	if _playerConnections[player] then
		for _, conn in _playerConnections[player] do
			conn:Disconnect()
		end
		_playerConnections[player] = nil
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function RespawnService:Init()
	-- Crear RemoteEvent
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	_respawnRemote = Instance.new("RemoteEvent")
	_respawnRemote.Name = "RespawnCountdown"
	_respawnRemote.Parent = remotesFolder
end

function RespawnService:Start()
	-- Desactivar respawn automático de Roblox
	Players.CharacterAutoLoads = false

	-- Conectar lifecycle ANTES de cargar characters
	Players.PlayerAdded:Connect(function(player)
		_onPlayerAdded(player)
		-- Defer LoadCharacter para que CoreScripts terminen de inicializar
		task.defer(function()
			player:LoadCharacter()
		end)
	end)
	Players.PlayerRemoving:Connect(_onPlayerRemoving)

	-- Spawn inicial de jugadores ya presentes (Studio quick-start)
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			_onPlayerAdded(player)
			task.defer(function()
				player:LoadCharacter()
			end)
		end)
	end
end

function RespawnService:Destroy()
	-- Cancelar todos los countdowns
	for _, data in _deadPlayers do
		if data.thread then
			task.cancel(data.thread)
		end
	end
	table.clear(_deadPlayers)

	for _, state in _teamCountdowns do
		if state.thread then
			task.cancel(state.thread)
		end
	end
	table.clear(_teamCountdowns)

	if _neutralCountdown.thread then
		task.cancel(_neutralCountdown.thread)
		_neutralCountdown.thread = nil
	end

	for _, conns in _playerConnections do
		for _, conn in conns do
			conn:Disconnect()
		end
	end
	table.clear(_playerConnections)
end

return RespawnService
