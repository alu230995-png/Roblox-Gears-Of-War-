--[[
	InputDetector.luau
	═══════════════════════════════════════════════════════════════
	CAPA 1: Detección de Raw Inputs
	═══════════════════════════════════════════════════════════════

	Solo detecta hechos físicos. No decide significado.
	Un input es un hecho: tecla presionada, gatillo activado, stick movido.

	Todos los mapeos de teclas se leen de PlayerBindings (perfil).
	Para rebind: llamar RebuildBindings() con un perfil modificado.

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
	  IsRawHeld(rawName) → boolean

	Ruta móvil:
	  FireUIButton(rawName, mode, data?) → inyecta evento directo
	  Los botones touch del HUD llaman este método.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")

local IS_MOBILE = UserInputService.TouchEnabled and not GuiService:IsTenFootInterface()

local PlayerBindings = require(script.Parent.PlayerBindings)

local InputDetector = {}
InputDetector.__index = InputDetector

function InputDetector.new(bindings)
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

	-- Mapeos leídos de PlayerBindings (perfil)
	self._keyToRaw = {}
	self._gamepadToRaw = {}
	self._moveKeys = {}
	self._holdThresholds = {}
	self._weaponSlots = {}

	self:RebuildBindings(bindings or PlayerBindings.DEFAULT)

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
	-- UI synthetic key (botones móviles)
	local uiKey = "UI_" .. rawName
	local uiStart = self._heldKeys[uiKey]
	if uiStart then
		return now - uiStart
	end
	-- Physical keys (teclado/gamepad)
	for key, pressStart in self._heldKeys do
		local name = self._keyToRaw[key] or self._gamepadToRaw[key]
		if name == rawName then
			return now - pressStart
		end
	end
	return 0
end

------------------------------------------------------------------------
-- PUBLIC API: Rebuild
------------------------------------------------------------------------

--- Recarga los mapeos físicos desde un perfil de PlayerBindings.
--- Limpia estado de tracking para evitar phantom held keys.
function InputDetector:RebuildBindings(bindings)
	self._keyToRaw = bindings.Keyboard
	self._gamepadToRaw = bindings.Gamepad
	self._moveKeys = bindings.MoveKeys
	self._holdThresholds = bindings.HoldThresholds
	self._weaponSlots = bindings.WeaponSlots

	-- Reset tracking: evita phantom held keys de bindings anteriores
	table.clear(self._heldKeys)
	table.clear(self._holdEmitted)
	table.clear(self._heldByRaw)
	table.clear(self._eventQueue)
end

--- Limpia el held state de todos los botones UI virtuales (keys sintéticas "UI_*").
--- Llamar al morir o al respawnear para evitar phantom held state entre vidas.
--- Si un botón estaba held (Visible=false cortó el InputEnded), esto garantiza
--- que _heldByRaw quede a cero y ningún intent continuo se active por stale state.
function InputDetector:ResetUIHeldState()
	local toRemove = {}
	for key in self._heldKeys do
		if type(key) == "string" and string.sub(key, 1, 3) == "UI_" then
			table.insert(toRemove, key)
		end
	end
	for _, key in toRemove do
		local rawName = string.sub(key, 4) -- strip "UI_"
		local count = (self._heldByRaw[rawName] or 0) - 1
		self._heldByRaw[rawName] = if count > 0 then count else nil
		self._heldKeys[key] = nil
		self._holdEmitted[key] = nil
	end
end

------------------------------------------------------------------------
-- RUTA UI / MÓVIL
-- Botones HUD, touchscreen, o cualquier UI que quiera simular input.
-- Llámalo desde el controlador del botón UI:
--   inputDetector:FireUIButton("CoverButton", "Tap")
--   inputDetector:FireUIButton("FireButton", "Pressed")
--   inputDetector:FireUIButton("SwapWeapon", "Pressed", 2) -- slot 2
--
-- Para botones hold-sensitive (ej. RoadieRun en móvil) usar los métodos
-- Down/Up para que IsRawHeld() retorne true mientras el botón se mantiene:
--   inputDetector:FireUIButtonDown("CoverButton", "HoldStart", elapsed)
--   inputDetector:FireUIButtonUp("CoverButton", "Release", elapsed)
------------------------------------------------------------------------
function InputDetector:FireUIButton(rawName: string, mode: string, data: any?)
	self:_queueEvent(rawName, mode, data)
end

--- FireUIButtonDown y FireUIButtonUp definidos al final del módulo.
--- Usan key sintética "UI_<rawName>" para no colisionar con teclas físicas.

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

	if IS_MOBILE then
		-- En mobile, el DynamicThumbstick de Roblox controla Humanoid.MoveDirection
		-- directamente. Leemos esa dirección y la convertimos a Vector2 camera-relative
		-- para que el resto del pipeline (IntentMapper → ActionResolver) funcione.
		local player = Players.LocalPlayer
		local character = player and player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if humanoid then
			local moveDir3 = humanoid.MoveDirection
			if moveDir3.Magnitude > 0.01 then
				local camera = workspace.CurrentCamera
				if camera then
					local camCF = camera.CFrame
					-- Proyectar vectores de cámara en el plano XZ
					local fwd = camCF.LookVector
					local right = camCF.RightVector
					local fwd2 = Vector2.new(fwd.X, fwd.Z)
					local right2 = Vector2.new(right.X, right.Z)
					if fwd2.Magnitude > 0.001 then
						fwd2 = fwd2.Unit
					end
					if right2.Magnitude > 0.001 then
						right2 = right2.Unit
					end

					local move2 = Vector2.new(moveDir3.X, moveDir3.Z)
					-- Dot products → componentes camera-relative (X = strafe, Y = forward)
					local forwardAmount = move2:Dot(fwd2)
					local rightAmount = move2:Dot(right2)
					dir = Vector2.new(rightAmount, forwardAmount)
					if dir.Magnitude > 1 then
						dir = dir.Unit
					end
				end
			end
		end
	else
		for keyCode, vec in self._moveKeys do
			if UserInputService:IsKeyDown(keyCode) then
				dir += vec
			end
		end

		if dir.Magnitude > 0 then
			dir = dir.Unit
		end
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

function InputDetector:FireUIButtonDown(rawName: string, mode: string, data: any?)
	self:_queueEvent(rawName, mode, data)
	local syntheticKey = "UI_" .. rawName
	if not self._heldKeys[syntheticKey] then
		self._heldKeys[syntheticKey] = os.clock()
		self._holdEmitted[syntheticKey] = (mode == "HoldStart")
		self._heldByRaw[rawName] = (self._heldByRaw[rawName] or 0) + 1
	end
end

function InputDetector:FireUIButtonUp(rawName: string, mode: string, data: any?)
	self:_queueEvent(rawName, mode, data)
	local syntheticKey = "UI_" .. rawName
	if self._heldKeys[syntheticKey] then
		self._heldKeys[syntheticKey] = nil
		self._holdEmitted[syntheticKey] = nil
		local count = (self._heldByRaw[rawName] or 0) - 1
		self._heldByRaw[rawName] = if count > 0 then count else nil
	end
end

return InputDetector
