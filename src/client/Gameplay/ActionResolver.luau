--[[
	ActionResolver.luau
	═══════════════════════════════════════════════════════════════
	CAPA 5: Resolución por Prioridad
	═══════════════════════════════════════════════════════════════
	
	El mismo input puede significar muchas cosas. La resolución se hace
	por prioridad: primero verifica si la acción de mayor prioridad es
	posible, si no, baja al siguiente nivel.
	
	Principio GoW — A (tap):
	  1. ¿Puedo entrar en cover? → Sí → EnterCover
	  2. ¿No? ¿Puedo evadirme?  → Sí → Evade/Roll
	  3. ¿No?                    → Idle (sin acción)
	
	Comunicación event-driven:
	  - self.ActionResolved (Signal) se dispara con (action, targetState, data)
	  - MovementController, AnimationController y CameraController escuchan
	    este signal sin que ActionResolver sepa de su existencia.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerStateModule = require(Shared:WaitForChild("Enums"):WaitForChild("PlayerState"))
local Constants = require(Shared:WaitForChild("Constants"))
local Signal = require(Shared:WaitForChild("Signal"))

local ActionResolver = {}
ActionResolver.__index = ActionResolver

function ActionResolver.new(stateMachine, inputBuffer, intentMapper, environmentSensor)
	local self = setmetatable({}, ActionResolver)

	self._stateMachine = stateMachine
	self._buffer = inputBuffer
	self._intents = intentMapper
	self._env = environmentSensor

	-- Signal de salida: (action: string, targetState: string?, data: any?)
	self.ActionResolved = Signal.new()

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function ActionResolver:Init()
	-- Signal creado en constructor
end

function ActionResolver:Start()
	-- Sin conexiones propias — Resolve() es llamado por el heartbeat
end

function ActionResolver:Destroy()
	if self.ActionResolved then
		self.ActionResolved:Destroy()
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Resuelve la acción a ejecutar este frame.
--- Dispara ActionResolved signal si la acción no es NoAction.
--- Retorna: actionName, targetState, actionData (para compatibilidad)
function ActionResolver:Resolve(): (string, string?, any?)
	local state = self._stateMachine:GetCurrentState()
	local env = self._env:GetContext()
	local stateConfig = PlayerStateModule.GetState(state)

	------------------------------------------------------------------------
	-- ÁRBOL 1: Estado actual determina qué árboles evaluar
	------------------------------------------------------------------------

	local action, targetState, data

	-- En estados bloqueantes (animación comprometida), no resolver nada
	if state == "Evading" or state == "Mantling" or state == "CoverSlide" or state == "Executing" then
		return "NoAction", nil, nil
	end

	-- DBNO: solo puede ser rescatado
	if state == "DBNO" then
		action, targetState, data = self:_resolveDBNO(env)
	-- Estados de cover
	elseif state == "CoverIdle" or state == "CoverAim" or state == "CoverBlindFire" then
		action, targetState, data = self:_resolveCoverState(state, env, stateConfig)
	-- RoadieRun
	elseif state == "RoadieRun" then
		action, targetState, data = self:_resolveRoadieRun(env)
	-- Estados libres: Idle, Walking, Aiming, Firing, Reloading, ActiveReloading
	else
		action, targetState, data = self:_resolveFreeState(state, env, stateConfig)
	end

	-- Disparar signal para listeners (MovementController, futuro: Camera, Animation)
	if action ~= "NoAction" then
		self.ActionResolved:Fire(action, targetState, data)

		if Constants.DEBUG_MODE then
			print(`[GoW] {action} → {targetState or "nil"} | State: {self._stateMachine:GetCurrentState()}`)
		end
	end

	return action, targetState, data
end

------------------------------------------------------------------------
-- RESOLVER: Estados libres (Idle, Walking, Aiming, Firing, etc.)
------------------------------------------------------------------------

function ActionResolver:_resolveFreeState(state: string, env, stateConfig): (string, string?, any?)
	-- Prioridad 1: Cover (el botón más importante de GoW)
	if self._buffer:HasIntent("WantsCover") then
		if env.HasCoverNearby and stateConfig.canTakeCover then
			self._buffer:Consume("WantsCover")
			return "EnterCover", "CoverSlide", { coverNormal = env.CoverNormal, coverPos = env.CoverPosition }
		end
	end

	-- Prioridad 2: Mantle
	if self._buffer:HasIntent("WantsMantle") then
		if env.HasLowCoverAhead and env.HasCoverNearby then
			self._buffer:Consume("WantsMantle")
			return "Mantle", "Mantling", nil
		end
	end

	-- Prioridad 3: Evade / Roll
	if self._buffer:HasIntent("WantsEvade") then
		if stateConfig.canEvade then
			self._buffer:Consume("WantsEvade")
			local moveDir = env.MoveDirection
			return "Evade", "Evading", { direction = moveDir }
		end
	end

	-- Prioridad 4: RoadieRun (intent continuo)
	if self._intents:HasIntent("WantsRoadieRun") then
		if stateConfig.canSprint and (state == "Idle" or state == "Walking") then
			return "StartRoadieRun", "RoadieRun", nil
		end
	end

	-- Prioridad 5: Aim
	if self._intents:HasIntent("WantsAim") then
		if stateConfig.canShoot and (state == "Idle" or state == "Walking") then
			return "StartAim", "Aiming", nil
		end
	end

	-- Prioridad 5b: Stop Aim
	if self._intents:HasIntent("WantsStopAim") then
		if state == "Aiming" then
			return "StopAim", "Idle", nil
		end
	end

	-- Prioridad 6: Shoot
	if self._intents:HasIntent("WantsShoot") then
		if stateConfig.canShoot then
			if state == "Aiming" then
				return "Shoot", "Firing", nil
			end
		end
	end

	-- Prioridad 6b: Stop Shoot
	if self._intents:HasIntent("WantsStopShoot") then
		if state == "Firing" then
			return "StopShoot", "Aiming", nil
		end
	end

	-- Prioridad 7: Reload
	if self._buffer:HasIntent("WantsReload") then
		if state == "Reloading" then
			-- Active Reload: segundo tap durante recarga
			self._buffer:Consume("WantsReload")
			return "ActiveReload", "ActiveReloading", nil
		elseif stateConfig.canMove then -- proxy para "puede recargar"
			self._buffer:Consume("WantsReload")
			return "Reload", "Reloading", nil
		end
	end

	-- Prioridad 8: Melee
	if self._buffer:HasIntent("WantsMelee") then
		self._buffer:Consume("WantsMelee")
		return "Melee", nil, nil
	end

	-- Prioridad 8b: Chainsaw
	if self._buffer:HasIntent("WantsChainsaw") then
		self._buffer:Consume("WantsChainsaw")
		return "Chainsaw", nil, nil
	end

	-- Prioridad 9: Interact
	if self._buffer:HasIntent("WantsInteract") then
		self._buffer:Consume("WantsInteract")
		return "Interact", nil, nil
	end

	-- Prioridad 10: Swap Weapon
	if self._buffer:HasIntent("WantsSwapWeapon") then
		local _, swapData = self._buffer:Consume("WantsSwapWeapon")
		return "SwapWeapon", nil, { slot = swapData }
	end

	-- Movimiento: si hay dirección → Walking. Si no → Idle.
	local hasMovement = self._intents:HasIntent("WantsMoveForward")
		or self._intents:HasIntent("WantsMoveBackward")
		or self._intents:HasIntent("WantsMoveLeft")
		or self._intents:HasIntent("WantsMoveRight")

	if hasMovement then
		if state == "Idle" then
			return "StartWalking", "Walking", nil
		end
		-- Ya en Walking → no action needed
		return "NoAction", nil, nil
	else
		-- Sin movimiento
		if state == "Walking" then
			return "StopWalking", "Idle", nil
		end
		return "NoAction", nil, nil
	end
end

------------------------------------------------------------------------
-- RESOLVER: RoadieRun
------------------------------------------------------------------------

function ActionResolver:_resolveRoadieRun(env): (string, string?, any?)
	-- Prioridad 1: Cover durante roadie run → CoverSlide (la más rápida del juego)
	if self._buffer:HasIntent("WantsCover") then
		if env.HasCoverNearby then
			self._buffer:Consume("WantsCover")
			return "SlideIntoCover", "CoverSlide", { coverNormal = env.CoverNormal, coverPos = env.CoverPosition }
		end
	end

	-- Prioridad 2: Mantle durante roadie run
	if env.HasLowCoverAhead and env.HasCoverNearby then
		if self._buffer:HasIntent("WantsMantle") then
			self._buffer:Consume("WantsMantle")
			return "Mantle", "Mantling", nil
		end
		-- Auto-mantle: si corremos directo a cover bajo
		if env.MoveDirection.Y > 0.5 and env.IsFacingCover then
			return "Mantle", "Mantling", nil
		end
	end

	-- Prioridad 3: Evade durante roadie run
	if self._buffer:HasIntent("WantsEvade") then
		self._buffer:Consume("WantsEvade")
		return "Evade", "Evading", { direction = env.MoveDirection }
	end

	-- Prioridad 4: Dejar de correr
	if not self._intents:HasIntent("WantsRoadieRun") then
		local hasMovement = self._intents:HasIntent("WantsMoveForward")
			or self._intents:HasIntent("WantsMoveBackward")
			or self._intents:HasIntent("WantsMoveLeft")
			or self._intents:HasIntent("WantsMoveRight")

		if hasMovement then
			return "StopRoadieRun", "Walking", nil
		else
			return "StopRoadieRun", "Idle", nil
		end
	end

	return "NoAction", nil, nil
end

------------------------------------------------------------------------
-- RESOLVER: Cover States
------------------------------------------------------------------------

function ActionResolver:_resolveCoverState(state: string, env, _stateConfig): (string, string?, any?)
	-- CoverAim → solo puede volver a CoverIdle o disparar
	if state == "CoverAim" then
		if self._intents:HasIntent("WantsStopAim") then
			return "ReturnToCover", "CoverIdle", nil
		end
		if self._intents:HasIntent("WantsShoot") then
			return "Shoot", "Firing", nil
		end
		return "NoAction", nil, nil
	end

	-- CoverBlindFire → solo puede volver a CoverIdle
	if state == "CoverBlindFire" then
		if not self._intents:HasIntent("WantsBlindFire") then
			return "StopBlindFire", "CoverIdle", nil
		end
		return "NoAction", nil, nil
	end

	-- CoverIdle → múltiples opciones
	if state == "CoverIdle" then
		-- Prioridad 1: Exit cover (move backward)
		if self._buffer:HasIntent("WantsExitCover") or self._intents:HasIntent("WantsExitCover") then
			self._buffer:Consume("WantsExitCover")
			return "ExitCover", "Idle", nil
		end

		-- Prioridad 2: Evade / Roll out
		if self._buffer:HasIntent("WantsEvade") then
			self._buffer:Consume("WantsEvade")
			return "RollOutOfCover", "Evading", { direction = env.MoveDirection }
		end

		-- Prioridad 3: Vault (cover bajo + move forward + cover button)
		if self._buffer:HasIntent("WantsCover") or self._buffer:HasIntent("WantsMantle") then
			if env.CoverType == "Low" and env.MoveDirection.Y > 0.3 then
				self._buffer:Consume("WantsCover")
				self._buffer:Consume("WantsMantle")
				return "Vault", "Mantling", nil
			end
		end

		-- Prioridad 4: Swat Turn (move lateral + cover adyacente)
		local wantsLeft = self._intents:HasIntent("WantsMoveLeft")
		local wantsRight = self._intents:HasIntent("WantsMoveRight")

		if wantsLeft and env.HasAdjacentCoverLeft then
			if self._buffer:HasIntent("WantsCover") then
				self._buffer:Consume("WantsCover")
				return "SwatTurn", "CoverSlide", { direction = "Left" }
			end
		end
		if wantsRight and env.HasAdjacentCoverRight then
			if self._buffer:HasIntent("WantsCover") then
				self._buffer:Consume("WantsCover")
				return "SwatTurn", "CoverSlide", { direction = "Right" }
			end
		end

		-- Prioridad 5: Aim (pop-up / peek)
		if self._intents:HasIntent("WantsAim") then
			return "PopUpAim", "CoverAim", nil
		end

		-- Prioridad 6: Blind Fire
		if self._intents:HasIntent("WantsBlindFire") then
			return "BlindFire", "CoverBlindFire", nil
		end

		-- Prioridad 7: Shoot sin aim (= blind fire)
		if self._intents:HasIntent("WantsShoot") and not self._intents:HasIntent("WantsAim") then
			return "BlindFire", "CoverBlindFire", nil
		end

		-- Prioridad 8: Reload en cover
		if self._buffer:HasIntent("WantsReload") then
			self._buffer:Consume("WantsReload")
			return "Reload", "Reloading", nil
		end

		-- Prioridad 9: Slide lateral en cover (movimiento sin cover adyacente)
		if wantsLeft and not env.IsAtCornerLeft then
			return "CoverSlideLeft", nil, nil
		end
		if wantsRight and not env.IsAtCornerRight then
			return "CoverSlideRight", nil, nil
		end

		-- Prioridad 10: Peek en esquina
		if wantsLeft and env.IsAtCornerLeft then
			return "PeekCornerLeft", nil, nil
		end
		if wantsRight and env.IsAtCornerRight then
			return "PeekCornerRight", nil, nil
		end
	end

	return "NoAction", nil, nil
end

------------------------------------------------------------------------
-- RESOLVER: DBNO
------------------------------------------------------------------------

function ActionResolver:_resolveDBNO(_env): (string, string?, any?)
	local hasMovement = self._intents:HasIntent("WantsMoveForward")
		or self._intents:HasIntent("WantsMoveBackward")
		or self._intents:HasIntent("WantsMoveLeft")
		or self._intents:HasIntent("WantsMoveRight")

	if hasMovement then
		return "Crawl", nil, nil
	end

	return "NoAction", nil, nil
end

return ActionResolver
