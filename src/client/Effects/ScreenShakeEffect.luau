--[[
	ScreenShakeEffect.luau
	═══════════════════════════════════════════════════════════════
	Wrapper sobre CameraController:FireImpulseShake().
	═══════════════════════════════════════════════════════════════

	Lee valores de EffectsConfig y delega al CameraController.
	NO duplica lógica de shake — solo provee API semántica.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConfig = require(Shared:WaitForChild("EffectsConfig"))

local ScreenShakeEffect = {}
ScreenShakeEffect.__index = ScreenShakeEffect

function ScreenShakeEffect.new()
	local self = setmetatable({}, ScreenShakeEffect)
	self._cameraController = nil
	return self
end

function ScreenShakeEffect:SetCameraController(cameraController)
	self._cameraController = cameraController
end

function ScreenShakeEffect:Destroy()
	self._cameraController = nil
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function ScreenShakeEffect:FireWeaponKick(weaponName: string)
	if not self._cameraController then
		return
	end

	local weaponConfig = EffectsConfig.WEAPONS[weaponName]
	if not weaponConfig or not weaponConfig.ScreenShake then
		return
	end

	local shake = weaponConfig.ScreenShake
	self._cameraController:FireImpulseShake(shake.FireX, shake.FireY)
end

function ScreenShakeEffect:FireDeathShake(deathType: string)
	if not self._cameraController then
		return
	end

	local deathConfig = EffectsConfig.DEATH[deathType]
	if not deathConfig or not deathConfig.ScreenShake then
		return
	end

	local shake = deathConfig.ScreenShake
	self._cameraController:FireImpulseShake(shake.X, shake.Y)
end

function ScreenShakeEffect:FireExplosionShake(distance: number)
	if not self._cameraController then
		return
	end

	local expShake = EffectsConfig.EXPLOSION.ScreenShake
	if not expShake then
		return
	end

	-- Atenuación por distancia
	if distance >= expShake.FalloffEnd then
		return
	end

	local intensity = 1.0
	if distance > expShake.FalloffStart then
		local range = expShake.FalloffEnd - expShake.FalloffStart
		intensity = 1.0 - ((distance - expShake.FalloffStart) / range)
	end

	self._cameraController:FireImpulseShake(expShake.MaxX * intensity, expShake.MaxY * intensity)
end

return ScreenShakeEffect
