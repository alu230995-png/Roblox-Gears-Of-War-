--[[
	CharacterModifier.luau
	═══════════════════════════════════════════════════════════════
	Proporciones físicas y Hitboxes competitivas del personaje.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	  1. ApplyGearsProportions — escalar el avatar a proporciones GoW
	     (hombros anchos, pecho profundo, cabeza compacta)
	  2. DisableVisualQueries — CanQuery = false en toda la malla R15
	     y accesorios para que los raycasts de combate los ignoren
	  3. CreateHitboxes — Parts invisibles weldeados a las zonas vitales
	     con CanQuery = true y CollisionGroup = "CombatHitboxes"
	  4. SetupCharacter — orquesta los tres pasos en orden

	Arquitectura de Raycasts:
	  - La malla visual (R15 + accesorios) tiene CanQuery = false
	    → no intercepta raycasts de combate
	  - Las hitboxes tienen CanQuery = true y pertenecen al grupo
	    "CombatHitboxes" → único target de raycasts de arma
	  - El arma usará RaycastParams.CollisionGroup = "CombatHitboxes"
	    para filtrar solo hitboxes y geometría del mapa

	Llamar desde el servidor en CharacterAdded (via PhysicsConfig).
]]

local PhysicsService = game:GetService("PhysicsService")

------------------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------------------

--- Nombre del CollisionGroup para hitboxes de combate.
--- Crear en Studio: Model → Collision Groups → "CombatHitboxes"
--- O se crea automáticamente en EnsureCollisionGroup().
local HITBOX_GROUP_NAME = "CombatHitboxes"

--- Dimensiones de cada hitbox (tamaño en studs).
--- Las claves coinciden con los nombres de las partes R15.
--- Cubren las zonas vitales con geometría más limpia que la malla R15.
local HITBOX_DATA = {
	Head = Vector3.new(1.2, 1.2, 1.2),
	UpperTorso = Vector3.new(2.2, 1.5, 1.2),
	LowerTorso = Vector3.new(2.2, 1.0, 1.2),
	LeftUpperArm = Vector3.new(1, 1.5, 1),
	RightUpperArm = Vector3.new(1, 1.5, 1),
	LeftLowerArm = Vector3.new(0.8, 1.5, 0.8),
	RightLowerArm = Vector3.new(0.8, 1.5, 0.8),
	LeftUpperLeg = Vector3.new(1.1, 2, 1.1),
	RightUpperLeg = Vector3.new(1.1, 2, 1.1),
	LeftLowerLeg = Vector3.new(1, 2, 1),
	RightLowerLeg = Vector3.new(1, 2, 1),
}

--- Proporciones GoW: soldado con equipo pesado, hombros anchos.
local BODY_SCALES = {
	BodyWidthScale = 1.35, -- Espalda mucho más ancha
	BodyDepthScale = 1.25, -- Pecho más profundo
	BodyHeightScale = 1.05, -- Ligeramente más altos
	HeadScale = 0.95, -- Cabeza compacta (enfatiza el cuerpo masivo)
}

------------------------------------------------------------------------
-- MODULE
------------------------------------------------------------------------

local CharacterModifier = {}

------------------------------------------------------------------------
-- 0. Garantizar que el CollisionGroup exista (server-only, idempotente)
------------------------------------------------------------------------

local _groupCreated = false

function CharacterModifier.EnsureCollisionGroup()
	if _groupCreated then
		return
	end

	-- PhysicsService.RegisterCollisionGroup es idempotente en Roblox ≥2024
	local ok = pcall(function()
		PhysicsService:RegisterCollisionGroup(HITBOX_GROUP_NAME)
	end)

	if ok then
		-- Las hitboxes NO colisionan entre sí ni con el grupo Default.
		-- Solo sirven como target de CanQuery para raycasts de combate.
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable(HITBOX_GROUP_NAME, "Default", false)
			PhysicsService:CollisionGroupSetCollidable(HITBOX_GROUP_NAME, HITBOX_GROUP_NAME, false)
		end)
	end

	_groupCreated = true
end

------------------------------------------------------------------------
-- 1. Proporciones GoW
------------------------------------------------------------------------

--- Escala el avatar a proporciones de soldado GoW.
--- Modifica los NumberValue de escala dentro del Humanoid.
function CharacterModifier.ApplyGearsProportions(humanoid: Humanoid)
	for scaleName, value in BODY_SCALES do
		local scaleValue = humanoid:FindFirstChild(scaleName)
		if scaleValue and scaleValue:IsA("NumberValue") then
			scaleValue.Value = value
		end
	end
end

------------------------------------------------------------------------
-- 2. Desactivar CanQuery en malla visual
------------------------------------------------------------------------

--- Pone CanQuery = false en todas las BaseParts del character
--- (excepto HumanoidRootPart) y en todos los accesorios.
--- Esto hace que la malla R15 sea "transparente" a los raycasts de combate.
function CharacterModifier.DisableVisualQueries(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			descendant.CanQuery = false
		end
	end
end

------------------------------------------------------------------------
-- 3. Crear hitboxes
------------------------------------------------------------------------

--- Crea Parts invisibles weldeados a cada zona vital del personaje.
--- Cada hitbox:
---   - Massless = true (no afecta física)
---   - CanCollide = false (no choca con nada)
---   - CanQuery = true (detectable por raycasts)
---   - CanTouch = false (sin eventos Touch)
---   - CollisionGroup = "CombatHitboxes"
function CharacterModifier.CreateHitboxes(character: Model)
	CharacterModifier.EnsureCollisionGroup()

	for partName, size in HITBOX_DATA do
		local targetPart = character:FindFirstChild(partName) :: BasePart?
		if not targetPart then
			continue
		end

		local hitbox = Instance.new("Part")
		hitbox.Name = partName .. "_Hitbox"
		hitbox.Size = size
		hitbox.CFrame = targetPart.CFrame
		hitbox.Transparency = 0.8
		hitbox.Color = Color3.new(1, 0, 0) -- Rojo (visible solo si Transparency < 1 para debug)

		-- Propiedades físicas
		hitbox.Massless = true
		hitbox.CanCollide = false
		hitbox.CanQuery = true
		hitbox.CanTouch = false

		-- Grupo de colisión
		hitbox.CollisionGroup = HITBOX_GROUP_NAME

		-- Weld al hueso R15 correspondiente
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = hitbox
		weld.Part1 = targetPart
		weld.Parent = hitbox

		-- Atributo para identificar la zona en el hit detection
		hitbox:SetAttribute("HitZone", partName)

		hitbox.Parent = character
	end
end

------------------------------------------------------------------------
-- 4. Cleanup (para respawn — destruir hitboxes antiguas)
------------------------------------------------------------------------

function CharacterModifier.CleanupHitboxes(character: Model)
	for _, child in character:GetChildren() do
		if child:IsA("Part") and child.Name:match("_Hitbox$") then
			child:Destroy()
		end
	end
end

------------------------------------------------------------------------
-- MAIN: Setup completo del personaje
------------------------------------------------------------------------

--- Orquesta los tres pasos en orden.
--- Llamar desde el servidor en CharacterAdded.
function CharacterModifier.SetupCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid

	-- 1. Proporciones GoW (antes de hitboxes para que los tamaños sean correctos)
	CharacterModifier.ApplyGearsProportions(humanoid)

	-- 2. Desactivar raycasts en la malla visual
	CharacterModifier.DisableVisualQueries(character)

	-- 3. Crear hitboxes competitivas
	CharacterModifier.CreateHitboxes(character)
end

--- Devuelve el nombre del CollisionGroup para uso en RaycastParams.
function CharacterModifier.GetHitboxGroupName(): string
	return HITBOX_GROUP_NAME
end

return CharacterModifier
