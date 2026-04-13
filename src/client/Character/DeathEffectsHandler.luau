--[[
	DeathEffectsHandler.luau
	═══════════════════════════════════════════════════════════════
	Efectos visuales de muerte — ejecutados en el CLIENTE.
	═══════════════════════════════════════════════════════════════

	Toda la física de muerte (ragdoll, fuerzas, attachments) se ejecuta
	en el SERVIDOR (HealthStateManager) para replicar a TODOS los clientes.

	Este módulo observa LifeState en todos los Characters y aplica
	SOLO efectos client-only que no necesitan replicar:
	  - Partículas de sangre / gore
	  - Sonidos de muerte
	  - Screen shake en el killer
	  - Etc. (a agregar según se necesite)

	Atributos que lee del Character:
	  LifeState           → "Dead" dispara el efecto
	  DeathType           → "Standard" | "Dismember" | "Headshot" | "Bleedout"
	  DeathHitDirection   → Vector3? (dirección de impacto)
	  DeathOverkillDamage → number? (daño excedente)
]]

local Players = game:GetService("Players")

local DeathEffectsHandler = {}
DeathEffectsHandler.__index = DeathEffectsHandler

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function DeathEffectsHandler.new(effectsController: any?)
	local self = setmetatable({}, DeathEffectsHandler)

	self._effectsController = effectsController
	self._characterConnections = {} :: { [Model]: { RBXScriptConnection } }
	self._globalConnections = {} :: { RBXScriptConnection }

	return self
end

------------------------------------------------------------------------
-- PRIVATE: Client-only VFX on death (particles, sounds, screen shake)
------------------------------------------------------------------------

function DeathEffectsHandler:_onDeath(character: Model)
	if not self._effectsController then
		return
	end

	local deathType = character:GetAttribute("DeathType") or "Standard"
	local hitDirection = character:GetAttribute("DeathHitDirection")
	local overkillDamage = character:GetAttribute("DeathOverkillDamage") or 0

	self._effectsController:OnDeath(character, deathType, hitDirection, overkillDamage)
end

------------------------------------------------------------------------
-- PRIVATE: Observe a character's LifeState
------------------------------------------------------------------------

function DeathEffectsHandler:_observeCharacter(character: Model)
	if self._characterConnections[character] then
		return
	end

	local connections = {} :: { RBXScriptConnection }
	self._characterConnections[character] = connections
	local deathFired = false

	local function triggerDeath()
		if deathFired then
			return
		end
		deathFired = true
		self:_onDeath(character)
	end

	-- Primary path: LifeState attribute set by HealthStateManager
	table.insert(
		connections,
		character:GetAttributeChangedSignal("LifeState"):Connect(function()
			local lifeState = character:GetAttribute("LifeState")
			if lifeState == "Dead" then
				triggerDeath()
			end
		end)
	)

	-- Fallback: Humanoid.Died covers deaths that bypass HealthStateManager
	-- (fall damage, reset, void, etc.)
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		table.insert(
			connections,
			humanoid.Died:Connect(function()
				triggerDeath()
			end)
		)
	end

	table.insert(
		connections,
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				self:_cleanupCharacter(character)
			end
		end)
	)

	-- Check if already dead at subscription time
	if character:GetAttribute("LifeState") == "Dead" then
		triggerDeath()
	end
end

function DeathEffectsHandler:_cleanupCharacter(character: Model)
	local connections = self._characterConnections[character]
	if connections then
		for _, conn in connections do
			conn:Disconnect()
		end
		self._characterConnections[character] = nil
	end
end

------------------------------------------------------------------------
-- PRIVATE: Player tracking
------------------------------------------------------------------------

function DeathEffectsHandler:_trackPlayer(player: Player)
	if player.Character then
		self:_observeCharacter(player.Character)
	end

	table.insert(
		self._globalConnections,
		player.CharacterAdded:Connect(function(character)
			self:_observeCharacter(character)
		end)
	)
end

------------------------------------------------------------------------
-- PUBLIC API (Lifecycle)
------------------------------------------------------------------------

function DeathEffectsHandler:Init()
	-- No side-effects
end

function DeathEffectsHandler:Start()
	for _, player in Players:GetPlayers() do
		self:_trackPlayer(player)
	end

	table.insert(
		self._globalConnections,
		Players.PlayerAdded:Connect(function(player)
			self:_trackPlayer(player)
		end)
	)
end

function DeathEffectsHandler:Destroy()
	for _, conn in self._globalConnections do
		conn:Disconnect()
	end
	self._globalConnections = {}

	for character, _ in self._characterConnections do
		self:_cleanupCharacter(character)
	end
end

return DeathEffectsHandler
