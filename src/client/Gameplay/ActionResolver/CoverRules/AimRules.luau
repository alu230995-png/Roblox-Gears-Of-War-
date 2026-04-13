--[[
	AimRules.luau
	═══════════════════════════════════════════════════════════════
	Reglas de apuntado desde cover:
	  - Aim (CoverAimHigh, CoverAimLow)
	  - CoverFiring
	  - Peek
	  - BlindFire (estado)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Helpers = require(script.Parent.Parent:WaitForChild("Helpers"))
local SharedRules = require(script.Parent:WaitForChild("SharedRules"))

local AimRules = {}

------------------------------------------------------------------------
-- COVER AIM RULES
------------------------------------------------------------------------

AimRules.Aim = {
	SharedRules.ExitCover, -- Prio 1: Salir de cover

	-- Prio 2: Cámara en la deadzone → salir de aim inmediatamente
	{
		id = "ReturnToCoverDeadzone",
		check = function(_resolver, ctx)
			local wantsAim = ctx.Intents:HasIntent("WantsAim")
			local inDeadzone = SharedRules.isAimDeadzone(ctx)
			if Constants.DEBUG_MODE and (wantsAim and inDeadzone) then
				print("[AimDebug] ReturnToCoverDeadzone CHECK PASSED — WantsAim=true + deadzone=true")
			end
			return wantsAim and inDeadzone
		end,
		execute = function()
			if Constants.DEBUG_MODE then
				print("[AimDebug] ReturnToCoverDeadzone EXECUTE → CoverIdle")
			end
			return "ReturnToCover", "CoverIdle", nil
		end,
	},

	-- Prio 3: Soltó el hold de aim
	{
		id = "ReturnToCover",
		check = function(_resolver, ctx)
			local wantsAim = ctx.Intents:HasIntent("WantsAim")
			if Constants.DEBUG_MODE then
				print(`[AimDebug] ReturnToCover CHECK — WantsAim={wantsAim} → pass={not wantsAim}`)
			end
			return not wantsAim
		end,
		execute = function()
			if Constants.DEBUG_MODE then
				print("[AimDebug] ReturnToCover EXECUTE → CoverIdle")
			end
			return "ReturnToCover", "CoverIdle", nil
		end,
	},

	-- Prio 4: Peek en esquina (aim + lateral input > threshold)
	SharedRules.EnterPeek,

	-- Prio 5: Disparo desde cover aim
	{
		id = "ShootFromCover",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsShoot")
		end,
		execute = function()
			return "Shoot", "CoverFiring", nil
		end,
	},
}

------------------------------------------------------------------------
-- COVER FIRING RULES
------------------------------------------------------------------------

AimRules.CoverFiring = {
	SharedRules.ExitCover, -- Prio 1

	-- Prio 2: Deadzone → salir de aim y disparo completamente
	-- NOTA: Deadzone NO aplica si el peek está activo.
	{
		id = "CancelCoverFiringDeadzone",
		check = function(_resolver, ctx)
			if ctx.Env.IsPeekActive then
				return false
			end
			return ctx.Intents:HasIntent("WantsAim") and SharedRules.isAimDeadzone(ctx)
		end,
		execute = function()
			return "ReturnToCover", "CoverIdle", nil
		end,
	},

	-- Prio 3: Soltó el hold de aim
	{
		id = "CancelCoverFiring",
		check = function(_resolver, ctx)
			return not ctx.Intents:HasIntent("WantsAim")
		end,
		execute = function()
			return "ReturnToCover", "CoverIdle", nil
		end,
	},

	-- Prio 4: Soltó el gatillo pero sigue apuntando
	{
		id = "StopCoverFiring",
		check = function(_resolver, ctx)
			return not ctx.Intents:HasIntent("WantsShoot")
		end,
		execute = function(_resolver, ctx)
			if ctx.Env.IsPeekActive then
				return "ReturnToAim", "CoverPeek", nil
			end
			local coverType = ctx.Env.ActiveCoverType
			if coverType == "High" then
				return "ReturnToAim", "CoverAimHigh", nil
			elseif coverType == "Low" then
				return "ReturnToAim", "CoverAimLow", nil
			end
			return "ReturnToCover", "CoverIdle", nil
		end,
	},
}

------------------------------------------------------------------------
-- COVER BLIND FIRE RULES
------------------------------------------------------------------------

AimRules.BlindFire = {
	{
		id = "StopBlindFire",
		check = function(_resolver, ctx)
			-- BlindFire se activa con WantsBlindFire O con WantsShoot sin WantsAim.
			-- Debe permanecer activo mientras cualquiera de las dos condiciones se mantenga.
			local wantsBlindFire = ctx.Intents:HasIntent("WantsBlindFire")
			local wantsShootNoAim = ctx.Intents:HasIntent("WantsShoot") and not ctx.Intents:HasIntent("WantsAim")
			return not wantsBlindFire and not wantsShootNoAim
		end,
		execute = function()
			return "StopBlindFire", "CoverIdle", nil
		end,
	},
}

------------------------------------------------------------------------
-- COVER PEEK RULES
------------------------------------------------------------------------

AimRules.Peek = {
	SharedRules.ExitCover, -- Prio 1

	-- Prio 2: Soltó aim
	{
		id = "ReturnToCoverFromPeek",
		check = function(_resolver, ctx)
			return not ctx.Intents:HasIntent("WantsAim")
		end,
		execute = function()
			return "ExitPeek", "CoverIdle", nil
		end,
	},

	-- Prio 3: Input lateral bajo el umbral o ya no en esquina
	-- IMPORTANTE: No salir de peek si el jugador está disparando.
	{
		id = "ExitPeek",
		check = function(_resolver, ctx)
			if ctx.Intents:HasIntent("WantsShoot") then
				return false
			end
			if not ctx.Env.IsInActiveCover then
				return true
			end
			local lateralScale = Helpers.computeSignedLateralScale(ctx)
			local atRight = ctx.Env.ActiveAtCornerRight
			local atLeft = ctx.Env.ActiveAtCornerLeft
			if atRight and lateralScale >= Constants.PEEK_INPUT_THRESHOLD then
				return false
			end
			if atLeft and lateralScale <= -Constants.PEEK_INPUT_THRESHOLD then
				return false
			end
			return true
		end,
		execute = function(_resolver, ctx)
			local coverType = ctx.Env.ActiveCoverType
			if coverType == "High" then
				return "ExitPeek", "CoverAimHigh", nil
			else
				return "ExitPeek", "CoverAimLow", nil
			end
		end,
	},

	-- Prio 4: Disparo desde peek
	{
		id = "ShootFromPeek",
		check = function(_resolver, ctx)
			return ctx.Intents:HasIntent("WantsShoot")
		end,
		execute = function()
			return "Shoot", "CoverFiring", nil
		end,
	},
}

return AimRules
