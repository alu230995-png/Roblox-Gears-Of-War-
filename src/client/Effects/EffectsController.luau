--[[
	EffectsController.luau
	═══════════════════════════════════════════════════════════════
	Coordinador central del sistema de efectos visuales.
	═══════════════════════════════════════════════════════════════

	Análogo a SoundController: coordina todos los sub-módulos de VFX.
	Compatible con ServiceLocator (Init/Start/Destroy).

	Subscribes to:
	  - WeaponClient.ShotFired / .ReloadStarted / .WeaponEquipped
	  - DeathEffectsHandler (via OnDeath call)

	Dispatches to:
	  - MuzzleFlashEffect, BulletTrailEffect, ImpactEffect
	  - BloodEffect, ExplosionEffect, ScreenShakeEffect
	  - SoundController (weapon/death sounds)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConfig = require(Shared:WaitForChild("EffectsConfig"))
local EffectsConstants = require(Shared:WaitForChild("EffectsConstants"))
local WeaponConstants = require(Shared:WaitForChild("WeaponConstants"))
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))

local ParticlePool = require(script.Parent.ParticlePool)
local TrailPool = require(script.Parent.TrailPool)
local MuzzleFlashEffect = require(script.Parent.MuzzleFlashEffect)
local BulletTrailEffect = require(script.Parent.BulletTrailEffect)
local ImpactEffect = require(script.Parent.ImpactEffect)
local BloodEffect = require(script.Parent.BloodEffect)
local ExplosionEffect = require(script.Parent.ExplosionEffect)
local ScreenShakeEffect = require(script.Parent.ScreenShakeEffect)

local EffectsController = {}
EffectsController.__index = EffectsController

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function EffectsController.new(_stateMachine: any)
	local self = setmetatable({}, EffectsController)

	-- Sub-modules (creados en Init)
	self._particlePool = nil
	self._trailPool = nil
	self._muzzleFlash = nil
	self._bulletTrail = nil
	self._impactEffect = nil
	self._bloodEffect = nil
	self._explosionEffect = nil
	self._screenShake = nil

	-- Dependencias externas (inyectadas post-Init)
	self._soundController = nil
	self._cameraController = nil

	-- Weapon signal connections
	self._weaponConnections = {} :: { [any]: { any } }

	-- Remote for receiving other players' shot effects
	self._weaponEffectsRemote = nil :: RemoteEvent?
	self._remoteConnection = nil :: RBXScriptConnection?

	-- Remote for receiving server-confirmed shot data (validated positions + damage)
	self._shotConfirmedRemote = nil :: RemoteEvent?
	self._shotConfirmedConnection = nil :: RBXScriptConnection?

	-- Active weapon client reference (for accessing scope)
	self._activeWeaponClient = nil

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE (ServiceLocator compatible)
------------------------------------------------------------------------

function EffectsController:Init()
	-- Crear pools
	self._particlePool = ParticlePool.new(EffectsConstants.PARTICLE_POOL_SIZE)
	self._trailPool = TrailPool.new(EffectsConstants.TRAIL_POOL_SIZE)

	self._particlePool:Init()
	self._trailPool:Init()

	-- Crear sub-módulos
	self._muzzleFlash = MuzzleFlashEffect.new()
	self._bulletTrail = BulletTrailEffect.new(self._trailPool)
	self._impactEffect = ImpactEffect.new(self._particlePool)
	self._bloodEffect = BloodEffect.new(self._particlePool)
	self._explosionEffect = ExplosionEffect.new()
	self._screenShake = ScreenShakeEffect.new()
end

function EffectsController:Start()
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not remotes then
		return
	end

	-- Escuchar efectos de disparo de OTROS jugadores (replicado por el servidor)
	self._weaponEffectsRemote = remotes:WaitForChild("WeaponEffects", 5) :: RemoteEvent?
	if self._weaponEffectsRemote then
		self._remoteConnection = self._weaponEffectsRemote.OnClientEvent:Connect(function(effectsData)
			self:_onRemoteShotEffects(effectsData)
		end)
	end

	-- Escuchar confirmación de disparo del servidor (posiciones validadas + daño)
	self._shotConfirmedRemote = remotes:WaitForChild("ShotConfirmed", 5) :: RemoteEvent?
	if self._shotConfirmedRemote then
		self._shotConfirmedConnection = self._shotConfirmedRemote.OnClientEvent:Connect(function(data)
			self:_onShotConfirmed(data)
		end)
	end
end

function EffectsController:Destroy()
	-- Desconectar remote de efectos replicados
	if self._remoteConnection then
		self._remoteConnection:Disconnect()
		self._remoteConnection = nil
	end
	if self._shotConfirmedConnection then
		self._shotConfirmedConnection:Disconnect()
		self._shotConfirmedConnection = nil
	end

	-- Desconectar todas las weapon connections
	for wc, connections in self._weaponConnections do
		for _, conn in connections do
			if conn.Disconnect then
				conn:Disconnect()
			end
		end
	end
	table.clear(self._weaponConnections)

	-- Destruir sub-módulos
	if self._muzzleFlash then
		self._muzzleFlash:Destroy()
	end
	if self._bulletTrail then
		self._bulletTrail:Destroy()
	end
	if self._impactEffect then
		self._impactEffect:Destroy()
	end
	if self._bloodEffect then
		self._bloodEffect:Destroy()
	end
	if self._explosionEffect then
		self._explosionEffect:Destroy()
	end
	if self._screenShake then
		self._screenShake:Destroy()
	end

	-- Destruir pools
	if self._particlePool then
		self._particlePool:Destroy()
	end
	if self._trailPool then
		self._trailPool:Destroy()
	end
end

------------------------------------------------------------------------
-- DEPENDENCY INJECTION (post-Init)
------------------------------------------------------------------------

function EffectsController:SetCameraController(cameraController)
	self._cameraController = cameraController
	if self._screenShake then
		self._screenShake:SetCameraController(cameraController)
	end
end

function EffectsController:SetSoundController(soundController)
	self._soundController = soundController
end

------------------------------------------------------------------------
-- WEAPON BINDING — conecta signals de un WeaponClient
------------------------------------------------------------------------

function EffectsController:BindWeaponClient(weaponClient)
	if self._weaponConnections[weaponClient] then
		return
	end

	local connections = {}

	-- ShotFired signal
	if weaponClient.ShotFired then
		table.insert(
			connections,
			weaponClient.ShotFired:Connect(function(weaponName, shotResult, character)
				self:OnShotFired(weaponName, shotResult, character, true)
			end)
		)
	end

	-- ReloadStarted signal
	if weaponClient.ReloadStarted then
		table.insert(
			connections,
			weaponClient.ReloadStarted:Connect(function(weaponName)
				local character = Players.LocalPlayer and Players.LocalPlayer.Character
				self:OnReloadStarted(weaponName, character)
			end)
		)
	end

	-- WeaponEquipped signal (ya existe en WeaponClient)
	if weaponClient.WeaponEquipped then
		table.insert(
			connections,
			weaponClient.WeaponEquipped:Connect(function(weaponName, _config)
				local character = Players.LocalPlayer and Players.LocalPlayer.Character
				self:OnWeaponEquipped(weaponName, character)
			end)
		)
	end

	self._weaponConnections[weaponClient] = connections
	self._activeWeaponClient = weaponClient
end

function EffectsController:UnbindWeaponClient(weaponClient)
	local connections = self._weaponConnections[weaponClient]
	if not connections then
		return
	end
	for _, conn in connections do
		if conn.Disconnect then
			conn:Disconnect()
		end
	end
	self._weaponConnections[weaponClient] = nil
	if self._activeWeaponClient == weaponClient then
		self._activeWeaponClient = nil
	end
end

------------------------------------------------------------------------
-- PUBLIC API — Event handlers
------------------------------------------------------------------------

function EffectsController:OnShotFired(weaponName: string, shotResult: any, character: Model?, isLocalShot: boolean?)
	if not shotResult then
		return
	end

	-- 1. Muzzle flash (siempre, para local y remoto)
	self._muzzleFlash:Fire(character, weaponName)

	if isLocalShot == false then
		-- Disparos de OTROS jugadores: usar datos del servidor tal cual
		-- (trails, impactos, sangre, sonido — todo inmediato)
		local origin = shotResult.Origin
		self._bulletTrail:Fire(origin, shotResult.HitPositions, weaponName)

		for pelletName, hitPos in shotResult.HitPositions do
			local hitPartName = shotResult.HitParts and shotResult.HitParts[pelletName]
			local isFlesh = self:_isFleshHit(hitPartName)

			if isFlesh then
				local dir = (hitPos - origin).Unit
				self._bloodEffect:FireHit(hitPos, dir)
				self:_playSound("VFX_Hit_Flesh", hitPos)
			else
				self._impactEffect:Fire(hitPos, nil, nil)
				self:_playSound("VFX_Impact_Bullet_Default", hitPos)
			end
		end
	else
		-- Disparo LOCAL: solo efectos inmediatos (trails/impactos/blood/hitmarkers
		-- se renderizan al recibir ShotConfirmed del servidor)

		-- Screen shake por disparo
		self._screenShake:FireWeaponKick(weaponName)
	end

	-- Weapon fire sound (siempre)
	local fireSoundKey = "VFX_Weapon_" .. weaponName .. "_Fire"
	if SoundConfig[fireSoundKey] then
		self:_playSound(fireSoundKey, character and self:_getCharacterPosition(character))
	end

	-- Explosión si el arma es explosiva (siempre)
	local weaponConfig = WeaponConstants.WEAPONS[weaponName]
	if weaponConfig and weaponConfig.Ballistics and weaponConfig.Ballistics.Explosive then
		local explosive = weaponConfig.Ballistics.Explosive
		if explosive.Enabled and explosive.Radius > 0 then
			for _, hitPos in shotResult.HitPositions do
				self:OnExplosion(hitPos, explosive.Radius, weaponName)
				break
			end
		end
	end
end

function EffectsController:OnReloadStarted(weaponName: string, character: Model?)
	-- Sonido de recarga específico del arma
	local reloadSoundKey = "VFX_Weapon_" .. weaponName .. "_Reload"
	if not SoundConfig[reloadSoundKey] then
		reloadSoundKey = "VFX_Weapon_Reload"
	end
	self:_playSound(reloadSoundKey, character and self:_getCharacterPosition(character))
end

function EffectsController:OnWeaponEquipped(weaponName: string, character: Model?)
	local _ = weaponName -- Reservado para sonidos per-weapon en el futuro
	self:_playSound("VFX_Weapon_Equip", character and self:_getCharacterPosition(character))
end

function EffectsController:OnDeath(
	character: Model,
	deathType: string,
	hitDirection: Vector3?,
	_overkillDamage: number?
)
	-- 1. Partículas de sangre
	self._bloodEffect:FireDeath(character, deathType, hitDirection)

	-- 2. Death sound
	local deathConfig = EffectsConfig.DEATH[deathType]
	if deathConfig and deathConfig.Sound then
		self:_playSound(deathConfig.Sound, self:_getCharacterPosition(character))
	end

	-- 3. Screen shake si el local player es el killer
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character and localPlayer.Character ~= character then
		self._screenShake:FireDeathShake(deathType)
	end
end

function EffectsController:OnExplosion(position: Vector3, radius: number, weaponName: string)
	-- VFX de explosión
	self._explosionEffect:Fire(position, radius, weaponName)

	-- Sonido de explosión
	self:_playSound("VFX_Explosion", position)

	-- Screen shake atenuado por distancia
	local localPlayer = Players.LocalPlayer
	if localPlayer and localPlayer.Character then
		local hrp = localPlayer.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hrp then
			local distance = (hrp.Position - position).Magnitude
			self._screenShake:FireExplosionShake(distance)
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Remote shot effects (otros jugadores)
------------------------------------------------------------------------

--- Procesa efectos de disparo recibidos del servidor (disparos de otros jugadores).
function EffectsController:_onRemoteShotEffects(effectsData: any)
	if typeof(effectsData) ~= "table" then
		return
	end

	local weaponName = effectsData.WeaponName
	local origin = effectsData.Origin
	local hitPositions = effectsData.HitPositions
	local hitParts = effectsData.HitParts
	local shooterCharacter = effectsData.ShooterCharacter

	if typeof(weaponName) ~= "string" or typeof(origin) ~= "Vector3" then
		return
	end
	if typeof(hitPositions) ~= "table" then
		return
	end

	local shotResult = {
		Origin = origin,
		HitPositions = hitPositions,
		HitParts = hitParts,
	}

	self:OnShotFired(weaponName, shotResult, shooterCharacter, false)
end

------------------------------------------------------------------------
-- PRIVATE: Shot confirmed by server (local player only)
------------------------------------------------------------------------

--- Procesa la confirmación del servidor con posiciones validadas y daño por pellet.
--- Renderiza efectos diferidos: trails, impactos, sangre, hitmarkers.
function EffectsController:_onShotConfirmed(data: any)
	if typeof(data) ~= "table" then
		return
	end

	local weaponName = data.WeaponName
	local muzzlePosition = data.MuzzlePosition
	local validatedHits = data.ValidatedHits
	local kills = data.Kills

	if typeof(weaponName) ~= "string" or typeof(muzzlePosition) ~= "Vector3" then
		return
	end
	if typeof(validatedHits) ~= "table" then
		return
	end

	-- 1. Bullet trails desde muzzle del servidor hasta cada hit validado
	local hitPositionsMap = {}
	for _, hit in validatedHits do
		local pelletKey = "Pellet_" .. tostring(hit.PelletIndex or 0)
		hitPositionsMap[pelletKey] = hit.HitPosition
	end
	self._bulletTrail:Fire(muzzlePosition, hitPositionsMap, weaponName)

	-- 2. Impactos y sangre por pellet (con daño para scaling)
	local hasFleshHit = false
	for _, hit in validatedHits do
		if hit.IsFlesh then
			hasFleshHit = true
			local dir = (hit.HitPosition - muzzlePosition).Unit
			self._bloodEffect:FireHit(hit.HitPosition, dir, hit.Damage)
			self:_playSound("VFX_Hit_Flesh", hit.HitPosition)
		else
			self._impactEffect:Fire(hit.HitPosition, nil, nil)
			self:_playSound("VFX_Impact_Bullet_Default", hit.HitPosition)
		end
	end

	-- 3. Hit marker sound
	if hasFleshHit then
		self:_playSound("VFX_Hit_Marker")
	end

	-- 4. Hitmarker visual en el ScopeRenderer
	local scope = self:_getActiveScope()
	if scope and scope.OnShotConfirmed then
		scope:OnShotConfirmed(data)
	end
end

--- Obtiene el ScopeRenderer activo del WeaponClient actual.
function EffectsController:_getActiveScope()
	if not self._activeWeaponClient then
		return nil
	end
	if self._activeWeaponClient.GetScope then
		return self._activeWeaponClient:GetScope()
	end
	return nil
end

------------------------------------------------------------------------
-- PRIVATE HELPERS
------------------------------------------------------------------------

local FLESH_PART_NAMES = {
	Head = true,
	UpperTorso = true,
	LowerTorso = true,
	HumanoidRootPart = true,
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
	-- R6 fallbacks
	Torso = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
}

function EffectsController:_isFleshHit(partName: string?): boolean
	if not partName then
		return false
	end
	return FLESH_PART_NAMES[partName] == true
end

function EffectsController:_playSound(soundName: string, position: Vector3?)
	if not self._soundController then
		return
	end
	self._soundController:PlayLocal(soundName, position)
end

function EffectsController:_getCharacterPosition(character: Model): Vector3?
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		return hrp.Position
	end
	return nil
end

return EffectsController
