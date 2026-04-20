--[[
	DBNOReviveHUD.client.luau
	═══════════════════════════════════════════════════════════════
	HUD profesional de DBNO estilo Gears of War.
	═══════════════════════════════════════════════════════════════

	Muestra:
	  • Anillo de progreso circular segmentado (36 segmentos)
	    alrededor del botón Cover (móvil) o ícono COG (PC)
	  • Título "ABATIDO" con animación de parpadeo
	  • Label instrucción "MANTÉN A PARA LEVANTARTE"
	  • Countdown timer con urgencia color-coded
	  • Overlay rojo sutil fullscreen

	Comportamiento por plataforma:
	  • Móvil: Reposiciona el botón Cover (SpaceMoveButton) al centro
	    del anillo durante DBNO; lo restaura al salir.
	  • PC: Muestra ícono COG "◆" en el centro del anillo.
	    Solo se muestra la barra circular (el input es vía teclado Space).

	Estilo visual:
	  - Segmentos de anillo low-poly (encaja con estética FPS del proyecto)
	  - Paleta fría: negros, crimsons, blancos, naranjas
	  - Todo en UDim2 scale para responsividad en todas las pantallas

	Capa: Presentación (UI) — Test
	Depende de:
	  - ServiceLocator singleton (registrado por ClientApp)
	  - DBNOHandler (señales: DBNOStarted, DBNOEnded, ReviveProgressUpdated, CountdownUpdated)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer

------------------------------------------------------------------------
-- PLATFORM DETECTION
------------------------------------------------------------------------

local IS_MOBILE = UserInputService.TouchEnabled and not GuiService:IsTenFootInterface()

------------------------------------------------------------------------
-- WAIT FOR ServiceLocator → DBNOHandler
------------------------------------------------------------------------

local ServiceLocator = require(script.Parent.Parent.Core.ServiceLocator)
local locator = ServiceLocator.new()

local dbnoHandler = nil
local MAX_WAIT = 10

local elapsed = 0
repeat
	task.wait(0.05)
	elapsed += 0.05
	dbnoHandler = locator:Get("DBNOHandler")
until dbnoHandler ~= nil or elapsed >= MAX_WAIT

if not dbnoHandler then
	warn("[DBNOReviveHUD] DBNOHandler no disponible tras " .. MAX_WAIT .. "s — abortando")
	return
end

------------------------------------------------------------------------
-- CONSTANTS — GOW DBNO Color Palette
------------------------------------------------------------------------

local COLOR_OVERLAY_TINT = Color3.fromRGB(80, 10, 10)
local COLOR_PANEL_BG = Color3.fromRGB(8, 10, 14)
local COLOR_PANEL_BORDER = Color3.fromRGB(40, 55, 75)
local COLOR_RING_INACTIVE = Color3.fromRGB(35, 35, 40)
local COLOR_RING_ACTIVE_START = Color3.fromRGB(180, 30, 30) -- Crimson
local COLOR_RING_ACTIVE_END = Color3.fromRGB(255, 220, 100) -- White-gold
local COLOR_RING_FULL = Color3.fromRGB(255, 255, 255)
local COLOR_TITLE = Color3.fromRGB(220, 50, 50)
local COLOR_TITLE_FLASH = Color3.fromRGB(255, 120, 120)
local COLOR_INSTRUCTION = Color3.fromRGB(180, 190, 200)
local COLOR_COUNTDOWN_NORMAL = Color3.fromRGB(255, 200, 80)
local COLOR_COUNTDOWN_WARN = Color3.fromRGB(255, 150, 50)
local COLOR_COUNTDOWN_URGENT = Color3.fromRGB(255, 60, 60)
local COLOR_CENTER_BG = Color3.fromRGB(12, 14, 18)
local COLOR_COG_ICON = Color3.fromRGB(180, 30, 30)
local COLOR_DEATH_FLASH = Color3.fromRGB(255, 30, 30)
local COLOR_REVIVE_FLASH = Color3.fromRGB(60, 255, 120)

local OVERLAY_TRANSPARENCY = 0.88
local PANEL_TRANSPARENCY = 0.2

-- Ring configuration
local RING_SEGMENTS = 36
local RING_SEGMENT_GAP_DEG = 2 -- gap between segments in degrees
local RING_SEGMENT_ARC_DEG = (360 / RING_SEGMENTS) - RING_SEGMENT_GAP_DEG

-- Sizes (all scale-based for responsiveness)
local RING_RADIUS_SCALE = 0.065 -- radius relative to viewport height
local RING_THICKNESS_SCALE = 0.008 -- segment thickness relative to viewport height
local RING_SEGMENT_LENGTH = 0.032 -- segment length relative to viewport height

------------------------------------------------------------------------
-- UI STATE
------------------------------------------------------------------------

local screenGui -- ScreenGui
local overlay -- fullscreen red tint
local centerPanel -- bottom-center container
local titleLabel -- "ABATIDO"
local instructionLabel -- "MANTÉN A PARA LEVANTARTE"
local countdownLabel -- "8.0s"
local ringContainer -- square container for ring segments
local centerCircle -- dark inner circle
local centerIcon -- COG icon (PC only)
local ringSegments = {} -- array of 36 Frame segments

-- Mobile button repositioning
local coverButtonRef = nil -- Reference to the mobile cover button
local coverButtonOrigPos = nil -- Original UDim2 position
local coverButtonOrigSize = nil -- Original UDim2 size
local coverButtonOrigAnchor = nil -- Original Vector2 anchorPoint
local coverButtonOrigParent = nil -- Original parent

-- Animation state
local titlePulseConn = nil
local isVisible = false

------------------------------------------------------------------------
-- CONNECTIONS
------------------------------------------------------------------------

local connections = {}

------------------------------------------------------------------------
-- HELPER: Lerp Color3
------------------------------------------------------------------------

local function lerpColor(c1: Color3, c2: Color3, alpha: number): Color3
	return Color3.new(c1.R + (c2.R - c1.R) * alpha, c1.G + (c2.G - c1.G) * alpha, c1.B + (c2.B - c1.B) * alpha)
end

------------------------------------------------------------------------
-- BUILD UI
------------------------------------------------------------------------

local function buildUI()
	-- ScreenGui
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DBNOReviveHUD"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 105
	screenGui.Enabled = false
	screenGui.Parent = player:WaitForChild("PlayerGui")

	-- ═══════════════════════════════════════════════════════════
	-- OVERLAY — Fullscreen red tint (GOW DBNO feel)
	-- ═══════════════════════════════════════════════════════════

	overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.Position = UDim2.new(0, 0, 0, 0)
	overlay.BackgroundColor3 = COLOR_OVERLAY_TINT
	overlay.BackgroundTransparency = OVERLAY_TRANSPARENCY
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 1
	overlay.Parent = screenGui

	-- ═══════════════════════════════════════════════════════════
	-- CENTER PANEL — Bottom-center container
	-- ═══════════════════════════════════════════════════════════

	centerPanel = Instance.new("Frame")
	centerPanel.Name = "CenterPanel"
	centerPanel.AnchorPoint = Vector2.new(0.5, 1)
	centerPanel.Position = UDim2.new(0.5, 0, 0.92, 0)
	centerPanel.Size = UDim2.new(0.28, 0, 0.32, 0)
	centerPanel.BackgroundColor3 = COLOR_PANEL_BG
	centerPanel.BackgroundTransparency = 1 -- transparent container, ring is the visual
	centerPanel.BorderSizePixel = 0
	centerPanel.ZIndex = 2
	centerPanel.Parent = screenGui

	local panelAspect = Instance.new("UIAspectRatioConstraint")
	panelAspect.AspectRatio = 0.7
	panelAspect.DominantAxis = Enum.DominantAxis.Height
	panelAspect.Parent = centerPanel

	-- ═══════════════════════════════════════════════════════════
	-- TITLE — "ABATIDO"
	-- ═══════════════════════════════════════════════════════════

	titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.AnchorPoint = Vector2.new(0.5, 0)
	titleLabel.Position = UDim2.new(0.5, 0, 0.0, 0)
	titleLabel.Size = UDim2.new(0.9, 0, 0.1, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = Enum.Font.GothamBlack
	titleLabel.TextScaled = true
	titleLabel.TextColor3 = COLOR_TITLE
	titleLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	titleLabel.TextStrokeTransparency = 0.3
	titleLabel.Text = "ABATIDO"
	titleLabel.ZIndex = 5
	titleLabel.Parent = centerPanel

	local titleConstraint = Instance.new("UITextSizeConstraint")
	titleConstraint.MaxTextSize = 22
	titleConstraint.MinTextSize = 10
	titleConstraint.Parent = titleLabel

	-- ═══════════════════════════════════════════════════════════
	-- RING CONTAINER — Square zone for circular segments
	-- ═══════════════════════════════════════════════════════════

	ringContainer = Instance.new("Frame")
	ringContainer.Name = "RingContainer"
	ringContainer.AnchorPoint = Vector2.new(0.5, 0.5)
	ringContainer.Position = UDim2.new(0.5, 0, 0.45, 0)
	ringContainer.Size = UDim2.new(0.7, 0, 0.55, 0)
	ringContainer.BackgroundTransparency = 1
	ringContainer.ZIndex = 3
	ringContainer.Parent = centerPanel

	local ringAspect = Instance.new("UIAspectRatioConstraint")
	ringAspect.AspectRatio = 1
	ringAspect.DominantAxis = Enum.DominantAxis.Width
	ringAspect.Parent = ringContainer

	-- ═══════════════════════════════════════════════════════════
	-- CENTER CIRCLE — Dark inner circle behind button/icon
	-- ═══════════════════════════════════════════════════════════

	centerCircle = Instance.new("Frame")
	centerCircle.Name = "CenterCircle"
	centerCircle.AnchorPoint = Vector2.new(0.5, 0.5)
	centerCircle.Position = UDim2.new(0.5, 0, 0.5, 0)
	centerCircle.Size = UDim2.new(0.52, 0, 0.52, 0)
	centerCircle.BackgroundColor3 = COLOR_CENTER_BG
	centerCircle.BackgroundTransparency = 0.15
	centerCircle.BorderSizePixel = 0
	centerCircle.ZIndex = 4
	centerCircle.Parent = ringContainer

	local centerCorner = Instance.new("UICorner")
	centerCorner.CornerRadius = UDim.new(0.5, 0)
	centerCorner.Parent = centerCircle

	local centerStroke = Instance.new("UIStroke")
	centerStroke.Thickness = 1.5
	centerStroke.Color = COLOR_PANEL_BORDER
	centerStroke.Transparency = 0.4
	centerStroke.Parent = centerCircle

	-- ═══════════════════════════════════════════════════════════
	-- COG ICON — Center icon (PC only, on mobile the button goes here)
	-- ═══════════════════════════════════════════════════════════

	centerIcon = Instance.new("TextLabel")
	centerIcon.Name = "CenterIcon"
	centerIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	centerIcon.Position = UDim2.new(0.5, 0, 0.5, 0)
	centerIcon.Size = UDim2.new(0.6, 0, 0.6, 0)
	centerIcon.BackgroundTransparency = 1
	centerIcon.Font = Enum.Font.GothamBlack
	centerIcon.TextScaled = true
	centerIcon.TextColor3 = COLOR_COG_ICON
	centerIcon.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	centerIcon.TextStrokeTransparency = 0.5
	centerIcon.Text = "◆"
	centerIcon.ZIndex = 5
	centerIcon.Visible = not IS_MOBILE -- only visible on PC
	centerIcon.Parent = centerCircle

	-- ═══════════════════════════════════════════════════════════
	-- RING SEGMENTS — 36 bars positioned in a circle
	-- ═══════════════════════════════════════════════════════════

	-- Each segment is a small Frame rotated around the center
	-- positioned using trigonometry (cos/sin) at the ring radius
	for i = 1, RING_SEGMENTS do
		local angleDeg = (i - 1) * (360 / RING_SEGMENTS) - 90 -- start from top (-90°)
		local angleRad = math.rad(angleDeg)

		-- Segment frame (anchored at its center, positioned on the ring)
		local segment = Instance.new("Frame")
		segment.Name = "Seg_" .. string.format("%02d", i)
		segment.AnchorPoint = Vector2.new(0.5, 0.5)

		-- Position on the circle: center + radius * (cos, sin)
		-- Ring radius is 0.44 of the container (slightly inside the edge)
		local radiusFraction = 0.44
		local px = 0.5 + radiusFraction * math.cos(angleRad)
		local py = 0.5 + radiusFraction * math.sin(angleRad)
		segment.Position = UDim2.new(px, 0, py, 0)

		-- Size: thin bar (width = thickness, height = arc length)
		segment.Size = UDim2.new(0.06, 0, 0.14, 0)

		-- Rotate to be tangential to the circle (perpendicular to radius)
		segment.Rotation = angleDeg + 90

		segment.BackgroundColor3 = COLOR_RING_INACTIVE
		segment.BackgroundTransparency = 0.3
		segment.BorderSizePixel = 0
		segment.ZIndex = 3
		segment.Parent = ringContainer

		-- Rounded corners for a polished low-poly look
		local segCorner = Instance.new("UICorner")
		segCorner.CornerRadius = UDim.new(0.25, 0)
		segCorner.Parent = segment

		ringSegments[i] = segment
	end

	-- ═══════════════════════════════════════════════════════════
	-- INSTRUCTION LABEL — "MANTÉN A PARA LEVANTARTE"
	-- ═══════════════════════════════════════════════════════════

	instructionLabel = Instance.new("TextLabel")
	instructionLabel.Name = "Instruction"
	instructionLabel.AnchorPoint = Vector2.new(0.5, 0)
	instructionLabel.Position = UDim2.new(0.5, 0, 0.76, 0)
	instructionLabel.Size = UDim2.new(0.95, 0, 0.08, 0)
	instructionLabel.BackgroundTransparency = 1
	instructionLabel.Font = Enum.Font.GothamBold
	instructionLabel.TextScaled = true
	instructionLabel.TextColor3 = COLOR_INSTRUCTION
	instructionLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	instructionLabel.TextStrokeTransparency = 0.4
	instructionLabel.Text = IS_MOBILE and "MANTÉN PARA LEVANTARTE" or "MANTÉN [A] PARA LEVANTARTE"
	instructionLabel.ZIndex = 5
	instructionLabel.Parent = centerPanel

	local instrConstraint = Instance.new("UITextSizeConstraint")
	instrConstraint.MaxTextSize = 14
	instrConstraint.MinTextSize = 8
	instrConstraint.Parent = instructionLabel

	-- ═══════════════════════════════════════════════════════════
	-- COUNTDOWN LABEL — "8.0s"
	-- ═══════════════════════════════════════════════════════════

	countdownLabel = Instance.new("TextLabel")
	countdownLabel.Name = "Countdown"
	countdownLabel.AnchorPoint = Vector2.new(0.5, 0)
	countdownLabel.Position = UDim2.new(0.5, 0, 0.86, 0)
	countdownLabel.Size = UDim2.new(0.5, 0, 0.1, 0)
	countdownLabel.BackgroundTransparency = 1
	countdownLabel.Font = Enum.Font.GothamBlack
	countdownLabel.TextScaled = true
	countdownLabel.TextColor3 = COLOR_COUNTDOWN_NORMAL
	countdownLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	countdownLabel.TextStrokeTransparency = 0.3
	countdownLabel.Text = "8.0s"
	countdownLabel.ZIndex = 5
	countdownLabel.Parent = centerPanel

	local cdConstraint = Instance.new("UITextSizeConstraint")
	cdConstraint.MaxTextSize = 20
	cdConstraint.MinTextSize = 10
	cdConstraint.Parent = countdownLabel
end

------------------------------------------------------------------------
-- RING UPDATE — Set ring progress (0.0 to 1.0)
------------------------------------------------------------------------

local function setRingProgress(ratio: number)
	ratio = math.clamp(ratio, 0, 1)

	local activeCount = math.floor(ratio * RING_SEGMENTS + 0.5)

	for i = 1, RING_SEGMENTS do
		local segment = ringSegments[i]
		if i <= activeCount then
			-- Active segment — color based on progress
			local segRatio = i / RING_SEGMENTS
			local color

			if ratio >= 0.98 then
				-- Almost full — bright white flash
				color = COLOR_RING_FULL
			else
				-- Crimson → White-gold gradient
				color = lerpColor(COLOR_RING_ACTIVE_START, COLOR_RING_ACTIVE_END, segRatio)
			end

			segment.BackgroundColor3 = color
			segment.BackgroundTransparency = 0
		else
			-- Inactive segment
			segment.BackgroundColor3 = COLOR_RING_INACTIVE
			segment.BackgroundTransparency = 0.3
		end
	end
end

------------------------------------------------------------------------
-- TITLE PULSE ANIMATION
------------------------------------------------------------------------

local function startTitlePulse()
	if titlePulseConn then
		return
	end

	local pulseTime = 0
	titlePulseConn = RunService.Heartbeat:Connect(function(dt)
		pulseTime += dt
		-- Slow pulse: 0.8 Hz
		local alpha = (math.sin(pulseTime * 2 * math.pi * 0.8) + 1) / 2
		titleLabel.TextColor3 = lerpColor(COLOR_TITLE, COLOR_TITLE_FLASH, alpha)

		-- Subtle scale pulse on instruction text
		local instrAlpha = (math.sin(pulseTime * 2 * math.pi * 0.5) + 1) / 2
		instructionLabel.TextTransparency = 0.1 + 0.25 * instrAlpha
	end)
end

local function stopTitlePulse()
	if titlePulseConn then
		titlePulseConn:Disconnect()
		titlePulseConn = nil
	end
end

------------------------------------------------------------------------
-- COUNTDOWN UPDATE
------------------------------------------------------------------------

local function setCountdown(remaining: number, _maxTime: number)
	local t = math.max(remaining, 0)
	countdownLabel.Text = string.format("%.1fs", t)

	-- Color: warm → orange → red según urgencia
	if t <= 2 then
		countdownLabel.TextColor3 = COLOR_COUNTDOWN_URGENT
		-- Urgent blinking
		local blink = math.floor(t * 4) % 2 == 0
		countdownLabel.TextTransparency = blink and 0 or 0.3
	elseif t <= 4 then
		countdownLabel.TextColor3 = COLOR_COUNTDOWN_WARN
		countdownLabel.TextTransparency = 0
	else
		countdownLabel.TextColor3 = COLOR_COUNTDOWN_NORMAL
		countdownLabel.TextTransparency = 0
	end
end

------------------------------------------------------------------------
-- REVIVE PROGRESS UPDATE
------------------------------------------------------------------------

local function setReviveProgress(points: number, threshold: number)
	local ratio = math.clamp(points / math.max(threshold, 1), 0, 1)
	setRingProgress(ratio)
end

------------------------------------------------------------------------
-- MOBILE — Cover Button Repositioning
------------------------------------------------------------------------

--- Finds the mobile cover button (SpaceMoveButton) in the PlayerGui
local function findCoverButton(): (GuiObject?, UDim2?, Vector2?, Instance?, UDim2?)
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return nil, nil, nil, nil, nil
	end

	local combatGui = playerGui:FindFirstChild("MobileTouchHUD_Combat")
	if not combatGui then
		return nil, nil, nil, nil, nil
	end

	-- Search recursively for the SpaceMoveButton
	local btn = combatGui:FindFirstChild("SpaceMoveButton", true)
	if not btn then
		return nil, nil, nil, nil, nil
	end

	return btn, btn.Position, btn.AnchorPoint, btn.Parent, btn.Size
end

--- Moves the cover button to the center of the ring
local function repositionCoverButton()
	if not IS_MOBILE then
		return
	end

	local btn, origPos, origAnchor, origParent, origSize = findCoverButton()
	if not btn then
		return
	end

	coverButtonRef = btn
	coverButtonOrigPos = origPos
	coverButtonOrigSize = origSize
	coverButtonOrigAnchor = origAnchor
	coverButtonOrigParent = origParent

	-- Reparent button into the center circle for perfect alignment
	btn.AnchorPoint = Vector2.new(0.5, 0.5)
	btn.Position = UDim2.new(0.5, 0, 0.5, 0)
	btn.Size = UDim2.new(0.85, 0, 0.85, 0)
	btn.ZIndex = 10
	btn.Parent = centerCircle

	-- Hide the COG icon since the button replaces it
	centerIcon.Visible = false
end

--- Restores the cover button to its original position
local function restoreCoverButton()
	if not IS_MOBILE or not coverButtonRef then
		return
	end

	if coverButtonOrigParent and coverButtonOrigPos and coverButtonOrigAnchor and coverButtonOrigSize then
		coverButtonRef.AnchorPoint = coverButtonOrigAnchor
		coverButtonRef.Position = coverButtonOrigPos
		coverButtonRef.ZIndex = 1
		coverButtonRef.Size = coverButtonOrigSize
		coverButtonRef.Parent = coverButtonOrigParent
	end

	coverButtonRef = nil
	coverButtonOrigPos = nil
	coverButtonOrigSize = nil
	coverButtonOrigAnchor = nil
	coverButtonOrigParent = nil
end

------------------------------------------------------------------------
-- SHOW / HIDE — DBNO state transitions
------------------------------------------------------------------------

local function showDBNO()
	if isVisible then
		return
	end
	isVisible = true

	-- Reset ring to 0%
	setRingProgress(0)
	setCountdown(8, 8)

	-- Reset title
	titleLabel.TextColor3 = COLOR_TITLE
	titleLabel.TextTransparency = 0

	-- Reset instruction
	instructionLabel.TextTransparency = 0

	-- Enable ScreenGui
	screenGui.Enabled = true

	-- Animate overlay fade-in
	overlay.BackgroundTransparency = 1
	local overlayTween =
		TweenService:Create(overlay, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundTransparency = OVERLAY_TRANSPARENCY,
		})
	overlayTween:Play()

	-- Start title pulse
	startTitlePulse()

	-- Reposition cover button (mobile)
	task.delay(0.1, function()
		repositionCoverButton()
	end)
end

local function hideDBNO(reason: string)
	if not isVisible then
		return
	end
	isVisible = false

	-- Stop animations
	stopTitlePulse()

	-- Restore cover button BEFORE hiding (mobile)
	restoreCoverButton()

	-- Flash effect based on reason
	if reason == "Died" then
		-- Flash red then fade
		titleLabel.TextColor3 = COLOR_DEATH_FLASH
		titleLabel.Text = "ELIMINADO"

		for i = 1, RING_SEGMENTS do
			ringSegments[i].BackgroundColor3 = COLOR_DEATH_FLASH
			ringSegments[i].BackgroundTransparency = 0
		end

		task.delay(0.6, function()
			if not isVisible then
				-- Fade out overlay
				local fadeTween =
					TweenService:Create(overlay, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						BackgroundTransparency = 1,
					})
				fadeTween:Play()
				fadeTween.Completed:Wait()

				if not isVisible then
					screenGui.Enabled = false
					titleLabel.Text = "ABATIDO"
				end
			end
		end)
	elseif reason == "Revived" then
		-- Flash green/white then fade
		titleLabel.TextColor3 = COLOR_REVIVE_FLASH
		titleLabel.Text = "¡LEVANTADO!"

		for i = 1, RING_SEGMENTS do
			ringSegments[i].BackgroundColor3 = COLOR_REVIVE_FLASH
			ringSegments[i].BackgroundTransparency = 0
		end

		task.delay(0.8, function()
			if not isVisible then
				local fadeTween =
					TweenService:Create(overlay, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						BackgroundTransparency = 1,
					})
				fadeTween:Play()
				fadeTween.Completed:Wait()

				if not isVisible then
					screenGui.Enabled = false
					titleLabel.Text = "ABATIDO"
				end
			end
		end)
	else
		-- Unknown reason — just hide
		screenGui.Enabled = false
	end
end

------------------------------------------------------------------------
-- BUILD & CONNECT
------------------------------------------------------------------------

buildUI()

-- Connect to DBNOHandler signals
table.insert(
	connections,
	dbnoHandler.DBNOStarted:Connect(function()
		showDBNO()
	end)
)

table.insert(
	connections,
	dbnoHandler.DBNOEnded:Connect(function(reason: string)
		hideDBNO(reason)
	end)
)

table.insert(
	connections,
	dbnoHandler.ReviveProgressUpdated:Connect(function(points: number, threshold: number)
		setReviveProgress(points, threshold)
	end)
)

table.insert(
	connections,
	dbnoHandler.CountdownUpdated:Connect(function(remaining: number, maxTime: number)
		setCountdown(remaining, maxTime)
	end)
)

------------------------------------------------------------------------
-- CLEANUP
-- Las conexiones se limpian automáticamente cuando el LocalScript se destruye.
------------------------------------------------------------------------
