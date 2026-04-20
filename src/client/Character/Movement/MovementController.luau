--[[
	MovementController.luau (Coordinator)
	═══════════════════════════════════════════════════════════════
	Ejecutor de Acciones Resueltas — Coordinator delgado
	═══════════════════════════════════════════════════════════════
	
	Recibe la acción resuelta por ActionResolver y la delega al
	sub-handler correspondiente (CoverMain, EvadeHandler).
	Gestiona:
	  - Delegación de acciones a sub-handlers
	  - RoadieRun velocity (AssemblyLinearVelocity directa)
	  - WalkSpeed por estado (via SpeedMap)
	  - Orquestación de Updates de sub-handlers
	
	NOTA: Esto es predicción del cliente. Las acciones que afectan
	gameplay (daño, inventario, HP) se validan en el servidor.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Signal = require(Shared:WaitForChild("Signal"))

-- Sub-handlers (siblings en el mismo folder Movement/)
local CoverMain = require(script.Parent.Cover)
local EvadeHandler = require(script.Parent.EvadeHandler)
local RotationHandler = require(script.Parent.RotationHandler)
local SpeedMap = require(script.Parent.SpeedMap)
local VaultHandler = require(script.Parent.VaultHandler)

local MovementController = {}
MovementController.__index = MovementController

function MovementController.new(
	stateMachine,
	actionResolver,
	environmentSensor
)
	local self = setmetatable({}, MovementController)

	self._stateMachine = stateMachine
	self._actionResolver = actionResolver
	self._envSensor = environmentSensor
	self._player = Players.LocalPlayer

	-- Sub-handlers
	self._coverHandler = CoverMain.new(stateMachine, environmentSensor)
	self._evadeHandler = EvadeHandler.new(stateMachine, self._coverHandler)
	self._vaultHandler = VaultHandler.new(stateMachine, self._coverHandler, environmentSensor)
	self._rotationHandler = RotationHandler.new()

	-- Cache de character refs (evita FindFirstChild cada frame)
	self._cachedCharacter = nil :: Model?
	self._cachedHumanoid = nil :: Humanoid?
	self._cachedHRP = nil :: BasePart?

	-- Vault pendiente desde CoverEntering (F key deferred):
	-- Se guarda al pulsar F durante entering, se ejecuta al completar el snap.
	self._pendingVaultFromEntering = nil :: { coverNormal: Vector3, coverInstance: BasePart }?

	-- Cover chain flag: se activa cuando ActionResolver resuelve "CoverChain"
	self._wantsCoverRedirect = false

	-- Conexiones gestionadas (cleanup en Destroy)
	self._connections = {}

	-- Signal de salida: Presentation (Animation, Camera) escucha acciones ejecutadas.
	-- Firma: (action: string, targetState: string?, data: any?)
	self.ActionExecuted = Signal.new()

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

--- Conecta al Signal ActionResolved del ActionResolver.
--- MovementController reacciona a acciones resueltas sin acoplamiento directo.
function MovementController:Start()
	-- RotationHandler gestiona AutoRotate del Humanoid
	self._rotationHandler:Start()

	self._connections.actionResolved = self._actionResolver.ActionResolved:Connect(function(action, targetState, data)
		self:ExecuteAction(action, targetState, data)
	end)

	-- Sincronizar WalkSpeed cuando WeaponClient (u otro sistema) transiciona el estado
	-- sin pasar por ExecuteAction (e.g. Reload, Firing, ActiveReloading).
	self._connections.stateChanged = self._stateMachine.StateChanged:Connect(function(_newState, _oldState)
		self:_applyMovementSpeed()
	end)
end

function MovementController:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)

	-- Propagar Destroy a sub-handlers
	if self._coverHandler and self._coverHandler.Destroy then
		self._coverHandler:Destroy()
	end
	if self._rotationHandler and self._rotationHandler.Destroy then
		self._rotationHandler:Destroy()
	end

	if self.ActionExecuted then
		self.ActionExecuted:Destroy()
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Ejecuta una acción resuelta por ActionResolver.
--- @param action string — nombre de la acción
--- @param targetState string? — estado destino (o nil si no hay transición)
--- @param data any? — datos adicionales
function MovementController:ExecuteAction(action: string, targetState: string?, data: any?)
	if action == "NoAction" then
		return
	end

	-- Acciones diferidas (sin transición de estado): solo guardar para Update()
	if action == "VaultFromEntering" then
		if not self._pendingVaultFromEntering and data then
			self._pendingVaultFromEntering = data
		end
		return
	end
	if action == "CoverChain" then
		self._wantsCoverRedirect = true
		return
	end

	-- Transicionar si hay target state
	if targetState then
		local currentState = self._stateMachine:GetCurrentState()
		local success = self._stateMachine:TransitionTo(targetState)
		if not success then
			-- ForceState para estados críticos (server-authoritative)
			if targetState == "DBNO" then
				self._stateMachine:ForceState(targetState)
			else
				if Constants.DEBUG_MODE and (action == "ReturnToCover" or action == "PopUpAim" or action == "ReturnToAim") then
					print(`[AimDebug] MovementController: TransitionTo({targetState}) FAILED from {currentState} — aborting {action}`)
				end
				return -- No se pudo transicionar, abortar acción
			end
		else
			if Constants.DEBUG_MODE and (action == "ReturnToCover" or action == "PopUpAim" or action == "ReturnToAim") then
				print(`[AimDebug] MovementController: TransitionTo({targetState}) SUCCESS from {currentState} — executing {action}`)
			end
		end
	end

	-- RoadieRun: cachear dirección para RotationHandler (dirección viene de ActionResolver)
	if action == "StartRoadieRun" or action == "CancelSwapToRun" then
		local direction = data and data.direction or nil
		self._rotationHandler:SetRoadieRunDirection(direction)
	end

	-- Intentar delegar a sub-handlers (cover → vault → evade → fallback)
	if not self._coverHandler:HandleAction(action, data) then
		if not self._vaultHandler:HandleAction(action, data) then
			if not self._evadeHandler:HandleAction(action, data) then
				-- Acciones que no requieren handler especializado
				-- (StartWalking, StopWalking, StartRoadieRun, StopRoadieRun,
				--  StartAim, StopAim, Shoot, StopShoot, Reload, ActiveReload,
				--  Melee, Chainsaw, Interact, SwapWeapon, Crawl)
				-- Velocidad se aplica automáticamente abajo por estado.
			end
		end
	end

	-- Aplicar velocidad al Humanoid según el nuevo estado
	self:_applyMovementSpeed()

	-- Notificar a Presentation (Animation, Camera)
	self.ActionExecuted:Fire(action, targetState, data)
end

--- Update cada frame. Maneja timers y lógica continua.
function MovementController:Update(dt: number)
	-- Cover redirect: activado por ActionResolver via "CoverChain" action
	local wantsCoverRedirect = self._wantsCoverRedirect
	self._wantsCoverRedirect = false
	local stateBefore = self._stateMachine:GetCurrentState()

	self._coverHandler:Update(dt, self._envSensor:GetContext(), wantsCoverRedirect)
	self._evadeHandler:Update(dt)
	self._vaultHandler:Update(dt)

	-- Re-leer estado: los sub-handlers pueden haber provocado una transición
	local stateAfter = self._stateMachine:GetCurrentState()

	-- Vault pendiente desde CoverEntering: ejecutar al completar el snap (CoverIdle)
	-- TransitionTo puede fallar por STATE_MIN_DURATION si CoverIdle acaba de entrar;
	-- en ese caso mantener el pending y reintentar el siguiente frame.
	if self._pendingVaultFromEntering then
		if stateAfter == "CoverIdle" then
			if self._stateMachine:TransitionTo("Vaulting") then
				local pendingData = self._pendingVaultFromEntering
				self._pendingVaultFromEntering = nil
				self._coverHandler:ResetCover()
				self._vaultHandler:HandleAction("Vault", pendingData)
				stateAfter = self._stateMachine:GetCurrentState()
			end
			-- Si TransitionTo falla (STATE_MIN_DURATION aún no cumplido),
			-- _pendingVaultFromEntering se mantiene y se reintenta el siguiente frame.
		elseif stateAfter ~= "CoverEntering" then
			-- Cualquier otro estado (ExitCover, Idle, etc.) → cancelar vault pendiente
			self._pendingVaultFromEntering = nil
		end
	end

	if stateAfter == "RoadieRun" then
		self:_updateRoadieRun()
	else
		if self._roadieRunLV and self._roadieRunLV.Enabled then
			self._roadieRunLV.Enabled = false
		end
	end

	self._rotationHandler:Update(dt, stateAfter, self._coverHandler:GetNormal())

	-- Solo re-aplicar velocidad si el estado cambió dentro de un sub-handler
	if stateAfter ~= stateBefore then
		self:_applyMovementSpeed()
	end
end

------------------------------------------------------------------------
-- PUBLIC: Sub-handler access (para Camera/Animation futuros)
------------------------------------------------------------------------

--- Retorna el CoverMain para que otros sistemas lean estado de cover.
function MovementController:GetCoverHandler()
	return self._coverHandler
end

--- Inyecta referencia al AimingController en RotationHandler (para Low Cover rotation override).
function MovementController:SetAimingController(aimingController)
	self._rotationHandler:SetAimingController(aimingController)
	self._rotationHandler:SetCoverHandler(self._coverHandler)
end

------------------------------------------------------------------------
-- INTERNAL: Character Refs Cache
------------------------------------------------------------------------

--- Refresca la cache de character/humanoid/hrp si el character cambió (respawn)
--- o si HRP/Humanoid no estaban listos en el cache anterior (race condition en mobile).
function MovementController:_refreshCache()
	local character = self._player.Character
	if character ~= self._cachedCharacter or (character and (not self._cachedHRP or not self._cachedHumanoid)) then
		self._cachedCharacter = character
		self._cachedHumanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
		self._cachedHRP = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?

		if self._cachedHRP then
			local attachment = self._cachedHRP:FindFirstChild("RoadieRunAttachment")
			if not attachment then
				attachment = Instance.new("Attachment")
				attachment.Name = "RoadieRunAttachment"
				attachment.Parent = self._cachedHRP
			end

			local lv = self._cachedHRP:FindFirstChild("RoadieRunVelocity")
			if not lv then
				lv = Instance.new("LinearVelocity")
				lv.Name = "RoadieRunVelocity"
				lv.Attachment0 = attachment
				lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
				lv.MaxAxesForce = Vector3.new(math.huge, 0, math.huge) -- Control XYZ, ignora gravedad Y
				lv.VectorVelocity = Vector3.zero
				lv.Enabled = false
				lv.Parent = self._cachedHRP
			end
			self._roadieRunLV = lv
		else
			self._roadieRunLV = nil
		end
	end
end

------------------------------------------------------------------------
-- INTERNAL: Movement Speed
------------------------------------------------------------------------

function MovementController:_applyMovementSpeed()
	self:_refreshCache()
	local humanoid = self._cachedHumanoid
	if not humanoid then
		return
	end

	local state = self._stateMachine:GetCurrentState()
	humanoid.WalkSpeed = SpeedMap.GetSpeed(state)
end

------------------------------------------------------------------------
-- INTERNAL: RoadieRun
------------------------------------------------------------------------

--- Aplica AssemblyLinearVelocity directa durante RoadieRun.
--- WalkSpeed=0 en SpeedMap garantiza que el Humanoid no aporte ninguna fuerza propia,
--- por lo que esta función es el ÚNICO origen de velocidad horizontal en RoadieRun.
--- Dirección: SIEMPRE LookVector — el personaje es forzado hacia adelante.
--- El RotationHandler gestiona la rotación (Quick Snap + Steering), y este módulo
--- simplemente aplica velocidad en la dirección a la que apunta el modelo.
function MovementController:_updateRoadieRun()
	self:_refreshCache()
	local hrp = self._cachedHRP
	if not hrp then
		return
	end

	-- Siempre avanzar hacia donde mira el personaje (auto-forward GoW)
	local rawDir = hrp.CFrame.LookVector

	-- Aplanar al plano horizontal y normalizar
	local flatDir = Vector3.new(rawDir.X, 0, rawDir.Z)
	if flatDir.Magnitude < Constants.ZERO_MAGNITUDE then
		if self._roadieRunLV then
			self._roadieRunLV.Enabled = false
		end
		return
	end
	flatDir = flatDir.Unit

	local targetVelocity = Vector3.new(
		flatDir.X * Constants.ROADIE_RUN_SPEED,
		0, -- Y is ignored by MaxAxesForce
		flatDir.Z * Constants.ROADIE_RUN_SPEED
	)

	if self._roadieRunLV then
		self._roadieRunLV.VectorVelocity = targetVelocity
		self._roadieRunLV.Enabled = true
	else
		-- Fallback to AssemblyLinearVelocity
		hrp.AssemblyLinearVelocity = Vector3.new(targetVelocity.X, hrp.AssemblyLinearVelocity.Y, targetVelocity.Z)
	end
end

return MovementController
