--[[
	ShotValidator.luau
	═══════════════════════════════════════════════════════════════
	Validación server-side de disparos.
	═══════════════════════════════════════════════════════════════

	Responsabilidad ÚNICA:
	  Determinar si un disparo reportado por el cliente es LEGÍTIMO.
	  No dispara raycasts, no aplica daño, no muta salud.

	Checks:
	  1. Tipo de datos del payload (anti-exploit)
	  2. Arma equipada coincide con la reportada
	  3. Rate limit (cadencia mínima entre disparos)
	  4. Munición disponible (> 0) y deducción
	  5. Jugador NO está recargando
	  6. Jugador está vivo (Humanoid.Health > 0)
	  7. Muzzle Attachment existe en el Tool equipado

	Retorna: ValidationResult con toda la info que los módulos
	posteriores necesitan, o nil si el disparo es inválido.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConstants = require(Shared:WaitForChild("WeaponConstants"))
local Constants = require(Shared:WaitForChild("Constants"))

local ReloadHandler = require(script.Parent:WaitForChild("ReloadHandler"))

local ShotValidator = {}

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

export type ValidationResult = {
	Player: Player,
	Character: Model,
	Humanoid: Humanoid,
	WeaponName: string,
	Config: any,
	MuzzlePosition: Vector3,
	HitPositions: { [string]: Vector3 },
}

------------------------------------------------------------------------
-- State tables (shared with WeaponServer via setters)
------------------------------------------------------------------------

local _equippedWeapons: { [Player]: string } = {}
local _ammoState: { [Player]: { current: number, reserve: number } } = {}
local _lastFireTime: { [Player]: number } = {}
local _reloadingPlayers: { [Player]: true? } = {}

------------------------------------------------------------------------
-- State accessors (WeaponServer inyecta las tablas)
------------------------------------------------------------------------

function ShotValidator.SetState(
	equippedWeapons: { [Player]: string },
	ammoState: { [Player]: { current: number, reserve: number } },
	lastFireTime: { [Player]: number },
	reloadingPlayers: { [Player]: true? }
)
	_equippedWeapons = equippedWeapons
	_ammoState = ammoState
	_lastFireTime = lastFireTime
	_reloadingPlayers = reloadingPlayers
end

------------------------------------------------------------------------
-- PRIVATE helpers
------------------------------------------------------------------------

local function _getCharacterAndHumanoid(player: Player): (Model?, Humanoid?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return character, humanoid
end

local function _findMuzzle(character: Model, weaponName: string): (Vector3?, Tool?)
	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child.Name == weaponName then
			local handle = child:FindFirstChild("Handle") :: BasePart?
			if not handle then
				warn(`[ShotValidator] Tool "{weaponName}" no tiene Handle`)
				return nil, nil
			end

			local muzzle = handle:FindFirstChild("Muzzle") :: Attachment?
			if not muzzle then
				warn(`[ShotValidator] Handle de "{weaponName}" no tiene Attachment "Muzzle"`)
				return nil, nil
			end

			return muzzle.WorldPosition, child :: Tool
		end
	end
	return nil, nil
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Valida un disparo completo. Retorna nil si el disparo es inválido.
--- Si es válido, consume 1 bala y actualiza el timestamp de fire rate.
function ShotValidator.Validate(player: Player, shotData: any): ValidationResult?
	-- 1. Tipo de datos del payload
	if typeof(shotData) ~= "table" then
		return nil
	end

	local weaponName = shotData.WeaponName
	if typeof(weaponName) ~= "string" then
		return nil
	end

	-- 2. Arma equipada == arma reportada
	local equipped = _equippedWeapons[player]
	if not equipped or equipped ~= weaponName then
		warn(`[ShotValidator] {player.Name} no tiene {weaponName} equipada`)
		return nil
	end

	local config = WeaponConstants.WEAPONS[weaponName]
	if not config then
		return nil
	end

	-- 3. Rate limit
	local now = os.clock()
	local lastFire = _lastFireTime[player] or 0
	local minInterval = config.Stats.FireRate - Constants.SERVER_FIRE_RATE_TOLERANCE
	if (now - lastFire) < minInterval then
		return nil
	end

	-- 4. Ammo check + deducción
	local ammo = _ammoState[player]
	if not ammo or ammo.current <= 0 then
		return nil
	end

	-- 5. No está recargando
	if _reloadingPlayers[player] then
		return nil
	end

	-- 6. Jugador vivo
	local shooterChar, shooterHumanoid = _getCharacterAndHumanoid(player)
	if not shooterChar or not shooterHumanoid or shooterHumanoid.Health <= 0 then
		return nil
	end

	-- 7. Muzzle Attachment
	local muzzlePos, _tool = _findMuzzle(shooterChar, weaponName)
	if not muzzlePos then
		warn(`[ShotValidator] {player.Name} no tiene Tool "{weaponName}" con Muzzle en el Character`)
		return nil
	end

	-- 8. Validar hitPositions (anti-exploit: límite de pellets)
	local hitPositions = shotData.HitPositions
	if typeof(hitPositions) ~= "table" then
		return nil
	end

	local maxPellets = #config.Ballistics.SpreadPattern
	local pelletCount = 0
	local validatedHits: { [string]: Vector3 } = {}

	for key, pos in hitPositions do
		pelletCount += 1
		-- Anti-DDoS: rechazar si excede el máximo de pellets del arma
		if pelletCount > maxPellets then
			warn(`[ShotValidator] {player.Name} envió más pellets ({pelletCount}) que el máximo ({maxPellets})`)
			return nil
		end
		-- Validar tipos: key debe ser string, pos debe ser Vector3
		if typeof(key) ~= "string" or typeof(pos) ~= "Vector3" then
			warn(`[ShotValidator] {player.Name} envió hitPositions con tipos inválidos`)
			return nil
		end
		validatedHits[key] = pos
	end

	-- Disparo VÁLIDO: consumir recursos
	ammo.current = ammo.current - 1
	_lastFireTime[player] = now

	-- Limpiar buff de recarga activa al vaciar cargador
	if ammo.current == 0 then
		ReloadHandler.ClearActiveBuff(player)
	end

	return {
		Player = player,
		Character = shooterChar,
		Humanoid = shooterHumanoid,
		WeaponName = weaponName,
		Config = config,
		MuzzlePosition = muzzlePos,
		HitPositions = validatedHits,
	}
end

return table.freeze(ShotValidator)
