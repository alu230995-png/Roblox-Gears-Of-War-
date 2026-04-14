--[[
	EffectsConstants.luau
	═══════════════════════════════════════════════════════════════
	Constantes de tuning para el sistema de efectos visuales.
	═══════════════════════════════════════════════════════════════

	Pool sizes, timing, budgets de partículas y mapeo de materiales.
]]

local EffectsConstants = {}

------------------------------------------------------------------------
-- POOL SIZES
------------------------------------------------------------------------

EffectsConstants.PARTICLE_POOL_SIZE = 20
EffectsConstants.TRAIL_POOL_SIZE = 12
EffectsConstants.MUZZLE_FLASH_POOL_SIZE = 4

------------------------------------------------------------------------
-- TIMING
------------------------------------------------------------------------

EffectsConstants.MUZZLE_FLASH_DURATION = 0.06
EffectsConstants.BULLET_TRAIL_LIFETIME = 0.3
EffectsConstants.IMPACT_DECAL_LIFETIME = 8.0
EffectsConstants.BLOOD_PARTICLE_LIFETIME = 1.5
EffectsConstants.EXPLOSION_PARTICLE_LIFETIME = 0.6
EffectsConstants.SHELL_CASING_LIFETIME = 3.0

------------------------------------------------------------------------
-- VISUAL SIZES
------------------------------------------------------------------------

EffectsConstants.IMPACT_DECAL_SIZE = 0.5
EffectsConstants.MUZZLE_FLASH_PART_SIZE = Vector3.new(0.1, 0.1, 0.1)
EffectsConstants.TRAIL_ANCHOR_SIZE = Vector3.new(0.1, 0.1, 0.1)

------------------------------------------------------------------------
-- PARTICLE BUDGETS — limites duros de partículas simultáneas
------------------------------------------------------------------------

EffectsConstants.MAX_ACTIVE_IMPACTS = 15
EffectsConstants.MAX_ACTIVE_TRAILS = 10
EffectsConstants.MAX_ACTIVE_BLOOD = 8
EffectsConstants.MAX_ACTIVE_EXPLOSIONS = 3

------------------------------------------------------------------------
-- MATERIAL → IMPACT TYPE
-- Mapea Enum.Material de Roblox al tipo de impacto en EffectsConfig.
------------------------------------------------------------------------

EffectsConstants.MATERIAL_TO_IMPACT_TYPE = {
	-- Metal
	[Enum.Material.Metal] = "Metal",
	[Enum.Material.CorrodedMetal] = "Metal",
	[Enum.Material.DiamondPlate] = "Metal",
	[Enum.Material.Glass] = "Metal",

	-- Concreto / Piedra
	[Enum.Material.Concrete] = "Concrete",
	[Enum.Material.Brick] = "Concrete",
	[Enum.Material.Cobblestone] = "Concrete",
	[Enum.Material.Slate] = "Concrete",
	[Enum.Material.Granite] = "Concrete",
	[Enum.Material.Marble] = "Concrete",
	[Enum.Material.Basalt] = "Concrete",
	[Enum.Material.Pavement] = "Concrete",
	[Enum.Material.Asphalt] = "Concrete",
	[Enum.Material.Rock] = "Concrete",
	[Enum.Material.Sandstone] = "Concrete",

	-- Madera
	[Enum.Material.Wood] = "Wood",
	[Enum.Material.WoodPlanks] = "Wood",

	-- Todo lo demás → Default
}

------------------------------------------------------------------------
-- PATH RESOLVER
-- Resuelve un string tipo "ReplicatedStorage.Particles.LancerMuzzle"
-- a la instancia correspondiente en el árbol de juego.
-- Retorna nil si algún segmento no existe.
------------------------------------------------------------------------

function EffectsConstants.ResolvePath(path: string): Instance?
	local segments = string.split(path, ".")
	if #segments == 0 then
		return nil
	end

	local root = game:GetService(segments[1])
	if not root then
		return nil
	end

	local current: Instance = root
	for i = 2, #segments do
		local child = current:FindFirstChild(segments[i])
		if not child then
			return nil
		end
		current = child
	end

	return current
end

------------------------------------------------------------------------
-- PATH NORMALIZER
-- Convierte Path (string | {string} | nil) en una tabla uniforme.
-- Retorna nil si Path es nil.
------------------------------------------------------------------------

function EffectsConstants.NormalizePaths(path: (string | { string })?): { string }?
	if path == nil then
		return nil
	end
	if type(path) == "string" then
		return { path }
	end
	return path :: { string }
end

------------------------------------------------------------------------
-- EMIT HELPER
-- Busca todos los ParticleEmitters en un clon y hace :Emit(n).
-- countOverride: si se pasa, usa ese valor para todos los emitters.
-- Si no, cada emitter usa su atributo "EmitCount" (o 1 si no tiene).
-- NO usa Enabled = true — solo burst instantáneo.
------------------------------------------------------------------------

-- countOverride: si se pasa, reemplaza el atributo EmitCount de cada emitter.
-- nil → cada emitter usa su propio atributo EmitCount (o 1 si no tiene).
function EffectsConstants.EmitAll(instance: Instance, countOverride: number?)
	for _, desc in instance:GetDescendants() do
		if desc:IsA("ParticleEmitter") then
			desc.Enabled = false
			local count = countOverride or desc:GetAttribute("EmitCount") or 1
			desc:Emit(count)
		end
	end
	-- También chequear si la instancia misma es un ParticleEmitter
	if instance:IsA("ParticleEmitter") then
		instance.Enabled = false
		local count = countOverride or instance:GetAttribute("EmitCount") or 1
		instance:Emit(count)
	end
end

------------------------------------------------------------------------
-- FREEZE
------------------------------------------------------------------------

table.freeze(EffectsConstants.MATERIAL_TO_IMPACT_TYPE)
table.freeze(EffectsConstants)

return EffectsConstants
