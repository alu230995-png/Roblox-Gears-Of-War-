--[[
	AimingController.luau
	═══════════════════════════════════════════════════════════════
	Cerebro del sistema de apuntado — Fase 1B/1C

	Responsabilidades:
	  1. Gestionar _isAiming vía HandleAction (recibe del ActionExecuted signal)
	  2. Update(dt) cada frame: shoulder + deadzone (high cover), zona frontal (low cover)
	  3. FOV delta: aplica AIM_ZOOM_FOV_DELTA al CameraController

	Dependencias inyectadas (DI):
	  - StateMachine  → leer estado actual
	  - CoverHandler  → leer coverNormal, coverType
	  - CameraController → SetShoulderSide, SetFOVDelta

	No posee signals propios. No toca physics ni animación.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local AimAngleUtils = require(script.Parent:WaitForChild("AimAngleUtil"))

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------
local AimingController = {}
AimingController.__index = AimingController

function AimingController.new(stateMachine, coverHandler, cameraController)
	local self = setmetatable({}, AimingController)

	self._stateMachine = stateMachine
	self._coverHandler = coverHandler
	self._cameraController = cameraController

	self._isAiming = false

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE (ServiceLocator compatible)
------------------------------------------------------------------------

function AimingController:Init() end

function AimingController:Start() end

function AimingController:Destroy() end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Recibe acciones del signal ActionExecuted.
--- Gestiona el flag _isAiming y el FOV delta.
function AimingController:HandleAction(action: string, _targetState: string?, _data: any?)
	if action == "PopUpAim" then
		if Constants.DEBUG_MODE then
			print(`[AimDebug] AimingController:HandleAction(PopUpAim) → _isAiming=true`)
		end
		self._isAiming = true
		self._cameraController:SetFOVDelta(Constants.AIM_ZOOM_FOV_DELTA)
	elseif action == "StartAim" then
		if Constants.DEBUG_MODE then
			print(`[AimDebug] AimingController:HandleAction(StartAim) → _isAiming=true`)
		end
		-- Free aim: FOV delta = 0 porque STATE_FOV["Aiming"] ya tiene el offset correcto
		self._isAiming = true
		self._cameraController:SetFOVDelta(0)
	elseif action == "ReturnToCover" or action == "StopAim" then
		if Constants.DEBUG_MODE then
			print(`[AimDebug] AimingController:HandleAction({action}) → _isAiming=false`)
		end
		self._isAiming = false
		self._cameraController:SetFOVDelta(0)
	end
end

--- Update por frame. Solo activo si _isAiming == true.
--- Lee cover state y ajusta shoulder/deadzone.
function AimingController:Update(_dt: number)
	if not self._isAiming then
		return
	end

	local state = self._stateMachine:GetCurrentState()

	if Constants.DEBUG_MODE then
		print(`[AimDebug] AimingController:Update — _isAiming=true, state={state}`)
	end

	if state == "CoverAimHigh" then
		self:_updateHighCover()
	elseif state == "CoverAimLow" then
		self:_updateLowCover()
	elseif state == "CoverAim" then
		-- Legacy fallback: misma lógica que high cover
		self:_updateHighCover()
	elseif state == "CoverFiring" then
		-- Disparando desde cover: shoulder y FOV ya fijados al entrar en aim.
		-- No actualizar shoulder durante el disparo para evitar jitter.
		return
	elseif state == "CoverPeek" then
		-- Asomado en esquina: shoulder determinado por el ángulo de peek, mantener FOV.
		return
	elseif state == "Aiming" then
		-- Free aim: sin shoulder logic, FOV ya gestionado por STATE_FOV
		return
	else
		-- Safety net: estado cambió por debajo (DBNO, cover destruido, etc.)
		if Constants.DEBUG_MODE then
			print(`[AimDebug] AimingController:Update SAFETY NET — state={state}, resetting _isAiming`)
		end
		self._isAiming = false
		self._cameraController:SetFOVDelta(0)
	end
end

--- Stub para Fase 2: penalización de precisión por movimiento.
--- Se invocará cuando el jugador camina mientras apunta.
function AimingController.OnMovementAccuracyPenalty(_isAiming: boolean)
	-- Fase 2: conectar a WeaponController
end

------------------------------------------------------------------------
-- PRIVATE: Camera Look helper
------------------------------------------------------------------------

--- Lee la dirección de la cámara proyectada al plano XZ.
--- @return Vector3? — nil si la cámara no existe o el vector es near-zero
function AimingController:_getCameraLookFlat(): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)

	if flat.Magnitude < Constants.ZERO_MAGNITUDE then
		return nil
	end

	return flat.Unit
end

------------------------------------------------------------------------
-- PRIVATE: High Cover (Fase 1B)
------------------------------------------------------------------------

--- Apuntado desde high cover: deadzone 20° + detección de hombro.
--- Si la cámara entra en la deadzone, el resolver (ReturnToCoverDeadzone) maneja la salida.
function AimingController:_updateHighCover()
	local coverNormal = self._coverHandler:GetNormal()
	if not coverNormal then
		return
	end

	local lookFlat = self:_getCameraLookFlat()
	if not lookFlat then
		return
	end

	local angle = AimAngleUtils.AngleFromCoverNormal(lookFlat, coverNormal)
	local side = AimAngleUtils.GetShoulderSide(angle, Constants.COVER_AIM_DEADZONE_ANGLE)

	if side == nil then
		-- Deadzone: el resolver maneja la salida vía ReturnToCoverDeadzone
		return
	end

	self._cameraController:SetShoulderSide(side)
end

------------------------------------------------------------------------
-- PRIVATE: Low Cover (Fase 1C)
------------------------------------------------------------------------

--- Apuntado desde low cover: zona frontal (apunta sobre el cover)
--- + zona lateral (misma lógica que high cover con shoulder + deadzone).
function AimingController:_updateLowCover()
	local coverNormal = self._coverHandler:GetNormal()
	if not coverNormal then
		return
	end

	local lookFlat = self:_getCameraLookFlat()
	if not lookFlat then
		return
	end

	local angle = AimAngleUtils.AngleFromCoverNormal(lookFlat, coverNormal)

	-- Zona frontal: ángulo dentro del cono LOW_COVER_FRONT_HALF_ANGLE.
	-- El personaje apunta SOBRE el low cover. Sin shoulder swap, sin deadzone.
	if math.abs(angle) <= Constants.LOW_COVER_FRONT_HALF_ANGLE then
		return
	end

	-- Zona lateral: misma lógica que high cover
	local side = AimAngleUtils.GetShoulderSide(angle, Constants.COVER_AIM_DEADZONE_ANGLE)

	if side == nil then
		-- Deadzone lateral: el resolver maneja la salida vía ReturnToCoverDeadzone
		return
	end

	self._cameraController:SetShoulderSide(side)
end

return AimingController
