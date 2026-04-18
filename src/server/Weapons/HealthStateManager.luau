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

	ULTRA-OPTIMIZACIÓN: Client-Sided Ragdolls
	═══════════════════════════════════════════════════════════════
	El servidor NO ejecuta NINGUNA física de muerte.
	  - No ragdoll (no IsKinematic)
	  - No fuerzas (no AssemblyLinearVelocity)
	  - No NetworkOwnership changes
	  - No destrucción de Attachments

	El servidor SOLO:
	  1. Mata al Humanoid (Health = 0)
	  2. Escribe atributos de muerte (LifeState, DeathType, etc.)
	  3. Congela el modelo original (Anchor HRP) para que no derive
	  4. Dispara RemoteEvent "DeathPhysicsRemote" a TODOS los clientes
	     con los datos matemáticos del impacto

	Cada CLIENTE recibe el evento y:
	  1. Clona el character localmente
	  2. Oculta el original (Transparency = 1, local-only)
	  3. Convierte el clon a ragdoll + aplica fuerzas
	  → Cada PC simula su propia versión del ragdoll

	Resultado: 0% CPU de física en el servidor, 0% ancho de banda
	de replicación de partes en movimiento. Solo un paquete ligero
	por muerte (~64 bytes).

	Atributos escritos:
	  LifeState           → "Alive" | "DBNO" | "Dead"
	  DeathType           → "Standard" | "Dismember" | "Headshot"
	  DeathHitDirection   → Vector3 (dirección normalizada de impacto)
	  DeathOverkillDamage → number (daño excedente sobre 0 HP)

	Comunica con CombatService via LifeState attribute.
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local HealthStateManager = {}

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local OVERKILL_THRESHOLD = Constants.OVERKILL_THRESHOLD or 10
local DISMEMBER_LIFETIME = Constants.DISMEMBER_LIFETIME or 8

------------------------------------------------------------------------
-- RemoteEvent: datos de muerte → todos los clientes
------------------------------------------------------------------------

local _deathPhysicsRemote = Instance.new("RemoteEvent")
_deathPhysicsRemote.Name = "DeathPhysicsRemote"
_deathPhysicsRemote.Parent = ReplicatedStorage

------------------------------------------------------------------------
-- PRIVATE: Freeze original — anchor HRP para evitar drift server-side
------------------------------------------------------------------------

local function _freezeOriginal(character: Model)
	-- Asegurar Archivable = true en TODA la jerarquía para que Clone() funcione en clientes
	character.Archivable = true
	for _, desc in character:GetDescendants() do
		if desc:IsA("Instance") then
			pcall(function()
				desc.Archivable = true
			end)
		end
	end

	-- Anclar TODAS las BaseParts y desactivar colisiones para congelar
	-- completamente el modelo. CanCollide = false evita que jugadores
	-- choquen con el cadáver invisible (el clon visual lo reemplaza).
	for _, part in character:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
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
	-- NUNCA romper joints en servidor — el clon client-side lo maneja
	humanoid.BreakJointsOnDeath = false
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
-- PRIVATE: Death types — kill + freeze + fire remote (ZERO physics)
------------------------------------------------------------------------

--- Standard: mata, congela original, envía datos a clientes
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
	_freezeOriginal(character)
	_deathPhysicsRemote:FireAllClients(character, "Standard", hitDirection, overkillDamage or 0)
end

--- Headshot: mata, congela original, envía datos a clientes
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
	_freezeOriginal(character)
	_deathPhysicsRemote:FireAllClients(character, "Headshot", hitDirection, overkillDamage)
end

--- Dismember: mata, congela original, envía datos a clientes, limpia original después
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
	_freezeOriginal(character)
	_deathPhysicsRemote:FireAllClients(character, "Dismember", hitDirection, overkillDamage)
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
