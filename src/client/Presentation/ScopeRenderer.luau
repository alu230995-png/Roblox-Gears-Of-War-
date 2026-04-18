--[[
	ScopeRenderer.luau
	═══════════════════════════════════════════════════════════════
	Renderiza el crosshair (scope) en pantalla con dots por pellet
	y sistema de hitmarkers dinámicos.
	═══════════════════════════════════════════════════════════════

	Uso:
	  local scope = ScopeRenderer.new(player, spreadPattern)
	  scope:SetVisible(true)
	  scope:SetAiming(true)
	  scope:OnShotConfirmed(data) -- hitmarker feedback
	  scope:Destroy()

	Hitmarkers:
	  - Gnasher (multi-pellet): dots individuales se iluminan al acertar,
	    borde negro escalado por daño, pulso en kill.
	  - Standard (single-pellet): cruz "X" central, rojo en headshot,
	    escala por daño, pulso en kill.
	  - Máximo 3 hitmarkers activos simultáneamente.
	  - Fade-out y destrucción automática.
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

------------------------------------------------------------------------
-- CONSTANTS
------------------------------------------------------------------------

local SIZE_NORMAL = Constants.SCOPE_SIZE_NORMAL
local SIZE_AIMING = Constants.SCOPE_SIZE_AIMING
local DOT_RADIUS = Constants.SCOPE_DOT_RADIUS
local TWEEN_DURATION = Constants.SCOPE_TWEEN_DURATION

local MAX_HITMARKERS = Constants.HITMARKER_MAX_ACTIVE or 3
local HITMARKER_DISPLAY_TIME = Constants.HITMARKER_DISPLAY_DURATION or 0.4
local HITMARKER_FADE_TIME = Constants.HITMARKER_FADE_DURATION or 0.15
local HITMARKER_STANDARD_SIZE = Constants.HITMARKER_STANDARD_BASE_SIZE or 12
local HITMARKER_HEADSHOT_SIZE = Constants.HITMARKER_HEADSHOT_BASE_SIZE or 16
local HITMARKER_HEADSHOT_COLOR = Constants.HITMARKER_HEADSHOT_COLOR or Color3.fromRGB(255, 50, 50)
local HITMARKER_KILL_SCALE = Constants.HITMARKER_KILL_SCALE or 1.5
local HITMARKER_STROKE_MAX = Constants.HITMARKER_GNASHER_STROKE_MAX or 1.0

local TWEEN_INFO = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------

local ScopeRenderer = {}
ScopeRenderer.__index = ScopeRenderer

function ScopeRenderer.new(player: Player, spreadPattern: { [number]: UDim2 })
	local self = setmetatable({}, ScopeRenderer)

	self._player = player
	self._spreadPattern = spreadPattern
	self._isAiming = false
	self._tween = nil :: Tween?

	-- Hitmarker state
	self._activeHitmarkers = {} :: { any }
	self._isMultiPellet = #spreadPattern > 1

	-- Crear ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ScopeGui"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 10
	self._screenGui = screenGui

	-- Contenedor centrado en la pantalla
	local container = Instance.new("Frame")
	container.Name = "ScopeContainer"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.new(0.5, 0, 0.5, 0)
	container.Size = UDim2.new(0, SIZE_NORMAL, 0, SIZE_NORMAL)
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.Parent = screenGui
	self._container = container

	-- Mantener aspecto cuadrado
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1.3
	aspect.Parent = container

	-- Crear dots para cada pellet (OCULTOS por defecto — Transparency=1)
	self._dots = {}
	for i, pos in spreadPattern do
		local dot = Instance.new("Frame")
		dot.Name = "Pellet_" .. tostring(i)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = pos
		dot.Size = UDim2.new(0, DOT_RADIUS * 2, 0, DOT_RADIUS * 2)
		dot.BackgroundColor3 = Color3.new(1, 1, 1)
		dot.BackgroundTransparency = 1
		dot.BorderSizePixel = 0
		dot.Parent = container

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = dot

		table.insert(self._dots, dot)
	end

	-- Parent al PlayerGui
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		screenGui.Parent = playerGui
	end

	return self
end

--- Devuelve el Frame contenedor del scope (usado por ShootingHandler para raycast).
function ScopeRenderer:GetContainer(): Frame?
	return self._container
end

--- Muestra u oculta el scope completo.
function ScopeRenderer:SetVisible(visible: boolean)
	if self._screenGui then
		self._screenGui.Enabled = visible
	end
end

--- Activa o desactiva el modo de apuntado (tween de tamaño).
function ScopeRenderer:SetAiming(isAiming: boolean)
	if self._isAiming == isAiming then
		return
	end
	self._isAiming = isAiming

	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end

	local targetSize = if isAiming
		then UDim2.new(0, SIZE_AIMING, 0, SIZE_AIMING)
		else UDim2.new(0, SIZE_NORMAL, 0, SIZE_NORMAL)

	self._tween = TweenService:Create(self._container, TWEEN_INFO, { Size = targetSize })
	self._tween:Play()
end

------------------------------------------------------------------------
-- HITMARKER SYSTEM
------------------------------------------------------------------------

--- Punto de entrada para hitmarkers. Llamado por EffectsController._onShotConfirmed.
function ScopeRenderer:OnShotConfirmed(data: any)
	if not data or not data.ValidatedHits then
		return
	end

	-- Verificar si hay hits de carne (solo mostrar hitmarkers para flesh hits)
	local hasFleshHit = false
	for _, hit in data.ValidatedHits do
		if hit.IsFlesh then
			hasFleshHit = true
			break
		end
	end
	if not hasFleshHit then
		return
	end

	-- Enforcer máximo de hitmarkers activos
	while #self._activeHitmarkers >= MAX_HITMARKERS do
		self:_removeOldestHitmarker()
	end

	if self._isMultiPellet then
		self:_showGnasherHitmarker(data)
	else
		self:_showStandardHitmarker(data)
	end
end

------------------------------------------------------------------------
-- PRIVATE: Gnasher hitmarker (multi-pellet)
------------------------------------------------------------------------

function ScopeRenderer:_showGnasherHitmarker(data: any)
	local hasKill = data.Kills and #data.Kills > 0

	local hitmarkerInfo = {
		tweens = {},
		cleanupParts = {},
		affectedDots = {},
	}

	for _, hit in data.ValidatedHits do
		if not hit.IsFlesh then
			continue
		end

		local pelletIndex = hit.PelletIndex
		local dot = self._dots[pelletIndex]
		if not dot or not dot.Parent then
			continue
		end

		-- Hacer visible el dot
		dot.BackgroundTransparency = 0
		table.insert(hitmarkerInfo.affectedDots, dot)

		-- UIStroke negro escalado por daño (max HITMARKER_STROKE_MAX px)
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Thickness = math.clamp((hit.Damage or 0) / 75, 0.3, HITMARKER_STROKE_MAX)
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = dot
		table.insert(hitmarkerInfo.cleanupParts, stroke)
	end

	-- Kill: el container crece lentamente; los dots hacen fade simultáneamente
	if hasKill and #hitmarkerInfo.affectedDots > 0 and self._container then
		local originalContainerSize = self._container.Size
		local enlargedSize = UDim2.new(
			0,
			math.round(originalContainerSize.X.Offset * HITMARKER_KILL_SCALE),
			0,
			math.round(originalContainerSize.Y.Offset * HITMARKER_KILL_SCALE)
		)

		local KILL_GROW_TIME = 0.2

		local growTween = TweenService:Create(
			self._container,
			TweenInfo.new(KILL_GROW_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = enlargedSize }
		)
		growTween:Play()
		growTween.Completed:Once(function()
			if self._container then
				self._container.Size = originalContainerSize
			end
		end)
		table.insert(hitmarkerInfo.tweens, growTween)

		-- Dots y strokes hacen fade durante el crecimiento
		for _, dot in hitmarkerInfo.affectedDots do
			if dot and dot.Parent then
				local fadeTween = TweenService:Create(
					dot,
					TweenInfo.new(KILL_GROW_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
					{ BackgroundTransparency = 1 }
				)
				fadeTween:Play()
				table.insert(hitmarkerInfo.tweens, fadeTween)

				local uiStroke = dot:FindFirstChildOfClass("UIStroke")
				if uiStroke then
					local strokeFadeTween = TweenService:Create(
						uiStroke,
						TweenInfo.new(KILL_GROW_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
						{ Thickness = 0 }
					)
					strokeFadeTween:Play()
					table.insert(hitmarkerInfo.tweens, strokeFadeTween)
				end
			end
		end
	end

	table.insert(self._activeHitmarkers, hitmarkerInfo)

	-- Fade out después del tiempo de display (si no fue kill, o si ya terminó el pulse)
	task.delay(HITMARKER_DISPLAY_TIME, function()
		self:_fadeOutGnasherHitmarker(hitmarkerInfo)
	end)
end

function ScopeRenderer:_fadeOutGnasherHitmarker(hitmarkerInfo: any)
	-- Tween dots de vuelta a transparente
	for _, dot in hitmarkerInfo.affectedDots do
		if dot and dot.Parent then
			local fadeTween = TweenService:Create(
				dot,
				TweenInfo.new(HITMARKER_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ BackgroundTransparency = 1 }
			)
			fadeTween:Play()
		end
	end

	-- Destruir UIStrokes y limpiar después del fade
	task.delay(HITMARKER_FADE_TIME + 0.05, function()
		for _, part in hitmarkerInfo.cleanupParts do
			if part and part.Parent then
				part:Destroy()
			end
		end
		local idx = table.find(self._activeHitmarkers, hitmarkerInfo)
		if idx then
			table.remove(self._activeHitmarkers, idx)
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Standard hitmarker (single-pellet, cruz "X")
------------------------------------------------------------------------

function ScopeRenderer:_showStandardHitmarker(data: any)
	if not data.ValidatedHits or #data.ValidatedHits == 0 then
		return
	end

	local hit = data.ValidatedHits[1]
	if not hit or not hit.IsFlesh then
		return
	end

	local isHeadshot = hit.HitPartName == "Head"
	local hasKill = data.Kills and #data.Kills > 0

	local hitmarkerInfo = {
		tweens = {},
		cleanupParts = {},
		affectedDots = {},
	}

	-- Determinar color y tamaño base
	local color = if isHeadshot then HITMARKER_HEADSHOT_COLOR else Color3.new(1, 1, 1)
	local baseSize = if isHeadshot then HITMARKER_HEADSHOT_SIZE else HITMARKER_STANDARD_SIZE

	-- Crear contenedor de la "X"
	local xContainer = Instance.new("Frame")
	xContainer.Name = "Hitmarker"
	xContainer.AnchorPoint = Vector2.new(0.5, 0.5)
	xContainer.Position = UDim2.new(0.5, 0, 0.5, 0)
	xContainer.Size = UDim2.fromOffset(baseSize, baseSize)
	xContainer.BackgroundTransparency = 1
	xContainer.BorderSizePixel = 0
	xContainer.Parent = self._container

	-- Dos líneas diagonales formando la X
	for _, rotation in { 45, -45 } do
		local line = Instance.new("Frame")
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = UDim2.new(0.5, 0, 0.5, 0)
		line.Size = UDim2.new(1, 0, 0, 2)
		line.Rotation = rotation
		line.BackgroundColor3 = color
		line.BackgroundTransparency = 0
		line.BorderSizePixel = 0
		line.Parent = xContainer
	end

	table.insert(hitmarkerInfo.cleanupParts, xContainer)

	-- Tween de escala: crecer al aparecer
	local scaleFactor = if hasKill then 1.8 else 1.4
	local targetSize = UDim2.fromOffset(math.floor(baseSize * scaleFactor), math.floor(baseSize * scaleFactor))

	local growTween = TweenService:Create(
		xContainer,
		TweenInfo.new(0.06, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = targetSize }
	)
	growTween:Play()
	table.insert(hitmarkerInfo.tweens, growTween)

	-- Volver al tamaño base después del grow
	local returnTween = TweenService:Create(
		xContainer,
		TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromOffset(baseSize, baseSize) }
	)
	growTween.Completed:Once(function()
		if xContainer.Parent then
			returnTween:Play()
		end
	end)
	table.insert(hitmarkerInfo.tweens, returnTween)

	table.insert(self._activeHitmarkers, hitmarkerInfo)

	-- Fade out
	task.delay(HITMARKER_DISPLAY_TIME, function()
		self:_fadeOutStandardHitmarker(hitmarkerInfo, xContainer)
	end)
end

function ScopeRenderer:_fadeOutStandardHitmarker(hitmarkerInfo: any, xContainer: Frame)
	if not xContainer or not xContainer.Parent then
		local idx = table.find(self._activeHitmarkers, hitmarkerInfo)
		if idx then
			table.remove(self._activeHitmarkers, idx)
		end
		return
	end

	-- Fade las líneas de la X
	for _, child in xContainer:GetChildren() do
		if child:IsA("Frame") then
			TweenService:Create(
				child,
				TweenInfo.new(HITMARKER_FADE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ BackgroundTransparency = 1 }
			):Play()
		end
	end

	-- Destruir después del fade
	task.delay(HITMARKER_FADE_TIME + 0.05, function()
		for _, part in hitmarkerInfo.cleanupParts do
			if part and part.Parent then
				part:Destroy()
			end
		end
		local idx = table.find(self._activeHitmarkers, hitmarkerInfo)
		if idx then
			table.remove(self._activeHitmarkers, idx)
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE: Hitmarker cleanup
------------------------------------------------------------------------

--- Fuerza la eliminación del hitmarker más antiguo.
function ScopeRenderer:_removeOldestHitmarker()
	local oldest = table.remove(self._activeHitmarkers, 1)
	if not oldest then
		return
	end

	for _, tween in oldest.tweens do
		tween:Cancel()
	end
	for _, part in oldest.cleanupParts do
		if part and part.Parent then
			part:Destroy()
		end
	end

	-- Resetear dots afectados (gnasher)
	if oldest.affectedDots then
		for _, dot in oldest.affectedDots do
			if dot and dot.Parent then
				dot.BackgroundTransparency = 1
			end
		end
	end
end

------------------------------------------------------------------------
-- DESTROY
------------------------------------------------------------------------

function ScopeRenderer:Destroy()
	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end

	-- Limpiar todos los hitmarkers activos
	for _, hitmarkerInfo in self._activeHitmarkers do
		for _, tween in hitmarkerInfo.tweens do
			tween:Cancel()
		end
		for _, part in hitmarkerInfo.cleanupParts do
			if part and part.Parent then
				part:Destroy()
			end
		end
	end
	table.clear(self._activeHitmarkers)

	if self._screenGui then
		self._screenGui:Destroy()
		self._screenGui = nil
	end

	self._container = nil
	self._dots = nil
end

return ScopeRenderer
