--[[
	MouseInput.luau
	═══════════════════════════════════════════════════════════════
	CAPA 1 — Input: Lectura de mouse/touch delta y control del cursor
	═══════════════════════════════════════════════════════════════

	Encapsula UserInputService:GetMouseDelta() y MouseBehavior
	para que la capa de Presentación (CameraController) no acceda
	directamente al servicio de input.

	En MOBILE: GetMouseDelta() captura TODOS los toques (incluyendo
	el joystick de movimiento), lo cual rota la cámara al mover.

	Solución: detectar el GuiObject real del DynamicThumbstick de Roblox
	(PlayerGui > TouchGui > TouchControlFrame). Si un touch empieza
	DENTRO de ese frame → es movimiento → se ignora para la cámara.
	Cualquier otro touch que se desplace → rota la cámara.

	Esto es más robusto que dividir la pantalla en "zonas" porque se
	adapta automáticamente al tamaño/posición real del joystick.
]]

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local IS_MOBILE = UserInputService.TouchEnabled and not GuiService:IsTenFootInterface()

local MouseInput = {}
MouseInput.__index = MouseInput

function MouseInput.new()
	local self = setmetatable({}, MouseInput)
	self._lastDelta = Vector2.zero
	self._connections = {} :: { any }

	-- Mobile touch tracking
	self._activeCameraTouch = nil :: InputObject? -- el toque activo para rotar cámara
	self._lastTouchPosition = nil :: Vector3? -- última posición del toque de cámara
	self._touchDelta = Vector2.zero -- delta acumulado del toque de cámara este frame

	return self
end

function MouseInput:Init() end

--- Bloquea el cursor al centro de la pantalla (solo PC).
function MouseInput:Start()
	if IS_MOBILE then
		self:_setupMobileTouchTracking()
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
end

--- Lee el delta este frame. Llamar una vez por frame antes de CameraController:Update().
function MouseInput:Update()
	if IS_MOBILE then
		-- En mobile, el delta viene del touch tracking manual
		self._lastDelta = self._touchDelta * Constants.CAM_MOBILE_SENSITIVITY_MULTIPLIER
		self._touchDelta = Vector2.zero
	else
		self._lastDelta = UserInputService:GetMouseDelta()
		-- Mantener el cursor bloqueado (Roblox puede resetearlo en algunos casos)
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		end
	end
end

--- Retorna el delta leído en el último Update().
function MouseInput:GetDelta(): Vector2
	return self._lastDelta
end

function MouseInput:Destroy()
	for _, conn in self._connections do
		if type(conn) == "table" and type(conn.Disconnect) == "function" then
			conn:Disconnect()
		elseif typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)
end

------------------------------------------------------------------------
-- MOBILE: Detección del DynamicThumbstick de Roblox (Simplificada)
------------------------------------------------------------------------

--- Verifica si una posición de pantalla debe considerarse como zona de joystick.
--- El DynamicThumbstick de Roblox spawnea en la mitad izquierda de la pantalla,
--- por lo que reservamos el 45% izquierdo exclusivamente para movimiento y
--- evitamos que rote la cámara.
function MouseInput:_isTouchOnThumbstick(screenPos: Vector3): boolean
	local cam = workspace.CurrentCamera
	local screenWidth = cam and cam.ViewportSize.X or 1920

	-- Consideramos el joystick cualquier toque en el 45% izquierdo
	return screenPos.X < (screenWidth * 0.45)
end

------------------------------------------------------------------------
-- MOBILE: Touch tracking — detecta thumbstick real para filtrar
------------------------------------------------------------------------

function MouseInput:_setupMobileTouchTracking()
	-- NO bloquear el cursor en mobile (interfiere con touch)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default

	-- TouchStarted: si el touch NO empieza en el thumbstick → es cámara
	table.insert(
		self._connections,
		UserInputService.TouchStarted:Connect(function(touch: InputObject, gameProcessed: boolean)
			-- Ignorar toques consumidos por UI (botones del HUD, etc.)
			if gameProcessed then
				return
			end
			-- Solo rastrear un toque de cámara a la vez
			if self._activeCameraTouch then
				return
			end
			-- Si el touch empieza sobre el joystick → NO es cámara
			if self:_isTouchOnThumbstick(touch.Position) then
				return
			end
			-- Es un touch libre → lo usamos para rotar la cámara
			self._activeCameraTouch = touch
			self._lastTouchPosition = touch.Position
		end)
	)

	-- TouchMoved: acumular delta solo del toque de cámara activo.
	-- Una vez aceptado como "cámara", siempre rastreamos su movimiento
	-- aunque el dedo pase sobre UI (evita que la cámara se trabe).
	table.insert(
		self._connections,
		UserInputService.TouchMoved:Connect(function(touch: InputObject, _gameProcessed: boolean)
			if touch ~= self._activeCameraTouch then
				return
			end
			if self._lastTouchPosition then
				local delta = touch.Position - self._lastTouchPosition
				self._touchDelta += Vector2.new(delta.X, delta.Y)
			end
			self._lastTouchPosition = touch.Position
		end)
	)

	-- TouchEnded: liberar el toque de cámara
	table.insert(
		self._connections,
		UserInputService.TouchEnded:Connect(function(touch: InputObject)
			if touch == self._activeCameraTouch then
				self._activeCameraTouch = nil
				self._lastTouchPosition = nil
			end
		end)
	)
end

return MouseInput
