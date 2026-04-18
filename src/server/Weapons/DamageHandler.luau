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
local Workspace = game:GetService("Workspace")

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
	PelletDetails: { PelletDetail },
}

--- Detalle de daño por pellet individual (para ShotConfirmed al cliente).
export type PelletDetail = {
	PelletName: string,
	HitPosition: Vector3,
	HitPartName: string,
	Damage: number,
	IsFlesh: boolean,
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

	-- Permite autodaño (explosivos) independientemente de equipos
	if shooterPlayer and victimPlayer and shooterPlayer == victimPlayer then
		return false
	end

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

--- Verifica la línea de visión para explosiones a un personaje.
--- Ignora otros personajes y busca TorsoHitbox y HeadHitbox.
--- Devuelve el multiplicador de daño (1.0 = torso, 0.5 = solo cabeza, 0.0 = pared)
local function _getExplosionLOSMultiplier(epicenter: Vector3, targetChar: Model): number
	local function _checkLoSToPart(part: BasePart?): boolean
		if not part then
			return false
		end

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude

		local exclude = {}
		for _, p in Players:GetPlayers() do
			if p.Character and p.Character ~= targetChar then
				table.insert(exclude, p.Character)
			end
		end
		-- Asegurar que los efectos o hitboxes del arma del tirador no bloqueen
		params.FilterDescendantsInstances = exclude

		local dir = (part.Position - epicenter)
		-- Rayo directo a la posición exacta con un margen
		local result = Workspace:Raycast(epicenter, dir.Unit * (dir.Magnitude + 0.1), params)

		if result then
			-- Impactó el character objetivo
			if result.Instance:IsDescendantOf(targetChar) then
				return true
			end
			-- Impactó algo más (pared, objeto duro)
			return false
		end
		-- Línea limpia (no impactó nada en medio)
		return true
	end

	local torso = targetChar:FindFirstChild("TorsoHitbox")
		or targetChar:FindFirstChild("UpperTorso")
		or targetChar:FindFirstChild("Torso")
		or targetChar:FindFirstChild("HumanoidRootPart")
	local head = targetChar:FindFirstChild("HeadHitbox") or targetChar:FindFirstChild("Head")

	local hitTorso = _checkLoSToPart(torso)
	local hitHead = _checkLoSToPart(head)

	if hitTorso then
		return 1.0
	elseif hitHead then
		return 0.5
	else
		return 0.0
	end
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
	local pelletDetails: { PelletDetail } = {}

	local stats = config.Stats
	local falloff = config.Ballistics.Falloff
	local explosive = config.Ballistics.Explosive

	for _, hit in hits do
		local hitHumanoid = hit.HitHumanoid
		local hitCharacter = hit.HitCharacter

		if explosive.Enabled and explosive.Radius > 0 then
			-- Lógica AoE: el hit es el epicentro (sin importar si impactó jugador o entorno)
			local hitPosition = hit.HitPosition
			local overlapParams = OverlapParams.new()
			overlapParams.FilterType = Enum.RaycastFilterType.Exclude
			-- NO excluimos al shooterChar, queremos evaluar si se daña a sí mismo
			overlapParams.FilterDescendantsInstances = {}

			local parts = Workspace:GetPartBoundsInRadius(hitPosition, explosive.Radius, overlapParams)
			local processedCharacters: { [Model]: true } = {}

			for _, part in parts do
				local parentModel = part.Parent
				if not parentModel or not parentModel:IsA("Model") then
					continue
				end

				if processedCharacters[parentModel] then
					continue
				end

				local aoeHumanoid = parentModel:FindFirstChildWhichIsA("Humanoid")
				if not aoeHumanoid or aoeHumanoid.Health <= 0 then
					continue
				end

				if _isFriendlyFire(shooterChar, parentModel) then
					continue
				end

				processedCharacters[parentModel] = true

				-- Line of Sight Raycast check
				local losMultiplier = _getExplosionLOSMultiplier(hitPosition, parentModel)
				if losMultiplier <= 0 then
					continue
				end

				-- Calcular distancia desde epicentro
				local targetHRP = parentModel:FindFirstChild("HumanoidRootPart")
				local targetPos = if targetHRP then targetHRP.Position else part.Position
				local distance = (targetPos - hitPosition).Magnitude

				-- Daño explosivo modificado: pasa falloff.Enabled
				local aoeDamage = BallisticsUtils.CalculateExplosionDamage(
					stats.BaseDamage,
					distance,
					explosive.Radius,
					falloff.Enabled
				)
				
				aoeDamage = aoeDamage * losMultiplier

				if aoeDamage <= 0 then
					continue
				end

				local existing = victimMap[aoeHumanoid]
				if existing then
					existing.TotalDamage += aoeDamage
					existing.PelletCount += 1
				else
					victimMap[aoeHumanoid] = {
						Humanoid = aoeHumanoid,
						Character = parentModel,
						TotalDamage = aoeDamage,
						LastHitZone = if losMultiplier == 0.5 then "Head" else "Torso",
						LastHitPartName = if losMultiplier == 0.5 then "Head" else "TorsoHitbox",
						PelletCount = 1,
						IsHeadshot = (losMultiplier == 0.5),
						HitDirection = (targetPos - hitPosition).Unit,
					}
				end
			end
			
			if hitHumanoid == nil then
				environmentHits += 1
			end
			-- Guardar detalle
			table.insert(pelletDetails, {
				PelletName = hit.PelletName or "",
				HitPosition = hit.HitPosition,
				HitPartName = hit.HitPartName,
				Damage = 0, -- Detalle principal 0, el daño está en victims
				IsFlesh = (hitHumanoid ~= nil),
			})

			continue
		end

		-- CASO HITSCAN NORMAL: Si dio al entorno, saltar
		if not hitHumanoid or not hitCharacter then
			environmentHits += 1
			table.insert(pelletDetails, {
				PelletName = hit.PelletName or "",
				HitPosition = hit.HitPosition,
				HitPartName = hit.HitPartName,
				Damage = 0,
				IsFlesh = false,
			})
			continue
		end

		-- Team Check direct hit
		if _isFriendlyFire(shooterChar, hitCharacter) then
			continue
		end

		-- Daño hitscan: zona + falloff por distancia
		local pelletDamage = BallisticsUtils.CalculateDamage(
			stats.BaseDamage,
			hit.HitPartName,
			hit.HitDistance,
			falloff.Enabled,
			falloff.StartDistance,
			falloff.DamagePerUnit
		)

		local hitZone = BallisticsUtils.GetHitZone(hit.HitPartName)
		local isHeadshot = hitZone == "Head"

		-- Registrar detalle por pellet (para ShotConfirmed)
		table.insert(pelletDetails, {
			PelletName = hit.PelletName or "",
			HitPosition = hit.HitPosition,
			HitPartName = hit.HitPartName,
			Damage = pelletDamage,
			IsFlesh = true,
		})

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
		PelletDetails = pelletDetails,
	}
end

return table.freeze(DamageHandler)
