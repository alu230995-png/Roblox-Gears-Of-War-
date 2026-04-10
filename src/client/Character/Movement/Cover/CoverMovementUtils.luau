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
