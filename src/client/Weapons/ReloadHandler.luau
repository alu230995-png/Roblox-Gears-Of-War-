--[[
	ReloadHandler.luau
	═══════════════════════════════════════════════════════════════
	Sub-handler de recarga para WeaponClient.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	  - Recarga normal (timer → _completeReload)
	  - Active Reload (segundo R durante recarga)
	  - Predicción local de munición (ammoState compartido con WeaponClient)
	  - Comunicación con servidor (RemoteEvent)

	ammoState es una tabla compartida { current: number, reserve: number }
	que WeaponClient y ReloadHandler leen/escriben por referencia.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local ReloadHandler = {}
ReloadHandler.__index = ReloadHandler

function ReloadHandler.new(
	ammoState: { current: number, reserve: number },
	config,
	weaponRemote: RemoteEvent?,
	weaponName: string,
	stateMachine,
	ammoChangedSignal
)
	local self = setmetatable({}, ReloadHandler)

	self._ammoState = ammoState
	self._config = config
	self._weaponRemote = weaponRemote
	self._weaponName = weaponName
	self._stateMachine = stateMachine
	self._ammoChangedSignal = ammoChangedSignal

	self._isReloading = false
	self._reloadThread = nil :: thread?
	self._reloadStartTime = 0
	self._hasActiveReloadBuff = false
	self._activeBuffThread = nil :: thread?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function ReloadHandler:IsReloading(): boolean
	return self._isReloading
end

function ReloadHandler:HasActiveReloadBuff(): boolean
	return self._hasActiveReloadBuff == true
end

function ReloadHandler:ClearActiveReloadBuff()
	if self._activeBuffThread then
		task.cancel(self._activeBuffThread)
		self._activeBuffThread = nil
	end
	self._hasActiveReloadBuff = false
end

function ReloadHandler:StartReload(): boolean
	if self._isReloading then
		return false
	end
	if not self._config then
		return false
	end

	local ammoConfig = self._config.Ammo
	if self._ammoState.current >= ammoConfig.ClipSize or self._ammoState.reserve <= 0 then
		return false
	end

	self._isReloading = true
	self._reloadStartTime = os.clock()

	-- Notificar servidor
	if self._weaponRemote then
		self._weaponRemote:FireServer("Reload", self._weaponName)
	end

	-- El buff del active reload anterior se consume al iniciar una recarga nueva.
	self:ClearActiveReloadBuff()

	if Constants.DEBUG_MODE then
		print(`[ReloadHandler] Reload started — {self._weaponName} ({ammoConfig.ReloadTime}s)`)
	end

	-- Timer de recarga
	self._reloadThread = task.delay(ammoConfig.ReloadTime, function()
		self._reloadThread = nil
		self:_completeReload()
	end)

	return true
end

function ReloadHandler:CancelReload()
	if self._reloadThread then
		task.cancel(self._reloadThread)
		self._reloadThread = nil
	end
	self._isReloading = false
	self._reloadStartTime = 0

	-- Devolver a Idle si seguimos en estado de recarga
	if self._stateMachine then
		local current = self._stateMachine:GetCurrentState()
		if current == "Reloading" or current == "ActiveReloading" then
			self._stateMachine:TransitionTo("Idle")
		end
	end
end

function ReloadHandler:AttemptActiveReload(): boolean
	if not self._isReloading then
		return false
	end
	if not self._config then
		return false
	end

	local ammoConfig = self._config.Ammo
	local reloadTime = ammoConfig.ReloadTime
	local elapsed = os.clock() - self._reloadStartTime
	local progress = elapsed / reloadTime

	if Constants.DEBUG_MODE then
		print(`[ReloadHandler] Progreso actual: {string.format("%.3f", progress)}`)
	end

	-- Enviar al servidor (autoridad)
	if self._weaponRemote then
		self._weaponRemote:FireServer("ActiveReload", {
			WeaponName = self._weaponName,
			Progress = progress,
		})
	end

	-- Predicción local: evaluar ventana y ajustar timer del cliente
	local windowStart = ammoConfig.ActiveReloadWindowStart or 0.35
	local windowDuration = ammoConfig.ActiveReloadWindowDuration or 0.15
	local windowEnd = windowStart + windowDuration

	-- Cancelar el timer de recarga actual
	if self._reloadThread then
		task.cancel(self._reloadThread)
		self._reloadThread = nil
	end

	local remainingTime = math.max(reloadTime - elapsed, 0.05)

	if progress >= windowStart and progress <= windowEnd then
		-- ACTIVE RELOAD EXITOSO — mitad del tiempo restante
		local newDelay = remainingTime / 2
		self._hasActiveReloadBuff = true
		if self._activeBuffThread then
			task.cancel(self._activeBuffThread)
		end
		self._activeBuffThread = task.delay(Constants.ACTIVE_RELOAD_BONUS_DURATION, function()
			self._activeBuffThread = nil
			self._hasActiveReloadBuff = false
		end)
		if Constants.DEBUG_MODE then
			print(
				`[ReloadHandler] ¡RECARGA ACTIVA EXITOSA! — {self._weaponName} | Completa en {string.format(
					"%.2f",
					newDelay
				)}s`
			)
		end

		self._reloadThread = task.delay(newDelay, function()
			self._reloadThread = nil
			self:_completeReload()
		end)
	else
		-- ACTIVE RELOAD FALLIDO — arma atascada, +50% tiempo
		local newDelay = remainingTime * 1.5
		self:ClearActiveReloadBuff()
		if Constants.DEBUG_MODE then
			print(
				`[ReloadHandler] RECARGA FALLIDA: Arma atascada — {self._weaponName} | Atascada {string.format(
					"%.2f",
					newDelay
				)}s`
			)
		end

		self._reloadThread = task.delay(newDelay, function()
			self._reloadThread = nil
			self:_completeReload()
		end)
	end

	return true
end

function ReloadHandler:Destroy()
	self:ClearActiveReloadBuff()
	self:CancelReload()
end

------------------------------------------------------------------------
-- PRIVATE
------------------------------------------------------------------------

function ReloadHandler:_completeReload()
	if not self._config then
		self._isReloading = false
		return
	end

	local clipSize = self._config.Ammo.ClipSize
	local needed = clipSize - self._ammoState.current
	local available = math.min(needed, self._ammoState.reserve)

	self._ammoState.current = self._ammoState.current + available
	self._ammoState.reserve = self._ammoState.reserve - available
	self._isReloading = false
	self._reloadStartTime = 0

	self._ammoChangedSignal:Fire(self._ammoState.current, self._ammoState.reserve)

	-- Devolver al jugador a un estado que permita actuar
	if self._stateMachine then
		local current = self._stateMachine:GetCurrentState()
		if current == "Reloading" or current == "ActiveReloading" then
			self._stateMachine:TransitionTo("Idle")
		elseif current == "Firing" then
			-- Auto-reload desde Firing: Firing → Idle (o Walking si se mueve)
			self._stateMachine:TransitionTo("Idle")
		end
	end

	if Constants.DEBUG_MODE then
		print(
			`[ReloadHandler] Reload complete — {self._weaponName} | Ammo: {self._ammoState.current}/{self._ammoState.reserve}`
		)
	end
end

return ReloadHandler
