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
	self._rotationOverride = nil :: string?
	self._peekSide = nil :: string?
	self._peekFaceDir = nil :: Vector3?

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
		self._rotationOverride = nil
		self._peekSide = nil
		self._peekFaceDir = nil
		self._cameraController:SetFOVDelta(0)
	elseif action == "ReturnToAim" then
		-- Soltó el gatillo pero sigue apuntando → re-aplicar FOV de aim
		if Constants.DEBUG_MODE then
			print(`[AimDebug] AimingController:HandleAction(ReturnToAim) → _isAiming stays true, FOV restored`)
		end
		self._isAiming = true
		self._cameraController:SetFOVDelta(Constants.AIM_ZOOM_FOV_DELTA)
	elseif action == "EnterPeek" then
		if Constants.DEBUG_MODE then
			print(`[AimDebug] AimingController:HandleAction(EnterPeek) → side={_data and _data.side}`)
		end
		self._isAiming = true
		self._peekSide = _data and _data.side or nil
		-- Cachear la dirección de cámara en el momento del peek.
		-- peekSide se determina a partir del input relativo a la cámara, por lo que
		-- faceDir debe derivarse del right de la cámara, no de wallRight.
		self._peekFaceDir = nil
		if self._peekSide then
			local camera = workspace.CurrentCamera
			if camera then
				local camRight = camera.CFrame.RightVector
				local flatRight = Vector3.new(camRight.X, 0, camRight.Z)
				if flatRight.Magnitude > 0.01 then
					self._peekFaceDir = (if self._peekSide == "Right" then flatRight else -flatRight).Unit
				end
			end
		end
		self._cameraController:SetFOVDelta(Constants.AIM_ZOOM_FOV_DELTA)
		if self._peekSide then
			self._cameraController:SetShoulderSide(self._peekSide)
		end
	elseif action == "ExitPeek" then
		if Constants.DEBUG_MODE then
			print("[AimDebug] AimingController:HandleAction(ExitPeek) → _peekSide=nil")
		end
		self._peekSide = nil
		self._peekFaceDir = nil
		-- No resetear _isAiming: el jugador sigue apuntando, vuelve a CoverAimHigh/Low
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
		-- Shoulder fijo al lado del peek, sin deadzone
		if self._peekSide then
			self._cameraController:SetShoulderSide(self._peekSide)
		end
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
		self._rotationOverride = nil
		self._cameraController:SetFOVDelta(0)
	end
end

--- Retorna true si el sistema de apuntado está activo.
function AimingController:IsAiming(): boolean
	return self._isAiming
end

--- Establece el lado del peek (para uso externo si necesario).
function AimingController:SetPeekSide(side: string?)
	self._peekSide = side
end

--- Retorna el lado actual del peek ("Left" | "Right" | nil).
function AimingController:GetPeekSide(): string?
	return self._peekSide
end

--- Retorna la dirección de rostro cacheada para el peek (relativa a la cámara al inicio del peek).
--- Nil si no hay peek activo o si la cámara no estaba disponible al inicio.
function AimingController:GetPeekFaceDir(): Vector3?
	return self._peekFaceDir
end

--- Stub para Fase 2: penalización de precisión por movimiento.
--- Se invocará cuando el jugador camina mientras apunta.
function AimingController.OnMovementAccuracyPenalty(_isAiming: boolean)
	-- Fase 2: conectar a WeaponController
end

--- Retorna el override de rotación activo para RotationHandler.
--- "CoverAimFront" cuando Low Cover aim está en el cono frontal, nil en caso contrario.
function AimingController:GetRotationOverride(): string?
	return self._rotationOverride
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
	self._rotationOverride = nil -- High cover: personaje nunca rota

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

--- Apuntado desde low cover:
--- Cono frontal (±LOW_COVER_FRONT_HALF_ANGLE del outward): el personaje rota
--- para encarar la cámara. Shoulder según signo del ángulo. Sin deadzone.
--- Zona lateral (fuera del cono): misma lógica que high cover pero SIN deadzone
--- (deadzoneAngle = 0). El personaje queda locked (cover snap maneja rotación).
function AimingController:_updateLowCover()
	local coverNormal = self._coverHandler:GetNormal()
	if not coverNormal then
		return
	end

	local lookFlat = self:_getCameraLookFlat()
	if not lookFlat then
		return
	end

	if AimAngleUtils.IsInsideFrontCone(lookFlat, coverNormal, Constants.LOW_COVER_FRONT_HALF_ANGLE) then
		-- Cono frontal: personaje rota para encarar cámara, shoulder según ángulo
		self._rotationOverride = "CoverAimFront"
		local angle = AimAngleUtils.AngleFromCoverNormal(lookFlat, coverNormal)
		local side = if angle >= 0 then "Right" else "Left"
		self._cameraController:SetShoulderSide(side)
	else
		-- Zona lateral: shoulder según lado, sin deadzone (deadzoneAngle = 0)
		self._rotationOverride = nil
		local angle = AimAngleUtils.AngleFromCoverNormal(lookFlat, coverNormal)
		local side = AimAngleUtils.GetShoulderSide(angle, 0)
		if side then
			self._cameraController:SetShoulderSide(side)
		end
	end
end

return AimingController
