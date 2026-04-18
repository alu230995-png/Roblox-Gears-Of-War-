--[[
	PeekHandler.luau
	═══════════════════════════════════════════════════════════════
	Sub-estado: Desplazamiento físico de peek en esquina de cover
	═══════════════════════════════════════════════════════════════

	Cuando el jugador apunta desde cover y empuja input lateral
	hacia una esquina exterior, el personaje se desplaza
	PEEK_OFFSET_STUDS hacia esa esquina para asomarse.

	Movimiento: P-controller via AssemblyLinearVelocity (mismo
	patrón que CoverSwapController). Sin teleportación via CFrame.

	Begin(side) → mueve hacia la esquina
	End()        → invierte target, vuelve a startPos
	Cancel()     → detiene sin restaurar posición
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local CoverMovementUtils = require(script.Parent.CoverMovementUtils)

local PeekHandler = {}
PeekHandler.__index = PeekHandler

--- Umbral de distancia para considerar que el personaje llegó al target.
local ARRIVAL_THRESHOLD = 0.3
--- Velocidad máxima del P-controller (studs/segundo).
local PEEK_MOVE_SPEED = 20

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function PeekHandler.new(coverState)
	local self = setmetatable({}, PeekHandler)

	self._state = coverState

	self._isActive = false
	self._returning = false
	self._startPos = nil :: Vector3?
	self._targetPos = nil :: Vector3?
	self._peekSide = nil :: string?

	-- Cache de character refs (evita FindFirstChild cada frame)
	self._cachedCharacter = nil :: Model?
	self._cachedHRP = nil :: BasePart?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Inicia el peek hacia el lado indicado.
--- @param side "Left" | "Right"
function PeekHandler:Begin(side: string)
	local hrp = self:_getHRP()
	if not hrp then
		return
	end

	local coverNormal = self._state.coverNormal
	if not coverNormal then
		return
	end

	-- wallRight = Up × Normal (misma convención que InCover)
	local wallRight = Vector3.yAxis:Cross(coverNormal)
	if wallRight.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	wallRight = wallRight.Unit

	-- Mantener un origen estable durante todo el ciclo de peek para
	-- evitar drift cuando Begin/End se alternan en frames rápidos.
	if not self._startPos then
		self._startPos = hrp.Position
	end
	self._peekSide = side

	local basePos = self._startPos
	if not basePos then
		basePos = hrp.Position
		self._startPos = basePos
	end

	local direction = if side == "Right" then 1 else -1
	self._targetPos = basePos + wallRight * direction * Constants.PEEK_OFFSET_STUDS

	self._isActive = true
	self._returning = false

	if Constants.DEBUG_MODE then
		print(
			string.format(
				"[PeekHandler] BEGIN side=%s | start=(%.1f,%.1f,%.1f) → target=(%.1f,%.1f,%.1f)",
				side,
				basePos.X,
				basePos.Y,
				basePos.Z,
				self._targetPos.X,
				self._targetPos.Y,
				self._targetPos.Z
			)
		)
	end
end

--- Inicia el retorno a la posición original y resetea rotación a coverNormal.
function PeekHandler:End()
	if not self._isActive then
		return
	end

	if not self._startPos then
		self._isActive = false
		return
	end

	-- Resetear rotación hacia la pared (coverNormal = convención cover)
	local hrp = self:_getHRP()
	local coverNormal = self._state.coverNormal
	if hrp and coverNormal then
		local flatNormal = Vector3.new(coverNormal.X, 0, coverNormal.Z)
		if flatNormal.Magnitude > Constants.ZERO_MAGNITUDE then
			hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + flatNormal.Unit)
		end
	end

	-- Invertir: ahora el target es la posición de inicio
	self._targetPos = self._startPos
	self._returning = true

	if Constants.DEBUG_MODE then
		print("[PeekHandler] END → returning to startPos")
	end
end

--- Cancela el peek inmediatamente sin restaurar posición.
function PeekHandler:Cancel()
	if not self._isActive then
		return
	end

	self._isActive = false
	self._returning = false
	self._startPos = nil
	self._targetPos = nil
	self._peekSide = nil

	local hrp = self:_getHRP()
	if hrp then
		-- Solo anular componente XZ, preservar Y
		local vel = hrp.AssemblyLinearVelocity
		hrp.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0)
	end

	if Constants.DEBUG_MODE then
		print("[PeekHandler] CANCELLED")
	end
end

--- Actualiza el movimiento P-controller cada frame.
--- @param dt number — delta time
function PeekHandler:Update(dt: number)
	if not self._isActive then
		return
	end

	local hrp = self:_getHRP()
	if not hrp or not self._targetPos then
		self._isActive = false
		self._returning = false
		self._startPos = nil
		self._targetPos = nil
		self._peekSide = nil
		return
	end

	local pos = hrp.Position
	local delta = self._targetPos - pos
	-- Solo mover en XZ, preservar Y
	local flatDelta = Vector3.new(delta.X, 0, delta.Z)
	local dist = flatDelta.Magnitude

	if dist < ARRIVAL_THRESHOLD then
		-- Llegamos al target
		local vel = hrp.AssemblyLinearVelocity
		hrp.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0)

		if self._returning then
			-- Snap exacto a la posición de origen (elimina drift residual)
			local exactPos = self._startPos
			if exactPos then
				hrp.CFrame = CFrame.new(exactPos.X, hrp.Position.Y, exactPos.Z) * hrp.CFrame.Rotation
			end
			-- Retorno completado: desactivar
			self._isActive = false
			self._returning = false
			self._startPos = nil
			self._targetPos = nil
			self._peekSide = nil
			if Constants.DEBUG_MODE then
				print("[PeekHandler] RETURN COMPLETE — snapped to exact startPos")
			end
		end
		return
	end

	-- P-controller: velocidad proporcional a distancia, clampeada a PEEK_MOVE_SPEED
	if dt > 0 then
		local desiredVel = flatDelta / dt
		if desiredVel.Magnitude > PEEK_MOVE_SPEED then
			desiredVel = desiredVel.Unit * PEEK_MOVE_SPEED
		end
		hrp.AssemblyLinearVelocity = Vector3.new(desiredVel.X, hrp.AssemblyLinearVelocity.Y, desiredVel.Z)
	end
end

--- Retorna true si el peek está activo (moviendo o en posición de peek).
function PeekHandler:IsActive(): boolean
	return self._isActive
end

--- Retorna el lado actual del peek ("Left" o "Right"), o nil.
function PeekHandler:GetPeekSide(): string?
	return self._peekSide
end

--- Retorna la posición de origen del peek (donde estaba el HRP al iniciar).
function PeekHandler:GetStartPos(): Vector3?
	return self._startPos
end

------------------------------------------------------------------------
-- INTERNAL
------------------------------------------------------------------------

function PeekHandler:_getHRP(): BasePart?
	return CoverMovementUtils.getHRP(self._state, self)
end

return PeekHandler
