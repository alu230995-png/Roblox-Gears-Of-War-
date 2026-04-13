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

function DeathEffectsHandler.new()
	local self = setmetatable({}, DeathEffectsHandler)

	self._characterConnections = {} :: { [Model]: { RBXScriptConnection } }
	self._globalConnections = {} :: { RBXScriptConnection }

	return self
end

------------------------------------------------------------------------
-- PRIVATE: Client-only VFX on death (particles, sounds, etc.)
------------------------------------------------------------------------

local function _onDeath(_character: Model)
	-- TODO: agregar efectos client-only aquí:
	--   - Partículas de sangre según DeathType
	--   - Sonido de muerte
	--   - Screen shake si el local player es el killer
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

	table.insert(
		connections,
		character:GetAttributeChangedSignal("LifeState"):Connect(function()
			local lifeState = character:GetAttribute("LifeState")
			if lifeState == "Dead" then
				_onDeath(character)
			end
		end)
	)

	table.insert(
		connections,
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				self:_cleanupCharacter(character)
			end
		end)
	)

	if character:GetAttribute("LifeState") == "Dead" then
		_onDeath(character)
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
