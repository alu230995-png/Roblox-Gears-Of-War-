--[[
	WeaponClient.luau
	═══════════════════════════════════════════════════════════════
	Coordinador de arma en el cliente (patrón MovementController).
	═══════════════════════════════════════════════════════════════

	Uso (desde ClientApp o un LocalScript):
	  local wc = WeaponClient.new(player, tool)
	  wc:Init(stateMachine, actionExecutedSignal, ScopeRendererClass)
	  wc:Start()

	Responsabilidades:
	  - Equip/Unequip lifecycle (Tool events + timers)
	  - Shooting loop (fire rate, auto-fire, ammo deduction)
	  - Scope lifecycle (crear al equipar, destruir al desequipar)
	  - Delegación a sub-handlers: ReloadHandler, HoldBreathHandler
	  - Señales para presentación (Animation, Camera, HUD)
	  - RemoteEvents hacia WeaponServer

	Sub-handlers:
	  - ReloadHandler  → reload + active reload
	  - HoldBreathHandler → hold-to-fire timer
	  - ShootingHandler → raycast puro (función estática)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConstants = require(Shared:WaitForChild("WeaponConstants"))
local Constants = require(Shared:WaitForChild("Constants"))
local Signal = require(Shared:WaitForChild("Signal"))

local ShootingHandler = require(script.Parent:WaitForChild("ShootingHandler"))
local ReloadHandler = require(script.Parent:WaitForChild("ReloadHandler"))
local HoldBreathHandler = require(script.Parent:WaitForChild("HoldBreathHandler"))

------------------------------------------------------------------------
-- STATES
------------------------------------------------------------------------

local WS_UNEQUIPPED = "Unequipped"
local WS_EQUIPPING = "Equipping"
local WS_EQUIPPED = "Equipped"
local WS_UNEQUIPPING = "Unequipping"

local TRANSITION_STATES: { [string]: true } = {
	[WS_EQUIPPING] = true,
	[WS_UNEQUIPPING] = true,
}

local FORCE_UNEQUIP_STATES: { [string]: true } = {
	RoadieRun = true,
	Evading = true,
	Mantling = true,
	Vaulting = true,
	CoverSlide = true,
	CoverExiting = true,
	CoverSwap = true,
	ExitCorner = true,
	DBNO = true,
	Death = true,
	Spectator = true,
	Lobby = true,
}

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------

local WeaponClient = {}
WeaponClient.__index = WeaponClient

function WeaponClient.new(player: Player, tool: Tool)
	local self = setmetatable({}, WeaponClient)

	self._player = player
	self._tool = tool
	self._connections = {} :: { RBXScriptConnection | { Disconnect: () -> () } }

	-- Identificación del arma
	self._weaponName = tool:GetAttribute("WeaponName") or tool.Name
	local config = WeaponConstants.WEAPONS[self._weaponName]
	if not config then
		warn("[WeaponClient] Arma no encontrada en WeaponConstants.WEAPONS: " .. tostring(self._weaponName))
	end
	self._config = config

	-- Estado interno
	self._weaponState = WS_UNEQUIPPED
	self._isToolEquipped = false
	self._transitionThread = nil :: thread?

	-- Ammo (tabla compartida por referencia con ReloadHandler)
	local ammo = config and config.Ammo
	self._ammoState = {
		current = if ammo then ammo.ClipSize else 0,
		reserve = if ammo then (ammo.CurrentAmmo - ammo.ClipSize) else 0,
	}

	-- Shooting state
	self._isShooting = false
	self._fireThread = nil :: thread?
	self._nextFireTime = 0

	-- Scope (managed internally)
	self._scope = nil
	self._ScopeRendererClass = nil

	-- Señales públicas
	self.WeaponStateChanged = Signal.new()
	self.WeaponEquipped = Signal.new()
	self.WeaponUnequipped = Signal.new()
	self.AmmoChanged = Signal.new()
	self.AimingChanged = Signal.new()
	self.ShotFired = Signal.new()
	self.ReloadStarted = Signal.new()

	-- Deps (inyectadas en Init)
	self._stateMachine = nil
	self._weaponRemote = nil :: RemoteEvent?

	-- Sub-handlers (creados en Init, cuando config y deps están listos)
	self._reloadHandler = nil
	self._holdBreathHandler = nil

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function WeaponClient:Init(stateMachine, actionExecutedSignal, ScopeRendererClass)
	self._stateMachine = stateMachine
	self._actionExecutedSignal = actionExecutedSignal
	self._ScopeRendererClass = ScopeRendererClass

	-- RemoteEvent
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes then
		self._weaponRemote = remotes:FindFirstChild("WeaponRemote") :: RemoteEvent?
	end

	-- Sub-handlers
	if self._config then
		self._reloadHandler = ReloadHandler.new(
			self._ammoState,
			self._config,
			self._weaponRemote,
			self._weaponName,
			self._stateMachine,
			self.AmmoChanged
		)

		local holdConfig = self._config.Mechanics and self._config.Mechanics.HoldingBreath
		if holdConfig then
			self._holdBreathHandler = HoldBreathHandler.new(holdConfig)
		end
	end
end

function WeaponClient:Start()
	-- Tool events
	table.insert(self._connections, self._tool.Equipped:Connect(function()
		self:_onToolEquipped()
	end))

	table.insert(self._connections, self._tool.Unequipped:Connect(function()
		self:_onToolUnequipped()
	end))

	-- PlayerState observer
	if self._stateMachine then
		table.insert(self._connections, self._stateMachine.StateChanged:Connect(function(newState, _oldState)
			self:_onPlayerStateChanged(newState)
		end))
	end

	-- ActionExecuted → HandleAction
	if self._actionExecutedSignal then
		table.insert(self._connections, self._actionExecutedSignal:Connect(function(action, targetState, data)
			self:HandleAction(action, targetState, data)
		end))
	end

	-- AimingChanged → scope visual
	table.insert(self._connections, self.AimingChanged:Connect(function(isAiming)
		if self._scope then
			self._scope:SetAiming(isAiming)
		end
	end))

	-- Si el Tool ya está equipado
	if self._tool.Parent and self._tool.Parent == self._player.Character then
		self:_onToolEquipped()
	end
end

function WeaponClient:Destroy()
	self:_cancelTransition()
	self:_cancelAllOperations()

	if self._holdBreathHandler then
		self._holdBreathHandler:Destroy()
	end
	if self._reloadHandler then
		self._reloadHandler:Destroy()
	end

	self:_destroyScope()

	for _, conn in self._connections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif conn.Disconnect then
			conn.Disconnect()
		end
	end
	table.clear(self._connections)

	self.WeaponStateChanged:Destroy()
	self.WeaponEquipped:Destroy()
	self.WeaponUnequipped:Destroy()
	self.AmmoChanged:Destroy()
	self.AimingChanged:Destroy()
	self.ShotFired:Destroy()
	self.ReloadStarted:Destroy()

	self._stateMachine = nil
	self._tool = nil :: any
	self._config = nil :: any
end

------------------------------------------------------------------------
-- PUBLIC API — Getters
------------------------------------------------------------------------

function WeaponClient:GetWeaponState(): string
	return self._weaponState
end

function WeaponClient:GetWeaponName(): string
	return self._weaponName
end

function WeaponClient:GetCurrentAmmo(): number
	return self._ammoState.current
end

function WeaponClient:GetReserveAmmo(): number
	return self._ammoState.reserve
end

function WeaponClient:GetStats()
	return self._config and self._config.Stats
end

function WeaponClient:IsEquipped(): boolean
	return self._weaponState == WS_EQUIPPED
end

function WeaponClient:IsTransitioning(): boolean
	return TRANSITION_STATES[self._weaponState] == true
end

function WeaponClient:GetConfig()
	return self._config
end

function WeaponClient:CanAct(): boolean
	return self._weaponState == WS_EQUIPPED
end

function WeaponClient:GetSpreadPattern()
	return self._config and self._config.Ballistics and self._config.Ballistics.SpreadPattern
end

function WeaponClient:GetScope()
	return self._scope
end

------------------------------------------------------------------------
-- PUBLIC API — Action dispatch
------------------------------------------------------------------------

function WeaponClient:HandleAction(action: string, _targetState: string?, _data: any?)
	if not self:CanAct() then
		return
	end

	-- Shooting
	if action == "Shoot" or action == "ShootFromCover" or action == "BlindFire" then
		self:_startFiring()
	elseif action == "StopShoot" or action == "StopBlindFire" then
		self:_stopFiring()
	elseif action == "ReturnToCover" then
		self:_stopFiring()
		self.AimingChanged:Fire(false)
	elseif action == "StopCoverFiring" then
		self:_stopFiring()

	-- Aim
	elseif action == "StartAim" or action == "PopUpAim" then
		self.AimingChanged:Fire(true)
	elseif action == "StopAim" then
		self.AimingChanged:Fire(false)

	-- Reload (delegado a ReloadHandler)
	elseif action == "Reload" then
		if self._reloadHandler then
			if self._stateMachine then
				self._stateMachine:TransitionTo("Reloading")
			end
			self:_stopFiring()
			if self._holdBreathHandler then
				self._holdBreathHandler:ForceCancel()
			end
			self._reloadHandler:StartReload()
			self.ReloadStarted:Fire(self._weaponName)
		end

	-- Active Reload (delegado a ReloadHandler)
	elseif action == "ActiveReload" then
		if self._reloadHandler then
			self._reloadHandler:AttemptActiveReload()
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE — Shooting
------------------------------------------------------------------------

function WeaponClient:_startFiring()
	if self._isShooting then
		return
	end
	if self._reloadHandler and self._reloadHandler:IsReloading() then
		return
	end
	if self._ammoState.current <= 0 then
		if self._ammoState.reserve > 0 and self._config and self._reloadHandler then
			if Constants.DEBUG_MODE then
				print(`[WeaponClient] Sin munición — recarga automática — {self._weaponName}`)
			end
			-- Transicionar a Reloading. Si falla (estado actual no lo permite),
			-- primero ir a Idle y luego a Reloading.
			if self._stateMachine then
				if not self._stateMachine:TransitionTo("Reloading") then
					self._stateMachine:TransitionTo("Idle")
					self._stateMachine:TransitionTo("Reloading")
				end
			end
			self._reloadHandler:StartReload()
		end
		return
	end
	if not self._config then
		return
	end

	-- HoldBreath: delegar al handler
	if self._holdBreathHandler and self._holdBreathHandler:IsEnabled() then
		if self._holdBreathHandler:IsActive() then
			return
		end
		self._isShooting = true
		self._holdBreathHandler:Start(function()
			if self._isShooting and self._weaponState == WS_EQUIPPED and self._ammoState.current > 0 then
				self:_fireOneShot()
			end
			self._isShooting = false
		end)
		return
	end

	-- Disparo normal
	self._isShooting = true

	self._fireThread = task.spawn(function()
		local stats = self._config.Stats

		while self._isShooting and self._weaponState == WS_EQUIPPED do
			if self._ammoState.current <= 0 then
				self._isShooting = false
				break
			end

			local now = os.clock()
			if now < self._nextFireTime then
				task.wait(self._nextFireTime - now)
				if not self._isShooting or self._weaponState ~= WS_EQUIPPED then
					break
				end
			end

			self:_fireOneShot()
			self._nextFireTime = os.clock() + stats.FireRate

			if not stats.AutoFire then
				self._isShooting = false
				break
			end
		end
	end)
end

function WeaponClient:_stopFiring()
	-- HoldBreath cancel
	if self._holdBreathHandler and self._holdBreathHandler:IsActive() then
		if self._holdBreathHandler:Cancel() then
			self._isShooting = false
			return
		end
	end

	self._isShooting = false
	if self._fireThread then
		task.cancel(self._fireThread)
		self._fireThread = nil
	end
end

function WeaponClient:_fireOneShot()
	if not self._config then
		return
	end

	local scopeContainer = self._scope and self._scope:GetContainer()
	local shotResult = ShootingHandler.FireOneShot(self._player, scopeContainer, self._config.Stats)

	self._ammoState.current = math.max(self._ammoState.current - 1, 0)
	self.AmmoChanged:Fire(self._ammoState.current, self._ammoState.reserve)

	if shotResult and self._weaponRemote then
		self._weaponRemote:FireServer("ProcessShot", {
			WeaponName = self._weaponName,
			Origin = shotResult.Origin,
			HitPositions = shotResult.HitPositions,
			HitParts = shotResult.HitParts,
			Timestamp = os.clock(),
		})
	end

	if Constants.DEBUG_MODE then
		local hitCount = 0
		if shotResult then
			for _ in shotResult.HitPositions do
				hitCount += 1
			end
		end
		print(
			`[WeaponClient] Shot fired — {self._weaponName} | Ammo: {self._ammoState.current}/{self._ammoState.reserve} | Hits: {hitCount}`
		)
	end

	-- Effects hook: notificar EffectsController del disparo
	if shotResult then
		self.ShotFired:Fire(self._weaponName, shotResult, self._player.Character)
	end
end

------------------------------------------------------------------------
-- PRIVATE — Tool events
------------------------------------------------------------------------

function WeaponClient:_onToolEquipped()
	self._isToolEquipped = true

	local currentState = self._stateMachine and self._stateMachine:GetCurrentState()
	if currentState and FORCE_UNEQUIP_STATES[currentState] then
		return
	end

	self:_cancelTransition()

	-- Re-identificar arma (pickup de suelo)
	local newName = self._tool:GetAttribute("WeaponName") or self._tool.Name
	if newName ~= self._weaponName then
		self._weaponName = newName
		self._config = WeaponConstants.WEAPONS[self._weaponName]

		if not self._config then
			warn("[WeaponClient] Arma no encontrada en WEAPONS al equipar: " .. tostring(self._weaponName))
		end

		local ammo = self._config and self._config.Ammo
		self._ammoState.current = if ammo then ammo.ClipSize else 0
		self._ammoState.reserve = if ammo then (ammo.CurrentAmmo - ammo.ClipSize) else 0
		self.AmmoChanged:Fire(self._ammoState.current, self._ammoState.reserve)
	end

	self:_setWeaponState(WS_EQUIPPING)

	self._transitionThread = task.delay(WeaponConstants.EQUIP_TIME, function()
		self._transitionThread = nil
		if self._weaponState ~= WS_EQUIPPING then
			return
		end

		self:_setWeaponState(WS_EQUIPPED)
		self.WeaponEquipped:Fire(self._weaponName, self._config)

		-- Scope lifecycle: crear al equipar
		self:_destroyScope()
		local spreadPattern = self._config and self._config.Ballistics and self._config.Ballistics.SpreadPattern
		if spreadPattern and self._ScopeRendererClass then
			self._scope = self._ScopeRendererClass.new(self._player, spreadPattern)
			self._scope:SetVisible(true)
		end

		if self._weaponRemote then
			self._weaponRemote:FireServer("Equip", self._weaponName)
		end
	end)
end

function WeaponClient:_onToolUnequipped()
	self._isToolEquipped = false

	self:_cancelAllOperations()
	self:_cancelTransition()

	if self._weaponState == WS_UNEQUIPPED then
		return
	end

	self:_setWeaponState(WS_UNEQUIPPING)

	self._transitionThread = task.delay(WeaponConstants.UNEQUIP_TIME, function()
		self._transitionThread = nil
		if self._weaponState ~= WS_UNEQUIPPING then
			return
		end

		self:_setWeaponState(WS_UNEQUIPPED)
		self.WeaponUnequipped:Fire(self._weaponName)

		-- Scope cleanup al desequipar
		self:_destroyScope()

		if self._weaponRemote then
			self._weaponRemote:FireServer("Unequip", self._weaponName)
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE — PlayerState observer
------------------------------------------------------------------------

function WeaponClient:_onPlayerStateChanged(newState: string)
	if FORCE_UNEQUIP_STATES[newState] then
		self:_cancelTransition()
		self:_cancelAllOperations()

		if self._weaponState ~= WS_UNEQUIPPED then
			self:_setWeaponState(WS_UNEQUIPPED)
			self.WeaponUnequipped:Fire(self._weaponName)
			self:_destroyScope()
		end
	else
		self:_stopFiring()

		if self._isToolEquipped and self._weaponState == WS_UNEQUIPPED then
			self:_onToolEquipped()
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE — Helpers, Transition & State
------------------------------------------------------------------------

--- Cancela shooting, holdBreath y reload en curso.
--- Usado en unequip, force-unequip y Destroy.
function WeaponClient:_cancelAllOperations()
	self:_stopFiring()
	if self._holdBreathHandler then
		self._holdBreathHandler:ForceCancel()
	end
	if self._reloadHandler then
		self._reloadHandler:CancelReload()
	end
end

--- Destruye el scope activo si existe.
function WeaponClient:_destroyScope()
	if self._scope then
		self._scope:Destroy()
		self._scope = nil
	end
end

function WeaponClient:_cancelTransition()
	if self._transitionThread then
		task.cancel(self._transitionThread)
		self._transitionThread = nil
	end
end

function WeaponClient:_setWeaponState(newState: string)
	if self._weaponState == newState then
		return
	end
	local oldState = self._weaponState
	self._weaponState = newState
	self.WeaponStateChanged:Fire(newState, oldState)
end

return WeaponClient
