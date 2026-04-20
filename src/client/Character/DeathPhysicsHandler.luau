--[[
	DeathPhysicsHandler.luau
	═══════════════════════════════════════════════════════════════
	Client-Sided Ragdolls — ULTRA-OPTIMIZACIÓN
	═══════════════════════════════════════════════════════════════

	El servidor NO ejecuta ninguna física de muerte. Solo dispara
	un RemoteEvent ("DeathPhysicsRemote") con los datos matemáticos
	del impacto (tipo, dirección, daño excedente).

	CADA cliente recibe el evento y:
	  1. Clona el character original (que el servidor dejó congelado/anclado)
	  2. Oculta el original (Transparency = 1, cambio local-only)
	  3. Marca el clon con IsRagdollClone = true (evita re-detección)
	  4. Convierte el clon a ragdoll (IsKinematic = false)
	  5. Aplica cambios estructurales según tipo de muerte:
	     - Headshot → destruir attachments del Head
	     - Dismember → destruir TODOS los attachments
	  6. Aplica fuerzas (velocidades) sobre el clon
	  7. Auto-limpieza del clon con Debris

	Resultado:
	  - 0% CPU de física en el servidor
	  - 0% ancho de banda de replicación de partes en movimiento
	  - Cada PC simula su propio ragdoll (posiciones finales ligeramente
	    diferentes entre clientes — imperceptible en un shooter rápido)

	Atributos que lee del Character original (para DeathEffectsHandler):
	  DeathType, DeathHitDirection, DeathOverkillDamage, LifeState
	  Estos siguen funcionando porque el original permanece en Workspace.

	Datos recibidos por RemoteEvent:
	  character      → Model (referencia al original congelado)
	  deathType      → "Standard" | "Dismember" | "Headshot"
	  hitDirection   → Vector3? (dirección normalizada de impacto)
	  overkillDamage → number (daño excedente sobre 0 HP)
]]

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local DeathPhysicsHandler = {}
DeathPhysicsHandler.__index = DeathPhysicsHandler

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local HEADSHOT_FORCE_MULTIPLIER = Constants.HEADSHOT_FORCE_MULTIPLIER or 50
local DISMEMBER_FORCE_MULTIPLIER = Constants.DISMEMBER_FORCE_MULTIPLIER or 15
local BODY_FORCE_MULTIPLIER = Constants.BODY_FORCE_MULTIPLIER or 1.2
local MIN_BODY_FORCE = Constants.MIN_BODY_FORCE or 1
local MAX_FORCE = Constants.MAX_FORCE or 100
local DISMEMBER_LIFETIME = Constants.DISMEMBER_LIFETIME or 8

-- Tiempo (segundos) que el ragdoll tiene física activa antes de congelarse
local RAGDOLL_SETTLE_TIME = 1
-- Tiempo para dismember (más largo porque las piezas vuelan más lejos)
local DISMEMBER_SETTLE_TIME = 4

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function DeathPhysicsHandler.new(effectsController: any?)
	local self = setmetatable({}, DeathPhysicsHandler)
	self._connections = {} :: { RBXScriptConnection }
	self._effectsController = effectsController
	return self
end

------------------------------------------------------------------------
-- PRIVATE: Force application (sobre el clon local)
------------------------------------------------------------------------

--- Fuerza al HumanoidRootPart
local function _applyBodyForce(clone: Model, hitDirection: Vector3, overkillDamage: number)
	local hrp = clone:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end
	local forceMagnitude = math.clamp(overkillDamage * BODY_FORCE_MULTIPLIER, MIN_BODY_FORCE, MAX_FORCE)
	hrp.AssemblyLinearVelocity = hitDirection * forceMagnitude
end

--- Standard: fuerza al cuerpo
local function _applyStandardForces(clone: Model, hitDirection: Vector3?, overkillDamage: number)
	if hitDirection then
		_applyBodyForce(clone, hitDirection, overkillDamage)
	end
end

--- Headshot: fuerza a la cabeza + fuerza al cuerpo
local function _applyHeadshotForces(clone: Model, hitDirection: Vector3, overkillDamage: number)
	local head = clone:FindFirstChild("Head") :: BasePart?
	if head then
		local force = math.min(math.max(overkillDamage, 5) * HEADSHOT_FORCE_MULTIPLIER, MAX_FORCE)
		local upComponent = Vector3.new(0, 0.4, 0)
		head.AssemblyLinearVelocity = (hitDirection + upComponent).Unit * force
		head.AssemblyAngularVelocity =
			Vector3.new((math.random() - 0.5) * 20, (math.random() - 0.5) * 20, (math.random() - 0.5) * 20)
	end
	_applyBodyForce(clone, hitDirection, overkillDamage)
end

--- Dismember: fuerza con spread a cada part
local function _applyDismemberForces(clone: Model, hitDirection: Vector3, overkillDamage: number)
	local force = math.min(math.max(overkillDamage, 5) * DISMEMBER_FORCE_MULTIPLIER, MAX_FORCE)

	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			local randomSpread = Vector3.new(math.random() - 0.5, math.random() * 0.5 + 0.3, math.random() - 0.5).Unit
			local finalDir = (hitDirection * 0.7 + randomSpread * 0.3).Unit

			part.AssemblyLinearVelocity = finalDir * force
			part.AssemblyAngularVelocity = Vector3.new(
				(math.random() - 0.5) * force * 0.1,
				(math.random() - 0.5) * force * 0.1,
				(math.random() - 0.5) * force * 0.1
			)
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Structural ragdoll setup (sobre el clon local)
------------------------------------------------------------------------

--- Ragdoll: IsKinematic = false en todos los AnimationConstraints del clon
local function _enableRagdoll(clone: Model)
	for _, descendant in clone:GetDescendants() do
		if descendant:IsA("AnimationConstraint") then
			descendant.IsKinematic = false
		end
	end
end

--- Destruye todos los Attachments de una BasePart
local function _destroyAttachmentsOnPart(part: BasePart)
	for _, child in part:GetChildren() do
		if child:IsA("Attachment") then
			child:Destroy()
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Hide original character (local-only, no replica)
------------------------------------------------------------------------

local function _hideOriginal(character: Model)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = 1
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE: Force CanCollide every frame (Stepped runs BEFORE physics)
------------------------------------------------------------------------

--- Conecta un listener a Stepped que fuerza CanCollide = true en todas
--- las BaseParts del clon ANTES de cada paso de física.
--- El Humanoid internamente setea CanCollide = false en extremidades;
--- este override gana porque Stepped corre después del Humanoid state update
--- pero antes de la simulación de física.
--- Retorna la RBXScriptConnection para desconectar al settle.
local function _forceCollision(clone: Model): RBXScriptConnection
	-- Cache de las parts para evitar GetDescendants cada frame
	local parts: { BasePart } = {}
	for _, desc in clone:GetDescendants() do
		if desc:IsA("BasePart") then
			table.insert(parts, desc)
		end
	end

	return RunService.Stepped:Connect(function()
		for _, part in parts do
			if part.Parent then
				part.CanCollide = true
			end
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Settle — congela el ragdoll tras N segundos para que no tiemble
------------------------------------------------------------------------

local function _settleClone(clone: Model, delay: number, collisionConn: RBXScriptConnection?)
	task.delay(delay, function()
		-- Desconectar el override de CanCollide — ya no hace falta, las parts se anclan
		if collisionConn then
			collisionConn:Disconnect()
		end

		if not clone or not clone.Parent then
			return
		end
		for _, part in clone:GetDescendants() do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
				part.AssemblyLinearVelocity = Vector3.zero
				part.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Create local ragdoll clone
------------------------------------------------------------------------

function DeathPhysicsHandler:_processDeathLocally(
	character: Model,
	deathType: string,
	hitDirection: Vector3?,
	overkillDamage: number
)
	-- Guard: character may have been destroyed between server fire and client receive
	-- Roblox can deliver a "dead" Instance ref that isn't nil but has no properties
	if not character or not character.Parent then
		return
	end

	-- Asegurar Archivable localmente (puede no haber replicado aún desde el server)
	pcall(function()
		character.Archivable = true
	end)

	local ok, clone = pcall(function()
		return character:Clone()
	end)
	if not ok or not clone then
		warn("[DeathPhysicsHandler] Clone failed for", character.Name, ":", tostring(clone))
		return
	end
	clone.Name = character.Name .. "_Ragdoll"
	clone:SetAttribute("IsRagdollClone", true)

	-- 2. Hide original (local-only change — other clients hide independently)
	_hideOriginal(character)

	-- 3. Un-anchor ALL BaseParts of the clone (el servidor ahora ancló el original)
	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end

	-- 4. Neutralize clone's Humanoid (conservar vivo para texturas/ropa)
	local humanoid = clone:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		humanoid.BreakJointsOnDeath = false
		humanoid.RequiresNeck = false
		humanoid.PlatformStand = true
		humanoid.Health = 1
	end

	-- 5. Enable ragdoll on clone
	_enableRagdoll(clone)

	-- 6. Apply structural changes + forces based on death type
	if deathType == "Headshot" and hitDirection then
		local head = clone:FindFirstChild("Head") :: BasePart?
		if head then
			_destroyAttachmentsOnPart(head)
		end
		_applyHeadshotForces(clone, hitDirection, overkillDamage)
	elseif deathType == "Dismember" and hitDirection then
		for _, part in clone:GetDescendants() do
			if part:IsA("BasePart") then
				_destroyAttachmentsOnPart(part)
			end
		end
		_applyDismemberForces(clone, hitDirection, overkillDamage)
	else
		_applyStandardForces(clone, hitDirection, overkillDamage)
	end

	-- 6b. Pase inicial CanCollide = true
	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = true
		end
	end

	-- 6c. Conectar override per-frame en Stepped (corre ANTES de physics).
	-- El Humanoid fuerza CanCollide = false en extremidades cada frame;
	-- este listener lo revierte justo antes de la simulación.
	local collisionConn = _forceCollision(clone)

	-- 7. Parent to workspace (starts local physics simulation)
	clone.Parent = workspace

	-- 7b. Blood particles sobre el clon (sincronizado — el original se moverá al subsuelo)
	if self._effectsController then
		self._effectsController:OnDeathBlood(clone, deathType, hitDirection, overkillDamage)
	end

	-- 8. Settle: congelar el ragdoll tras unos segundos para evitar temblores
	local settleTime = if deathType == "Dismember" then DISMEMBER_SETTLE_TIME else RAGDOLL_SETTLE_TIME
	_settleClone(clone, settleTime, collisionConn)

	-- 9. Auto-cleanup
	Debris:AddItem(clone, DISMEMBER_LIFETIME)
end

------------------------------------------------------------------------
-- PUBLIC API (Lifecycle)
------------------------------------------------------------------------

function DeathPhysicsHandler:Init()
	-- No side-effects
end

function DeathPhysicsHandler:Start()
	local deathPhysicsRemote = ReplicatedStorage:WaitForChild("DeathPhysicsRemote")

	table.insert(
		self._connections,
		deathPhysicsRemote.OnClientEvent:Connect(function(character, deathType, hitDirection, overkillDamage)
		self:_processDeathLocally(character, deathType, hitDirection, overkillDamage)
		end)
	)
end

function DeathPhysicsHandler:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
end

return DeathPhysicsHandler
