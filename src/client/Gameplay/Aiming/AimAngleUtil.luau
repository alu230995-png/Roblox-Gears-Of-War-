--[[
	AimAngleUtils.luau
	═══════════════════════════════════════════════════════════════
	Matemática pura para el sistema de apuntado en cover.
	Sin estado interno, sin referencias a game.

	AngleFromCoverNormal — ángulo con signo entre cámara y normal de pared
	GetShoulderSide     — convierte ese ángulo en "Left", "Right", o nil (deadzone)
]]

local AimAngleUtils = {}

--- Calcula el ángulo con signo (grados) entre la dirección de la cámara
--- y la normal de la superficie de cover, ambos proyectados en el plano XZ.
---
--- Convención: medido desde la dirección OPUESTA a la normal (la pared).
---   0°   → cámara mira directamente hacia la pared     (DEADZONE)
---   ±90° → cámara mira perpendicular a la pared        (lateral)
---   ~180° → cámara mira hacia afuera del cover          (dirección ideal de apuntado)
---
--- Positivo → lado derecho de la pared. Negativo → lado izquierdo.
---
--- @param cameraLookFlat Vector3  -LookVector de la cámara, aplanado a XZ y normalizado
--- @param coverNormal    Vector3 -Normal de la pared de cover (ya es XZ por diseño)
--- @return number — ángulo en grados, con signo
function AimAngleUtils.AngleFromCoverNormal(cameraLookFlat: Vector3, coverNormal: Vector3): number
	-- Invertir cámara: así 0° = mira hacia la pared (deadzone), ~180° = mira al frente correcto
	local lookX = -cameraLookFlat.X
	local lookZ = -cameraLookFlat.Z
	local dot = lookX * coverNormal.X + lookZ * coverNormal.Z
	local crossY = coverNormal.X * lookZ - coverNormal.Z * lookX
	return math.deg(math.atan2(crossY, dot))
end

--- Convierte un ángulo con signo en el lado de hombro correspondiente.
---
--- @param signedAngle   number — ángulo de AngleFromCoverNormal
--- @param deadzoneAngle number — medio-ángulo de la zona muerta (grados, positivo)
--- @return string? — "Right" si supera la deadzone por la derecha,
---                    "Left" si la supera por la izquierda,
---                    nil si está dentro de la zona muerta.
function AimAngleUtils.GetShoulderSide(signedAngle: number, deadzoneAngle: number): string?
	if signedAngle > deadzoneAngle then
		return "Right"
	elseif signedAngle < -deadzoneAngle then
		return "Left"
	end
	return nil
end

--- Verifica si la cámara está dentro del cono frontal del cover (mirando "hacia afuera").
---
--- Usa el producto punto entre cameraLook y la dirección outward (-coverNormal).
--- Convención directa: 0° = mirando hacia afuera = centro del cono frontal.
---
--- @param cameraLookFlat Vector3 — LookVector aplanado a XZ y normalizado
--- @param coverNormal    Vector3 — Normal de la pared (apunta hacia dentro de la pared)
--- @param halfAngle      number  — medio-ángulo del cono frontal (grados, positivo)
--- @return boolean — true si la cámara está dentro del cono frontal
function AimAngleUtils.IsInsideFrontCone(cameraLookFlat: Vector3, coverNormal: Vector3, halfAngle: number): boolean
	local outward = -coverNormal
	local dot = cameraLookFlat.X * outward.X + cameraLookFlat.Z * outward.Z
	return dot >= math.cos(math.rad(halfAngle))
end

return table.freeze(AimAngleUtils)
