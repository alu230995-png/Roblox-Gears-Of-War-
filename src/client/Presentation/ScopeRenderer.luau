--[[
	ScopeRenderer.luau
	═══════════════════════════════════════════════════════════════
	Renderiza el crosshair (scope) en pantalla con dots por pellet.
	═══════════════════════════════════════════════════════════════

	Uso:
	  local scope = ScopeRenderer.new(player, spreadPattern)
	  scope:SetVisible(true)
	  scope:SetAiming(true)  -- tween a tamaño reducido
	  scope:SetAiming(false) -- tween a tamaño normal
	  local container = scope:GetContainer() -- Frame con los dots
	  scope:Destroy()

	Cada pellet del SpreadPattern se representa como un Frame circular
	posicionado con UDim2 relativo dentro del contenedor.
	Al apuntar, el contenedor se encoge (SCOPE_SIZE_NORMAL → SCOPE_SIZE_AIMING)
	para simular mayor precisión.
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

local TWEEN_INFO = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------

local ScopeRenderer = {}
ScopeRenderer.__index = ScopeRenderer

--- Crea un nuevo ScopeRenderer con dots basados en el SpreadPattern del arma.
--- @param player Player — jugador local (para PlayerGui)
--- @param spreadPattern { [number]: UDim2 } — posiciones de pellets en espacio relativo
function ScopeRenderer.new(player: Player, spreadPattern: { [number]: UDim2 })
	local self = setmetatable({}, ScopeRenderer)

	self._player = player
	self._spreadPattern = spreadPattern
	self._isAiming = false
	self._tween = nil :: Tween?

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

	-- Crear dots para cada pellet
	self._dots = {}
	for i, pos in spreadPattern do
		local dot = Instance.new("Frame")
		dot.Name = "Pellet_" .. tostring(i)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = pos
		dot.Size = UDim2.new(0, DOT_RADIUS * 2, 0, DOT_RADIUS * 2)
		dot.BackgroundColor3 = Color3.new(1, 1, 1)
		dot.BorderSizePixel = 0
		dot.Parent = container

		-- Hacerlo circular
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

	-- Cancelar tween anterior
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

--- Limpieza total.
function ScopeRenderer:Destroy()
	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end

	if self._screenGui then
		self._screenGui:Destroy()
		self._screenGui = nil
	end

	self._container = nil
	self._dots = nil
end

return ScopeRenderer
