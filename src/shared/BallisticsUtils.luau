--[[
	BallisticsUtils.luau
	═══════════════════════════════════════════════════════════════
	Utilidades de balística: cálculo de daño, zonas de impacto,
	headshot detection y caída de daño por distancia.
	═══════════════════════════════════════════════════════════════
]]

local BallisticsUtils = {}

------------------------------------------------------------------------
-- HITBOX MULTIPLIERS
------------------------------------------------------------------------

--- Multiplicadores de daño por zona de impacto.
--- Compatible con R6, R15 y HitBox custom.
local HIT_ZONE_MAP: { [string]: string } = {
	-- R15
	Head = "Head",
	UpperTorso = "Torso",
	LowerTorso = "Torso",
	LeftUpperArm = "Limb",
	LeftLowerArm = "Limb",
	LeftHand = "Limb",
	RightUpperArm = "Limb",
	RightLowerArm = "Limb",
	RightHand = "Limb",
	LeftUpperLeg = "Limb",
	LeftLowerLeg = "Limb",
	LeftFoot = "Limb",
	RightUpperLeg = "Limb",
	RightLowerLeg = "Limb",
	RightFoot = "Limb",
	-- R6
	Torso = "Torso",
	["Left Arm"] = "Limb",
	["Right Arm"] = "Limb",
	["Left Leg"] = "Limb",
	["Right Leg"] = "Limb",
	-- HumanoidRootPart (fallback)
	HumanoidRootPart = "Torso",
}

local ZONE_MULTIPLIERS: { [string]: number } = {
	Head = 3.0,
	Torso = 1.5,
	Limb = 0.75,
}

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Devuelve la zona de impacto ("Head", "Torso", "Limb") a partir del nombre de la parte.
--- Devuelve "Torso" como fallback si la parte es desconocida.
function BallisticsUtils.GetHitZone(hitPartName: string): string
	return HIT_ZONE_MAP[hitPartName] or "Torso"
end

--- Devuelve true si el impacto fue en la cabeza.
function BallisticsUtils.IsHeadshot(hitPartName: string): boolean
	return HIT_ZONE_MAP[hitPartName] == "Head"
end

--- Calcula el daño final considerando zona de impacto y caída de daño por distancia.
--- Los multiplicadores de zona (Head=3.0, Torso=1.5, Limb=0.75) son fijos y
--- definidos en ZONE_MULTIPLIERS — ya no se pasan por arma.
--- @param baseDamage number — daño base del arma (por pellet)
--- @param hitPartName string — nombre de la parte impactada
--- @param distance number — distancia del origin al impacto (studs)
--- @param falloffEnabled boolean — si la caída de daño está activa
--- @param falloffStartDistance number — studs donde empieza la caída
--- @param falloffDamagePerUnit number — daño restado por stud más allá del inicio
--- @return number — daño final (mínimo 1)
function BallisticsUtils.CalculateDamage(
	baseDamage: number,
	hitPartName: string,
	distance: number,
	falloffEnabled: boolean,
	falloffStartDistance: number,
	falloffDamagePerUnit: number
): number
	local zone = BallisticsUtils.GetHitZone(hitPartName)
	local multiplier = ZONE_MULTIPLIERS[zone] or 1.0

	local damage = baseDamage * multiplier

	-- Caída de daño por distancia
	if falloffEnabled and distance > falloffStartDistance then
		local excess = distance - falloffStartDistance
		damage = damage - (excess * falloffDamagePerUnit)
	end

	return math.max(damage, 1)
end

--- Calcula daño de explosión con caída lineal por distancia al epicentro.
--- @param baseDamage number — daño máximo en el epicentro
--- @param distance number — distancia del epicentro al objetivo (studs)
--- @param explosionRadius number — radio máximo de la explosión (studs)
--- @return number — daño final (0 si fuera de radio)
function BallisticsUtils.CalculateExplosionDamage(baseDamage: number, distance: number, explosionRadius: number): number
	if explosionRadius <= 0 or distance >= explosionRadius then
		return 0
	end
	local falloff = 1 - (distance / explosionRadius)
	return math.max(baseDamage * falloff, 0)
end

return table.freeze(BallisticsUtils)
