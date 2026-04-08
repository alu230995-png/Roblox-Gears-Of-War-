--[[
	SoundService.luau (Server)
	═══════════════════════════════════════════════════════════════
	Servicio autoritativo de sonido en el servidor.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades:
	  1. Crear RemoteEvents para el sistema de sonido
	  2. Validar peticiones de sonido de clientes (anti-cheat básico)
	  3. Replicar sonidos de un jugador a todos los demás
	  4. Emitir sonidos globales del servidor a todos los clientes
	
	Flujos:
	  A) Player → Server → Others:
	     Cliente llama SoundReplicate:FireServer(soundName, position)
	     Servidor valida soundName en SoundConfig
	     Servidor reenvía a TODOS excepto el jugador origen
	
	  B) Server → All:
	     Otro servicio del servidor llama SoundService:PlayForAll(soundName, position?)
	     Servidor dispara SoundFromServer a todos los clientes
	
	Rate limiting:
	  Cada jugador tiene un budget de sonidos por segundo para prevenir spam.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))

local SoundService = {}

------------------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------------------

local REMOTE_SOUND_REPLICATE = "SoundReplicate"
local REMOTE_SOUND_FROM_SERVER = "SoundFromServer"

-- Rate limiting: máximo sonidos por jugador por segundo
local MAX_SOUNDS_PER_SECOND = 15
local RATE_WINDOW = 1 -- segundos

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------

local _remoteReplicate: RemoteEvent = nil
local _remoteFromServer: RemoteEvent = nil
local _connections = {}

-- Rate limit tracker: { [Player] = { count: number, windowStart: number } }
local _rateLimits = {}

------------------------------------------------------------------------
-- INIT / START / DESTROY
------------------------------------------------------------------------

function SoundService:Init()
	-- Crear carpeta de Remotes si no existe
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	-- Crear RemoteEvents
	_remoteReplicate = Instance.new("RemoteEvent")
	_remoteReplicate.Name = REMOTE_SOUND_REPLICATE
	_remoteReplicate.Parent = remotesFolder

	_remoteFromServer = Instance.new("RemoteEvent")
	_remoteFromServer.Name = REMOTE_SOUND_FROM_SERVER
	_remoteFromServer.Parent = remotesFolder
end

function SoundService:Start()
	-- Escuchar peticiones de sonido de clientes
	local conn = _remoteReplicate.OnServerEvent:Connect(function(player: Player, soundName: any, position: any)
		self:_onClientSoundRequest(player, soundName, position)
	end)
	table.insert(_connections, conn)

	-- Limpiar rate limits cuando un jugador sale
	local leaveConn = Players.PlayerRemoving:Connect(function(player: Player)
		_rateLimits[player] = nil
	end)
	table.insert(_connections, leaveConn)
end

function SoundService:Destroy()
	for _, conn in _connections do
		conn:Disconnect()
	end
	table.clear(_connections)
	table.clear(_rateLimits)
end

------------------------------------------------------------------------
-- PUBLIC API — Para otros servicios del servidor
------------------------------------------------------------------------

--- Reproduce un sonido para TODOS los clientes (alarma, countdown, etc.)
function SoundService:PlayForAll(soundName: string, position: Vector3?)
	if not SoundConfig[soundName] then
		warn(`[SoundService] Sonido no encontrado en SoundConfig: {soundName}`)
		return
	end

	_remoteFromServer:FireAllClients(soundName, position)
end

--- Reproduce un sonido para UN jugador específico.
function SoundService:PlayForPlayer(player: Player, soundName: string, position: Vector3?)
	if not SoundConfig[soundName] then
		warn(`[SoundService] Sonido no encontrado en SoundConfig: {soundName}`)
		return
	end

	_remoteFromServer:FireClient(player, soundName, position)
end

--- Reproduce un sonido para todos EXCEPTO un jugador.
function SoundService:PlayForOthers(excludePlayer: Player, soundName: string, position: Vector3?)
	if not SoundConfig[soundName] then
		warn(`[SoundService] Sonido no encontrado en SoundConfig: {soundName}`)
		return
	end

	for _, player in Players:GetPlayers() do
		if player ~= excludePlayer then
			_remoteFromServer:FireClient(player, soundName, position)
		end
	end
end

------------------------------------------------------------------------
-- CLIENT REQUEST HANDLER
------------------------------------------------------------------------

function SoundService:_onClientSoundRequest(player: Player, soundName: any, position: any)
	-- Validación de tipos (anti-exploit)
	if type(soundName) ~= "string" then
		warn(`[SoundService] Tipo inválido de soundName de {player.Name}`)
		return
	end

	if position ~= nil and typeof(position) ~= "Vector3" then
		warn(`[SoundService] Tipo inválido de position de {player.Name}`)
		return
	end

	-- Validar que el sonido existe en config
	local config = SoundConfig[soundName]
	if not config then
		warn(`[SoundService] Sonido desconocido '{soundName}' de {player.Name}`)
		return
	end

	-- Rate limiting
	if not self:_checkRateLimit(player) then
		warn(`[SoundService] Rate limit excedido para {player.Name}`)
		return
	end

	-- Validar posición para sonidos Global
	if config.Scope == "Global" then
		if not position then
			-- Usar posición del personaje del jugador como fallback
			local character = player.Character
			if character then
				local root = character:FindFirstChild("HumanoidRootPart")
				if root then
					position = root.Position
				end
			end
		else
			-- Sanity check: la posición reportada no debe estar absurdamente lejos del jugador
			local character = player.Character
			if character then
				local root = character:FindFirstChild("HumanoidRootPart")
				if root and (position - root.Position).Magnitude > 50 then
					-- Posición sospechosa — usar posición real del jugador
					position = root.Position
				end
			end
		end
	end

	-- Replicar a todos los demás jugadores
	for _, otherPlayer in Players:GetPlayers() do
		if otherPlayer ~= player then
			_remoteReplicate:FireClient(otherPlayer, soundName, position, player)
		end
	end
end

------------------------------------------------------------------------
-- RATE LIMITING
------------------------------------------------------------------------

function SoundService:_checkRateLimit(player: Player): boolean
	local now = os.clock()
	local entry = _rateLimits[player]

	if not entry then
		_rateLimits[player] = { count = 1, windowStart = now }
		return true
	end

	-- Resetear ventana si expiró
	if now - entry.windowStart >= RATE_WINDOW then
		entry.count = 1
		entry.windowStart = now
		return true
	end

	-- Incrementar y verificar
	entry.count += 1
	return entry.count <= MAX_SOUNDS_PER_SECOND
end

return SoundService
