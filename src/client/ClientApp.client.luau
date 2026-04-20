--[[
	ClientApp.client.luau
	═══════════════════════════════════════════════════════════════
	ENTRY POINT DEL CLIENTE — Solo bootstrapping
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades:
	  1. Crear instancias de todos los sistemas
	  2. Registrar en ServiceLocator
	  3. Fase Init(): sin side-effects, sin conexiones
	  4. Fase Start(): conectar signals, arrancar conexiones
	  5. Heartbeat: game loop central (temporal — se moverá a CharacterController)
	
	Este archivo NO contiene lógica de gameplay. Solo bootstrapping.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

------------------------------------------------------------------------
-- SHARED MODULES
------------------------------------------------------------------------
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local StateMachine = require(Shared:WaitForChild("Utils"):WaitForChild("StateMachine"))
local PlayerState = require(Shared:WaitForChild("Enums"):WaitForChild("PlayerState"))

------------------------------------------------------------------------
-- CLIENT MODULES
------------------------------------------------------------------------
-- Core
local ServiceLocator = require(script.Parent.Core.ServiceLocator)

-- Input (Capas 1-3 — ya cumplen SRP)
local InputDetector = require(script.Parent.Input.InputDetector)
local IntentMapper = require(script.Parent.Input.IntentMapper)
local InputBuffer = require(script.Parent.Input.InputBuffer)
local MouseInput = require(script.Parent.Input.MouseInput)

-- World
local EnvironmentSensor = require(script.Parent.World.EnvironmentSensor)

-- Gameplay (Capa 5)
local ActionResolver = require(script.Parent.Gameplay.ActionResolver)

-- Movement (refactored — Character/Movement/ con sub-handlers)
local MovementController = require(script.Parent.Character.Movement.MovementController)

-- Animation (Fase 4 — skeleton funcional)
local AnimationController = require(script.Parent.Animation.AnimationController)

-- Camera (Fase 5 — skeleton funcional)
local CameraController = require(script.Parent.Camera.CameraController)

-- Aiming (Fase 1B/1C — shoulder, FOV zoom, deadzone)
local AimingController = require(script.Parent.Gameplay.Aiming.AimingController)

-- Sound System
local SoundController = require(script.Parent.Sound.SoundController)

-- Health (observa LifeState del server → transiciones de StateMachine)
local HealthObserver = require(script.Parent.Character.HealthObserver)

-- Death Effects (ragdoll, dismember, headshot — client-side visuals)
local DeathEffectsHandler = require(script.Parent.Character.DeathEffectsHandler)

-- Death Physics (forces applied client-side to avoid server overload)
local DeathPhysicsHandler = require(script.Parent.Character.DeathPhysicsHandler)

-- Death Sequence (blood effect → spectator transition → respawn hooks)
local DeathSequenceHandler = require(script.Parent.Character.DeathSequenceHandler)

-- DBNO Handler (countdown UI hooks, self-revive input)
local DBNOHandler = require(script.Parent.Character.DBNOHandler)

-- Spectator (camera cycling over other players during death)
local SpectatorController = require(script.Parent.Spectator.SpectatorController)

-- Effects System (VFX: muzzle flash, trails, impacts, blood, explosions)
local EffectsController = require(script.Parent.Effects.EffectsController)

-- Weapons (shooting, reload, scope)
local WeaponClient = require(script.Parent.Weapons.WeaponClient)

-- Presentation (UI/visual — Layer 5)
local ScopeRenderer = require(script.Parent.Presentation.ScopeRenderer)

-- Mobile Touch HUD (botones táctiles para móvil)
local MobileTouchHUD = require(script.Parent.UI.MobileTouchHUD)

-- Weapon HUD (munición + active reload — estilo GOW profesional)
local WeaponHUD = require(script.Parent.UI.WeaponHUD)

------------------------------------------------------------------------
-- BOOTSTRAP
------------------------------------------------------------------------
local locator = ServiceLocator.new()

-- Crear instancias (orden importa: dependencias primero)
local stateMachine = StateMachine.new("Idle", PlayerState.Transitions)

-- Registrar grupos HSM (orden: padres antes de hijos)
for groupName, groupConfig in PlayerState.Groups do
	stateMachine:RegisterGroup(groupName, {
		Parent = groupConfig.Parent,
		States = groupConfig.States,
	})
end
stateMachine:BuildGroupHierarchy()

local inputDetector = InputDetector.new()
local mouseInput = MouseInput.new()
local envSensor = EnvironmentSensor.new()
local intentMapper = IntentMapper.new(inputDetector)
local inputBuffer = InputBuffer.new()
local actionResolver = ActionResolver.new(stateMachine, inputBuffer, intentMapper, envSensor)
local movementController = MovementController.new(stateMachine, actionResolver, envSensor)
local animationController = AnimationController.new(stateMachine, movementController.ActionExecuted)
local cameraController = CameraController.new(stateMachine, movementController.ActionExecuted, mouseInput)

-- Conectar señales del Cover system a CameraController (Capa 4 → Capa 5 via signals)
local coverHandler = movementController:GetCoverHandler()
coverHandler.CoverSettleChanged:Connect(function(active)
	cameraController:SetCoverSettleActive(active)
end)
coverHandler.ShoulderSideChanged:Connect(function(side)
	cameraController:SetShoulderSide(side)
end)
coverHandler.InnerCornerTransition:Connect(function(newNormal)
	cameraController:NotifyInnerCornerTransition(newNormal)
end)

-- AimingController: cerebro del sistema de apuntado (Fase 1B/1C)
local aimingController = AimingController.new(stateMachine, coverHandler, cameraController)
movementController.ActionExecuted:Connect(function(action, targetState, data)
	aimingController:HandleAction(action, targetState, data)
end)

-- DI: RotationHandler necesita leer GetRotationOverride() para Low Cover aim
movementController:SetAimingController(aimingController)

local soundController = SoundController.new(stateMachine)
local healthObserver = HealthObserver.new(stateMachine)
local effectsController = EffectsController.new(stateMachine)
local deathEffectsHandler = DeathEffectsHandler.new(effectsController)
local deathPhysicsHandler = DeathPhysicsHandler.new(effectsController)
local deathSequenceHandler = DeathSequenceHandler.new(stateMachine, effectsController)
local spectatorController = SpectatorController.new(stateMachine)
local dbnoHandler = DBNOHandler.new(stateMachine, movementController.ActionExecuted)
local mobileTouchHUD = MobileTouchHUD.new(inputDetector, stateMachine, spectatorController)
local weaponHUD = WeaponHUD.new()

------------------------------------------------------------------------
-- WEAPON SYSTEM — Per-Tool management (scan directo, sin WeaponToolManager)
------------------------------------------------------------------------
local player = game:GetService("Players").LocalPlayer
local weaponClients = {} :: { [Tool]: any }

local function setupWeaponTool(tool: Tool)
	if weaponClients[tool] then
		return
	end
	local wc = WeaponClient.new(player, tool)
	wc:Init(stateMachine, movementController.ActionExecuted, ScopeRenderer)
	wc:Start()
	weaponClients[tool] = wc

	wc:SetSoundController(soundController)

	-- Bind effects system to this weapon
	effectsController:BindWeaponClient(wc)

	-- WeaponHUD: bind arma actual al HUD profesional
	weaponHUD:BindWeapon(wc)
	wc.WeaponEquipped:Connect(function()
		weaponHUD:BindWeapon(wc)
	end)

	-- Camera shake: solo tras disparo real validado por WeaponClient
	wc.ShotFired:Connect(function()
		cameraController:FireImpulseShake(math.rad(1.2), math.rad(0.4))
	end)

	tool.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then
			task.defer(function()
				local entry = weaponClients[tool]
				if entry then
					weaponClients[tool] = nil
					effectsController:UnbindWeaponClient(entry)
					entry:Destroy()
				end
			end)
		end
	end)
end

local function scanForTools(container: Instance)
	for _, child in container:GetChildren() do
		if child:IsA("Tool") then
			setupWeaponTool(child :: Tool)
		end
	end
	container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			setupWeaponTool(child :: Tool)
		end
	end)
end

-- Registrar en ServiceLocator (orden de registro = orden de Init/Start)
locator:Register("StateMachine", stateMachine)
locator:Register("InputDetector", inputDetector)
locator:Register("MouseInput", mouseInput)
locator:Register("EnvironmentSensor", envSensor)
locator:Register("IntentMapper", intentMapper)
locator:Register("InputBuffer", inputBuffer)
locator:Register("ActionResolver", actionResolver)
locator:Register("MovementController", movementController)
locator:Register("AnimationController", animationController)
locator:Register("CameraController", cameraController)
locator:Register("AimingController", aimingController)
locator:Register("SoundController", soundController)
locator:Register("HealthObserver", healthObserver)
locator:Register("EffectsController", effectsController)
locator:Register("DeathEffectsHandler", deathEffectsHandler)
locator:Register("DeathPhysicsHandler", deathPhysicsHandler)
locator:Register("DeathSequenceHandler", deathSequenceHandler)
locator:Register("SpectatorController", spectatorController)
locator:Register("DBNOHandler", dbnoHandler)
locator:Register("MobileTouchHUD", mobileTouchHUD)
locator:Register("WeaponHUD", weaponHUD)

-- FASE 1: Init (sin side-effects, sin conexiones)
locator:InitAll()

-- FASE 2: Start (conecta signals, arranca conexiones)
-- Después de Start:
--   InputDetector escucha UIS events (su propio Heartbeat interno)
--   MovementController escucha ActionResolver.ActionResolved via Signal
--   AnimationController escucha StateChanged + ActionExecuted
--   CameraController escucha StateChanged + ActionExecuted
locator:StartAll()

-- Scan weapons AFTER StartAll so WeaponHUD:Start() has built the UI before BindWeapon is called
local backpack = player:WaitForChild("Backpack")
scanForTools(backpack)
if player.Character then
	scanForTools(player.Character)
end
player.CharacterAdded:Connect(function(character)
	scanForTools(character)
end)

-- Post-Start DI: EffectsController necesita referencias a Camera y Sound
effectsController:SetCameraController(cameraController)
effectsController:SetSoundController(soundController)

------------------------------------------------------------------------
-- RESPAWN CLEANUP — Limpiar estado residual de la vida anterior
------------------------------------------------------------------------
healthObserver.Respawned:Connect(function()
	inputBuffer:Clear()
	inputDetector:ResetUIHeldState()
end)

------------------------------------------------------------------------
-- COVER STATE → SERVER (para tasa de regen en CombatService)
------------------------------------------------------------------------
do
	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
	local coverRemote = remotesFolder and remotesFolder:WaitForChild("CoverStateChanged", 10) :: RemoteEvent?
	if coverRemote then
		local wasInCover = false
		stateMachine.StateChanged:Connect(function(_newState: string, _oldState: string)
			local inCover = stateMachine:IsInGroup("CoverGroup")
			if inCover ~= wasInCover then
				wasInCover = inCover
				coverRemote:FireServer(inCover)
			end
		end)
	end
end

------------------------------------------------------------------------
-- HEARTBEAT — Game Loop central
------------------------------------------------------------------------
-- NOTA ARQUITECTURA: Este heartbeat es TEMPORAL. En el refactor de
-- Fase 3 (CharacterController), el loop se moverá allí.
-- ClientApp solo hará bootstrap. Por ahora permanece aquí como
-- orquestador del pipeline de input (ARQREG 06: un solo Heartbeat).

RunService.Heartbeat:Connect(function(dt: number)
	-- Paso 1: IntentMapper traduce eventos + polling → intenciones
	intentMapper:Update()

	-- Paso 2: InputBuffer almacena intents discretos y limpia expirados
	inputBuffer:PushFromIntents(intentMapper:GetActiveIntents())
	inputBuffer:CleanExpired()

	-- Paso 3: EnvironmentSensor escanea el entorno (state-driven)
	-- Solo hace raycasts cuando el estado lo requiere
	local currentState = stateMachine:GetCurrentState()
	local coverNormal = movementController:GetCoverHandler():GetNormal()
	local wantsCoverSearch = inputBuffer:HasIntent("WantsCover")
	local moveDir = inputDetector:GetMoveDirection()
	envSensor:Update(currentState, coverNormal, wantsCoverSearch, moveDir)

	-- Paso 4: ActionResolver evalúa intents + estado + env
	-- Dispara ActionResolved Signal → MovementController reacciona automáticamente
	actionResolver:Resolve()

	-- Paso 5: Update continuo (timers, cover snap, rotación, evade decay)
	movementController:Update(dt)

	-- Paso 5a: AimingController — lee cover state fresco, aplica shoulder/FOV antes de cámara
	aimingController:Update(dt)

	-- Paso 5b: MouseInput lee delta ANTES de la cámara
	mouseInput:Update()

	-- Paso 5c: SpectatorController — smooth follow del target (antes de cámara normal)
	spectatorController:Update(dt)

	-- Paso 5d: Cámara DESPUÉS de movement — garantiza que lea el HRP post-corrección
	-- (wall-glue, smooth rotation) sin jitter de 1-frame lag.
	cameraController:Update(dt)

	-- Paso 6: StateMachine update (callbacks OnUpdate de estados)
	stateMachine:Update(dt)
end)

------------------------------------------------------------------------
-- STARTUP LOG
------------------------------------------------------------------------
if Constants.DEBUG_MODE then
	print(
		"[GoW Client] ═══════════════════════════════════════"
	)
	print("[GoW Client] Gears of War — Sistema iniciado")
	print(`[GoW Client] Estado inicial: {stateMachine:GetCurrentState()}`)
	print(`[GoW Client] Gravity: {workspace.Gravity}`)
	print("[GoW Client] Arquitectura: ServiceLocator + Signal-driven")
	print("[GoW Client] Capas: Detector → Mapper → Buffer → Resolver → [Signal] → Controller")
	print("[GoW Client] Sound System: SoundController + SoundPlayer")
	print(
		"[GoW Client] ═══════════════════════════════════════"
	)
end
