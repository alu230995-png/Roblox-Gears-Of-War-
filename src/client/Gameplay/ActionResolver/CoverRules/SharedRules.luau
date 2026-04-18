--[[
	SharedRules.luau
	═══════════════════════════════════════════════════════════════
	Reglas compartidas reutilizadas en múltiples sub-estados de cover.
	Exporta reglas individuales que se insertan en las tablas de prioridad.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Helpers = require(script.Parent.Parent:WaitForChild("Helpers"))
local AimAngleUtils = require(script.Parent.Parent.Parent:WaitForChild("Aiming"):WaitForChild("AimAngleUtil"))

local SharedRules = {}

------------------------------------------------------------------------
-- DEADZONE HELPER (delegado a AimAngleUtils)
------------------------------------------------------------------------

function SharedRules.isAimDeadzone(ctx): boolean
	return AimAngleUtils.IsAimDeadzone(
		ctx.Env.ActiveCoverNormal,
		ctx.Env.ActiveCoverType,
		Constants.COVER_AIM_DEADZONE_ANGLE
	)
end

------------------------------------------------------------------------
-- SHARED COVER RULES
------------------------------------------------------------------------

SharedRules.ExitCover = {
	id = "ExitCover",
	check = function(_resolver, ctx)
	-- Intent buffered o continuo (ej: desde binding directo)
	if ctx.Buffer:HasIntent("WantsExitCover") or ctx.Intents:HasIntent("WantsExitCover") then
		return true
	end

	-- Si el sensor perdió pared de respaldo, forzar salida de cover.
	if ctx.Env.IsInActiveCover and ctx.Env.HasActiveCoverBehind == false then
		return true
	end

	-- Detección vectorial cross-platform: humanoid.MoveDirection · coverNormal > umbral
	-- Si el dot product es positivo, el jugador empuja HACIA la normal (alejándose de la pared)
	local coverNormal = ctx.Env.ActiveCoverNormal
	if not coverNormal then
		return false
	end
	local character = Players.LocalPlayer.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false
	end
	local moveDir = humanoid.MoveDirection
	if moveDir.Magnitude < Constants.MOVE_DIRECTION_THRESHOLD then
		return false
	end
	return moveDir:Dot(coverNormal) > Constants.EXIT_COVER_BACK_THRESHOLD
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsExitCover")
		return "ExitCover", "CoverExiting", nil
	end,
}

SharedRules.RollOutOfCover = {
	id = "RollOutOfCover",
	check = function(resolver, ctx)
		return ctx.Buffer:HasIntent("WantsEvade") and Helpers.isEvadeCooldownMet(resolver)
	end,
	execute = function(resolver, ctx)
		resolver._evadeStartTime = os.clock()
		ctx.Buffer:Consume("WantsEvade")
		return "RollOutOfCover", "Evading", nil
	end,
}

--- CornerRollOut (fallback de CoverSwap): En esquina exterior + WantsCover
--- y NO se encontró swap válido + dirección MUY lateral (≈ paralela a la pared) →
--- roll completo con marometa (misma animación/sonido que Evade).
SharedRules.CornerRollOut = {
	id = "CornerRollOut",
	check = function(resolver, ctx)
		return ctx.Env.IsAtOuterCorner
			and ctx.Buffer:HasIntent("WantsCover")
			and Helpers.isEvadeCooldownMet(resolver)
			and Helpers.computeLateralScale(ctx) >= Constants.EXIT_CORNER_LATERAL_THRESHOLD
	end,
	execute = function(resolver, ctx)
		resolver._evadeStartTime = os.clock()
		ctx.Buffer:Consume("WantsCover")
		local dir = ctx.Env.RawMovementDirection or ctx.Env.CornerExitDirection
		return "CornerRollOut", "Evading", { direction = dir }
	end,
}

--- ExitCorner (fallback de CoverSwap): En esquina exterior + WantsCover
--- y NO se encontró swap válido + dirección DIAGONAL (no puramente lateral) →
--- salida rápida sin marometa, misma física pero duración más corta.
SharedRules.ExitCorner = {
	id = "ExitCorner",
	check = function(resolver, ctx)
		return ctx.Env.IsAtOuterCorner
			and ctx.Buffer:HasIntent("WantsCover")
			and Helpers.isEvadeCooldownMet(resolver)
			and Helpers.computeLateralScale(ctx) < Constants.EXIT_CORNER_LATERAL_THRESHOLD
	end,
	execute = function(resolver, ctx)
		resolver._evadeStartTime = os.clock()
		ctx.Buffer:Consume("WantsCover")
		local dir = ctx.Env.RawMovementDirection or ctx.Env.CornerExitDirection
		return "ExitCorner", "ExitCorner", { direction = dir }
	end,
}

SharedRules.PopUpAim = {
	id = "PopUpAim",
	check = function(_resolver, ctx)
		return ctx.Intents:HasIntent("WantsAim") and not SharedRules.isAimDeadzone(ctx)
	end,
	execute = function(_resolver, ctx)
		local coverType = ctx.Env.ActiveCoverType
		if coverType == "Low" then
			return "PopUpAim", "CoverAimLow", nil
		end
		-- High o desconocido → CoverAimHigh (tiene transiciones completas a Peek/Firing)
		return "PopUpAim", "CoverAimHigh", nil
	end,
}

SharedRules.BlindFire = {
	id = "BlindFire",
	check = function(_resolver, ctx)
		return (
			ctx.Intents:HasIntent("WantsBlindFire")
			or (ctx.Intents:HasIntent("WantsShoot") and not ctx.Intents:HasIntent("WantsAim"))
		) and not SharedRules.isAimDeadzone(ctx)
	end,
	execute = function()
		return "BlindFire", "CoverBlindFire", nil
	end,
}

SharedRules.EnterPeek = {
	id = "EnterPeek",
	check = function(_resolver, ctx)
		-- Solo desde aim states (apuntando desde cover)
		if ctx.State ~= "CoverAimHigh" and ctx.State ~= "CoverAimLow" and ctx.State ~= "CoverAim" then
			return false
		end
		if not ctx.Intents:HasIntent("WantsAim") then
			return false
		end
		if not ctx.Env.IsInActiveCover then
			return false
		end
		local lateralScale = Helpers.computeSignedLateralScale(ctx)
		local atRight = ctx.Env.ActiveAtCornerRight
		local atLeft = ctx.Env.ActiveAtCornerLeft
		if atRight and lateralScale >= Constants.PEEK_INPUT_THRESHOLD then
			return true
		end
		if atLeft and lateralScale <= -Constants.PEEK_INPUT_THRESHOLD then
			return true
		end
		return false
	end,
	execute = function(_resolver, ctx)
		local lateralScale = Helpers.computeSignedLateralScale(ctx)
		local side = if lateralScale > 0 then "Right" else "Left"
		return "EnterPeek", "CoverPeek", { side = side }
	end,
}

SharedRules.ReloadInCover = {
	id = "ReloadInCover",
	check = function(_resolver, ctx)
		return ctx.Buffer:HasIntent("WantsReload")
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsReload")
		return "Reload", nil, nil
	end,
}

SharedRules.BlockCoverTap = {
	id = "BlockCoverTap",
	check = function(_resolver, ctx)
		return ctx.Buffer:HasIntent("WantsCover")
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsCover") -- batch consumption limpia WantsMantle + WantsEvade
		return "NoAction", nil, nil
	end,
}

SharedRules.VaultFromCover = {
	id = "VaultFromCover",
	check = function(_resolver, ctx)
		if
			not (
				ctx.Env.IsInActiveCover
				and ctx.Buffer:HasIntent("WantsCover")
				and ctx.Env.ActiveCoverType == "Low"
				and Helpers.isMovingIntoCover(ctx, ctx.Env.ActiveCoverNormal)
			)
		then
			return false
		end
		return Helpers.preCheckVault(ctx, ctx.Env.ActiveCoverNormal, ctx.Env.ActiveCoverInstance)
	end,
	execute = function(_resolver, ctx)
		ctx.Buffer:Consume("WantsCover")
		local vd = ctx._vaultData
		return "Vault",
			"Vaulting",
			{
				coverNormal = ctx.Env.ActiveCoverNormal,
				coverInstance = ctx.Env.ActiveCoverInstance,
				landingPos = vd.landingPos,
				landingType = vd.landingType,
			}
	end,
}

return SharedRules
