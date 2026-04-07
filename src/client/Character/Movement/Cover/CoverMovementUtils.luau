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
--- Anula la componente de velocidad perpendicular si el error excede el umbral.
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

	if math.abs(err) > Constants.COVER_GLUE_MAX_DIST then
		local correction = coverNormal * err
		hrp.CFrame = hrp.CFrame - Vector3.new(correction.X, 0, correction.Z)

		local vel = hrp.AssemblyLinearVelocity
		hrp.AssemblyLinearVelocity = vel - coverNormal * vel:Dot(coverNormal)
	end
end

--- Interpola la orientación del HRP hacia coverNormal (exponential smoothing,
--- frame-rate independent).
--- @param state table — coverState compartido (coverNormal)
--- @param hrp BasePart — HumanoidRootPart
--- @param dt number — delta time
function CoverMovementUtils.smoothRotation(state: any, hrp: BasePart, dt: number)
	local coverNormal = state.coverNormal
	if not coverNormal then
		return
	end

	local pos = hrp.Position
	local targetCF = CFrame.lookAt(pos, pos + coverNormal)
	hrp.CFrame = hrp.CFrame:Lerp(targetCF, 1 - math.exp(-Constants.CORNER_TURN_SPEED * dt))
end

return CoverMovementUtils
