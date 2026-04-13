--[[
	CoverRules/init.luau
	═══════════════════════════════════════════════════════════════
	Coordinador de reglas de cover — API pública unificada.

	Estructura interna:
	  - SharedRules.luau    — reglas compartidas (ExitCover, PopUpAim, etc.)
	  - AimRules.luau       — Aim, CoverFiring, Peek, BlindFire
	  - MovementRules.luau  — Idle, Walking, Running
	  - TransitionRules.luau — Entering, Swap

	Este init exporta la misma API que el CoverRules.luau original:
	  CoverRules.Aim, CoverRules.CoverFiring, CoverRules.BlindFire,
	  CoverRules.Peek, CoverRules.Idle, CoverRules.Walking,
	  CoverRules.Running, CoverRules.Entering, CoverRules.Swap,
	  CoverRules.SubRules
]]

local AimRules = require(script:WaitForChild("AimRules"))
local MovementRules = require(script:WaitForChild("MovementRules"))
local TransitionRules = require(script:WaitForChild("TransitionRules"))

local CoverRules = {}

------------------------------------------------------------------------
-- EXPORT: Tablas de reglas por categoría
------------------------------------------------------------------------

-- Aim-related
CoverRules.Aim = AimRules.Aim
CoverRules.CoverFiring = AimRules.CoverFiring
CoverRules.BlindFire = AimRules.BlindFire
CoverRules.Peek = AimRules.Peek

-- Movement-related
CoverRules.Idle = MovementRules.Idle
CoverRules.Walking = MovementRules.Walking
CoverRules.Running = MovementRules.Running

-- Transition-related
CoverRules.Entering = TransitionRules.Entering
CoverRules.Swap = TransitionRules.Swap

------------------------------------------------------------------------
-- SUB-STATE MAPPING
-- Los nuevos estados de cover (CoverCorners) usan Idle como fallback.
-- CoverSwap se maneja en ActionResolver/init.luau (es ActionGroup).
------------------------------------------------------------------------

CoverRules.SubRules = {
	CoverAim = CoverRules.Aim,
	CoverAimHigh = CoverRules.Aim,
	CoverAimLow = CoverRules.Aim,
	CoverPeek = CoverRules.Peek,
	CoverFiring = CoverRules.CoverFiring,
	CoverBlindFire = CoverRules.BlindFire,
	CoverIdle = CoverRules.Idle,
	CoverWalking = CoverRules.Walking,
	CoverRunning = CoverRules.Running,
	CoverCorners = CoverRules.Idle,
}

return CoverRules
