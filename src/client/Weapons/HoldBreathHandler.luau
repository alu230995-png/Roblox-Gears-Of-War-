--[[
	HoldBreathHandler.luau
	═══════════════════════════════════════════════════════════════
	Sub-handler de HoldingBreath (hold-to-fire) para WeaponClient.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	  - Timer de espera antes de disparar (HoldingBreath.Duration)
	  - Cancelación al soltar botón (CancelOnRelease)
	  - Si CancelOnRelease=false: soltar dispara con precisión según progreso
	  - Callback al cumplir duración → WeaponClient dispara
]]

local HoldBreathHandler = {}
HoldBreathHandler.__index = HoldBreathHandler

function HoldBreathHandler.new(holdConfig)
	local self = setmetatable({}, HoldBreathHandler)

	self._config = holdConfig -- { Enabled, Duration, CancelOnRelease, MaxChargeSpread? }
	self._isActive = false
	self._thread = nil :: thread?
	self._startTime = 0

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Retorna true si HoldingBreath está habilitado en la config.
function HoldBreathHandler:IsEnabled(): boolean
	return self._config and self._config.Enabled == true
end

function HoldBreathHandler:IsActive(): boolean
	return self._isActive
end

--- Inicia el timer de HoldingBreath. Al cumplir Duration, llama onComplete.
--- @param onComplete () -> () — callback que WeaponClient usa para disparar
function HoldBreathHandler:Start(onComplete: () -> ())
	if self._isActive then
		return
	end

	self._isActive = true
	self._startTime = os.clock()

	self._thread = task.delay(self._config.Duration, function()
		self._thread = nil
		self._isActive = false
		if onComplete then
			onComplete()
		end
	end)
end

--- Retorna el progreso actual de carga (0..1). 0 = recién empezó, 1 = completo.
function HoldBreathHandler:GetProgress(): number
	if not self._isActive then
		return 0
	end
	local elapsed = os.clock() - self._startTime
	return math.clamp(elapsed / self._config.Duration, 0, 1)
end

--- Cancela el timer. Retorna true si CancelOnRelease aplica.
function HoldBreathHandler:Cancel(): boolean
	if not self._isActive then
		return false
	end

	if self._config.CancelOnRelease then
		self:_stopThread()
		return true
	end

	return false
end

--- Fuerza cancelación (para cleanup, Destroy, unequip).
function HoldBreathHandler:ForceCancel()
	self:_stopThread()
end

function HoldBreathHandler:Destroy()
	self:_stopThread()
end

------------------------------------------------------------------------
-- PRIVATE
------------------------------------------------------------------------

function HoldBreathHandler:_stopThread()
	self._isActive = false
	if self._thread then
		task.cancel(self._thread)
		self._thread = nil
	end
end

return HoldBreathHandler
