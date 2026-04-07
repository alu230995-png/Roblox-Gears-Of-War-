--[[
	InputDetector.luau
	═══════════════════════════════════════════════════════════════
	CAPA 1: Detección de Raw Inputs
	═══════════════════════════════════════════════════════════════
	
	Solo detecta hechos físicos. No decide significado.
	Un input es un hecho: tecla presionada, gatillo activado, stick movido.
	
	Emite eventos discretos (queued para consumir por frame):
	  CoverButton   → Tap | HoldStart | Release
	  SprintModifier → Pressed | Released
	  FireButton    → Pressed | Released
	  AimButton     → Pressed | Released
	  ReloadButton  → Pressed
	  BlindFireButton → Pressed | Released
	  MeleeButton   → Tap | HoldStart | Release
	  EvadeButton   → Pressed
	  InteractButton → Pressed
	  SwapWeapon    → Pressed (data = slot number)
	
	Provee polling continuo:
	  GetMoveDirection() → Vector2
	  IsHeld(rawName)    → boolean
]]

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local InputDetector = {}
InputDetector.__index = InputDetector

function InputDetector.new()
	local self = setmetatable({}, InputDetector)

	-- Cola de eventos discretos (drenada cada frame por IntentMapper)
	self._eventQueue = {}

	-- Tracking de teclas held: [key] = pressStartTime
	self._heldKeys = {}
	-- Tracking de hold ya emitido: [key] = true
	self._holdEmitted = {}
	-- Reverse index: [rawName] = count de keys held que mapean a ese raw
	self._heldByRaw = {}

	-- Conexiones a limpiar
	self._connections = {}

	-- Dirección de movimiento actual (polling)
	self._moveDirection = Vector2.zero

	-- WASD → vectores de dirección
	self._moveKeys = {
		[Enum.KeyCode.W] = Vector2.new(0, 1),
		[Enum.KeyCode.S] = Vector2.new(0, -1),
		[Enum.KeyCode.A] = Vector2.new(-1, 0),
		[Enum.KeyCode.D] = Vector2.new(1, 0),
	}

	------------------------------------------------------------------------
	-- MAPEO: KeyCode/UserInputType → RawInputName
	-- Basado en el layout de Gears of War adaptado a PC
	------------------------------------------------------------------------
	self._keyToRaw = {
		-- Botón contexto-sensitivo (tap/hold como GoW A button)
		[Enum.KeyCode.Space] = "CoverButton",

		-- Sprint separado en PC (Shift = RoadieRun)
		[Enum.KeyCode.LeftShift] = "SprintModifier",

		-- Evade separado en PC (Alt = Roll)
		[Enum.KeyCode.LeftAlt] = "EvadeButton",

		-- Combate
		[Enum.UserInputType.MouseButton1] = "FireButton",
		[Enum.UserInputType.MouseButton2] = "AimButton",
		[Enum.KeyCode.R] = "ReloadButton",
		[Enum.KeyCode.Q] = "BlindFireButton",

		-- Melee (tap = golpe, hold = chainsaw)
		[Enum.KeyCode.V] = "MeleeButton",

		-- Interacción (curb stomp, rescatar, activar objetos)
		[Enum.KeyCode.E] = "InteractButton",
		[Enum.KeyCode.F] = "InteractButton",

		-- Swap weapon
		[Enum.KeyCode.One] = "SwapWeapon",
		[Enum.KeyCode.Two] = "SwapWeapon",
		[Enum.KeyCode.Three] = "SwapWeapon",
	}

	------------------------------------------------------------------------
	-- MAPEO GAMEPAD (contexto-sensitivo como GoW original)
	------------------------------------------------------------------------
	self._gamepadToRaw = {
		[Enum.KeyCode.ButtonA] = "CoverButton", -- A = contexto-sensitivo
		[Enum.KeyCode.ButtonR2] = "FireButton",
		[Enum.KeyCode.ButtonL2] = "AimButton",
		[Enum.KeyCode.ButtonR1] = "ReloadButton",
		[Enum.KeyCode.ButtonB] = "MeleeButton",
		[Enum.KeyCode.ButtonX] = "InteractButton",
		[Enum.KeyCode.ButtonY] = "SwapWeapon",
	}

	------------------------------------------------------------------------
	-- Botones que usan detección TAP vs HOLD
	-- Los demás emiten Pressed/Released inmediato
	------------------------------------------------------------------------
	self._holdThresholds = {
		CoverButton = Constants.HOLD_THRESHOLD, -- 150ms
		MeleeButton = Constants.MELEE_HOLD_THRESHOLD, -- 500ms
	}

	------------------------------------------------------------------------
	-- Mapeo de teclas numéricas a slot de arma
	------------------------------------------------------------------------
	self._weaponSlots = {
		[Enum.KeyCode.One] = 1,
		[Enum.KeyCode.Two] = 2,
		[Enum.KeyCode.Three] = 3,
		[Enum.KeyCode.ButtonY] = 0, -- Gamepad: cycle
	}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function InputDetector:Start()
	table.insert(
		self._connections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return
			end
			self:_onInputBegan(input)
		end)
	)

	table.insert(
		self._connections,
		UserInputService.InputEnded:Connect(function(input, _gameProcessed)
			-- SIEMPRE procesar release para keys que ya estamos trackeando.
			-- Si ignoramos releases con gameProcessed=true, _heldKeys retiene
			-- phantom entries → sprint/fire infinito al perder foco a UI.
			local key = self:_getKey(input)
			if self._heldKeys[key] == nil then
				return
			end
			self:_onInputEnded(input)
		end)
	)

	-- Heartbeat: hold detection + move direction polling
	table.insert(
		self._connections,
		RunService.Heartbeat:Connect(function(_dt)
			self:_updateHolds()
			self:_updateMoveDirection()
		end)
	)
end

function InputDetector:Destroy()
	for _, conn in self._connections do
		conn:Disconnect()
	end
	table.clear(self._connections)
	table.clear(self._eventQueue)
	table.clear(self._heldKeys)
	table.clear(self._holdEmitted)
	table.clear(self._heldByRaw)
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Drena la cola de eventos. Llamar una vez por frame desde IntentMapper.
--- Retorna la lista de eventos y limpia la cola.
function InputDetector:DrainEvents(): { { Name: string, Mode: string, Data: any?, Timestamp: number } }
	local events = self._eventQueue
	if #events == 0 then
		return events
	end
	self._eventQueue = {}
	return events
end

--- Dirección de movimiento actual (WASD normalizado).
function InputDetector:GetMoveDirection(): Vector2
	return self._moveDirection
end

--- Verifica si un raw input está actualmente held. O(1).
function InputDetector:IsRawHeld(rawName: string): boolean
	return (self._heldByRaw[rawName] or 0) > 0
end

--- Tiempo que lleva held un raw input. Retorna 0 si no está held.
function InputDetector:GetHoldDuration(rawName: string): number
	local now = os.clock()
	for key, pressStart in self._heldKeys do
		local name = self._keyToRaw[key] or self._gamepadToRaw[key]
		if name == rawName then
			return now - pressStart
		end
	end
	return 0
end

------------------------------------------------------------------------
-- RUTA UI / MÓVIL
-- Botones HUD, touchscreen, o cualquier UI que quiera simular input.
-- Llámalo desde el controlador del botón UI:
--   inputDetector:FireUIButton("CoverButton", "Tap")
--   inputDetector:FireUIButton("FireButton", "Pressed")
--   inputDetector:FireUIButton("SwapWeapon", "Pressed", 2) -- slot 2
------------------------------------------------------------------------
function InputDetector:FireUIButton(rawName: string, mode: string, data: any?)
	self:_queueEvent(rawName, mode, data)
end

------------------------------------------------------------------------
-- INTERNAL: Input Began
------------------------------------------------------------------------

function InputDetector:_onInputBegan(input: InputObject)
	local rawName = self:_getRawName(input)
	if not rawName then
		return
	end

	-- Registrar press time y reverse index
	local key = self:_getKey(input)
	self._heldKeys[key] = os.clock()
	self._holdEmitted[key] = false
	self._heldByRaw[rawName] = (self._heldByRaw[rawName] or 0) + 1

	-- Si NO es hold-sensitive, emitir Pressed inmediatamente
	if not self._holdThresholds[rawName] then
		local data = self._weaponSlots[input.KeyCode]
		self:_queueEvent(rawName, "Pressed", data)
	end
	-- Si ES hold-sensitive, esperar (hold detection en _updateHolds)
end

------------------------------------------------------------------------
-- INTERNAL: Input Ended
------------------------------------------------------------------------

function InputDetector:_onInputEnded(input: InputObject)
	local rawName = self:_getRawName(input)
	if not rawName then
		return
	end

	local key = self:_getKey(input)
	local pressStart = self._heldKeys[key]
	local wasHoldEmitted = self._holdEmitted[key]

	-- Limpiar tracking + reverse index
	self._heldKeys[key] = nil
	self._holdEmitted[key] = nil
	local count = (self._heldByRaw[rawName] or 0) - 1
	self._heldByRaw[rawName] = if count > 0 then count else nil

	if self._holdThresholds[rawName] and pressStart then
		-- Botón hold-sensitive
		if wasHoldEmitted then
			-- Ya se emitió HoldStart → ahora emitir Release
			local holdDuration = os.clock() - pressStart
			self:_queueEvent(rawName, "Release", holdDuration)
		else
			-- Nunca alcanzó threshold → es un Tap
			self:_queueEvent(rawName, "Tap", nil)
		end
	else
		-- Botón normal → Released
		self:_queueEvent(rawName, "Released", nil)
	end
end

------------------------------------------------------------------------
-- INTERNAL: Hold Detection (cada frame)
------------------------------------------------------------------------

function InputDetector:_updateHolds()
	local now = os.clock()

	for key, pressStart in self._heldKeys do
		-- Solo procesar botones hold-sensitive que aún no emitieron HoldStart
		if self._holdEmitted[key] then
			continue
		end

		local rawName = self._keyToRaw[key] or self._gamepadToRaw[key]
		if not rawName then
			continue
		end

		local threshold = self._holdThresholds[rawName]
		if not threshold then
			continue
		end

		local elapsed = now - pressStart
		if elapsed >= threshold then
			self._holdEmitted[key] = true
			self:_queueEvent(rawName, "HoldStart", elapsed)
		end
	end
end

------------------------------------------------------------------------
-- INTERNAL: Move Direction (cada frame)
------------------------------------------------------------------------

function InputDetector:_updateMoveDirection()
	local dir = Vector2.zero

	for keyCode, vec in self._moveKeys do
		if UserInputService:IsKeyDown(keyCode) then
			dir += vec
		end
	end

	if dir.Magnitude > 0 then
		dir = dir.Unit
	end

	self._moveDirection = dir
end

------------------------------------------------------------------------
-- INTERNAL: Utilidades
------------------------------------------------------------------------

function InputDetector:_getRawName(input: InputObject): string?
	if input.KeyCode ~= Enum.KeyCode.Unknown then
		return self._keyToRaw[input.KeyCode] or self._gamepadToRaw[input.KeyCode]
	else
		return self._keyToRaw[input.UserInputType]
	end
end

function InputDetector:_getKey(input: InputObject): any
	if input.KeyCode ~= Enum.KeyCode.Unknown then
		return input.KeyCode
	else
		return input.UserInputType
	end
end

function InputDetector:_queueEvent(name: string, mode: string, data: any?)
	table.insert(self._eventQueue, {
		Name = name,
		Mode = mode,
		Data = data,
		Timestamp = os.clock(),
	})
end

return InputDetector
