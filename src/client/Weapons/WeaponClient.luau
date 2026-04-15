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
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))

local ShootingHandler = require(script.Parent:WaitForChild("ShootingHandler"))
local ReloadHandlerModule: any = require(script.Parent:WaitForChild("ReloadHandler"))
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

-- Estados donde el disparo está activo — _onPlayerStateChanged NO debe matar el loop
local FIRING_ACTIVE_STATES: { [string]: true } = {
	Firing = true,
	CoverFiring = true,
	CoverBlindFire = true,
}

-- Estados del StateMachine que solo existen mientras un arma está activa.
-- Si desequipamos el arma y la FSM sigue en uno de estos, FORZAR Idle
-- para que el arma nueva no quede bloqueada por un estado ajeno.
local WEAPON_OWNED_STATES: { [string]: true } = {
	Firing = true,
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
	self.HoldStarted = Signal.new()
	self.HoldReleased = Signal.new()

	-- Deps (inyectadas en Init)
	self._stateMachine = nil
	self._weaponRemote = nil :: RemoteEvent?
	self._soundController = nil

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
		self._reloadHandler = ReloadHandlerModule.new(
			self._ammoState,
			self._config,
			self._weaponRemote,
			self._weaponName,
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
	table.insert(
		self._connections,
		self._tool.Equipped:Connect(function()
			self:_onToolEquipped()
		end)
	)

	table.insert(
		self._connections,
		self._tool.Unequipped:Connect(function()
			self:_onToolUnequipped()
		end)
	)

	-- PlayerState observer
	if self._stateMachine then
		table.insert(
			self._connections,
			self._stateMachine.StateChanged:Connect(function(newState, _oldState)
				self:_onPlayerStateChanged(newState)
			end)
		)
	end

	-- ActionExecuted → HandleAction
	if self._actionExecutedSignal then
		table.insert(
			self._connections,
			self._actionExecutedSignal:Connect(function(action, targetState, data)
				self:HandleAction(action, targetState, data)
			end)
		)
	end

	-- AimingChanged → scope visual
	table.insert(
		self._connections,
		self.AimingChanged:Connect(function(isAiming)
			if self._scope then
				self._scope:SetAiming(isAiming)
			end
		end)
	)

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
	self.HoldStarted:Destroy()
	self.HoldReleased:Destroy()

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

function WeaponClient:SetSoundController(soundController)
	self._soundController = soundController
end

function WeaponClient:CanAct(): boolean
	return self._weaponState == WS_EQUIPPED
end

function WeaponClient:GetSpreadPattern()
	return self._config and self._config.Ballistics and self._config.Ballistics.SpreadPattern
end

function WeaponClient:GetReloadHandler()
	return self._reloadHandler
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

	-- Shooting (WeaponClient es autoridad de transición a Firing desde estados libres)
	if action == "Shoot" or action == "ShootFromCover" or action == "BlindFire" then
		if not _targetState then
			-- Estado libre: transicionar ANTES de arrancar el loop.
			-- Si STATE_MIN_DURATION bloquea la transición, no se dispara.
			if not self._stateMachine or not self._stateMachine:TransitionTo("Firing") then
				return
			end
		end
		local started = self:_startFiring()
		-- Si arrancó el loop pero falla (sin munición, recargando, etc.),
		-- revertir a Idle si seguimos en Firing.
		if not started and not _targetState then
			local current = self._stateMachine and self._stateMachine:GetCurrentState()
			if current == "Firing" then
				self._stateMachine:TransitionTo("Idle")
			end
		end
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

	-- Reload (delegado a ReloadHandler — WeaponClient decide normal vs active)
	-- Reloading es un ESTADO DEL ARMA, no del jugador.
	-- El PlayerState no cambia: el jugador puede recargar en Idle, Walking, CoverIdle, etc.
	elseif action == "Reload" then
		if self._reloadHandler then
			-- Si ya está recargando → intentar active reload
			if self._reloadHandler:IsReloading() then
				self._reloadHandler:AttemptActiveReload()
				return
			end

			-- Iniciar recarga nueva
			local started = self._reloadHandler:StartReload()
			if not started then
				return
			end

			self:_stopFiring()
			if self._holdBreathHandler then
				self._holdBreathHandler:ForceCancel()
			end
			self.ReloadStarted:Fire(self._weaponName)
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE — Shooting
------------------------------------------------------------------------

function WeaponClient:_startFiring(): boolean
	if self._isShooting then
		return false
	end
	if self._reloadHandler and self._reloadHandler:IsReloading() then
		return false
	end
	if self._ammoState.current <= 0 then
		if self._ammoState.reserve > 0 and self._config and self._reloadHandler then
			if Constants.DEBUG_MODE then
				print(`[WeaponClient] Sin munición — recarga automática — {self._weaponName}`)
			end
			-- Validar primero, no transicionar player state (reload es estado del arma)
			local started = self._reloadHandler:StartReload()
			if started then
				self.ReloadStarted:Fire(self._weaponName)
			end
		end
		return false
	end
	if not self._config then
		return false
	end

	-- HoldBreath: delegar al handler
	if self._holdBreathHandler and self._holdBreathHandler:IsEnabled() then
		if self._holdBreathHandler:IsActive() then
			return false
		end
		self._isShooting = true
		self:_startHoldSound()
		self.HoldStarted:Fire(self._weaponName, self._player.Character)
		self._holdBreathHandler:Start(function()
			self:_stopHoldSound()
			self.HoldReleased:Fire(self._weaponName, self._player.Character)
			if self._isShooting and self._weaponState == WS_EQUIPPED and self._ammoState.current > 0 then
				self:_fireOneShot(1) -- carga completa = precisión perfecta
			end
			self._isShooting = false
		end)
		return true
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

		-- Post-loop cleanup: el loop terminó naturalmente (no por _stopFiring)
		self._isShooting = false
		self._fireThread = nil

		-- Si la munición se agotó, intentar recarga automática
		if self._ammoState.current <= 0 and self._ammoState.reserve > 0 then
			if self._reloadHandler and self._config then
				local started = self._reloadHandler:StartReload()
				if started then
					self.ReloadStarted:Fire(self._weaponName)
					return
				end
			end
		end

		-- No se pudo recargar: volver al estado apropiado si seguimos en Firing
		if self._stateMachine and self._stateMachine:GetCurrentState() == "Firing" then
			self._stateMachine:TransitionTo("Idle")
		end
	end)

	return true
end

function WeaponClient:_stopFiring()
	-- HoldBreath cancel
	if self._holdBreathHandler and self._holdBreathHandler:IsActive() then
		local progress = self._holdBreathHandler:GetProgress()
		self:_stopHoldSound()
		self.HoldReleased:Fire(self._weaponName, self._player.Character)

		if self._holdBreathHandler:Cancel() then
			-- CancelOnRelease=true: disparo cancelado completamente
			self._isShooting = false
			return
		end

		-- CancelOnRelease=false: disparar con precisión según progreso de carga
		self._holdBreathHandler:ForceCancel()
		if self._weaponState == WS_EQUIPPED and self._ammoState.current > 0 then
			self:_fireOneShot(progress)
		end
		self._isShooting = false
		return
	end

	self._isShooting = false
	if self._fireThread then
		task.cancel(self._fireThread)
		self._fireThread = nil
	end
end

function WeaponClient:_fireOneShot(chargeProgress: number?)
	if not self._config then
		return
	end

	-- Calcular dispersión angular por carga incompleta
	local chargeSpreadRad: number? = nil
	if chargeProgress ~= nil and chargeProgress < 1 then
		local holdConfig = self._config.Mechanics and self._config.Mechanics.HoldingBreath
		local maxSpreadDeg = holdConfig and holdConfig.MaxChargeSpread or 15
		chargeSpreadRad = math.rad(maxSpreadDeg) * (1 - chargeProgress)
	end

	local scopeContainer = self._scope and self._scope:GetContainer()
	local shotResult = ShootingHandler.FireOneShot(self._player, scopeContainer, self._config.Stats, chargeSpreadRad)

	self._ammoState.current = math.max(self._ammoState.current - 1, 0)
	self.AmmoChanged:Fire(self._ammoState.current, self._ammoState.reserve)

	if shotResult and self._weaponRemote then
		self._weaponRemote:FireServer("ProcessShot", {
			WeaponName = self._weaponName,
			Origin = shotResult.Origin,
			HitPositions = shotResult.HitPositions,
			HitParts = shotResult.HitParts,
			Timestamp = os.clock(),
			ChargeProgress = chargeProgress,
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
		local hasActiveReload = false
		if self._reloadHandler and self._reloadHandler.HasActiveReloadBuff then
			hasActiveReload = self._reloadHandler:HasActiveReloadBuff()
		end

		self.ShotFired:Fire(self._weaponName, shotResult, self._player.Character, hasActiveReload)
	end

	if self._ammoState.current == 0 and self._reloadHandler and self._reloadHandler.ClearActiveReloadBuff then
		self._reloadHandler:ClearActiveReloadBuff()
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

	-- Notificar servidor INMEDIATAMENTE (no tras el delay) para que
	-- el estado de arma equipada esté sincronizado antes de disparar.
	if self._weaponRemote then
		self._weaponRemote:FireServer("Equip", self._weaponName)
	end

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
	end)
end

function WeaponClient:_onToolUnequipped()
	self._isToolEquipped = false

	self:_cancelAllOperations()
	self:_cancelTransition()

	if self._weaponState == WS_UNEQUIPPED then
		return
	end

	-- Notificar servidor INMEDIATAMENTE con el nombre del arma
	-- para que ignore unequips tardíos si ya se equipó otra.
	if self._weaponRemote then
		self._weaponRemote:FireServer("Unequip", self._weaponName)
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
		-- No matar el loop de disparo si transitamos a un estado donde se está disparando
		if not FIRING_ACTIVE_STATES[newState] then
			self:_stopFiring()
		end

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
	self:_stopHoldSound()
	if self._holdBreathHandler then
		self._holdBreathHandler:ForceCancel()
	end
	if self._reloadHandler then
		self._reloadHandler:CancelReload()
		self._reloadHandler:ClearActiveReloadBuff()
	end

	-- Safety net: si la StateMachine sigue en un estado que solo existe
	-- mientras esta arma está activa (Reloading, Firing, etc.), forzar a Idle.
	-- Necesario porque TransitionTo puede fallar por STATE_MIN_DURATION
	-- cuando el swap es más rápido que 0.1s.
	if self._stateMachine then
		local currentState = self._stateMachine:GetCurrentState()
		if WEAPON_OWNED_STATES[currentState] then
			self._stateMachine:ForceState("Idle")
		end
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

------------------------------------------------------------------------
-- PRIVATE — Hold Sound (looped while holding breath)
------------------------------------------------------------------------

function WeaponClient:_getHoldSoundName(): string?
	local key = "VFX_Weapon_" .. self._weaponName .. "_Hold"
	if SoundConfig[key] then
		return key
	end
	return nil
end

function WeaponClient:_startHoldSound()
	if not self._soundController then
		return
	end
	local soundName = self:_getHoldSoundName()
	if not soundName then
		return
	end
	local character = self._player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local position = hrp and hrp.Position or nil
	self._soundController:PlayLocal(soundName, position)
end

function WeaponClient:_stopHoldSound()
	if not self._soundController then
		return
	end
	local soundName = self:_getHoldSoundName()
	if not soundName then
		return
	end
	self._soundController:StopLooped(soundName)
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
