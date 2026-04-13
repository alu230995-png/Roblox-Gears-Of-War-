--[[
	DamageHandler.luau
	═══════════════════════════════════════════════════════════════
	Cálculo de daño acumulado por disparo.
	═══════════════════════════════════════════════════════════════

	Responsabilidad ÚNICA:
	  Recibir los resultados de raycast (PelletHit[]) y calcular
	  el daño total a aplicar por víctima, siguiendo este pipeline:

	  1. Detección de impacto → qué hitbox fue golpeada
	  2. Multiplicadores → daño × multiplicador de zona (Head/Torso/Limb)
	  3. Atenuación por distancia → falloff balístico
	  4. Team Check → fuego amigo = 0 daño
	  5. Acumulación → sumar todos los pellets por víctima

	Retorna: DamageReport con daño total por víctima, zona del
	     último impacto (para headshot death), y overkill info.

	NO muta salud. Solo CALCULA.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BallisticsUtils = require(Shared:WaitForChild("BallisticsUtils"))

local DamageHandler = {}

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

--- Info de daño acumulado para una víctima.
export type VictimDamage = {
	Humanoid: Humanoid,
	Character: Model,
	TotalDamage: number,
	LastHitZone: string,
	LastHitPartName: string,
	PelletCount: number,
	IsHeadshot: boolean,
	HitDirection: Vector3,
}

--- Resultado completo de un disparo procesado.
export type DamageReport = {
	Victims: { VictimDamage },
	EnvironmentHits: number,
}

------------------------------------------------------------------------
-- PRIVATE helpers
------------------------------------------------------------------------

--- Obtiene el Player dueño de un Character (nil si es NPC).
local function _getPlayerFromCharacter(character: Model): Player?
	return Players:GetPlayerFromCharacter(character)
end

--- Comprueba si dos characters están en el mismo equipo.
--- Retorna true si son aliados (mismo team o sin team asignado).
local function _isFriendlyFire(shooterChar: Model, victimChar: Model): boolean
	local shooterPlayer = _getPlayerFromCharacter(shooterChar)
	local victimPlayer = _getPlayerFromCharacter(victimChar)

	-- Si alguno no es jugador (NPC), no es fuego amigo
	if not shooterPlayer or not victimPlayer then
		return false
	end

	-- Sin equipos asignados → no es fuego amigo
	if not shooterPlayer.Team or not victimPlayer.Team then
		return false
	end

	return shooterPlayer.Team == victimPlayer.Team
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Calcula el daño total por víctima a partir de los resultados de raycast.
--- Acumula múltiples pellets que impactan la misma víctima (escopeta).
--- Para armas con Explosive.Enabled, usa daño de explosión (AoE lineal).
---
--- @param hits { PelletHit } — resultados de ServerRaycast.CastPellets
--- @param shooterChar Model — Character del tirador
--- @param origin Vector3 — posición de origen del disparo (Muzzle)
--- @param config any — WeaponConstants.WEAPONS[weaponName]
--- @return DamageReport
function DamageHandler.CalculateDamage(hits: any, shooterChar: Model, origin: Vector3, config: any): DamageReport
	-- Acumulador: Humanoid → VictimDamage
	local victimMap: { [Humanoid]: VictimDamage } = {}
	local environmentHits = 0

	local stats = config.Stats
	local falloff = config.Ballistics.Falloff
	local explosive = config.Ballistics.Explosive

	for _, hit in hits do
		local hitHumanoid = hit.HitHumanoid
		local hitCharacter = hit.HitCharacter

		if not hitHumanoid or not hitCharacter then
			-- Impacto en entorno (pared, suelo, etc.)
			-- Para explosivos: daño AoE a jugadores cercanos al impacto
			if explosive.Enabled then
				-- TODO: buscar humanoids en radio de explosión y aplicar AoE
				-- Por ahora se acumula como environment hit
			end
			environmentHits += 1
			continue
		end

		-- Team Check: ignorar fuego amigo
		if _isFriendlyFire(shooterChar, hitCharacter) then
			continue
		end

		-- Calcular daño de este pellet
		local pelletDamage: number

		if explosive.Enabled then
			-- Daño explosivo: caída lineal por distancia al impacto
			pelletDamage = BallisticsUtils.CalculateExplosionDamage(stats.BaseDamage, hit.HitDistance, explosive.Radius)
		else
			-- Daño hitscan: zona + falloff por distancia
			pelletDamage = BallisticsUtils.CalculateDamage(
				stats.BaseDamage,
				hit.HitPartName,
				hit.HitDistance,
				falloff.Enabled,
				falloff.StartDistance,
				falloff.DamagePerUnit
			)
		end

		local hitZone = BallisticsUtils.GetHitZone(hit.HitPartName)
		local isHeadshot = hitZone == "Head"

		-- Acumular daño por víctima
		local existing = victimMap[hitHumanoid]
		if existing then
			existing.TotalDamage += pelletDamage
			existing.PelletCount += 1
			-- Guardar la zona del ÚLTIMO impacto (para headshot death logic)
			existing.LastHitZone = hitZone
			existing.LastHitPartName = hit.HitPartName
			-- Si cualquier pellet fue headshot, marcar como headshot
			if isHeadshot then
				existing.IsHeadshot = true
			end
			-- Actualizar dirección de impacto al último pellet
			existing.HitDirection = (hit.HitPosition - origin).Unit
		else
			victimMap[hitHumanoid] = {
				Humanoid = hitHumanoid,
				Character = hitCharacter,
				TotalDamage = pelletDamage,
				LastHitZone = hitZone,
				LastHitPartName = hit.HitPartName,
				PelletCount = 1,
				IsHeadshot = isHeadshot,
				HitDirection = (hit.HitPosition - origin).Unit,
			}
		end
	end

	-- Convertir map a array
	local victims: { VictimDamage } = {}
	for _, victimData in victimMap do
		table.insert(victims, victimData)
	end

	return {
		Victims = victims,
		EnvironmentHits = environmentHits,
	}
end

return table.freeze(DamageHandler)
