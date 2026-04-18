--[[
	DBNOService.luau
	═══════════════════════════════════════════════════════════════
	Servicio autoritativo de mecánicas DBNO en el servidor.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	- Auto-revive: validar input del cliente, acumular puntos, ejecutar revive
	- ProximityPrompt: crear/destruir prompts en personajes DBNO
	- Team resolution: aliado → Revive, enemigo → Eliminate (sin animación)

	Atributos escritos (en Character):
	  DBNORevivePoints  → number (puntos acumulados, replicado para UI)

	Comunicación:
	  RemoteEvent "DBNOSelfRevive" (client → server)
	  ProximityPrompt.Triggered (server-side)

	Separación de autoridad:
	  CombatService: countdown timer, bleedout, HP drain, atributo DBNOTimeRemaining
	  DBNOService: auto-revive, proximity prompts, team-based resolution
	  HealthStateManager: daño → DBNO / muerte por arma

	REGLA 05: El servidor es AUTORITATIVO sobre revive y eliminate.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local DBNOService = {}

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------

--- RemoteEvent para auto-revive (client → server)
local _selfReviveRemote: RemoteEvent = nil :: any

--- Último intento de auto-revive por jugador (timestamp para cooldown)
local _lastReviveAttempts: { [Player]: number } = {}

--- ProximityPrompts activos por jugador DBNO
local _proximityPrompts: { [Player]: ProximityPrompt } = {}

--- Conexiones de ProximityPrompt.Triggered por jugador
local _promptConnections: { [Player]: RBXScriptConnection } = {}

--- Conexiones de LifeState watcher por jugador
local _lifeStateConnections: { [Player]: RBXScriptConnection } = {}

------------------------------------------------------------------------
-- PRIVATE: Team helpers
------------------------------------------------------------------------

--- Determina si dos jugadores son aliados (mismo equipo).
--- Sin equipo → no es aliado de nadie.
local function _isAlly(player1: Player, player2: Player): boolean
	if player1.Team == nil or player2.Team == nil then
		return false
	end
	return player1.Team == player2.Team
end

------------------------------------------------------------------------
-- PRIVATE: Revive & Eliminate
------------------------------------------------------------------------

--- Revive a un jugador DBNO: restaura LifeState y HP.
--- CombatService reacciona al cambio de LifeState → cancela bleedout.
local function _revivePlayer(player: Player, character: Model, humanoid: Humanoid)
	character:SetAttribute("LifeState", "Alive")
	humanoid.Health = Constants.MAX_HEALTH

	-- Limpiar atributos DBNO
	character:SetAttribute("DBNOTimeRemaining", nil)
	character:SetAttribute("DBNORevivePoints", nil)

	-- Limpiar cooldown
	_lastReviveAttempts[player] = nil
end

--- Elimina directamente a un jugador DBNO (enemigo interactuó).
--- Sin animación de ejecución por ahora — eliminación directa.
local function _eliminatePlayer(character: Model, humanoid: Humanoid, killerName: string?)
	character:SetAttribute("LifeState", "Dead")
	character:SetAttribute("DeathType", "Executed")
	if killerName then
		character:SetAttribute("KillerName", killerName)
	end
	humanoid.Health = 0
end

------------------------------------------------------------------------
-- PRIVATE: ProximityPrompt management
------------------------------------------------------------------------

local function _removePrompt(player: Player)
	if _proximityPrompts[player] then
		_proximityPrompts[player]:Destroy()
		_proximityPrompts[player] = nil
	end
	if _promptConnections[player] then
		_promptConnections[player]:Disconnect()
		_promptConnections[player] = nil
	end
end

local function _createPrompt(player: Player, character: Model)
	_removePrompt(player)

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = player.DisplayName
	prompt.ActionText = "Interact"
	prompt.MaxActivationDistance = Constants.DBNO_PROMPT_RANGE
	prompt.HoldDuration = Constants.DBNO_PROMPT_HOLD_TIME
	prompt.RequiresLineOfSight = false
	prompt.Parent = hrp

	_proximityPrompts[player] = prompt

	_promptConnections[player] = prompt.Triggered:Connect(function(interactor: Player)
		-- Guard: todavía en DBNO
		if character:GetAttribute("LifeState") ~= "DBNO" then
			return
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not humanoid or humanoid.Health <= 0 then
			return
		end

		-- Resolver acción según equipo
		if _isAlly(interactor, player) then
			_revivePlayer(player, character, humanoid)
		else
			_eliminatePlayer(character, humanoid, interactor.Name)
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Self-revive handler
------------------------------------------------------------------------

local function _onSelfReviveRequest(player: Player)
	local character = player.Character
	if not character then
		return
	end

	-- Guard: debe estar en DBNO
	local lifeState = character:GetAttribute("LifeState")
	if lifeState ~= "DBNO" then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	-- Cooldown server-side (autoritativo)
	local now = os.clock()
	local lastAttempt = _lastReviveAttempts[player] or 0
	if now - lastAttempt < Constants.DBNO_REVIVE_COOLDOWN then
		return
	end
	_lastReviveAttempts[player] = now

	-- Determinar puntos según movimiento
	local isMoving = humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD
	local points = isMoving and Constants.DBNO_REVIVE_POINTS_MOVING or Constants.DBNO_REVIVE_POINTS_STILL

	-- Acumular puntos
	local current = character:GetAttribute("DBNORevivePoints") or 0
	local newPoints = current + points
	character:SetAttribute("DBNORevivePoints", newPoints)

	-- Verificar umbral de auto-revive
	if newPoints >= Constants.DBNO_REVIVE_THRESHOLD then
		_revivePlayer(player, character, humanoid)
	end
end

------------------------------------------------------------------------
-- PRIVATE: LifeState watcher
------------------------------------------------------------------------

local function _onLifeStateChanged(player: Player, character: Model)
	local lifeState = character:GetAttribute("LifeState")

	if lifeState == "DBNO" then
		_createPrompt(player, character)
	else
		_removePrompt(player)
		_lastReviveAttempts[player] = nil
	end
end

local function _bindCharacter(player: Player, character: Model)
	-- Limpiar anterior
	if _lifeStateConnections[player] then
		_lifeStateConnections[player]:Disconnect()
	end
	_removePrompt(player)
	_lastReviveAttempts[player] = nil

	_lifeStateConnections[player] = character:GetAttributeChangedSignal("LifeState"):Connect(function()
		_onLifeStateChanged(player, character)
	end)

	-- Verificar estado inicial (por si ya está en DBNO al bindear)
	local initialState = character:GetAttribute("LifeState")
	if initialState == "DBNO" then
		_createPrompt(player, character)
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
	_removePrompt(player)
	_lastReviveAttempts[player] = nil
	if _lifeStateConnections[player] then
		_lifeStateConnections[player]:Disconnect()
		_lifeStateConnections[player] = nil
	end
end

------------------------------------------------------------------------
-- PUBLIC API (Init / Start / Destroy)
------------------------------------------------------------------------

function DBNOService:Init()
	-- Crear RemoteEvent
	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotesFolder then
		remotesFolder = Instance.new("Folder")
		remotesFolder.Name = "Remotes"
		remotesFolder.Parent = ReplicatedStorage
	end

	_selfReviveRemote = Instance.new("RemoteEvent")
	_selfReviveRemote.Name = "DBNOSelfRevive"
	_selfReviveRemote.Parent = remotesFolder
end

function DBNOService:Start()
	_selfReviveRemote.OnServerEvent:Connect(function(player: Player)
		_onSelfReviveRequest(player)
	end)

	Players.PlayerAdded:Connect(_onPlayerAdded)
	Players.PlayerRemoving:Connect(_onPlayerRemoving)

	-- Handle players already in game (Studio quick-start)
	for _, player in Players:GetPlayers() do
		task.spawn(_onPlayerAdded, player)
	end
end

function DBNOService:Destroy()
	for player, _ in _proximityPrompts do
		_removePrompt(player)
	end
	for _, conn in _lifeStateConnections do
		conn:Disconnect()
	end
	table.clear(_lifeStateConnections)
	table.clear(_lastReviveAttempts)
end

return DBNOService
