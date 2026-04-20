--[[
	MobileTouchHUD.luau
	═══════════════════════════════════════════════════════════════
	Sistema de botones táctiles para móvil — Data-Driven.
	═══════════════════════════════════════════════════════════════

	Lee TODA la configuración de botones desde PlayerBindings:
	  .MobileButtons     → Botones de combate/cover (via InputDetector)
	  .SpectatorButtons  → Botones de espectador (via SpectatorController)
	  .HoldThresholds    → Umbrales tap/hold para botones HoldSensitive

	Estrategia de clonado:
	  1. Clonar la ScreenGui COMPLETA desde ReplicatedStorage al PlayerGui
	  2. Buscar cada botón DENTRO del clon por UIName
	  3. Asignar acciones a los botones encontrados

	Visibilidad condicional por VisibilityGroup:
	  "Combat" → AliveGroup + Tool equipado
	  "Cover"  → AliveGroup (visible incluso en DBNO para self-revive)
	  Spectator buttons → solo en estado Spectator

	Assets esperados en ReplicatedStorage:
	  Assets/UI/MobileUI/                         ← ScreenGui que se clona
	    └── ContextActionService/                  ← Frame contenedor
	        ├── AimButton       (UIName)
	        ├── ReloadButton    (UIName)
	        ├── ShootButton     (UIName)
	        └── SpaceMoveButton (UIName)

	  Assets/UI/SpectatorMobileUI/                ← ScreenGui que se clona
	    └── ContextActionService/
	        ├── NextPlayerLeftButton  (UIName)
	        └── NextPlayerRightButton (UIName)

	Capa: Presentación (UI)
	Depende de: InputDetector (Capa 1), StateMachine, SpectatorController, PlayerBindings
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlayerBindings = require(script.Parent.Parent.Input.PlayerBindings)

local MobileTouchHUD = {}
MobileTouchHUD.__index = MobileTouchHUD

------------------------------------------------------------------------
-- MOBILE DETECTION
------------------------------------------------------------------------
local IS_MOBILE = UserInputService.TouchEnabled

------------------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------------------
local WAIT_TIMEOUT = 5

--- Retorna true si el InputObject es un tipo válido para botones (Touch o Mouse)
local function isValidButtonInput(input: InputObject): boolean
	local t = input.UserInputType
	return t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1
end

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function MobileTouchHUD.new(inputDetector, stateMachine, spectatorController)
	local self = setmetatable({}, MobileTouchHUD)

	self._inputDetector = inputDetector
	self._stateMachine = stateMachine
	self._spectatorController = spectatorController

	self._connections = {} :: { any }

	-- Cloned ScreenGuis (guardamos referencia para Destroy)
	self._combatScreenGui = nil :: ScreenGui?
	self._spectatorScreenGui = nil :: ScreenGui?

	-- Cloned button references keyed by config Id
	-- { [Id] = { instance: Instance, config: MobileButtonConfig } }
	self._combatButtons = {} :: { [string]: { instance: Instance, config: any } }
	self._spectatorButtonInstances = {} :: { [string]: Instance }

	-- State tracking
	self._hasToolEquipped = false
	self._isAlive = false
	self._isSpectator = false
	self._isDBNO = false

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function MobileTouchHUD:Init()
	-- Sin side-effects
end

function MobileTouchHUD:Start()
	if not IS_MOBILE then
		return
	end
	self:_cloneCombatScreen()
	self:_cloneSpectatorScreen()

	self:_wireCombatButtonEvents()
	self:_wireSpectatorButtonEvents()
	self:_wireStateEvents()
	self:_wireToolDetection()

	-- Evaluar estado inicial
	self:_evaluateState(self._stateMachine:GetCurrentState())
	self:_updateVisibility()
end

function MobileTouchHUD:Destroy()
	for _, conn in self._connections do
		if type(conn) == "table" and type(conn.Disconnect) == "function" then
			conn:Disconnect()
		elseif typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)

	if self._combatScreenGui then
		self._combatScreenGui:Destroy()
		self._combatScreenGui = nil
	end
	if self._spectatorScreenGui then
		self._spectatorScreenGui:Destroy()
		self._spectatorScreenGui = nil
	end
end

------------------------------------------------------------------------
-- PRIVATE: Safe navigation with timeout
------------------------------------------------------------------------

--- Navega una cadena de WaitForChild con timeout.
--- Retorna nil + warn si algún eslabón falla.
local function safeFindPath(root: Instance, path: { string }): Instance?
	local current = root
	for _, name in path do
		local child = current:WaitForChild(name, WAIT_TIMEOUT)
		if not child then
			warn(`[MobileTouchHUD] Path not found: {current:GetFullName()}/{name} (timeout {WAIT_TIMEOUT}s)`)
			return nil
		end
		current = child
	end
	return current
end

------------------------------------------------------------------------
-- PRIVATE: Find GuiButton descendant
------------------------------------------------------------------------

--- Busca el primer GuiButton dentro de un frame (puede ser el frame mismo).
local function findButton(instance: Instance): GuiButton?
	if instance:IsA("GuiButton") then
		return instance :: GuiButton
	end
	return instance:FindFirstChildWhichIsA("GuiButton", true) :: GuiButton?
end

------------------------------------------------------------------------
-- PRIVATE: Clone combat ScreenGui completa, buscar botones dentro
------------------------------------------------------------------------

function MobileTouchHUD:_cloneCombatScreen()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- Clonar la ScreenGui entera (MobileUI) → mantiene layout/posiciones originales
	local mobileUI = safeFindPath(ReplicatedStorage, { "Assets", "UI", "Mobile", "MobileUI" })
	if not mobileUI then
		warn("[MobileTouchHUD] Cannot find ReplicatedStorage/Assets/UI/Mobile/MobileUI")
		return
	end

	local clone = mobileUI:Clone()
	clone.Name = "MobileTouchHUD_Combat"
	clone.ResetOnSpawn = false
	clone.Enabled = true
	clone.Parent = playerGui
	self._combatScreenGui = clone

	-- Buscar cada botón definido en PlayerBindings.MobileButtons DENTRO del clon
	local bindings = PlayerBindings.DEFAULT
	for _, config in bindings.MobileButtons do
		local buttonInstance = clone:FindFirstChild(config.UIName, true) -- recursive search
		if buttonInstance then
			self._combatButtons[config.Id] = {
				instance = buttonInstance,
				config = config,
			}
			buttonInstance.Visible = false
		else
			warn(`[MobileTouchHUD] Button not found inside MobileUI clone: {config.UIName}`)
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Clone spectator ScreenGui completa, buscar botones dentro
------------------------------------------------------------------------

function MobileTouchHUD:_cloneSpectatorScreen()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local spectatorUI = safeFindPath(ReplicatedStorage, { "Assets", "UI", "Mobile", "SpectatorMobileUI" })
	if not spectatorUI then
		warn("[MobileTouchHUD] Cannot find ReplicatedStorage/Assets/UI/Mobile/SpectatorMobileUI")
		return
	end

	local clone = spectatorUI:Clone()
	clone.Name = "MobileTouchHUD_Spectator"
	clone.ResetOnSpawn = false
	clone.Enabled = true
	clone.Parent = playerGui
	self._spectatorScreenGui = clone

	-- Buscar cada botón definido en PlayerBindings.SpectatorButtons DENTRO del clon
	local bindings = PlayerBindings.DEFAULT
	for _, config in bindings.SpectatorButtons do
		local buttonInstance = clone:FindFirstChild(config.UIName, true) -- recursive search
		if buttonInstance then
			self._spectatorButtonInstances[config.Id] = buttonInstance
			buttonInstance.Visible = false
		else
			warn(`[MobileTouchHUD] Button not found inside SpectatorMobileUI clone: {config.UIName}`)
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Wire combat button events (data-driven from MobileButtons)
------------------------------------------------------------------------

function MobileTouchHUD:_wireCombatButtonEvents()
	local inputDetector = self._inputDetector
	local bindings = PlayerBindings.DEFAULT

	for _, entry in self._combatButtons do
		local config = entry.config
		local btn = findButton(entry.instance)
		if not btn then
			warn(`[MobileTouchHUD] No GuiButton found inside: {entry.instance:GetFullName()}`)
			continue
		end

		if config.HoldSensitive then
			-- Hold-sensitive: implementar detección tap vs hold
			local holdThreshold = bindings.HoldThresholds[config.RawInput] or 0.3
			local pressStart = nil :: number?
			local holdEmitted = false

			table.insert(
				self._connections,
				btn.InputBegan:Connect(function(input)
					if isValidButtonInput(input) then
						pressStart = os.clock()
						holdEmitted = false
					end
				end)
			)

			table.insert(
				self._connections,
				btn.InputEnded:Connect(function(input)
					if not isValidButtonInput(input) then
						return
					end
					if not pressStart then
						return
					end

					local elapsed = os.clock() - pressStart
					pressStart = nil

					if holdEmitted then
						-- HoldStart ya se emitió → emitir Release y limpiar held state
						inputDetector:FireUIButtonUp(config.RawInput, "Release", elapsed)
					else
						-- Nunca alcanzó threshold → es un Tap
						inputDetector:FireUIButton(config.RawInput, "Tap")
					end
					holdEmitted = false
				end)
			)

			-- Hold detection via Heartbeat
			table.insert(
				self._connections,
				RunService.Heartbeat:Connect(function()
					-- Botón oculto (muerte/respawn con hold activo): limpiar estado local.
					-- Roblox no garantiza InputEnded cuando Visible=false, así que lo hacemos aquí.
					if not entry.instance.Visible then
						if holdEmitted then
							inputDetector:FireUIButtonUp(config.RawInput, "Release", 0)
						end
						pressStart = nil
						holdEmitted = false
						return
					end
					if not pressStart or holdEmitted then
						return
					end
					local elapsed = os.clock() - pressStart
					if elapsed >= holdThreshold then
						holdEmitted = true
						inputDetector:FireUIButtonDown(config.RawInput, "HoldStart", elapsed)
					end
				end)
			)
		else
			-- Non-hold: Pressed / Released
			table.insert(
				self._connections,
				btn.InputBegan:Connect(function(input)
					if isValidButtonInput(input) then
						inputDetector:FireUIButtonDown(config.RawInput, "Pressed")
					end
				end)
			)

			table.insert(
				self._connections,
				btn.InputEnded:Connect(function(input)
					if isValidButtonInput(input) then
						inputDetector:FireUIButtonUp(config.RawInput, "Released")
					end
				end)
			)
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Wire spectator button events (data-driven from SpectatorButtons)
------------------------------------------------------------------------

function MobileTouchHUD:_wireSpectatorButtonEvents()
	local spectatorController = self._spectatorController
	local bindings = PlayerBindings.DEFAULT

	for _, config in bindings.SpectatorButtons do
		local instance = self._spectatorButtonInstances[config.Id]
		if not instance then
			continue
		end

		local btn = findButton(instance)
		if not btn then
			continue
		end

		local action = config.Action
		table.insert(
			self._connections,
			btn.Activated:Connect(function()
				if action == "RequestNext" then
					spectatorController:RequestNext()
				elseif action == "RequestPrevious" then
					spectatorController:RequestPrevious()
				end
			end)
		)
	end
end

------------------------------------------------------------------------
-- PRIVATE: State tracking
------------------------------------------------------------------------

function MobileTouchHUD:_evaluateState(state: string)
	local sm = self._stateMachine

	self._isAlive = sm:IsInGroup("AliveGroup")
	self._isDBNO = state == "DBNO"
	self._isSpectator = state == "Spectator"
end

function MobileTouchHUD:_wireStateEvents()
	table.insert(
		self._connections,
		self._stateMachine.StateChanged:Connect(function(newState: string, _oldState: string)
			self:_evaluateState(newState)
			self:_updateVisibility()
			-- Limpiar UI held state al morir: los closures de botones pueden
			-- haber quedado activos cuando el botón se ocultó mid-hold.
			if newState == "Death" or newState == "Spectator" or newState == "Lobby" then
				self._inputDetector:ResetUIHeldState()
			end
		end)
	)
end

------------------------------------------------------------------------
-- PRIVATE: Tool equip detection
------------------------------------------------------------------------

function MobileTouchHUD:_wireToolDetection()
	local player = Players.LocalPlayer

	local function scanCharacterForTool(character: Model)
		for _, child in character:GetChildren() do
			if child:IsA("Tool") then
				self._hasToolEquipped = true
				self:_updateVisibility()
				return
			end
		end
		self._hasToolEquipped = false
		self:_updateVisibility()
	end

	local function bindCharacter(character: Model)
		scanCharacterForTool(character)

		table.insert(
			self._connections,
			character.ChildAdded:Connect(function(child)
				if child:IsA("Tool") then
					self._hasToolEquipped = true
					self:_updateVisibility()
				end
			end)
		)

		table.insert(
			self._connections,
			character.ChildRemoved:Connect(function(child)
				if child:IsA("Tool") then
					local hasAnyTool = false
					for _, sibling in character:GetChildren() do
						if sibling:IsA("Tool") then
							hasAnyTool = true
							break
						end
					end
					self._hasToolEquipped = hasAnyTool
					self:_updateVisibility()
				end
			end)
		)
	end

	if player.Character then
		bindCharacter(player.Character)
	end

	table.insert(
		self._connections,
		player.CharacterAdded:Connect(function(character)
			self._hasToolEquipped = false
			self:_updateVisibility()
			-- Limpiar UI held state residual de la vida anterior
			self._inputDetector:ResetUIHeldState()
			bindCharacter(character)
		end)
	)

	table.insert(
		self._connections,
		player.CharacterRemoving:Connect(function()
			self._hasToolEquipped = false
			self:_updateVisibility()
		end)
	)
end

------------------------------------------------------------------------
-- PRIVATE: Visibility update (driven by VisibilityGroup)
------------------------------------------------------------------------

function MobileTouchHUD:_updateVisibility()
	-- Combat/Cover buttons: visibility driven by VisibilityGroup field
	for _, entry in self._combatButtons do
		local group = entry.config.VisibilityGroup
		local visible = false

		if group == "Combat" then
			visible = self._isAlive and self._hasToolEquipped
		elseif group == "Cover" then
			-- Visible en vivo Y en DBNO (WantsSelfRevive = CoverButton.Tap para auto-revive)
			visible = self._isAlive or self._isDBNO
		end

		entry.instance.Visible = visible
	end

	-- Spectator buttons: visible only in Spectator state
	for _, instance in self._spectatorButtonInstances do
		instance.Visible = self._isSpectator
	end
end

------------------------------------------------------------------------
-- PUBLIC: Utility — IS_MOBILE flag para que otros sistemas consulten
------------------------------------------------------------------------

function MobileTouchHUD.IsMobile(): boolean
	return IS_MOBILE
end

return MobileTouchHUD
