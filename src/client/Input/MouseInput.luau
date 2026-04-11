--[[
	MouseInput.luau
	═══════════════════════════════════════════════════════════════
	CAPA 1 — Input: Lectura de mouse delta y control del cursor
	═══════════════════════════════════════════════════════════════

	Encapsula UserInputService:GetMouseDelta() y MouseBehavior
	para que la capa de Presentación (CameraController) no acceda
	directamente al servicio de input.
]]

local UserInputService = game:GetService("UserInputService")

local MouseInput = {}
MouseInput.__index = MouseInput

function MouseInput.new()
	local self = setmetatable({}, MouseInput)
	self._lastDelta = Vector2.zero
	return self
end

function MouseInput:Init() end

--- Bloquea el cursor al centro de la pantalla.
function MouseInput:Start()
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
end

--- Lee el delta del mouse este frame. Llamar una vez por frame antes de CameraController:Update().
function MouseInput:Update()
	self._lastDelta = UserInputService:GetMouseDelta()
	-- Mantener el cursor bloqueado (Roblox puede resetearlo en algunos casos)
	if UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
end

--- Retorna el delta del mouse leído en el último Update().
function MouseInput:GetDelta(): Vector2
	return self._lastDelta
end

function MouseInput:Destroy() end

return MouseInput
