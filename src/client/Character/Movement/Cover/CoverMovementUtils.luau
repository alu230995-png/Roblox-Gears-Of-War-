--[[
	CoverMovementUtils.luau
	═══════════════════════════════════════════════════════════════
	Helpers compartidos para InCover y CoverRunning
	═══════════════════════════════════════════════════════════════

	Centraliza _applyWallGlue y _smoothRotation, que antes vivían
	duplicados en InCover y CoverRunning con implementaciones
	byte-for-byte idénticas.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local CoverMovementUtils = {}

------------------------------------------------------------------------
-- BUG-010 fix: shared _getHRP() (was tripled in CoverRunning, InCover,
-- CoverSwapController). Each caller passes its cached refs table.
------------------------------------------------------------------------

--- Obtiene el HumanoidRootPart del personaje local con cache.
--- @param state table — coverState compartido (state.player.Character)
--- @param cache table — tabla con _cachedCharacter y _cachedHRP
--- @return BasePart? — nil si no hay character
function CoverMovementUtils.getHRP(state: any, cache: any): BasePart?
	local character = state.player.Character
	if not character then
		cache._cachedCharacter = nil
		cache._cachedHRP = nil
		return nil
	end
	if character ~= cache._cachedCharacter then
		cache._cachedCharacter = character
		cache._cachedHRP = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return cache._cachedHRP
end

--- Detecta y ejecuta transición de esquina interna.
--- Actualiza coverState, hace crossover push, aplica cooldown,
--- notifica cámara, y recalcula el riel.
--- @param state table — coverState compartido
--- @param hrp BasePart — HumanoidRootPart
--- @param coverNormal Vector3 — normal actual de cover
--- @param wallRight Vector3 — riel actual (unitario)
--- @param movementScale number — dot product del movimiento sobre wallRight
--- @param moveDirWorld Vector3 — dirección de movimiento en world space
--- @return Vector3 coverNormal — normal actualizada (puede cambiar)
--- @return Vector3 wallRight — riel actualizado (puede cambiar)
--- @return number movementScale — proyección actualizada
--- @return boolean transitioned — true si hubo transición
function CoverMovementUtils.handleInnerCornerTransition(
	state: any,
	hrp: BasePart,
	coverNormal: Vector3,
	wallRight: Vector3,
	movementScale: number,
	moveDirWorld: Vector3
): (Vector3, Vector3, number, boolean)
	local sensor = state.envSensor
	if not sensor then
		return coverNormal, wallRight, movementScale, false
	end

	local newNormal, newPosition, newInstance = sensor:CheckInnerCorner(hrp, coverNormal, wallRight, movementScale)

	if not newNormal then
		return coverNormal, wallRight, movementScale, false
	end

	-- A) Actualizar estado compartido con la nueva pared
	state.coverNormal = newNormal
	state.coverPosition = newPosition
	state.coverInstance = newInstance

	-- FIX: verificar magnitud antes de .Unit — si newNormal es cercana al eje Y
	-- (normal vertical), el cross product es casi cero y .Unit produce NaN.
	local rawRight = Vector3.yAxis:Cross(newNormal)
	if rawRight.Magnitude < Constants.ZERO_MAGNITUDE then
		-- Normal degenerate (vertical): abortar transición sin corromper estado.
		state.coverNormal = coverNormal
		state.coverPosition = nil
		state.coverInstance = nil
		return coverNormal, wallRight, movementScale, false
	end
	state.wallRight = rawRight.Unit

	-- B) Crossover push: empujar al personaje pasada la juntura
	local newWallRight = state.wallRight
	local pushDir = newWallRight * math.sign(movementScale)
	hrp.CFrame = hrp.CFrame + pushDir * Constants.CORNER_CROSSOVER_PUSH

	-- C) Notificar a la cámara para nudge de yaw hacia la nueva normal
	state.onInnerCornerTransition:Fire(newNormal)

	-- D) Recalcular el riel y la proyección con la nueva normal
	coverNormal = newNormal
	wallRight = Vector3.yAxis:Cross(coverNormal)
	if wallRight.Magnitude < Constants.ZERO_MAGNITUDE then
		return coverNormal, wallRight, 0, true
	end
	wallRight = wallRight.Unit
	movementScale = moveDirWorld:Dot(wallRight)

	return coverNormal, wallRight, movementScale, true
end

--- Corrige la posición del HRP para mantenerlo pegado a la pared de cover.
--- Usa corrección basada en velocidad (no CFrame snap) para evitar luchar
--- contra el motor de física. Converge en 2-3 frames sin provocar respuestas
--- de colisión espurias.
--- @param state table — coverState compartido (coverNormal, coverPosition)
--- @param hrp BasePart — HumanoidRootPart
function CoverMovementUtils.applyWallGlue(state: any, hrp: BasePart)
	local coverNormal = state.coverNormal
	local coverPosition = state.coverPosition
	if not coverNormal or not coverPosition then
		return
	end

	local toPlayer = hrp.Position - coverPosition
	local perpDist = toPlayer:Dot(coverNormal)
	local err = perpDist - Constants.COVER_OFFSET

	-- Siempre anular la componente de velocidad perpendicular a la pared
	-- para prevenir drift acumulativo, independientemente del error.
	local vel = hrp.AssemblyLinearVelocity
	local perpVel = coverNormal * vel:Dot(coverNormal)

	if math.abs(err) > Constants.COVER_GLUE_MAX_DIST then
		-- Inyectar velocidad correctiva proporcional al error en vez de snap de CFrame.
		-- El motor de física integra esta velocidad naturalmente sin generar colisiones.
		local correctionVel = coverNormal * -err * Constants.COVER_GLUE_CORRECTION_SPEED
		hrp.AssemblyLinearVelocity =
			Vector3.new(vel.X - perpVel.X + correctionVel.X, vel.Y, vel.Z - perpVel.Z + correctionVel.Z)
	else
		-- Sin error significativo: solo limpiar componente perpendicular
		hrp.AssemblyLinearVelocity = vel - perpVel
	end
end

--- Interpola la orientación del HRP hacia coverNormal (exponential smoothing,
--- frame-rate independent). Solo toca ROTACIÓN — nunca modifica posición.
--- @param state table — coverState compartido (coverNormal)
--- @param hrp BasePart — HumanoidRootPart
--- @param dt number — delta time
function CoverMovementUtils.smoothRotation(state: any, hrp: BasePart, dt: number)
	local coverNormal = state.coverNormal
	if not coverNormal then
		return
	end

	local targetRot = CFrame.lookAt(Vector3.zero, coverNormal).Rotation
	local alpha = 1 - math.exp(-Constants.CORNER_TURN_SPEED * dt)
	hrp.CFrame = CFrame.new(hrp.Position) * hrp.CFrame.Rotation:Lerp(targetRot, alpha)
end

return CoverMovementUtils
