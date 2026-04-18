--[[
	DeathPhysicsHandler.luau
	═══════════════════════════════════════════════════════════════
	Aplica fuerzas físicas de muerte en el CLIENTE.
	═══════════════════════════════════════════════════════════════

	El servidor (HealthStateManager) escribe atributos y ejecuta cambios
	estructurales que deben replicar (ragdoll, destruir attachments, kill).

	Este módulo observa LifeState = "Dead" en TODOS los characters y
	aplica las fuerzas físicas (velocidades) desde el cliente, evitando
	que el servidor tenga que ejecutar SetNetworkOwner(nil) + cálculos
	de física para cada muerte.

	Cada cliente aplica fuerzas solo si el character fue asignado a él
	vía el atributo `ClientPhysicsOwner`.
	- Para los jugadores: se asignan a sí mismos.
	- Para NPCs: el servidor se los asigna al jugador que los mató
	  (o al jugador más cercano).

	Atributos que lee del Character (escritos por HealthStateManager):
	  ClientPhysicsOwner  → Nombre del jugador que debe ejecutar la física
	  DeathType           → "Standard" | "Dismember" | "Headshot"
	  DeathHitDirection   → Vector3 (dirección normalizada de impacto)
	  DeathOverkillDamage → number (daño excedente sobre 0 HP)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local DeathPhysicsHandler = {}
DeathPhysicsHandler.__index = DeathPhysicsHandler

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local HEADSHOT_FORCE_MULTIPLIER = Constants.HEADSHOT_FORCE_MULTIPLIER or 50
local DISMEMBER_FORCE_MULTIPLIER = Constants.DISMEMBER_FORCE_MULTIPLIER or 15
local BODY_FORCE_MULTIPLIER = Constants.BODY_FORCE_MULTIPLIER or 1.2
local MIN_BODY_FORCE = Constants.MIN_BODY_FORCE or 1
local MAX_FORCE = Constants.MAX_FORCE or 100

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function DeathPhysicsHandler.new()
	local self = setmetatable({}, DeathPhysicsHandler)
	self._connections = {} :: { RBXScriptConnection }
	return self
end

------------------------------------------------------------------------
-- PRIVATE: Force application
------------------------------------------------------------------------

--- Fuerza al HumanoidRootPart (standard y headshot)
local function _applyBodyForce(character: Model, hitDirection: Vector3, overkillDamage: number)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	local forceMagnitude = math.clamp(overkillDamage * BODY_FORCE_MULTIPLIER, MIN_BODY_FORCE, MAX_FORCE)
	hrp.AssemblyLinearVelocity = hitDirection * forceMagnitude
end

--- Standard: fuerza al cuerpo
local function _applyStandardForces(character: Model, hitDirection: Vector3?, overkillDamage: number)
	if hitDirection then
		_applyBodyForce(character, hitDirection, overkillDamage)
	end
end

--- Headshot: fuerza a la cabeza + fuerza al cuerpo
local function _applyHeadshotForces(character: Model, hitDirection: Vector3, overkillDamage: number)
	local head = character:FindFirstChild("Head") :: BasePart?
	if head then
		local force = math.min(math.max(overkillDamage, 5) * HEADSHOT_FORCE_MULTIPLIER, MAX_FORCE)
		local upComponent = Vector3.new(0, 0.4, 0)
		head.AssemblyLinearVelocity = (hitDirection + upComponent).Unit * force
		head.AssemblyAngularVelocity =
			Vector3.new((math.random() - 0.5) * 20, (math.random() - 0.5) * 20, (math.random() - 0.5) * 20)
	end
	_applyBodyForce(character, hitDirection, overkillDamage)
end

--- Dismember: fuerza con spread a cada part
local function _applyDismemberForces(character: Model, hitDirection: Vector3, overkillDamage: number)
	local force = math.min(math.max(overkillDamage, 5) * DISMEMBER_FORCE_MULTIPLIER, MAX_FORCE)

	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			local randomSpread = Vector3.new(math.random() - 0.5, math.random() * 0.5 + 0.3, math.random() - 0.5).Unit
			local finalDir = (hitDirection * 0.7 + randomSpread * 0.3).Unit

			part.AssemblyLinearVelocity = finalDir * force
			part.AssemblyAngularVelocity = Vector3.new(
				(math.random() - 0.5) * force * 0.1,
				(math.random() - 0.5) * force * 0.1,
				(math.random() - 0.5) * force * 0.1
			)
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Death handler — dispatches by DeathType
------------------------------------------------------------------------

function DeathPhysicsHandler:_onCharacterDied(character: Model)
	-- Verificar si nuestro cliente es el asignado para simular física
	local physicsOwner = character:GetAttribute("ClientPhysicsOwner")
	if physicsOwner ~= Players.LocalPlayer.Name then
		return
	end

	local deathType = character:GetAttribute("DeathType") or "Standard"
	local hitDirection = character:GetAttribute("DeathHitDirection") :: Vector3?
	local overkillDamage = (character:GetAttribute("DeathOverkillDamage") or 0) :: number

	if deathType == "Headshot" and hitDirection then
		_applyHeadshotForces(character, hitDirection, overkillDamage)
	elseif deathType == "Dismember" and hitDirection then
		_applyDismemberForces(character, hitDirection, overkillDamage)
	else
		_applyStandardForces(character, hitDirection, overkillDamage)
	end
end

------------------------------------------------------------------------
-- PRIVATE: Observe characters (players + NPCs)
------------------------------------------------------------------------

function DeathPhysicsHandler:_observeCharacter(character: Model)
	local deathHandled = false

	local conn = character:GetAttributeChangedSignal("LifeState"):Connect(function()
		if deathHandled then
			return
		end
		local lifeState = character:GetAttribute("LifeState")
		if lifeState == "Dead" then
			deathHandled = true
			self:_onCharacterDied(character)
		end
	end)
	table.insert(self._connections, conn)

	-- Cleanup when character is removed
	local cleanupConn
	cleanupConn = character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			conn:Disconnect()
			cleanupConn:Disconnect()
		end
	end)
	table.insert(self._connections, cleanupConn)

	-- Check if already dead at subscription time
	if character:GetAttribute("LifeState") == "Dead" and not deathHandled then
		deathHandled = true
		self:_onCharacterDied(character)
	end
end

------------------------------------------------------------------------
-- PRIVATE: NPC AND PLAYER TRACKING
------------------------------------------------------------------------

local function _isNPC(model: Model): boolean
	if not model:IsA("Model") then
		return false
	end
	if not model:FindFirstChildWhichIsA("Humanoid") then
		return false
	end
	if Players:GetPlayerFromCharacter(model) then
		return false
	end
	return true
end

function DeathPhysicsHandler:_scanForNPCs(container: Instance)
	for _, child in container:GetChildren() do
		if _isNPC(child :: Model) then
			self:_observeCharacter(child :: Model)
		end
	end
end

function DeathPhysicsHandler:_trackPlayer(player: Player)
	if player.Character then
		self:_observeCharacter(player.Character)
	end
	table.insert(
		self._connections,
		player.CharacterAdded:Connect(function(character)
			self:_observeCharacter(character)
		end)
	)
end

------------------------------------------------------------------------
-- PUBLIC API (Lifecycle)
------------------------------------------------------------------------

function DeathPhysicsHandler:Init()
	-- No side-effects
end

function DeathPhysicsHandler:Start()
	local Workspace = game:GetService("Workspace")

	-- Track all players
	for _, player in Players:GetPlayers() do
		self:_trackPlayer(player)
	end

	table.insert(
		self._connections,
		Players.PlayerAdded:Connect(function(player)
			self:_trackPlayer(player)
		end)
	)

	-- Track NPCs
	self:_scanForNPCs(Workspace)

	table.insert(
		self._connections,
		Workspace.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("Humanoid") then
				local model = descendant.Parent
				if model and _isNPC(model :: Model) then
					self:_observeCharacter(model :: Model)
				end
			end
		end)
	)
end

function DeathPhysicsHandler:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

return DeathPhysicsHandler
