--[[
	MuzzleFlashEffect.luau
	═══════════════════════════════════════════════════════════════
	Flash + PointLight en el muzzle del arma al disparar.
	═══════════════════════════════════════════════════════════════
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local EffectsConfig = require(Shared:WaitForChild("EffectsConfig"))
local EffectsConstants = require(Shared:WaitForChild("EffectsConstants"))

local MuzzleFlashEffect = {}
MuzzleFlashEffect.__index = MuzzleFlashEffect

function MuzzleFlashEffect.new()
	local self = setmetatable({}, MuzzleFlashEffect)
	return self
end

function MuzzleFlashEffect:Destroy() end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

function MuzzleFlashEffect:Fire(character: Model?, weaponName: string, hasActiveReload: boolean?)
	if not character then
		return
	end

	local config = EffectsConfig.WEAPONS[weaponName]
	if not config or not config.MuzzleFlash then
		return
	end

	local muzzleConfig = config.MuzzleFlash
	if hasActiveReload and config.ActiveReloadEffects and config.ActiveReloadEffects.MuzzleFlash then
		muzzleConfig = config.ActiveReloadEffects.MuzzleFlash
	end

	-- Buscar el Tool en el personaje y su Handle
	local tool = nil
	for _, child in character:GetChildren() do
		if child:IsA("Tool") then
			local wName = child:GetAttribute("WeaponName") or child.Name
			if wName == weaponName then
				tool = child
				break
			end
		end
	end

	if not tool then
		return
	end

	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if not handle then
		return
	end

	-- Si tiene Path, clonar instancia(s) pre-hecha(s) e ignorar otros parámetros
	if muzzleConfig.Path then
		local paths = EffectsConstants.NormalizePaths(muzzleConfig.Path)
		if not paths then
			return
		end

		local pathDelay = muzzleConfig.PathDelay or 0
		local duration = muzzleConfig.Duration or EffectsConstants.MUZZLE_FLASH_DURATION

		local function cloneOne(path: string)
			local template = EffectsConstants.ResolvePath(path)
			if not template then
				warn("[MuzzleFlashEffect] Path not found: " .. path)
				return
			end

			local clone = template:Clone()
			local muzzleAtt = handle:FindFirstChild("Muzzle")

			-- Orientación inteligente:
			-- Construimos el CFrame con CFrame.lookAt para que el LookVector
			-- del Part clonado apunte siempre en la dirección de disparo del arma.
			-- Esto alinea correctamente partículas con Orientation = VelocityParallel
			-- y EmissionDirection = Front.
			if clone:IsA("BasePart") then
				local forward = handle.CFrame.LookVector
				local up = handle.CFrame.UpVector
				if muzzleAtt and muzzleAtt:IsA("Attachment") then
					-- Posición del attachment, rotación alineada al cañón
					local pos = muzzleAtt.WorldPosition
					clone.CFrame = CFrame.lookAt(pos, pos + forward, up)
				else
					-- Sin attachment: punta del handle, mirando hacia adelante
					local tipPos = handle.Position + forward * (handle.Size.Z * 0.5)
					clone.CFrame = CFrame.lookAt(tipPos, tipPos + forward, up)
				end
				clone.Anchored = true
				clone.CanCollide = false
				clone.CanQuery = false
				clone.CanTouch = false
				clone.Transparency = 1
				clone.Parent = handle.Parent
			else
				-- No es BasePart (Folder, Model parcial, etc.) — parentear al handle
				clone.Parent = handle
			end

			-- Emit burst (NO Enabled = true)
			EffectsConstants.EmitAll(clone)

			task.delay(duration, function()
				clone:Destroy()
			end)
		end

		if pathDelay > 0 and #paths > 1 then
			task.spawn(function()
				for i, p in paths do
					if i > 1 then
						task.wait(pathDelay)
					end
					cloneOne(p)
				end
			end)
		else
			for _, p in paths do
				cloneOne(p)
			end
		end
		return
	end

	-- Buscar Attachment "Muzzle" o usar posición del Handle
	local muzzlePoint = handle:FindFirstChild("Muzzle")

	-- PointLight temporal
	local light = Instance.new("PointLight")
	light.Color = muzzleConfig.Color
	light.Range = muzzleConfig.LightRange
	light.Brightness = muzzleConfig.LightBrightness
	light.Parent = handle

	-- Partícula flash (BillboardGui con Frame coloreado)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(muzzleConfig.Scale * 40, muzzleConfig.Scale * 40)
	billboard.StudsOffset = Vector3.zero
	billboard.Adornee = handle
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0

	local flashFrame = Instance.new("Frame")
	flashFrame.Size = UDim2.fromScale(1, 1)
	flashFrame.BackgroundColor3 = muzzleConfig.Color
	flashFrame.BackgroundTransparency = 0.2
	flashFrame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = flashFrame

	flashFrame.Parent = billboard
	billboard.Parent = handle

	-- Posicionar si hay Muzzle attachment (offset manual)
	if muzzlePoint and muzzlePoint:IsA("Attachment") then
		billboard.StudsOffset = muzzlePoint.Position
	end

	-- Cleanup automático
	local duration = muzzleConfig.Duration or EffectsConstants.MUZZLE_FLASH_DURATION
	task.delay(duration, function()
		light:Destroy()
		billboard:Destroy()
	end)
end

return MuzzleFlashEffect
