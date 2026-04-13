--[[
	ReloadHandler.luau
	═══════════════════════════════════════════════════════════════
	Gestión de recarga server-side con Active Reload.
	═══════════════════════════════════════════════════════════════

	Responsabilidad ÚNICA:
	  Validar solicitudes de recarga, gestionar la ventana de
	  Active Reload (éxito/fallo), y actualizar el contador de
	  munición server-side tras el timer de recarga.

	Active Reload:
	  - Éxito (timing en ventana): tiempo restante / 2, buff de daño activo.
	  - Fallo (timing fuera de ventana): tiempo restante × 1.5, arma atascada.
	  - Normal (sin segundo input): espera el ReloadTime completo.

	No toca: raycast, daño, salud, drops.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConstants = require(Shared:WaitForChild("WeaponConstants"))
local Constants = require(Shared:WaitForChild("Constants"))

local ReloadHandler = {}

------------------------------------------------------------------------
-- State tables (inyectadas por WeaponServer)
------------------------------------------------------------------------

local _equippedWeapons: { [Player]: string } = {}
local _ammoState: { [Player]: { current: number, reserve: number } } = {}
local _reloadingPlayers: { [Player]: true? } = {}

------------------------------------------------------------------------
-- Active Reload tracking (internas — no inyectadas)
------------------------------------------------------------------------

local _reloadThreads: { [Player]: thread? } = {}
local _reloadStartTime: { [Player]: number } = {}
local _reloadWeaponName: { [Player]: string } = {}
local _activeBuffPlayers: { [Player]: true? } = {}

------------------------------------------------------------------------
-- State accessors
------------------------------------------------------------------------

function ReloadHandler.SetState(
	equippedWeapons: { [Player]: string },
	ammoState: { [Player]: { current: number, reserve: number } },
	reloadingPlayers: { [Player]: true? }
)
	_equippedWeapons = equippedWeapons
	_ammoState = ammoState
	_reloadingPlayers = reloadingPlayers
end

------------------------------------------------------------------------
-- PRIVATE — Completar recarga (transferir munición)
------------------------------------------------------------------------

local function _completeReload(player: Player, weaponName: string)
	_reloadThreads[player] = nil
	_reloadStartTime[player] = nil
	_reloadWeaponName[player] = nil

	-- Guard: si la recarga fue cancelada entre el schedule y la ejecución
	if not _reloadingPlayers[player] then
		return
	end

	_reloadingPlayers[player] = nil

	-- Re-validar estado tras el delay
	local currentAmmo = _ammoState[player]
	if not currentAmmo then
		return
	end
	if _equippedWeapons[player] ~= weaponName then
		return
	end

	local config = WeaponConstants.WEAPONS[weaponName]
	if not config then
		return
	end

	local clipSize = config.Ammo.ClipSize
	local needed = clipSize - currentAmmo.current
	local available = math.min(needed, currentAmmo.reserve)
	currentAmmo.current = currentAmmo.current + available
	currentAmmo.reserve = currentAmmo.reserve - available

	if Constants.DEBUG_MODE then
		print(`[ReloadHandler] Recarga completada — {weaponName} | Ammo: {currentAmmo.current}/{currentAmmo.reserve}`)
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Procesa una solicitud de recarga normal. Valida pre-condiciones y
--- programa un task.delay para refill de munición.
--- @return boolean — true si la recarga fue iniciada
function ReloadHandler.ProcessReload(player: Player, weaponName: any): boolean
	if typeof(weaponName) ~= "string" then
		return false
	end

	local equipped = _equippedWeapons[player]
	if not equipped or equipped ~= weaponName then
		return false
	end

	local config = WeaponConstants.WEAPONS[weaponName]
	if not config then
		return false
	end

	local ammoConfig = config.Ammo
	local ammo = _ammoState[player]
	if not ammo then
		return false
	end

	-- Solo bloquear si cargador lleno Y sin reserva (no hay nada que ganar)
	if ammo.current >= ammoConfig.ClipSize and ammo.reserve <= 0 then
		return false
	end

	-- Ya recargando
	if _reloadingPlayers[player] then
		return false
	end

	-- Limpiar buff de recarga activa previa al iniciar nueva recarga
	_activeBuffPlayers[player] = nil

	_reloadingPlayers[player] = true
	_reloadStartTime[player] = os.clock()
	_reloadWeaponName[player] = weaponName

	if Constants.DEBUG_MODE then
		print(`[ReloadHandler] Recarga iniciada — {weaponName} ({ammoConfig.ReloadTime}s)`)
	end

	-- Timer de recarga server-side (guardando referencia para poder cancelar)
	_reloadThreads[player] = task.delay(ammoConfig.ReloadTime, function()
		_completeReload(player, weaponName)
	end)

	return true
end

--- Procesa un intento de Active Reload (segundo press de R durante recarga).
--- El servidor calcula el progreso con su propio reloj (no confía en el cliente).
--- @return boolean — true si el active reload fue procesado
function ReloadHandler.ProcessActiveReload(player: Player, weaponName: any, _clientProgress: any): boolean
	if typeof(weaponName) ~= "string" then
		return false
	end

	-- Debe estar recargando
	if not _reloadingPlayers[player] then
		return false
	end

	-- Arma debe coincidir
	if _reloadWeaponName[player] ~= weaponName then
		return false
	end

	local config = WeaponConstants.WEAPONS[weaponName]
	if not config then
		return false
	end

	local ammoConfig = config.Ammo
	local startTime = _reloadStartTime[player]
	if not startTime then
		return false
	end

	-- Calcular progreso server-side (autoridad)
	local elapsed = os.clock() - startTime
	local reloadTime = ammoConfig.ReloadTime
	local progress = elapsed / reloadTime

	-- Leer ventana de active reload del arma
	local windowStart = ammoConfig.ActiveReloadWindowStart or 0.35
	local windowDuration = ammoConfig.ActiveReloadWindowDuration or 0.15
	local windowEnd = windowStart + windowDuration

	-- Cancelar el thread de recarga activo
	local currentThread = _reloadThreads[player]
	if currentThread then
		task.cancel(currentThread)
		_reloadThreads[player] = nil
	end

	local remainingTime = math.max(reloadTime - elapsed, 0.05)

	if progress >= windowStart and progress <= windowEnd then
		-- ═══════════════════════════════════════════════════════
		-- ACTIVE RELOAD EXITOSO — mitad del tiempo restante + buff
		-- ═══════════════════════════════════════════════════════
		local newDelay = remainingTime / 2
		_activeBuffPlayers[player] = true

		if Constants.DEBUG_MODE then
			print(
				`[ReloadHandler] ¡RECARGA ACTIVA EXITOSA! — {weaponName} | Progreso: {string.format("%.3f", progress)} | Completa en {string.format(
					"%.2f",
					newDelay
				)}s`
			)
		end

		_reloadThreads[player] = task.delay(newDelay, function()
			_completeReload(player, weaponName)
		end)
	else
		-- ═══════════════════════════════════════════════════════
		-- ACTIVE RELOAD FALLIDO — arma atascada, +50% tiempo
		-- ═══════════════════════════════════════════════════════
		local newDelay = remainingTime * 1.5

		if Constants.DEBUG_MODE then
			print(
				`[ReloadHandler] RECARGA FALLIDA: Arma atascada — {weaponName} | Progreso: {string.format(
					"%.3f",
					progress
				)} | Ventana: [{string.format("%.3f", windowStart)}, {string.format("%.3f", windowEnd)}] | Atascada {string.format(
					"%.2f",
					newDelay
				)}s`
			)
		end

		_reloadThreads[player] = task.delay(newDelay, function()
			_completeReload(player, weaponName)
		end)
	end

	return true
end

--- Cancela la recarga de un jugador (equip/unequip/muerte/evade/roadie run).
--- Cancela el thread pendiente para evitar transferencia de munición fantasma.
function ReloadHandler.CancelReload(player: Player)
	local reloadThread = _reloadThreads[player]
	if reloadThread then
		task.cancel(reloadThread)
		_reloadThreads[player] = nil
	end
	_reloadingPlayers[player] = nil
	_reloadStartTime[player] = nil
	_reloadWeaponName[player] = nil
end

--- Devuelve true si el jugador está recargando.
function ReloadHandler.IsReloading(player: Player): boolean
	return _reloadingPlayers[player] == true
end

--- Devuelve true si el jugador tiene el buff de recarga activa.
function ReloadHandler.HasActiveBuff(player: Player): boolean
	return _activeBuffPlayers[player] == true
end

--- Limpia el buff de recarga activa (cargador vacío o nueva recarga).
function ReloadHandler.ClearActiveBuff(player: Player)
	if _activeBuffPlayers[player] then
		_activeBuffPlayers[player] = nil
		if Constants.DEBUG_MODE then
			print(`[ReloadHandler] Buff de recarga activa consumido — {player.Name}`)
		end
	end
end

--- Limpia todo el estado de un jugador (para PlayerRemoving).
function ReloadHandler.CleanupPlayer(player: Player)
	ReloadHandler.CancelReload(player)
	_activeBuffPlayers[player] = nil
end

return table.freeze(ReloadHandler)
