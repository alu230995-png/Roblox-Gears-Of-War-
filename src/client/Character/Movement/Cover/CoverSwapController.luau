--[[
	CoverSwapController.luau
	═══════════════════════════════════════════════════════════════
	Sub-estado: Salto entre coberturas adyacentes (Cover Swap)
	═══════════════════════════════════════════════════════════════

	Ejecuta el movimiento curvo (flecha rosa) desde la esquina de
	la cover actual hasta la posición de descanso (punto rojo) en
	la nueva cobertura adyacente.

	Trayectoria: Curva de Bézier cuadrática
	  P(t) = (1-t)² × P0 + 2t(1-t) × P1 + t² × P2
	  - P0 = posición inicial del jugador
	  - P1 = punto de control (midpoint + arco vertical)
	  - P2 = punto rojo (posición final en nueva cover)

	Secuencia de finalización (orden crítico):
	  1. Actualizar coverState con datos de la nueva cover
	  2. _isActive = false
	  3. Retornar "complete" → CoverMain cambia a CoverIdle
	  → CoverIdle nunca ve datos stale

	Cancelación: SOLO via hold Space → CoverRunning.
	No hay otra vía de escape — CoverSwap es ActionGroup.

	STATUS: Implementación completa de Fase 1-3 del Cover Swap.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local CoverSwapController = {}
CoverSwapController.__index = CoverSwapController

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CoverSwapController.new(coverState)
	local self = setmetatable({}, CoverSwapController)

	self._state = coverState -- referencia al estado compartido de CoverMain

	-- Estado del swap
	self._isActive = false
	self._elapsed = 0

	-- Datos de la trayectoria Bézier
	self._startPos = Vector3.zero
	self._controlPoint = Vector3.zero
	self._targetPos = Vector3.zero

	-- Datos de la nueva cover (se aplican al coverState al completar)
	self._newNormal = nil :: Vector3?
	self._newCoverPart = nil :: BasePart?
	self._newCoverType = nil :: string?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Inicia el Cover Swap con los datos calculados por CornerCover.
--- @param swapData table — { newPart, newNormal, hitPosition, moveDir }
function CoverSwapController:Begin(swapData)
	local hrp = self:_getHRP()
	if not hrp then
		return
	end

	-- Almacenar datos de la nueva cover
	self._newCoverPart = swapData.newPart
	self._newNormal = swapData.newNormal
	self._newCoverType = if swapData.newPart.Size.Y <= 3.5 then "Low" else "High"

	-- P0: posición inicial del jugador
	self._startPos = hrp.Position

	-- P2: punto rojo — posición final de descanso en la nueva cover
	local newWallRight = Vector3.yAxis:Cross(swapData.newNormal)
	if newWallRight.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	newWallRight = newWallRight.Unit

	-- hitPosition + normal × OFFSET + tangente × (-moveDir) × SAFETY_MARGIN
	self._targetPos = swapData.hitPosition
		+ (swapData.newNormal * Constants.COVER_OFFSET)
		+ (newWallRight * -swapData.moveDir * Constants.COVER_SWAP_SAFETY_MARGIN)

	-- Preservar Y del jugador (no caer ni flotar)
	self._targetPos = Vector3.new(self._targetPos.X, self._startPos.Y, self._targetPos.Z)

	-- P1: punto de control (midpoint + arco vertical para la curva rosa)
	local distance = (self._targetPos - self._startPos).Magnitude
	local midpoint = (self._startPos + self._targetPos) / 2
	self._controlPoint = midpoint + Vector3.new(0, distance * Constants.COVER_SWAP_ARC_HEIGHT, 0)

	-- Activar y resetear timer
	self._isActive = true
	self._elapsed = 0

	-- Congelar velocidad del personaje
	hrp.AssemblyLinearVelocity = Vector3.zero

	if Constants.DEBUG_MODE then
		local dist = (self._targetPos - self._startPos).Magnitude
		print(
			string.format(
				"[CoverSwap] BEGIN: start=(%.1f,%.1f,%.1f) → target=(%.1f,%.1f,%.1f) | dist=%.2f | dur=%.2fs",
				self._startPos.X,
				self._startPos.Y,
				self._startPos.Z,
				self._targetPos.X,
				self._targetPos.Y,
				self._targetPos.Z,
				dist,
				Constants.COVER_SWAP_DURATION
			)
		)

		-- Función auxiliar para esferas de debug
		local function dbgSphere(pos: Vector3, color: Color3, label: string)
			local s = Instance.new("Part")
			s.Name = "DEBUG_Bezier_" .. label
			s.Shape = Enum.PartType.Ball
			s.Anchored = true
			s.CanCollide = false
			s.CanQuery = false
			s.CastShadow = false
			s.Size = Vector3.one * 0.5
			s.Position = pos
			s.Color = color
			s.Material = Enum.Material.Neon
			s.Parent = workspace
			Debris:AddItem(s, Constants.COVER_SWAP_DURATION + 1.0)
		end

		-- P0 verde = inicio | P1 amarillo = control | P2 rojo = destino
		dbgSphere(self._startPos, Color3.fromRGB(30, 200, 30), "P0_Start")
		dbgSphere(self._controlPoint, Color3.fromRGB(255, 210, 0), "P1_Control")
		dbgSphere(self._targetPos, Color3.fromRGB(220, 30, 30), "P2_Target")
	end
end

--- Actualiza el movimiento Bézier cada frame.
--- @param dt number — delta time
--- @return string? — "complete" cuando termina, nil mientras está en progreso
function CoverSwapController:Update(dt: number): string?
	if not self._isActive then
		return nil
	end

	local hrp = self:_getHRP()
	if not hrp then
		self._isActive = false
		return nil
	end

	-- Avanzar tiempo
	self._elapsed += dt
	local t = math.clamp(self._elapsed / Constants.COVER_SWAP_DURATION, 0, 1)

	-- Bézier cuadrática: P(t) = (1-t)² × P0 + 2t(1-t) × P1 + t² × P2
	local oneMinusT = 1 - t
	local curvePos = oneMinusT * oneMinusT * self._startPos
		+ 2 * t * oneMinusT * self._controlPoint
		+ t * t * self._targetPos

	-- Mover al personaje y mantenerlo mirando hacia la nueva pared
	hrp.CFrame = CFrame.lookAt(curvePos, curvePos - self._newNormal)

	-- Congelar velocidad durante el movimiento (evitar interferencia de física)
	hrp.AssemblyLinearVelocity = Vector3.zero

	if t >= 1 then
		-- ═══════════════════════════════════════════════════════════
		-- ORDEN CRÍTICO: actualizar coverState ANTES de retornar
		-- "complete", para que CoverIdle arranque con datos correctos
		-- ═══════════════════════════════════════════════════════════

		-- 1. Snap a posición exacta
		hrp.CFrame = CFrame.lookAt(self._targetPos, self._targetPos - self._newNormal)
		hrp.AssemblyLinearVelocity = Vector3.zero

		-- 2. Actualizar estado compartido con la nueva cover
		local newWallRight = Vector3.yAxis:Cross(self._newNormal)
		if newWallRight.Magnitude >= Constants.ZERO_MAGNITUDE then
			newWallRight = newWallRight.Unit
		end

		self._state.coverNormal = self._newNormal
		self._state.coverPosition = self._targetPos - (self._newNormal * Constants.COVER_OFFSET)
		self._state.coverInstance = self._newCoverPart
		self._state.coverType = self._newCoverType
		self._state.wallRight = newWallRight

		-- 3. Desactivar
		self._isActive = false

		if Constants.DEBUG_MODE then
			print(
				string.format(
					"[CoverSwap] COMPLETE → snap a (%.1f,%.1f,%.1f) | nueva cover: %s",
					self._targetPos.X,
					self._targetPos.Y,
					self._targetPos.Z,
					if self._newCoverPart then self._newCoverPart.Name else "nil"
				)
			)
		end

		-- 4. Señal para CoverMain
		return "complete"
	end

	return nil
end

--- Retorna true si el swap está en progreso.
function CoverSwapController:IsActive(): boolean
	return self._isActive
end

--- Cancela el swap inmediatamente (solo llamado por hold Space → CoverRunning).
--- El jugador se queda donde esté en la curva — no se limpia coverState.
function CoverSwapController:Cancel()
	if not self._isActive then
		return
	end

	if Constants.DEBUG_MODE then
		print(
			string.format(
				"[CoverSwap] CANCELADO en t=%.2f (elapsed=%.3fs / %.3fs dur)",
				math.clamp(self._elapsed / Constants.COVER_SWAP_DURATION, 0, 1),
				self._elapsed,
				Constants.COVER_SWAP_DURATION
			)
		)
	end

	self._isActive = false

	-- Detener movimiento donde esté
	local hrp = self:_getHRP()
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
end

------------------------------------------------------------------------
-- INTERNAL: Helpers
------------------------------------------------------------------------

function CoverSwapController:_getHRP(): BasePart?
	local character = self._state.player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

return CoverSwapController
