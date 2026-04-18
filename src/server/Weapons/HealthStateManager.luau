--[[
	HealthStateManager.luau
	═══════════════════════════════════════════════════════════════
	Gestión de salud, DBNO y tipos de muerte en el servidor.
	═══════════════════════════════════════════════════════════════

	Responsabilidad ÚNICA:
	  Recibir el DamageReport del DamageHandler y aplicar el daño
	  determinando el resultado para cada víctima:

	  1. Restar daño a la salud actual
	  2. Si salud <= DBNO threshold y > 0 → iniciar DBNO
	  3. Si salud entre 0 y -OVERKILL_THRESHOLD → muerte estándar
	  4. Si salud < -OVERKILL_THRESHOLD → muerte por desmembramiento
	  5. Si el impacto letal fue headshot → muerte headshot

	El servidor ejecuta los cambios ESTRUCTURALES que deben replicar a
	todos los clientes (ragdoll, destrucción de attachments, kill).
	Las FUERZAS FÍSICAS (velocidades) se aplican en el CLIENTE del
	jugador que muere (DeathPhysicsHandler) — él ya es network owner
	de su propio personaje, así la simulación se distribuye entre
	todos los clientes en vez de sobrecargar al servidor.

	Atributos escritos:
	  LifeState           → "Alive" | "DBNO" | "Dead"
	  DeathType           → "Standard" | "Dismember" | "Headshot"
	  DeathHitDirection   → Vector3 (dirección normalizada de impacto)
	  DeathOverkillDamage → number (daño excedente sobre 0 HP)

	Comunica con CombatService via LifeState attribute.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local HealthStateManager = {}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local OVERKILL_THRESHOLD = Constants.OVERKILL_THRESHOLD or 10
local DISMEMBER_LIFETIME = Constants.DISMEMBER_LIFETIME or 8

-- Force constants (usados server-side solo para NPCs)
local HEADSHOT_FORCE_MULTIPLIER = Constants.HEADSHOT_FORCE_MULTIPLIER or 50
local DISMEMBER_FORCE_MULTIPLIER = Constants.DISMEMBER_FORCE_MULTIPLIER or 15
local BODY_FORCE_MULTIPLIER = Constants.BODY_FORCE_MULTIPLIER or 1.2
local MIN_BODY_FORCE = Constants.MIN_BODY_FORCE or 1
local MAX_FORCE = Constants.MAX_FORCE or 100

------------------------------------------------------------------------
-- PRIVATE: Physics Helpers (structural — must replicate from server)
------------------------------------------------------------------------

--- Encuentra el jugador más cercano a un character (fallback para NPCs sin killer)
local function _getNearestPlayer(character: Model): Player?
	local nearest = nil
	local minSquareDist = math.huge
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end

	local pos = hrp.Position
	for _, p in Players:GetPlayers() do
		if p.Character then
			local pHrp = p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if pHrp then
				local distSq = (pHrp.Position - pos).Magnitude
				if distSq < minSquareDist then
					minSquareDist = distSq
					nearest = p
				end
			end
		end
	end
	return nearest
end

--- Recolecta todas las AnimationConstraints del character.
local function _getAllConstraints(character: Model): { AnimationConstraint }
	local constraints = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("AnimationConstraint") then
			table.insert(constraints, descendant)
		end
	end
	return constraints
end

--- Elimina todos los Attachments de una BasePart.
local function _destroyAttachmentsOnPart(part: BasePart)
	for _, child in part:GetChildren() do
		if child:IsA("Attachment") then
			child:Destroy()
		end
	end
end

--- Ragdoll: IsKinematic = false en todos los AnimationConstraints.
--- Debe ser server-side para que replique a todos los clientes.
local function _enableRagdoll(character: Model)
	for _, constraint in _getAllConstraints(character) do
		constraint.IsKinematic = false
	end
end

------------------------------------------------------------------------
-- PRIVATE: Post-death physics — Player vs NPC
------------------------------------------------------------------------

--- Para JUGADORES: devuelve network ownership al cliente.
--- Cuando Humanoid.Health = 0, Roblox transfiere ownership al servidor
--- automáticamente. Devolvemos ownership al cliente para que
--- DeathPhysicsHandler aplique fuerzas (distribuye carga).
local function _giveOwnershipToPlayer(character: Model, player: Player)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			pcall(function()
				part:SetNetworkOwner(player)
			end)
		end
	end
end

--- Fuerza al HumanoidRootPart (NPC server-side).
local function _applyBodyForce(character: Model, hitDirection: Vector3, overkillDamage: number)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	local forceMagnitude = math.clamp(overkillDamage * BODY_FORCE_MULTIPLIER, MIN_BODY_FORCE, MAX_FORCE)
	hrp.AssemblyLinearVelocity = hitDirection * forceMagnitude
end

--- Aplica fuerzas server-side para NPCs (no tienen cliente que simule).
local function _applyNPCForces(character: Model, deathType: string, hitDirection: Vector3?, overkillDamage: number)
	if not hitDirection then
		return
	end

	if deathType == "Headshot" then
		local head = character:FindFirstChild("Head") :: BasePart?
		if head then
			local force = math.min(math.max(overkillDamage, 5) * HEADSHOT_FORCE_MULTIPLIER, MAX_FORCE)
			local upComponent = Vector3.new(0, 0.4, 0)
			head.AssemblyLinearVelocity = (hitDirection + upComponent).Unit * force
			head.AssemblyAngularVelocity =
				Vector3.new((math.random() - 0.5) * 20, (math.random() - 0.5) * 20, (math.random() - 0.5) * 20)
		end
		_applyBodyForce(character, hitDirection, overkillDamage)
	elseif deathType == "Dismember" then
		local force = math.min(math.max(overkillDamage, 5) * DISMEMBER_FORCE_MULTIPLIER, MAX_FORCE)
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				local randomSpread =
					Vector3.new(math.random() - 0.5, math.random() * 0.5 + 0.3, math.random() - 0.5).Unit
				local finalDir = (hitDirection * 0.7 + randomSpread * 0.3).Unit
				part.AssemblyLinearVelocity = finalDir * force
				part.AssemblyAngularVelocity = Vector3.new(
					(math.random() - 0.5) * force * 0.1,
					(math.random() - 0.5) * force * 0.1,
					(math.random() - 0.5) * force * 0.1
				)
			end
		end
	else
		-- Standard
		_applyBodyForce(character, hitDirection, overkillDamage)
	end
end

--- Decide si delegar física al cliente (Player) o aplicar server-side (NPC).
local function _handlePostDeathPhysics(
	character: Model,
	deathType: string,
	hitDirection: Vector3?,
	overkillDamage: number,
	killerName: string?
)
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		-- Jugador: devolver ownership a sí mismo
		character:SetAttribute("ClientPhysicsOwner", player.Name)
		_giveOwnershipToPlayer(character, player)
	else
		-- NPC: buscar killer o jugador más cercano
		local ownerPlayer = if killerName then Players:FindFirstChild(killerName) else nil
		if not ownerPlayer then
			ownerPlayer = _getNearestPlayer(character)
		end

		if ownerPlayer then
			-- Delegar simulación al killer o jugador más cercano
			character:SetAttribute("ClientPhysicsOwner", ownerPlayer.Name)
			_giveOwnershipToPlayer(character, ownerPlayer)
		else
			-- Fallback: no hay jugadores, o algo falló, simula el servidor (raro)
			_applyNPCForces(character, deathType, hitDirection, overkillDamage)
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Write death attributes (NO physics, NO kill)
------------------------------------------------------------------------

local function _writeDeathData(
	humanoid: Humanoid,
	character: Model,
	deathType: string,
	hitDirection: Vector3?,
	overkillDamage: number?,
	killerName: string?,
	weaponName: string?
)
	humanoid.BreakJointsOnDeath = (deathType == "Dismember")
	humanoid.RequiresNeck = false

	character:SetAttribute("DeathType", deathType)
	if hitDirection then
		character:SetAttribute("DeathHitDirection", hitDirection)
	end
	if overkillDamage then
		character:SetAttribute("DeathOverkillDamage", overkillDamage)
	end

	-- Killer info hooks (UI, sonido, kill feed)
	if killerName then
		character:SetAttribute("KillerName", killerName)
	end
	if weaponName then
		character:SetAttribute("KillerWeapon", weaponName)
	end

	-- LifeState = "Dead" → CombatService cancela bleedout
	character:SetAttribute("LifeState", "Dead")
end

------------------------------------------------------------------------
-- PRIVATE: Death types — ownership + kill + physics
------------------------------------------------------------------------

--- Standard: ragdoll (fuerzas las aplica el cliente via DeathPhysicsHandler)
local function _standardDeath(
	humanoid: Humanoid,
	character: Model,
	hitDirection: Vector3?,
	overkillDamage: number?,
	killerName: string?,
	weaponName: string?
)
	_writeDeathData(humanoid, character, "Standard", hitDirection, overkillDamage, killerName, weaponName)
	humanoid.Health = 0
	_enableRagdoll(character)
	_handlePostDeathPhysics(character, "Standard", hitDirection, overkillDamage or 0, killerName)
end

--- Headshot: ragdoll + eliminar attachments del Head (fuerzas las aplica el cliente)
local function _headshotDeath(
	humanoid: Humanoid,
	character: Model,
	hitDirection: Vector3,
	overkillDamage: number,
	killerName: string?,
	weaponName: string?
)
	_writeDeathData(humanoid, character, "Headshot", hitDirection, overkillDamage, killerName, weaponName)
	humanoid.Health = 0
	_enableRagdoll(character)

	local head = character:FindFirstChild("Head") :: BasePart?
	if head then
		-- Eliminar Attachments del Head → separa la cabeza (debe replicar)
		_destroyAttachmentsOnPart(head)
		head.CanCollide = true
		Debris:AddItem(head, DISMEMBER_LIFETIME)
	end

	_handlePostDeathPhysics(character, "Headshot", hitDirection, overkillDamage, killerName)
end

--- Dismember: eliminar todos los attachments + ragdoll (fuerzas las aplica el cliente o server para NPCs)
local function _dismemberDeath(
	humanoid: Humanoid,
	character: Model,
	overkillDamage: number,
	hitDirection: Vector3,
	killerName: string?,
	weaponName: string?
)
	_writeDeathData(humanoid, character, "Dismember", hitDirection, overkillDamage, killerName, weaponName)
	humanoid.Health = 0

	-- 1. Eliminar todos los Attachments → rompe todas las conexiones (debe replicar)
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			_destroyAttachmentsOnPart(part)
			part.CanCollide = true
		end
	end

	-- 2. IsKinematic = false en constraints restantes
	for _, constraint in _getAllConstraints(character) do
		constraint.IsKinematic = false
	end

	_handlePostDeathPhysics(character, "Dismember", hitDirection, overkillDamage, killerName)
	Debris:AddItem(character, DISMEMBER_LIFETIME)
end

------------------------------------------------------------------------
-- PRIVATE: DBNO
------------------------------------------------------------------------

--- Inicia el estado DBNO: clampea HP al threshold y marca LifeState.
--- El bleedout lo gestiona CombatService (ya existente) escuchando
--- el cambio de LifeState a "DBNO".
local function _enterDBNO(humanoid: Humanoid, character: Model, newHealth: number)
	character:SetAttribute("LifeState", "DBNO")
	-- Clampear a DBNO health (no dejar que baje de 1 en la transición)
	humanoid.Health = math.clamp(newHealth, 1, Constants.DBNO_HEALTH)
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Aplica el daño calculado a cada víctima, determinando el tipo de muerte.
---
--- Pipeline por víctima:
---   1. currentHP - totalDamage = newHP
---   2. if newHP > DBNO_HEALTH → solo restar (Alive)
---   3. if newHP > 0 and newHP <= DBNO_HEALTH → DBNO
---   4. if newHP <= 0:
---      a. overkill = |newHP|
---      b. if isHeadshot and lastHitZone == "Head" → headshot death
---      c. if overkill > OVERKILL_THRESHOLD → dismember death
---      d. else → standard death
---
--- @param damageReport DamageReport — resultado de DamageHandler.CalculateDamage
function HealthStateManager.ApplyDamage(damageReport: any, shooterName: string?, weaponName: string?)
	if Constants.DEBUG_MODE then
		print(damageReport)
	end

	for _, victim in damageReport.Victims do
		local humanoid: Humanoid = victim.Humanoid
		local character: Model = victim.Character

		-- Guard: humanoid/character may have been destroyed
		if not humanoid or not character or not humanoid.Parent or not character.Parent then
			continue
		end

		-- No dañar a jugadores ya muertos
		local lifeState = character:GetAttribute("LifeState")
		if lifeState == "Dead" then
			continue
		end

		local currentHP = humanoid.Health
		local newHP = currentHP - victim.TotalDamage

		if newHP > Constants.DBNO_HEALTH then
			-- Vivo: solo restar daño normalmente
			humanoid.Health = newHP
		elseif newHP > 0 then
			-- Transición a DBNO (si no estaba ya)
			if lifeState == "Alive" then
				_enterDBNO(humanoid, character, newHP)
			else
				-- Ya en DBNO: solo restar
				humanoid.Health = newHP
			end
		else
			-- Muerte: calcular overkill
			local overkillDamage = math.abs(newHP)

			-- Determinar tipo de muerte
			if victim.IsHeadshot and victim.LastHitZone == "Head" then
				-- Headshot death: cabeza sale volando
				_headshotDeath(humanoid, character, victim.HitDirection, overkillDamage, shooterName, weaponName)
			elseif overkillDamage > OVERKILL_THRESHOLD then
				-- Dismember death: parts salen volando
				_dismemberDeath(humanoid, character, overkillDamage, victim.HitDirection, shooterName, weaponName)
			else
				-- Standard death
				_standardDeath(humanoid, character, victim.HitDirection, overkillDamage, shooterName, weaponName)
			end
		end
	end
end

return table.freeze(HealthStateManager)
