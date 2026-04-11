--[[
	VaultHandler.luau
	═══════════════════════════════════════════════════════════════
	Vault over low cover — Bezier 3D kinematic movement
	═══════════════════════════════════════════════════════════════
	
	Ejecuta el salto sobre cover baja usando una curva Bézier cuadrática:
	  B(t) = (1-t)²·P0 + 2(1-t)·t·P1 + t²·P2
	
	- P0: posición del personaje al iniciar el vault
	- P1: punto de control (midpoint elevado)
	- P2: landing position (validado por EnvironmentSensor)
	
	Gestiona:
	  - NoCollisionConstraint para ignorar la cover durante el vault
	  - Validación de seguridad via EnvironmentSensor:CheckVaultSafety
	  - Restauración de colisión al VAULT_COLLISION_RESTORE_PROGRESS
	  - Fallback: si safety check falla → abortar y volver a Idle
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local REMOTE_SOUND_REPLICATE = "SoundReplicate"
local SOUND_VAULT = "VFX_Vault"

local VaultHandler = {}
VaultHandler.__index = VaultHandler

local VAULT_ACTIONS: { [string]: boolean } = table.freeze({
	Vault = true,
})

function VaultHandler.new(stateMachine, coverHandler, environmentSensor)
	local self = setmetatable({}, VaultHandler)

	self._stateMachine = stateMachine
	self._coverHandler = coverHandler
	self._envSensor = environmentSensor
	self._player = Players.LocalPlayer

	-- Vault state
	self._active = false
	self._elapsed = 0
	self._duration = Constants.VAULT_DURATION
	self._p0 = nil :: Vector3?
	self._p1 = nil :: Vector3?
	self._p2 = nil :: Vector3?
	self._coverInstance = nil :: BasePart?
	self._noCollision = nil :: NoCollisionConstraint?
	self._collisionRestored = false
	self._landingType = nil :: string? -- "through" | "top"

	-- Cache de character refs (evita FindFirstChild cada frame durante vault)
	self._cachedCharacter = nil :: Model?
	self._cachedHRP = nil :: BasePart?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function VaultHandler:HandleAction(action: string, data: any?): boolean
	if not VAULT_ACTIONS[action] then
		return false
	end

	self:_startVault(data)
	return true
end

function VaultHandler:Update(dt: number)
	if not self._active then
		return
	end

	self._elapsed += dt
	local t = math.clamp(self._elapsed / self._duration, 0, 1)

	-- Restore collision before vault ends.
	-- "top" vaults: restaurar en el pico del arco (t=0.5) para que el personaje
	-- aterrice encima de la cover sin atravesarla.
	-- "through" vaults: restaurar tarde (t=0.85) para no colisionar al cruzar.
	if not self._collisionRestored then
		local restoreThreshold = if self._landingType == "top"
			then Constants.VAULT_COLLISION_RESTORE_TOP
			else Constants.VAULT_COLLISION_RESTORE_PROGRESS
		if t >= restoreThreshold then
			self:_restoreCollision()
			self._collisionRestored = true
		end
	end

	-- Validate cover instance still exists
	if self._coverInstance and not self._envSensor:ValidateCoverInstance(self._coverInstance) then
		self:_finishVault()
		return
	end

	-- Bezier interpolation
	local hrp = self:_getHRP()
	if not hrp then
		self:_finishVault()
		return
	end

	if t >= 1 then
		-- Vault complete — snap to landing
		hrp.CFrame = CFrame.new(self._p2)
			* CFrame.Angles(0, math.atan2(-hrp.CFrame.LookVector.X, -hrp.CFrame.LookVector.Z), 0)
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)
		self:_finishVault()
		return
	end

	-- B(t) = (1-t)²·P0 + 2(1-t)·t·P1 + t²·P2
	local oneMinusT = 1 - t
	local pos = oneMinusT * oneMinusT * self._p0 + 2 * oneMinusT * t * self._p1 + t * t * self._p2

	-- Kinematic: override position, kill horizontal velocity
	hrp.CFrame = CFrame.new(pos) * CFrame.Angles(0, math.atan2(-hrp.CFrame.LookVector.X, -hrp.CFrame.LookVector.Z), 0)
	hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
end

function VaultHandler:IsVaulting(): boolean
	return self._active
end

------------------------------------------------------------------------
-- INTERNAL
------------------------------------------------------------------------

function VaultHandler:_startVault(data: any?)
	local hrp = self:_getHRP()
	if not hrp or not data then
		return
	end

	local coverNormal = data.coverNormal
	local coverInstance = data.coverInstance
	if not coverNormal or not coverInstance then
		return
	end

	-- Forward direction: into the cover (-normal), horizontal only
	local forwardDir = -Vector3.new(coverNormal.X, 0, coverNormal.Z)
	if forwardDir.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	forwardDir = forwardDir.Unit

	-- Safety check:
	-- Normal vault path (from CoverRules / FreeStateRules): pre-validated por ActionResolver
	--   → data contiene landingPos + landingType, no hay que volver a lanzar raycasts.
	-- VaultFromEntering: deferred path, data NO tiene landing info → fallback con raycasts.
	local isSafe: boolean
	local landingPos: Vector3?
	local landingType: string?
	if data.landingPos then
		isSafe, landingPos, landingType = true, data.landingPos, data.landingType
	else
		isSafe, landingPos, landingType =
			self._envSensor:CheckVaultSafety(hrp.Position, forwardDir, self._cachedCharacter, coverInstance)
	end
	if not isSafe or not landingPos then
		if Constants.DEBUG_MODE then
			print("[VaultHandler] Safety check FAILED — aborting vault")
		end
		-- Revert state
		self._stateMachine:TransitionTo("Idle")
		return
	end

	-- Compute Bezier control points
	local startPos = hrp.Position

	local coverTopY = coverInstance.Position.Y + (coverInstance.Size.Y * 0.5)
	local hipHeight = Constants.COVER_DEFAULT_HIP_HEIGHT

	-- P2.Y depende de si el vault es "through" (al otro lado) o "top" (encima de la cover)
	local endY: number
	if landingType == "top" then
		-- Queda encima de la cover (cover ancha o sin suelo al otro lado)
		endY = coverTopY + hipHeight
	else
		-- Atraviesa al otro lado: aterriza en el suelo real
		endY = landingPos.Y + hipHeight
	end
	local endPos = Vector3.new(landingPos.X, endY, landingPos.Z)

	local midPoint = (startPos + endPos) / 2
	local controlPoint = midPoint + Vector3.new(0, Constants.VAULT_ARC_HEIGHT, 0)

	self._p0 = startPos
	self._p1 = controlPoint
	self._p2 = endPos
	self._coverInstance = coverInstance
	self._elapsed = 0
	self._collisionRestored = false
	self._landingType = landingType
	self._active = true

	-- Lock state machine
	self._stateMachine:Lock()

	-- Reset cover (exit cover state cleanly)
	self._coverHandler:ResetCover()

	-- NoCollisionConstraint: ignore cover part during vault
	self:_disableCollision(hrp, coverInstance)

	local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
	if remotesFolder then
		local soundReplicate = remotesFolder:FindFirstChild(REMOTE_SOUND_REPLICATE)
		if soundReplicate and soundReplicate:IsA("RemoteEvent") then
			soundReplicate:FireServer(SOUND_VAULT, hrp.Position)
		end
	end

	if Constants.DEBUG_MODE then
		print(
			string.format(
				"[VaultHandler] START — P0=(%.1f,%.1f,%.1f) P2=(%.1f,%.1f,%.1f) duration=%.2fs",
				startPos.X,
				startPos.Y,
				startPos.Z,
				endPos.X,
				endPos.Y,
				endPos.Z,
				self._duration
			)
		)
	end
end

function VaultHandler:_finishVault()
	self:_restoreCollision()
	self._active = false
	self._p0 = nil
	self._p1 = nil
	self._p2 = nil
	self._coverInstance = nil
	self._landingType = nil

	self._stateMachine:Unlock()
	self._stateMachine:TransitionTo("Idle")
end

function VaultHandler:_disableCollision(hrp: BasePart, coverPart: BasePart)
	-- Cleanup any existing constraint
	self:_restoreCollision()

	local constraint = Instance.new("NoCollisionConstraint")
	constraint.Part0 = hrp
	constraint.Part1 = coverPart
	constraint.Parent = hrp
	self._noCollision = constraint
end

function VaultHandler:_restoreCollision()
	if self._noCollision then
		self._noCollision:Destroy()
		self._noCollision = nil
	end
end

--- Obtiene el HumanoidRootPart del personaje local con cache (nil si no existe).
function VaultHandler:_getHRP(): BasePart?
	local character = self._player.Character
	if not character then
		self._cachedCharacter = nil
		self._cachedHRP = nil
		return nil
	end
	if character ~= self._cachedCharacter then
		self._cachedCharacter = character
		self._cachedHRP = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return self._cachedHRP
end

return VaultHandler
