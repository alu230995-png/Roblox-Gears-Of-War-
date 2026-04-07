--[[
	CoverSwapController.luau
	═══════════════════════════════════════════════════════════════
	Sub-estado: Salto entre coberturas adyacentes (Cover Swap)
	═══════════════════════════════════════════════════════════════

	Ejecuta el movimiento curvo (flecha rosa) desde la esquina de
	la cover actual hasta la posición de descanso (punto rojo) en
	la nueva cobertura adyacente.

	Trayectoria: Curva de Bézier cuadrática (arco horizontal 2D)
	  P(t) = (1-t)² × P0 + 2t(1-t) × P1 + t² × P2
	  - P0 = posición inicial del jugador
	  - P1 = punto de control (midpoint + arco horizontal hacia afuera de la pared)
	  - P2 = punto rojo (posición final en nueva cover)

	Movimiento: Físico — AssemblyLinearVelocity dirige al personaje
	  a lo largo de la curva. No hay teleportación via CFrame.

	Rotación:
	  - t < 0.80: El personaje mira en la dirección de viaje (tangente de Bézier)
	  - t ≥ 0.80: Blend progresivo hacia la orientación de cover (+newNormal)
	  - t = 1.00: Snap final con espalda contra la pared (= InCover convention)

	Secuencia de finalización (orden crítico):
	  1. Actualizar coverState con datos de la nueva cover
	  2. _isActive = false
	  3. Retornar "complete" → CoverMain cambia a CoverIdle
	  → CoverIdle nunca ve datos stale

	Cancelación: SOLO via hold Space → CoverRunning.
	No hay otra vía de escape — CoverSwap es ActionGroup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local CoverSwapController = {}
CoverSwapController.__index = CoverSwapController

-- Umbral de t en el que el personaje comienza a rotar hacia la nueva cover.
-- Por encima de este valor, la orientación hace blend progresivo hacia la normal de destino.
local COVER_SWAP_BLEND_T = 0.80

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CoverSwapController.new(coverState)
	local self = setmetatable({}, CoverSwapController)

	self._state = coverState -- referencia al estado compartido de CoverMain

	-- Estado del swap
	self._isActive = false
	self._elapsed = 0
	self._duration = 0

	-- Datos de la trayectoria Bézier
	self._startPos = Vector3.zero
	self._controlPoint = Vector3.zero
	self._targetPos = Vector3.zero
	self._startNormal = nil :: Vector3? -- normal de la cover original (para arco 2D)

	-- Datos de la nueva cover (se aplican al coverState al completar)
	self._newNormal = nil :: Vector3?
	self._newWallRight = nil :: Vector3?
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
	self._newCoverType = if swapData.newPart.Size.Y <= Constants.COVER_HEIGHT_LOW_MAX then "Low" else "High"

	-- P0: posición inicial del jugador
	self._startPos = hrp.Position

	-- P2: punto rojo — posición final calculada geométricamente
	-- En vez de usar hitPosition (impreciso, depende del ángulo del rayo),
	-- calculamos la esquina frontal exacta de la nueva Part usando half-extents.
	local newNormal = swapData.newNormal
	local newWallRight = Vector3.yAxis:Cross(newNormal)
	if newWallRight.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	newWallRight = newWallRight.Unit
	self._newWallRight = newWallRight

	-- Normal actual de la cover origen (para calcular la dirección del arco 2D)
	self._startNormal = self._state.coverNormal or newNormal

	local newPart = swapData.newPart
	local moveDir = swapData.moveDir

	-- Half-extents: proyectar Size/2 sobre normal y tangente en espacio local
	local extents = newPart.Size * 0.5
	local nLocal = newPart.CFrame:VectorToObjectSpace(newNormal)
	local tLocal = newPart.CFrame:VectorToObjectSpace(newWallRight)

	local halfDepth = math.abs(nLocal.X) * extents.X + math.abs(nLocal.Y) * extents.Y + math.abs(nLocal.Z) * extents.Z
	local halfWidth = math.abs(tLocal.X) * extents.X + math.abs(tLocal.Y) * extents.Y + math.abs(tLocal.Z) * extents.Z

	-- Esquina frontal exacta: centro → cara frontal → borde lateral opuesto a moveDir
	local center = newPart.CFrame.Position
	local cornerPos = center + (newNormal * halfDepth) - (newWallRight * moveDir * halfWidth)

	-- Posición final: esquina + separación de pared + margen de seguridad hacia adentro
	self._targetPos = cornerPos
		+ (newNormal * Constants.COVER_OFFSET)
		+ (newWallRight * moveDir * Constants.COVER_SWAP_SAFETY_MARGIN)

	-- Preservar Y del jugador (no caer ni flotar)
	self._targetPos = Vector3.new(self._targetPos.X, self._startPos.Y, self._targetPos.Z)

	-- P1: arco horizontal 2D — midpoint empujado hacia afuera de la pared actual.
	-- El arco curva por el hueco entre coberturas (plano XZ, Y constante).
	local distance = (self._targetPos - self._startPos).Magnitude
	local midpoint = (self._startPos + self._targetPos) / 2
	local outwardDir = Vector3.new(self._startNormal.X, 0, self._startNormal.Z)
	if outwardDir.Magnitude >= Constants.ZERO_MAGNITUDE then
		outwardDir = outwardDir.Unit
	end
	self._controlPoint = midpoint + outwardDir * (distance * Constants.COVER_SWAP_ARC_HEIGHT)
	self._controlPoint = Vector3.new(self._controlPoint.X, self._startPos.Y, self._controlPoint.Z)

	-- Activar y resetear timer
	-- Duración dinámica: distancia / velocidad (swaps cortos son rápidos, largos más lentos)
	-- Guardar contra start == target (distance ≈ 0 daría duration = 0 → NaN en Update)
	if distance < Constants.ZERO_MAGNITUDE then
		return
	end
	self._duration = distance / Constants.COVER_SWAP_SPEED
	self._isActive = true
	self._elapsed = 0

	-- Congelar velocidad del personaje
	hrp.AssemblyLinearVelocity = Vector3.zero

	if Constants.DEBUG_MODE then
		print(
			string.format(
				"[CoverSwap] BEGIN: start=(%.1f,%.1f,%.1f) → target=(%.1f,%.1f,%.1f) | dist=%.2f | speed=%.0f | dur=%.2fs",
				self._startPos.X,
				self._startPos.Y,
				self._startPos.Z,
				self._targetPos.X,
				self._targetPos.Y,
				self._targetPos.Z,
				distance,
				Constants.COVER_SWAP_SPEED,
				self._duration
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
			Debris:AddItem(s, self._duration + 1.0)
		end

		-- P0 verde = inicio | P1 amarillo = control | P2 rojo = destino
		dbgSphere(self._startPos, Color3.fromRGB(30, 200, 30), "P0_Start")
		dbgSphere(self._controlPoint, Color3.fromRGB(255, 210, 0), "P1_Control")
		dbgSphere(self._targetPos, Color3.fromRGB(220, 30, 30), "P2_Target")
	end
end

--- Actualiza el movimiento Bézier cada frame (físico + rotación progresiva).
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
	local t = math.clamp(self._elapsed / self._duration, 0, 1)

	-- Bézier cuadrática: P(t) = (1-t)² × P0 + 2t(1-t) × P1 + t² × P2
	local oneMinusT = 1 - t
	local curvePos = oneMinusT * oneMinusT * self._startPos
		+ 2 * t * oneMinusT * self._controlPoint
		+ t * t * self._targetPos

	-- Bézier derivada (tangente): P'(t) = 2(1-t)(P1-P0) + 2t(P2-P1)
	local tangent = 2 * oneMinusT * (self._controlPoint - self._startPos)
		+ 2 * t * (self._targetPos - self._controlPoint)

	-- ═══════════════════════════════════════════════════════════
	-- ROTACIÓN: dirección de viaje → blend → espalda contra la pared
	-- ═══════════════════════════════════════════════════════════
	local flatTangent = Vector3.new(tangent.X, 0, tangent.Z)
	-- coverNormal apunta AFUERA de la pared → lookAt(pos, pos + N) = espalda contra pared
	local coverFacing = Vector3.new(self._newNormal.X, 0, self._newNormal.Z)

	local facingDir: Vector3
	if t < COVER_SWAP_BLEND_T then
		-- Fase de viaje: mirar en la dirección de movimiento
		facingDir = flatTangent
	else
		-- Fase de aterrizaje: blend progresivo hacia orientación de cover
		local alpha = (t - COVER_SWAP_BLEND_T) / (1 - COVER_SWAP_BLEND_T)
		if flatTangent.Magnitude > Constants.ZERO_MAGNITUDE and coverFacing.Magnitude > Constants.ZERO_MAGNITUDE then
			facingDir = flatTangent.Unit:Lerp(coverFacing.Unit, alpha)
		else
			facingDir = coverFacing
		end
	end

	-- Aplicar rotación (solo cambia orientación, posición = donde está ahora)
	if facingDir.Magnitude > Constants.ZERO_MAGNITUDE then
		hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + facingDir.Unit)
	end

	-- ═══════════════════════════════════════════════════════════
	-- MOVIMIENTO FÍSICO: velocidad para seguir la curva de Bézier
	-- El motor de física mueve al personaje — no hay teleportación.
	-- Auto-correctivo: (objetivo - actual) / dt actúa como P-controller.
	-- ═══════════════════════════════════════════════════════════
	if dt > 0 then
		hrp.AssemblyLinearVelocity = (curvePos - hrp.Position) / dt
	end

	if t >= 1 then
		-- ═══════════════════════════════════════════════════════════
		-- ORDEN CRÍTICO: actualizar coverState ANTES de retornar
		-- "complete", para que CoverIdle arranque con datos correctos
		-- ═══════════════════════════════════════════════════════════

		-- 1. Snap a posición y rotación exactas (espalda contra pared nueva)
		hrp.CFrame = CFrame.lookAt(self._targetPos, self._targetPos + self._newNormal)
		hrp.AssemblyLinearVelocity = Vector3.zero

		-- 2. Actualizar estado compartido con la nueva cover
		self._state.coverNormal = self._newNormal
		self._state.coverPosition = self._targetPos - (self._newNormal * Constants.COVER_OFFSET)
		self._state.coverInstance = self._newCoverPart
		self._state.coverType = self._newCoverType
		self._state.wallRight = self._newWallRight

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
		local tDebug = if self._duration > 0 then math.clamp(self._elapsed / self._duration, 0, 1) else 0
		print(
			string.format(
				"[CoverSwap] CANCELADO en t=%.2f (elapsed=%.3fs / %.3fs dur)",
				tDebug,
				self._elapsed,
				self._duration
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
