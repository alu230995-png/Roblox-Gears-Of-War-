--[[
	ServerRaycast.luau
	═══════════════════════════════════════════════════════════════
	Raycasting y matemáticas de trazado en el servidor.
	═══════════════════════════════════════════════════════════════

	Responsabilidad ÚNICA:
	  Re-raycast server-side de cada pellet para validar impactos
	  reportados por el cliente. No aplica daño ni muta salud.

	Retorna una tabla de resultados de raycast por pellet, incluyendo
	la información necesaria para que DamageHandler calcule el daño.
]]

local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local ServerRaycast = {}

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

export type PelletHit = {
	HitInstance: Instance,
	HitPosition: Vector3,
	HitNormal: Vector3,
	HitPartName: string,
	HitDistance: number,
	HitCharacter: Model?,
	HitHumanoid: Humanoid?,
}

export type ServerRaycastResult = {
	Hits: { PelletHit },
	Misses: number,
	Origin: Vector3,
}

------------------------------------------------------------------------
-- DEBUG visuals
------------------------------------------------------------------------

local DEBUG_ENABLED = Constants.DEBUG_MODE
local DEBUG_HIT_LIFETIME = 3
local DEBUG_HIT_SIZE = Vector3.new(0.4, 0.4, 0.4)

local function _createDebugHitPart(position: Vector3, hitCharacter: boolean)
	if not DEBUG_ENABLED then
		return
	end

	local part = Instance.new("Part")
	part.Name = "DebugHit"
	part.Shape = Enum.PartType.Ball
	part.Size = DEBUG_HIT_SIZE
	part.Position = position
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.BrickColor = if hitCharacter then BrickColor.new("Lime green") else BrickColor.new("Really red")
	part.Transparency = 0.3
	part.Parent = Workspace

	Debris:AddItem(part, DEBUG_HIT_LIFETIME)
end

local function _createDebugRayLine(origin: Vector3, endPos: Vector3, hitCharacter: boolean?)
	if not DEBUG_ENABLED then
		return
	end

	local mid = (origin + endPos) / 2
	local distance = (endPos - origin).Magnitude
	if distance < 0.01 then
		return
	end

	local part = Instance.new("Part")
	part.Name = "DebugRay"
	part.Size = Vector3.new(0.05, 0.05, distance)
	part.CFrame = CFrame.lookAt(mid, endPos)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Transparency = 0.4

	if hitCharacter == nil then
		part.BrickColor = BrickColor.new("New Yeller")
	elseif hitCharacter then
		part.BrickColor = BrickColor.new("Lime green")
	else
		part.BrickColor = BrickColor.new("Really red")
	end

	part.Parent = Workspace
	Debris:AddItem(part, DEBUG_HIT_LIFETIME)
end

------------------------------------------------------------------------
-- HIT ZONE RESOLUTION
------------------------------------------------------------------------
-- Resuelve el nombre de body part a partir de lo que el raycast impactó.
-- Prioridad:
--   1. Atributo "HitZone" en la instancia (hitbox custom de CharacterModifier)
--   2. Nombre de part R15/R6 directa (e.g. "Head", "UpperTorso")
--   3. Accessory Handle → busca body part weldeada
--   4. Fallback: nombre crudo de la instancia

local function _resolveBodyPartName(hitInstance: Instance): string
	-- 1. Hitbox custom: tiene atributo HitZone puesto por CharacterModifier
	local hitZoneAttr = hitInstance:GetAttribute("HitZone")
	if hitZoneAttr and typeof(hitZoneAttr) == "string" then
		return hitZoneAttr
	end

	-- 2. Accessory Handle: buscar la part del cuerpo a la que está weldeada
	local accessory = hitInstance:FindFirstAncestorOfClass("Accessory")
	if accessory then
		-- Los accesorios se unen al body via WeldConstraint o Weld
		for _, desc in accessory:GetDescendants() do
			if desc:IsA("Weld") or desc:IsA("WeldConstraint") then
				local part0 = (desc :: any).Part0
				local part1 = (desc :: any).Part1
				-- Una de las dos parts es el Handle, la otra es la body part
				if part0 and part0 ~= hitInstance and part0:IsA("BasePart") then
					local bodyZone = part0:GetAttribute("HitZone")
					if bodyZone then
						return bodyZone
					end
					return part0.Name
				end
				if part1 and part1 ~= hitInstance and part1:IsA("BasePart") then
					local bodyZone = part1:GetAttribute("HitZone")
					if bodyZone then
						return bodyZone
					end
					return part1.Name
				end
			end
		end
	end

	-- 3. Nombre directo (R15/R6 part sin hitbox)
	return hitInstance.Name
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Activa o desactiva los visuals de debug.
function ServerRaycast.SetDebugEnabled(enabled: boolean)
	DEBUG_ENABLED = enabled
end

--- Ejecuta re-raycasts server-side para cada pellet reportado por el cliente.
--- Usa SphereCast para buscar cabezas/partes del jugador como aim-assist.
--- Pipeline: SphereCast → buscar Head → buscar body parts → fallback raycast.
--- @param origin Vector3 — Muzzle.WorldPosition del servidor
--- @param hitPositions { [string]: Vector3 } — posiciones reportadas por el cliente
--- @param shooterChar Model — Character del tirador (excluido del raycast)
--- @param config any — WeaponConstants.WEAPONS[weaponName]
--- @return ServerRaycastResult
function ServerRaycast.CastPellets(
	origin: Vector3,
	hitPositions: { [string]: Vector3 },
	shooterChar: Model,
	config: any
): ServerRaycastResult
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { shooterChar }
	raycastParams.IgnoreWater = true

	local stats = config.Stats
	local sphereRadius = config.Mechanics.SphereCastRadius

	local hits: { PelletHit } = {}
	local misses = 0

	-- Anti-DDoS: límite máximo de pellets basado en SpreadPattern
	local maxPellets = #config.Ballistics.SpreadPattern
	local processedCount = 0

	for _pelletName, clientHitPos in hitPositions do
		processedCount += 1
		-- Segunda capa de defensa: limitar iteraciones
		if processedCount > maxPellets then
			break
		end

		if typeof(clientHitPos) ~= "Vector3" then
			continue
		end

		local direction = (clientHitPos - origin)
		local distance = direction.Magnitude

		-- Fuera de rango (con tolerancia del 20%)
		if distance > stats.Range * 1.2 then
			continue
		end

		local rayDir = direction.Unit * math.min(distance + Constants.SERVER_HIT_TOLERANCE, stats.Range)

		-- 1. SphereCast: buscar jugadores en el radio
		local sphereResult = Workspace:Spherecast(origin, sphereRadius, rayDir, raycastParams)

		local finalResult: RaycastResult? = nil

		if sphereResult and sphereResult.Instance then
			local hitChar = sphereResult.Instance:FindFirstAncestorOfClass("Model")
			local hitHumanoid: Humanoid? = if hitChar then hitChar:FindFirstChildOfClass("Humanoid") else nil

			if hitHumanoid and hitHumanoid.Health > 0 and hitChar ~= shooterChar then
				-- SphereCast encontró un jugador: verificar si impactó la Head directamente.
				-- Solo cuenta como headshot si el ray original pasa por la Head,
				-- NO se desvía el ray para buscar la cabeza artificialmente.
				local sphereHitPartName = _resolveBodyPartName(sphereResult.Instance)
				if sphereHitPartName == "Head" then
					-- El SphereCast impactó Head (o accesorio weldeado a Head):
					-- Confirmar con raycast fino hacia la posición exacta de impacto
					local head = hitChar:FindFirstChild("Head") :: BasePart?
					if head then
						local headDir = (head.Position - origin)
						local headResult =
							Workspace:Raycast(origin, headDir.Unit * (headDir.Magnitude + 2), raycastParams)
						if headResult and headResult.Instance then
							local headPartChar = headResult.Instance:FindFirstAncestorOfClass("Model")
							if headPartChar == hitChar then
								finalResult = headResult
							end
						end
					end
				end

				-- Si no fue headshot confirmado, usar el resultado del SphereCast (body part)
				if not finalResult then
					finalResult = sphereResult
				end
			end
		end

		-- 2. Fallback: raycast normal si SphereCast no encontró jugador
		if not finalResult then
			finalResult = Workspace:Raycast(origin, rayDir, raycastParams)
		end

		if finalResult and finalResult.Instance then
			local hitChar = finalResult.Instance:FindFirstAncestorOfClass("Model")
			local hitHumanoid: Humanoid? = nil
			if hitChar then
				hitHumanoid = hitChar:FindFirstChildOfClass("Humanoid")
			end

			local isCharHit = hitHumanoid ~= nil and hitHumanoid.Health > 0 and hitChar ~= shooterChar

			local resolvedPartName = _resolveBodyPartName(finalResult.Instance)

			table.insert(hits, {
				HitInstance = finalResult.Instance,
				HitPosition = finalResult.Position,
				HitNormal = finalResult.Normal,
				HitPartName = resolvedPartName,
				HitDistance = (finalResult.Position - origin).Magnitude,
				HitCharacter = if isCharHit then hitChar else nil,
				HitHumanoid = if isCharHit then hitHumanoid else nil,
			})

			_createDebugRayLine(origin, finalResult.Position, isCharHit)
			_createDebugHitPart(finalResult.Position, isCharHit)
		else
			misses += 1
			_createDebugRayLine(origin, origin + rayDir, nil)
		end
	end

	return {
		Hits = hits,
		Misses = misses,
		Origin = origin,
	}
end

return table.freeze(ServerRaycast)
