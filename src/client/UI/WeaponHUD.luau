--[[
	WeaponHUD.luau
	═══════════════════════════════════════════════════════════════
	HUD profesional de arma estilo Gears of War.
	═══════════════════════════════════════════════════════════════

	Muestra:
	  • Nombre del arma activa
	  • Contador de munición (cargador | reserva)
	  • Barra de recarga con Active Reload visual:
	    - Cursor animado que se mueve de izquierda a derecha
	    - Zona "sweet spot" marcada en azul/cyan
	    - Feedback visual: PERFECT (verde), JAMMED (rojo), completado, cancelado

	Estilo visual:
	  - Panel angular sin bordes redondeados (militar, tactical)
	  - Paleta fría: negros profundos, grises, azules
	  - Tipografía GothamBold/GothamMedium — pesada y legible
	  - Separador diagonal para el efecto biselado GOW

	Capa: Presentación (UI)
	Depende de: WeaponClient (signals), ReloadHandler (signals)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local WeaponHUD = {}
WeaponHUD.__index = WeaponHUD

------------------------------------------------------------------------
-- CONSTANTS — GOW Color Palette
------------------------------------------------------------------------

local COLOR_PANEL_BG = Color3.fromRGB(8, 10, 14)
local COLOR_PANEL_BORDER = Color3.fromRGB(40, 55, 75)
local COLOR_ACCENT = Color3.fromRGB(50, 140, 210) -- Blue accent
local COLOR_ACCENT_BRIGHT = Color3.fromRGB(80, 200, 255) -- Cyan highlight
local COLOR_TEXT_PRIMARY = Color3.fromRGB(230, 235, 240)
local COLOR_TEXT_SECONDARY = Color3.fromRGB(140, 155, 170)
local COLOR_TEXT_LOW_AMMO = Color3.fromRGB(255, 180, 50)
local COLOR_TEXT_NO_AMMO = Color3.fromRGB(255, 55, 55)
local COLOR_SEPARATOR = Color3.fromRGB(55, 70, 90)
local COLOR_RELOAD_BG = Color3.fromRGB(20, 25, 32)
local COLOR_RELOAD_FILL = Color3.fromRGB(60, 80, 110)
local COLOR_RELOAD_CURSOR = Color3.fromRGB(255, 255, 255)
local COLOR_SWEET_ZONE = Color3.fromRGB(50, 180, 255)
local COLOR_PERFECT = Color3.fromRGB(60, 255, 120)
local COLOR_JAMMED = Color3.fromRGB(255, 50, 50)
local COLOR_COMPLETE = Color3.fromRGB(180, 200, 220)

local PANEL_TRANSPARENCY = 0.15
local BORDER_THICKNESS = 2
local RELOAD_BAR_HEIGHT = 10
local CURSOR_WIDTH = 4

-- Reload bar animation
local CURSOR_GLOW_SIZE = 12

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function WeaponHUD.new()
	local self = setmetatable({}, WeaponHUD)

	self._screenGui = nil :: ScreenGui?
	self._connections = {} :: { any }
	self._weaponConnections = {} :: { any }

	-- UI references
	self._container = nil
	self._uiaspectratio = nil
	self._weaponNameLabel = nil
	self._ammoCurrentLabel = nil
	self._ammoSeparator = nil
	self._ammoReserveLabel = nil
	self._reloadContainer = nil
	self._reloadBarBg = nil
	self._reloadBarFill = nil
	self._reloadCursor = nil
	self._reloadCursorGlow = nil
	self._sweetZone = nil
	self._sweetZoneMarkerLeft = nil
	self._sweetZoneMarkerRight = nil
	self._reloadStatusLabel = nil
	self._borderTop = nil
	self._borderBottom = nil
	self._borderLeft = nil
	self._borderRight = nil
	self._accentLine = nil
	self._diamondIcon = nil

	-- State
	self._isReloading = false
	self._reloadStartTime = 0
	self._reloadDuration = 0
	self._windowStart = 0
	self._windowDuration = 0
	self._heartbeatConn = nil :: RBXScriptConnection?
	self._activeReloadResult = nil :: string? -- "perfect" | "jammed" | nil
	self._currentWeaponName = ""

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function WeaponHUD:Init()
	-- Sin side-effects
end

function WeaponHUD:Start()
	self:_buildUI()
	self._container.Visible = false
	self._weaponNameLabel.Text = ""
	self._ammoCurrentLabel.Text = "--"
	self._ammoReserveLabel.Text = "--"
end

function WeaponHUD:Destroy()
	self:_clearWeaponConnections()

	if self._heartbeatConn then
		self._heartbeatConn:Disconnect()
		self._heartbeatConn = nil
	end

	for _, conn in self._connections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif type(conn) == "table" and conn.Disconnect then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)

	if self._screenGui then
		self._screenGui:Destroy()
		self._screenGui = nil
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Conecta el HUD a un WeaponClient. Desconecta el anterior si existe.
function WeaponHUD:BindWeapon(weaponClient)
	self:_clearWeaponConnections()
	self:_stopReloadDisplay(nil)

	if not weaponClient then
		self._container.Visible = false
		return
	end

	self._currentWeaponName = weaponClient:GetWeaponName() or "---"
	self._weaponNameLabel.Text = string.upper(self._currentWeaponName)
	self:_updateAmmoDisplay(weaponClient:GetCurrentAmmo(), weaponClient:GetReserveAmmo())
	self._container.Visible = true

	-- AmmoChanged
	table.insert(
		self._weaponConnections,
		weaponClient.AmmoChanged:Connect(function(current, reserve)
			self:_updateAmmoDisplay(current, reserve)
		end)
	)

	-- WeaponEquipped → update name
	table.insert(
		self._weaponConnections,
		weaponClient.WeaponEquipped:Connect(function(weaponName, _config)
			self._currentWeaponName = weaponName or "---"
			self._weaponNameLabel.Text = string.upper(self._currentWeaponName)
			self._container.Visible = true
		end)
	)

	-- WeaponUnequipped → hide
	table.insert(
		self._weaponConnections,
		weaponClient.WeaponUnequipped:Connect(function(_weaponName)
			self._container.Visible = false
		end)
	)

	-- ReloadHandler signals
	local rh = weaponClient:GetReloadHandler()
	if rh then
		table.insert(
			self._weaponConnections,
			rh.ReloadBegan:Connect(function(weaponName, reloadTime, windowStart, windowDuration)
				self:_startReloadDisplay(weaponName, reloadTime, windowStart, windowDuration)
			end)
		)

		table.insert(
			self._weaponConnections,
			rh.ReloadCompleted:Connect(function(_weaponName)
				self:_stopReloadDisplay("complete")
			end)
		)

		table.insert(
			self._weaponConnections,
			rh.ReloadCancelled:Connect(function(_weaponName)
				self:_stopReloadDisplay("cancelled")
			end)
		)

		table.insert(
			self._weaponConnections,
			rh.ActiveReloadAttempted:Connect(function(_weaponName, success, _progress)
				if success then
					self:_flashActiveReloadResult("perfect")
				else
					self:_flashActiveReloadResult("jammed")
				end
			end)
		)
	end
end

------------------------------------------------------------------------
-- PRIVATE — Build UI
------------------------------------------------------------------------

function WeaponHUD:_buildUI()
	local player = Players.LocalPlayer

	-- ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "WeaponHUD_GOW"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 100
	screenGui.Parent = player:WaitForChild("PlayerGui")
	self._screenGui = screenGui

	-- ═══════════════════════════════════════════════════════════
	-- MAIN CONTAINER — Bottom-right, angular panel
	-- ═══════════════════════════════════════════════════════════
	local container = Instance.new("Frame")
	container.Name = "WeaponPanel"
	container.AnchorPoint = Vector2.new(1, 1)
	container.Position = UDim2.new(0.983, 0, 0.18, 0)
	container.Size = UDim2.new(0.24, 0, 0.226, 0)
	container.BackgroundColor3 = COLOR_PANEL_BG
	container.BackgroundTransparency = PANEL_TRANSPARENCY
	container.BorderSizePixel = 0
	container.Parent = screenGui
	self._container = container

	local uiAspectRatio = Instance.new("UIAspectRatioConstraint")
	uiAspectRatio.DominantAxis = Enum.DominantAxis.Height
	uiAspectRatio.AspectRatio = 3.5
	uiAspectRatio.Parent = container
	self._uiaspectratio = uiAspectRatio

	-- ═══════════════════════════════════════════════════════════
	-- BORDER LINES — Sharp military edges (no UICorner)
	-- ═══════════════════════════════════════════════════════════
	self._borderTop =
		self:_createBorderLine(container, "Top", UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 0, BORDER_THICKNESS))

	self._borderBottom = self:_createBorderLine(
		container,
		"Bottom",
		UDim2.new(0, 0, 1, -BORDER_THICKNESS),
		UDim2.new(1, 0, 0, BORDER_THICKNESS)
	)

	self._borderLeft =
		self:_createBorderLine(container, "Left", UDim2.new(0, 0, 0, 0), UDim2.new(0, BORDER_THICKNESS, 1, 0))

	self._borderRight = self:_createBorderLine(
		container,
		"Right",
		UDim2.new(1, -BORDER_THICKNESS, 0, 0),
		UDim2.new(0, BORDER_THICKNESS, 1, 0)
	)

	-- Accent line — bright colored top border
	local accentLine = Instance.new("Frame")
	accentLine.Name = "AccentLine"
	accentLine.Position = UDim2.new(0, 0, 0, 0)
	accentLine.Size = UDim2.new(1, 0, 0, 3)
	accentLine.BackgroundColor3 = COLOR_ACCENT
	accentLine.BorderSizePixel = 0
	accentLine.ZIndex = 3
	accentLine.Parent = container
	self._accentLine = accentLine

	-- ═══════════════════════════════════════════════════════════
	-- INNER CONTENT FRAME (padded)
	-- ═══════════════════════════════════════════════════════════
	local innerFrame = Instance.new("Frame")
	innerFrame.Name = "Inner"
	innerFrame.Position = UDim2.new(0.05, 0, 0.087, 0)
	innerFrame.Size = UDim2.new(0.9, 0, 0.826, 0)
	innerFrame.BackgroundTransparency = 1
	innerFrame.Parent = container

	-- ═══════════════════════════════════════════════════════════
	-- ROW 1: Diamond COG icon + Weapon Name
	-- ═══════════════════════════════════════════════════════════
	local headerRow = Instance.new("Frame")
	headerRow.Name = "HeaderRow"
	headerRow.Size = UDim2.new(1, 0, 0.168, 0)
	headerRow.Position = UDim2.new(0, 0, 0.021, 0)
	headerRow.BackgroundTransparency = 1
	headerRow.Parent = innerFrame

	-- Small diamond icon (GOW COG insignia feel)
	local diamondIcon = Instance.new("TextLabel")
	diamondIcon.Name = "DiamondIcon"
	diamondIcon.Size = UDim2.new(0.055, 0, 0.875, 0)
	diamondIcon.Position = UDim2.new(0, 0, 0.06, 0)
	diamondIcon.BackgroundTransparency = 1
	diamondIcon.Font = Enum.Font.GothamBold
	diamondIcon.TextScaled = true
	diamondIcon.TextColor3 = COLOR_ACCENT
	diamondIcon.Text = "◆"
	diamondIcon.TextXAlignment = Enum.TextXAlignment.Center
	diamondIcon.Parent = headerRow
	self._diamondIcon = diamondIcon

	-- Weapon name
	local weaponNameLabel = Instance.new("TextLabel")
	weaponNameLabel.Name = "WeaponName"
	weaponNameLabel.Size = UDim2.new(0.93, 0, 1, 0)
	weaponNameLabel.Position = UDim2.new(0.07, 0, 0, 0)
	weaponNameLabel.BackgroundTransparency = 1
	weaponNameLabel.Font = Enum.Font.GothamMedium
	weaponNameLabel.TextScaled = true
	weaponNameLabel.TextColor3 = COLOR_TEXT_SECONDARY
	weaponNameLabel.TextXAlignment = Enum.TextXAlignment.Left
	weaponNameLabel.Text = "LANCER"
	weaponNameLabel.Parent = headerRow
	self._weaponNameLabel = weaponNameLabel
	
	local nameConstraint = Instance.new("UITextSizeConstraint")
	nameConstraint.MaxTextSize = 14
	nameConstraint.Parent = weaponNameLabel

	-- ═══════════════════════════════════════════════════════════
	-- HORIZONTAL SEPARATOR
	-- ═══════════════════════════════════════════════════════════
	local separator = Instance.new("Frame")
	separator.Name = "Separator"
	separator.Size = UDim2.new(1, 0, 0.01, 0)
	separator.Position = UDim2.new(0, 0, 0.23, 0)
	separator.BackgroundColor3 = COLOR_SEPARATOR
	separator.BackgroundTransparency = 0.5
	separator.BorderSizePixel = 0
	separator.Parent = innerFrame

	-- ═══════════════════════════════════════════════════════════
	-- ROW 2: AMMO COUNTER — Big numbers
	-- ═══════════════════════════════════════════════════════════
	local ammoRow = Instance.new("Frame")
	ammoRow.Name = "AmmoRow"
	ammoRow.Size = UDim2.new(1, 0, 0.44, 0)
	ammoRow.Position = UDim2.new(0, 0, 0.27, 0)
	ammoRow.BackgroundTransparency = 1
	ammoRow.Parent = innerFrame

	-- Current ammo (large, right-aligned in left half)
	local ammoCurrentLabel = Instance.new("TextLabel")
	ammoCurrentLabel.Name = "AmmoCurrent"
	ammoCurrentLabel.Size = UDim2.new(0.46, 0, 1, 0)
	ammoCurrentLabel.Position = UDim2.new(0, 0, 0, 0)
	ammoCurrentLabel.BackgroundTransparency = 1
	ammoCurrentLabel.Font = Enum.Font.GothamBlack
	ammoCurrentLabel.TextScaled = true
	ammoCurrentLabel.TextColor3 = COLOR_TEXT_PRIMARY
	ammoCurrentLabel.TextXAlignment = Enum.TextXAlignment.Right
	ammoCurrentLabel.Text = "24"
	ammoCurrentLabel.Parent = ammoRow
	self._ammoCurrentLabel = ammoCurrentLabel

	local pulseScale = Instance.new("UIScale")
	pulseScale.Parent = ammoCurrentLabel

	-- Vertical separator bar
	local ammoSep = Instance.new("Frame")
	ammoSep.Name = "AmmoSep"
	ammoSep.AnchorPoint = Vector2.new(0.5, 0.5)
	ammoSep.Size = UDim2.new(0.008, 0, 0.66, 0)
	ammoSep.Position = UDim2.new(0.5, 0, 0.5, 0)
	ammoSep.BackgroundColor3 = COLOR_SEPARATOR
	ammoSep.BorderSizePixel = 0
	ammoSep.Parent = ammoRow
	self._ammoSeparator = ammoSep

	-- Reserve ammo (smaller, left-aligned in right half)
	local ammoReserveLabel = Instance.new("TextLabel")
	ammoReserveLabel.Name = "AmmoReserve"
	ammoReserveLabel.Size = UDim2.new(0.46, 0, 0.63, 0)
	ammoReserveLabel.Position = UDim2.new(0.54, 0, 0.37, 0)
	ammoReserveLabel.BackgroundTransparency = 1
	ammoReserveLabel.Font = Enum.Font.GothamBold
	ammoReserveLabel.TextScaled = true
	ammoReserveLabel.TextColor3 = COLOR_TEXT_SECONDARY
	ammoReserveLabel.TextXAlignment = Enum.TextXAlignment.Left
	ammoReserveLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	ammoReserveLabel.Text = "96"
	ammoReserveLabel.Parent = ammoRow
	self._ammoReserveLabel = ammoReserveLabel

	-- ═══════════════════════════════════════════════════════════
	-- ROW 3: RELOAD BAR (hidden by default)
	-- ═══════════════════════════════════════════════════════════
	local reloadContainer = Instance.new("Frame")
	reloadContainer.Name = "ReloadContainer"
	reloadContainer.Size = UDim2.new(1, 0, 0.294, 0)
	reloadContainer.Position = UDim2.new(0, 0, 0.736, 0)
	reloadContainer.BackgroundTransparency = 1
	reloadContainer.Visible = false
	reloadContainer.Parent = innerFrame
	self._reloadContainer = reloadContainer

	-- Status label (RELOADING / PERFECT / JAMMED)
	local reloadStatusLabel = Instance.new("TextLabel")
	reloadStatusLabel.Name = "ReloadStatus"
	reloadStatusLabel.Size = UDim2.new(1, 0, 0.428, 0)
	reloadStatusLabel.Position = UDim2.new(0, 0, 0, 0)
	reloadStatusLabel.BackgroundTransparency = 1
	reloadStatusLabel.Font = Enum.Font.GothamBold
	reloadStatusLabel.TextScaled = true
	reloadStatusLabel.TextColor3 = COLOR_TEXT_SECONDARY
	reloadStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	reloadStatusLabel.Text = "RELOADING"
	reloadStatusLabel.Parent = reloadContainer
	self._reloadStatusLabel = reloadStatusLabel

	local statusConstraint = Instance.new("UITextSizeConstraint")
	statusConstraint.MaxTextSize = 12
	statusConstraint.Parent = reloadStatusLabel

	-- Bar background
	local reloadBarBg = Instance.new("Frame")
	reloadBarBg.Name = "ReloadBarBg"
	reloadBarBg.Size = UDim2.new(1, 0, 0.357, 0)
	reloadBarBg.Position = UDim2.new(0, 0, 0.535, 0)
	reloadBarBg.BackgroundColor3 = COLOR_RELOAD_BG
	reloadBarBg.BorderSizePixel = 0
	reloadBarBg.ClipsDescendants = true
	reloadBarBg.Parent = reloadContainer
	self._reloadBarBg = reloadBarBg

	-- Bar border (thin outline)
	local barBorder = Instance.new("UIStroke")
	barBorder.Thickness = 1
	barBorder.Color = COLOR_PANEL_BORDER
	barBorder.Parent = reloadBarBg

	-- Fill (progress from left)
	local reloadBarFill = Instance.new("Frame")
	reloadBarFill.Name = "ReloadFill"
	reloadBarFill.Size = UDim2.new(0, 0, 1, 0)
	reloadBarFill.BackgroundColor3 = COLOR_RELOAD_FILL
	reloadBarFill.BorderSizePixel = 0
	reloadBarFill.Parent = reloadBarBg
	self._reloadBarFill = reloadBarFill

	-- Sweet zone (active reload window)
	local sweetZone = Instance.new("Frame")
	sweetZone.Name = "SweetZone"
	sweetZone.Size = UDim2.new(0.15, 0, 1, 0) -- Will be set dynamically
	sweetZone.Position = UDim2.new(0.35, 0, 0, 0) -- Will be set dynamically
	sweetZone.BackgroundColor3 = COLOR_SWEET_ZONE
	sweetZone.BackgroundTransparency = 0.6
	sweetZone.BorderSizePixel = 0
	sweetZone.ZIndex = 2
	sweetZone.Parent = reloadBarBg
	self._sweetZone = sweetZone

	-- Sweet zone left marker (thin bright line)
	local sweetLeft = Instance.new("Frame")
	sweetLeft.Name = "SweetLeft"
	sweetLeft.Size = UDim2.new(0.008, 0, 1.4, 0)
	sweetLeft.Position = UDim2.new(0, 0, -0.2, 0)
	sweetLeft.AnchorPoint = Vector2.new(0.5, 0)
	sweetLeft.BackgroundColor3 = COLOR_SWEET_ZONE
	sweetLeft.BorderSizePixel = 0
	sweetLeft.ZIndex = 3
	sweetLeft.Parent = sweetZone
	self._sweetZoneMarkerLeft = sweetLeft

	-- Sweet zone right marker
	local sweetRight = Instance.new("Frame")
	sweetRight.Name = "SweetRight"
	sweetRight.Size = UDim2.new(0.008, 0, 1.4, 0)
	sweetRight.Position = UDim2.new(1, 0, -0.2, 0)
	sweetRight.AnchorPoint = Vector2.new(0.5, 0)
	sweetRight.BackgroundColor3 = COLOR_SWEET_ZONE
	sweetRight.BorderSizePixel = 0
	sweetRight.ZIndex = 3
	sweetRight.Parent = sweetZone
	self._sweetZoneMarkerRight = sweetRight

	-- Cursor (moving indicator)
	local reloadCursor = Instance.new("Frame")
	reloadCursor.Name = "Cursor"
	reloadCursor.Size = UDim2.new(0.015, 0, 1.6, 0)
	reloadCursor.Position = UDim2.new(0, 0, -0.3, 0)
	reloadCursor.AnchorPoint = Vector2.new(0.5, 0)
	reloadCursor.BackgroundColor3 = COLOR_RELOAD_CURSOR
	reloadCursor.BorderSizePixel = 0
	reloadCursor.ZIndex = 4
	reloadCursor.Parent = reloadBarBg
	self._reloadCursor = reloadCursor

	-- Cursor glow (larger, semi-transparent behind cursor)
	local cursorGlow = Instance.new("Frame")
	cursorGlow.Name = "CursorGlow"
	cursorGlow.Size = UDim2.new(3.0, 0, 1.6, 0)
	cursorGlow.Position = UDim2.new(0.5, 0, 0.5, 0)
	cursorGlow.AnchorPoint = Vector2.new(0.5, 0.5)
	cursorGlow.BackgroundColor3 = COLOR_ACCENT_BRIGHT
	cursorGlow.BackgroundTransparency = 0.7
	cursorGlow.BorderSizePixel = 0
	cursorGlow.ZIndex = 3
	cursorGlow.Parent = reloadCursor
	self._reloadCursorGlow = cursorGlow
end

------------------------------------------------------------------------
-- PRIVATE — Border line helper
------------------------------------------------------------------------

function WeaponHUD:_createBorderLine(parent: Frame, name: string, position: UDim2, size: UDim2): Frame
	local line = Instance.new("Frame")
	line.Name = "Border_" .. name
	line.Position = position
	line.Size = size
	line.BackgroundColor3 = COLOR_PANEL_BORDER
	line.BorderSizePixel = 0
	line.ZIndex = 2
	line.Parent = parent
	return line
end

------------------------------------------------------------------------
-- PRIVATE — Ammo Display
------------------------------------------------------------------------

function WeaponHUD:_updateAmmoDisplay(current: number, reserve: number)
	self._ammoCurrentLabel.Text = tostring(current)
	self._ammoReserveLabel.Text = tostring(reserve)

	-- Color coding — GOW style
	if current == 0 then
		self._ammoCurrentLabel.TextColor3 = COLOR_TEXT_NO_AMMO
		-- Pulse effect on empty
		self:_pulseElement(self._ammoCurrentLabel)
	elseif current <= 3 then
		self._ammoCurrentLabel.TextColor3 = COLOR_TEXT_LOW_AMMO
	else
		self._ammoCurrentLabel.TextColor3 = COLOR_TEXT_PRIMARY
	end
end

------------------------------------------------------------------------
-- PRIVATE — Pulse micro-animation
------------------------------------------------------------------------

function WeaponHUD:_pulseElement(element: TextLabel)
	-- Pulse effect using UIScale
	local uiScale = element:FindFirstChild("UIScale")
	if uiScale and uiScale:IsA("UIScale") then
		local tweenInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
		local tween = TweenService:Create(uiScale, tweenInfo, { Scale = 1.15 })
		tween:Play()
	end
end

------------------------------------------------------------------------
-- PRIVATE — Reload Display
------------------------------------------------------------------------

function WeaponHUD:_startReloadDisplay(
	_weaponName: string,
	reloadTime: number,
	windowStart: number,
	windowDuration: number
)
	self._isReloading = true
	self._reloadStartTime = os.clock()
	self._reloadDuration = reloadTime
	self._windowStart = windowStart
	self._windowDuration = windowDuration
	self._activeReloadResult = nil

	-- Show reload bar
	self._reloadContainer.Visible = true
	self._reloadStatusLabel.Text = "RELOADING"
	self._reloadStatusLabel.TextColor3 = COLOR_TEXT_SECONDARY
	self._reloadBarFill.Size = UDim2.new(0, 0, 1, 0)
	self._reloadBarFill.BackgroundColor3 = COLOR_RELOAD_FILL
	self._reloadCursor.Visible = true
	self._reloadCursor.Position = UDim2.new(0, 0, -0.3, 0)
	self._reloadCursor.BackgroundColor3 = COLOR_RELOAD_CURSOR
	self._reloadCursorGlow.BackgroundColor3 = COLOR_ACCENT_BRIGHT
	self._reloadCursorGlow.BackgroundTransparency = 0.7

	-- Position the sweet zone
	self._sweetZone.Position = UDim2.new(windowStart, 0, 0, 0)
	self._sweetZone.Size = UDim2.new(windowDuration, 0, 1, 0)
	self._sweetZone.BackgroundColor3 = COLOR_SWEET_ZONE
	self._sweetZone.BackgroundTransparency = 0.6
	self._sweetZone.Visible = true
	self._sweetZoneMarkerLeft.BackgroundColor3 = COLOR_SWEET_ZONE
	self._sweetZoneMarkerRight.BackgroundColor3 = COLOR_SWEET_ZONE

	-- Animate border accent to indicate reload
	self._accentLine.BackgroundColor3 = COLOR_ACCENT_BRIGHT

	-- Cursor animation via Heartbeat
	if self._heartbeatConn then
		self._heartbeatConn:Disconnect()
	end

	self._heartbeatConn = RunService.Heartbeat:Connect(function()
		if not self._isReloading then
			return
		end

		-- If active reload already resolved, stop cursor
		if self._activeReloadResult then
			return
		end

		local elapsed = os.clock() - self._reloadStartTime
		local progress = math.clamp(elapsed / self._reloadDuration, 0, 1)

		-- Move cursor
		self._reloadCursor.Position = UDim2.new(progress, 0, -0.3, 0)

		-- Fill bar behind cursor
		self._reloadBarFill.Size = UDim2.new(progress, 0, 1, 0)

		-- Cursor color change when inside sweet zone
		local windowEnd = self._windowStart + self._windowDuration
		if progress >= self._windowStart and progress <= windowEnd then
			self._reloadCursor.BackgroundColor3 = COLOR_SWEET_ZONE
			self._reloadCursorGlow.BackgroundColor3 = COLOR_SWEET_ZONE
			self._reloadCursorGlow.BackgroundTransparency = 0.4
		else
			self._reloadCursor.BackgroundColor3 = COLOR_RELOAD_CURSOR
			self._reloadCursorGlow.BackgroundColor3 = COLOR_ACCENT_BRIGHT
			self._reloadCursorGlow.BackgroundTransparency = 0.7
		end
	end)
end

function WeaponHUD:_flashActiveReloadResult(result: string)
	self._activeReloadResult = result

	if result == "perfect" then
		-- Flash green — PERFECT
		self._reloadStatusLabel.Text = "◆ PERFECT RELOAD"
		self._reloadStatusLabel.TextColor3 = COLOR_PERFECT
		self._reloadCursor.BackgroundColor3 = COLOR_PERFECT
		self._reloadCursorGlow.BackgroundColor3 = COLOR_PERFECT
		self._reloadCursorGlow.BackgroundTransparency = 0.3
		self._reloadBarFill.BackgroundColor3 = Color3.fromRGB(30, 120, 60)
		self._sweetZone.BackgroundColor3 = COLOR_PERFECT
		self._sweetZone.BackgroundTransparency = 0.3
		self._accentLine.BackgroundColor3 = COLOR_PERFECT

		-- Flash the entire panel border green briefly
		self._borderTop.BackgroundColor3 = COLOR_PERFECT
		self._borderBottom.BackgroundColor3 = COLOR_PERFECT
		self._borderLeft.BackgroundColor3 = COLOR_PERFECT
		self._borderRight.BackgroundColor3 = COLOR_PERFECT

		task.delay(0.5, function()
			self:_resetBorderColor()
		end)
	elseif result == "jammed" then
		-- Flash red — JAMMED
		self._reloadStatusLabel.Text = "✕ JAMMED"
		self._reloadStatusLabel.TextColor3 = COLOR_JAMMED
		self._reloadCursor.BackgroundColor3 = COLOR_JAMMED
		self._reloadCursorGlow.BackgroundColor3 = COLOR_JAMMED
		self._reloadCursorGlow.BackgroundTransparency = 0.3
		self._reloadBarFill.BackgroundColor3 = Color3.fromRGB(120, 30, 30)
		self._accentLine.BackgroundColor3 = COLOR_JAMMED

		-- Flash border red
		self._borderTop.BackgroundColor3 = COLOR_JAMMED
		self._borderBottom.BackgroundColor3 = COLOR_JAMMED
		self._borderLeft.BackgroundColor3 = COLOR_JAMMED
		self._borderRight.BackgroundColor3 = COLOR_JAMMED

		task.delay(0.5, function()
			self:_resetBorderColor()
		end)
	end
end

function WeaponHUD:_stopReloadDisplay(reason: string?)
	local wasReloading = self._isReloading
	self._isReloading = false
	self._activeReloadResult = nil

	if self._heartbeatConn then
		self._heartbeatConn:Disconnect()
		self._heartbeatConn = nil
	end

	if not wasReloading and reason ~= "cancelled" then
		self._reloadContainer.Visible = false
		return
	end

	-- Reset accent line
	self._accentLine.BackgroundColor3 = COLOR_ACCENT

	if reason == "complete" then
		-- Already had active reload feedback? Just hide.
		-- Otherwise show normal completion
		if not self._activeReloadResult then
			self._reloadStatusLabel.Text = "RELOAD COMPLETE"
			self._reloadStatusLabel.TextColor3 = COLOR_COMPLETE
			self._reloadBarFill.Size = UDim2.new(1, 0, 1, 0)
			self._reloadBarFill.BackgroundColor3 = COLOR_COMPLETE
			self._reloadCursor.Visible = false
		end

		task.delay(0.8, function()
			if not self._isReloading then
				self._reloadContainer.Visible = false
			end
		end)
	elseif reason == "cancelled" then
		self._reloadStatusLabel.Text = "CANCELLED"
		self._reloadStatusLabel.TextColor3 = COLOR_TEXT_LOW_AMMO
		self._reloadCursor.Visible = false

		task.delay(0.5, function()
			if not self._isReloading then
				self._reloadContainer.Visible = false
			end
		end)
	else
		-- nil / unknown → just hide
		self._reloadContainer.Visible = false
	end

	self:_resetBorderColor()
end

------------------------------------------------------------------------
-- PRIVATE — Border color reset
------------------------------------------------------------------------

function WeaponHUD:_resetBorderColor()
	if self._borderTop then
		self._borderTop.BackgroundColor3 = COLOR_PANEL_BORDER
	end
	if self._borderBottom then
		self._borderBottom.BackgroundColor3 = COLOR_PANEL_BORDER
	end
	if self._borderLeft then
		self._borderLeft.BackgroundColor3 = COLOR_PANEL_BORDER
	end
	if self._borderRight then
		self._borderRight.BackgroundColor3 = COLOR_PANEL_BORDER
	end
end

------------------------------------------------------------------------
-- PRIVATE — Connection cleanup
------------------------------------------------------------------------

function WeaponHUD:_clearWeaponConnections()
	for _, conn in self._weaponConnections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif type(conn) == "table" and conn.Disconnect then
			conn:Disconnect()
		end
	end
	table.clear(self._weaponConnections)
end

return WeaponHUD
