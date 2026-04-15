--[[
	AmmoHUD.client.luau  (TEST — borrar después)
	═══════════════════════════════════════════════════════════════
	UI sencilla de prueba que muestra:
	  • Balas actuales / reserva
	  • Porcentaje de recarga cuando se está recargando
	═══════════════════════════════════════════════════════════════
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

------------------------------------------------------------------------
-- UI — Crear ScreenGui
------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AmmoHUD_Test"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 100
screenGui.Parent = player:WaitForChild("PlayerGui")

-- Contenedor principal (esquina inferior derecha)
local container = Instance.new("Frame")
container.Name = "AmmoContainer"
container.AnchorPoint = Vector2.new(1, 1)
container.Position = UDim2.new(1, -30, 1, -30)
container.Size = UDim2.new(0, 220, 0, 90)
container.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
container.BackgroundTransparency = 0.3
container.BorderSizePixel = 0
container.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = container

local padding = Instance.new("UIPadding")
padding.PaddingLeft = UDim.new(0, 14)
padding.PaddingRight = UDim.new(0, 14)
padding.PaddingTop = UDim.new(0, 10)
padding.PaddingBottom = UDim.new(0, 10)
padding.Parent = container

-- Label de munición: "12 / 48"
local ammoLabel = Instance.new("TextLabel")
ammoLabel.Name = "AmmoLabel"
ammoLabel.Size = UDim2.new(1, 0, 0, 32)
ammoLabel.Position = UDim2.new(0, 0, 0, 0)
ammoLabel.BackgroundTransparency = 1
ammoLabel.Font = Enum.Font.GothamBold
ammoLabel.TextSize = 28
ammoLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
ammoLabel.TextXAlignment = Enum.TextXAlignment.Right
ammoLabel.Text = "-- / --"
ammoLabel.Parent = container

-- Label de recarga: "Recargando: 45%"
local reloadLabel = Instance.new("TextLabel")
reloadLabel.Name = "ReloadLabel"
reloadLabel.Size = UDim2.new(1, 0, 0, 18)
reloadLabel.Position = UDim2.new(0, 0, 0, 36)
reloadLabel.BackgroundTransparency = 1
reloadLabel.Font = Enum.Font.GothamMedium
reloadLabel.TextSize = 16
reloadLabel.TextColor3 = Color3.fromRGB(200, 200, 80)
reloadLabel.TextXAlignment = Enum.TextXAlignment.Right
reloadLabel.Text = ""
reloadLabel.Visible = false
reloadLabel.Parent = container

-- Barra de recarga (fondo)
local reloadBarBg = Instance.new("Frame")
reloadBarBg.Name = "ReloadBarBg"
reloadBarBg.Size = UDim2.new(1, 0, 0, 6)
reloadBarBg.Position = UDim2.new(0, 0, 0, 58)
reloadBarBg.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
reloadBarBg.BorderSizePixel = 0
reloadBarBg.Visible = false
reloadBarBg.Parent = container

local barCorner = Instance.new("UICorner")
barCorner.CornerRadius = UDim.new(0, 3)
barCorner.Parent = reloadBarBg

-- Barra de recarga (fill)
local reloadBarFill = Instance.new("Frame")
reloadBarFill.Name = "ReloadBarFill"
reloadBarFill.Size = UDim2.new(0, 0, 1, 0)
reloadBarFill.BackgroundColor3 = Color3.fromRGB(200, 200, 80)
reloadBarFill.BorderSizePixel = 0
reloadBarFill.Parent = reloadBarBg

local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(0, 3)
fillCorner.Parent = reloadBarFill

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------

local isReloading = false
local reloadStartTime = 0
local reloadDuration = 0
local heartbeatConn: RBXScriptConnection? = nil
local weaponConnections: { RBXScriptConnection | { Disconnect: () -> () } } = {}

------------------------------------------------------------------------
-- UPDATE FUNCTIONS
------------------------------------------------------------------------

local function updateAmmoDisplay(current: number, reserve: number)
	ammoLabel.Text = `{current} / {reserve}`

	-- Cambiar color si bajas de munición
	if current == 0 then
		ammoLabel.TextColor3 = Color3.fromRGB(255, 60, 60)
	elseif current <= 3 then
		ammoLabel.TextColor3 = Color3.fromRGB(255, 180, 50)
	else
		ammoLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	end
end

local function startReloadDisplay(
	_weaponName: string,
	reloadTime: number,
	_windowStart: number,
	_windowDuration: number
)
	isReloading = true
	reloadStartTime = os.clock()
	reloadDuration = reloadTime

	reloadLabel.Visible = true
	reloadLabel.Text = "Recargando: 0%"
	reloadLabel.TextColor3 = Color3.fromRGB(200, 200, 80)
	reloadBarBg.Visible = true
	reloadBarFill.Size = UDim2.new(0, 0, 1, 0)
	reloadBarFill.BackgroundColor3 = Color3.fromRGB(200, 200, 80)

	-- Heartbeat para actualizar porcentaje
	if heartbeatConn then
		heartbeatConn:Disconnect()
	end
	heartbeatConn = RunService.Heartbeat:Connect(function()
		if not isReloading then
			return
		end
		local elapsed = os.clock() - reloadStartTime
		local progress = math.clamp(elapsed / reloadDuration, 0, 1)
		local pct = math.floor(progress * 100)
		reloadLabel.Text = `Recargando: {pct}%`
		reloadBarFill.Size = UDim2.new(progress, 0, 1, 0)
	end)
end

local function stopReloadDisplay(success: boolean?)
	isReloading = false
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end

	if success then
		reloadLabel.Text = "Recarga completa!"
		reloadLabel.TextColor3 = Color3.fromRGB(80, 255, 80)
		reloadBarFill.Size = UDim2.new(1, 0, 1, 0)
		reloadBarFill.BackgroundColor3 = Color3.fromRGB(80, 255, 80)
		task.delay(1, function()
			if not isReloading then
				reloadLabel.Visible = false
				reloadBarBg.Visible = false
			end
		end)
	else
		reloadLabel.Text = "Recarga cancelada"
		reloadLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
		reloadBarFill.BackgroundColor3 = Color3.fromRGB(255, 80, 80)
		task.delay(0.8, function()
			if not isReloading then
				reloadLabel.Visible = false
				reloadBarBg.Visible = false
			end
		end)
	end
end

------------------------------------------------------------------------
-- Hook: escuchar WeaponClient compartido via _G (test only)
------------------------------------------------------------------------

local function clearWeaponConnections()
	for _, conn in weaponConnections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif conn.Disconnect then
			conn.Disconnect()
		end
	end
	table.clear(weaponConnections)
end

local function bindToWeaponClient()
	-- selene: allow(global_usage)
	local hookTable = _G._testAmmoHUD
	if not hookTable then
		return
	end

	local wc = hookTable.WeaponClient
	if not wc then
		return
	end

	-- Limpiar conexiones del arma anterior
	clearWeaponConnections()
	stopReloadDisplay(false)

	-- AmmoChanged -> update display
	if wc.AmmoChanged then
		table.insert(
			weaponConnections,
			wc.AmmoChanged:Connect(function(current, reserve)
				updateAmmoDisplay(current, reserve)
			end)
		)
	end

	-- Reload signals from ReloadHandler
	local rh = hookTable.ReloadHandler or (wc.GetReloadHandler and wc:GetReloadHandler())
	if rh then
		if rh.ReloadBegan then
			table.insert(
				weaponConnections,
				rh.ReloadBegan:Connect(function(weaponName, reloadTime, windowStart, windowDuration)
					startReloadDisplay(weaponName, reloadTime, windowStart, windowDuration)
				end)
			)
		end
		if rh.ReloadCompleted then
			table.insert(
				weaponConnections,
				rh.ReloadCompleted:Connect(function()
					stopReloadDisplay(true)
				end)
			)
		end
		if rh.ReloadCancelled then
			table.insert(
				weaponConnections,
				rh.ReloadCancelled:Connect(function()
					stopReloadDisplay(false)
				end)
			)
		end
	end

	container.Visible = true
	updateAmmoDisplay(wc:GetCurrentAmmo(), wc:GetReserveAmmo())
end

------------------------------------------------------------------------
-- INIT — Esperar a que ClientApp exponga el WeaponClient via _G
------------------------------------------------------------------------

container.Visible = true
ammoLabel.Text = "Sin arma"

task.defer(function()
	-- Polling: esperar hasta que ClientApp ponga el hook
	-- selene: allow(global_usage)
	while not _G._testAmmoHUD do
		task.wait(0.25)
	end

	-- Bind inicial
	bindToWeaponClient()

	-- Registrar callback para swaps de arma futuros
	-- selene: allow(global_usage)
	_G._testAmmoHUD_onSwap = function()
		bindToWeaponClient()
	end

	print("[AmmoHUD] Conectado a WeaponClient")
end)
