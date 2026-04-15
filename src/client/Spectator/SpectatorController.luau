--[[
	SpectatorController.luau
	═══════════════════════════════════════════════════════════════
	Controlador de modo espectador — cámara sobre otros jugadores.
	═══════════════════════════════════════════════════════════════

	Responsabilidades:
	- Cuando el jugador entra en estado "Spectator", posicionar la cámara
	  en otros jugadores vivos (teammates primero).
	- Cycling: Q/E (PC), Shoot/Aim (consola) para cambiar de objetivo.
	- Si no hay jugadores vivos → cámara fija en la posición de muerte.
	- Hook para botones de móvil (Next/Previous) — UI por implementar.

	Capa: Presentación (Capa 5)
	Depende de: StateMachine, InputDetector (Capa 1)
	Comunica: Señales para que UI reaccione (SpectatorTargetChanged, etc.)
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Signal = require(Shared:WaitForChild("Signal"))

local SpectatorController = {}
SpectatorController.__index = SpectatorController

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function SpectatorController.new(stateMachine)
	local self = setmetatable({}, SpectatorController)

	self._stateMachine = stateMachine
	self._active = false
	self._targets = {} :: { Player }
	self._currentIndex = 0
	self._deathPosition = nil :: Vector3?
	self._deathLookAt = nil :: Vector3?
	self._connections = {} :: { any }
	self._inputConnections = {} :: { any }

	--- Señal pública: se dispara al cambiar de objetivo.
	--- Payload: (targetPlayer: Player?, targetName: string?)
	self.TargetChanged = Signal.new()

	--- Señal pública: hook para UI de botones móviles.
	--- Payload: (isActive: boolean)
	self.ActiveChanged = Signal.new()

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function SpectatorController:Init()
	-- Sin side-effects
end

function SpectatorController:Start()
	-- Escuchar cambios de estado
	self._connections.stateChanged = self._stateMachine.StateChanged:Connect(
		function(newState: string, _oldState: string)
			if newState == "Spectator" then
				self:_activate()
			elseif self._active then
				self:_deactivate()
			end
		end
	)
end

function SpectatorController:Destroy()
	self:_deactivate()
	for _, conn in self._connections do
		if type(conn) == "table" and type(conn.Disconnect) == "function" then
			conn:Disconnect()
		elseif typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)
	self.TargetChanged:Destroy()
	self.ActiveChanged:Destroy()
end

------------------------------------------------------------------------
-- PRIVATE: Activate / Deactivate
------------------------------------------------------------------------

function SpectatorController:_activate()
	if self._active then
		return
	end
	self._active = true

	-- Guardar posición de muerte
	local localPlayer = Players.LocalPlayer
	local character = localPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		self._deathPosition = hrp.Position
		self._deathLookAt = hrp.Position + hrp.CFrame.LookVector * 10
	else
		self._deathPosition = Vector3.new(0, 50, 0)
		self._deathLookAt = Vector3.new(0, 50, -10)
	end

	-- Construir lista de targets
	self:_refreshTargets()

	-- Si hay targets, ir al primero; si no, cámara fija
	if #self._targets > 0 then
		self._currentIndex = 1
		self:_focusOnTarget(self._targets[1])
	else
		self:_focusOnDeathPosition()
	end

	-- Conectar inputs de cycling
	self:_connectInputs()

	self.ActiveChanged:Fire(true)
end

function SpectatorController:_deactivate()
	if not self._active then
		return
	end
	self._active = false

	-- Desconectar inputs
	for _, conn in self._inputConnections do
		if type(conn) == "table" and type(conn.Disconnect) == "function" then
			conn:Disconnect()
		elseif typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
	end
	table.clear(self._inputConnections)

	-- Restaurar cámara
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	self._targets = {}
	self._currentIndex = 0

	self.ActiveChanged:Fire(false)
end

------------------------------------------------------------------------
-- PRIVATE: Target management
------------------------------------------------------------------------

function SpectatorController:_refreshTargets()
	self._targets = {}
	local localPlayer = Players.LocalPlayer
	local localTeam = localPlayer.Team

	-- Priorizar teammates vivos
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer then
			local char = player.Character
			if char then
				local humanoid = char:FindFirstChildWhichIsA("Humanoid")
				local lifeState = char:GetAttribute("LifeState")
				if humanoid and humanoid.Health > 0 and lifeState ~= "Dead" then
					-- Teammates primero
					if localTeam and player.Team == localTeam then
						table.insert(self._targets, 1, player)
					else
						table.insert(self._targets, player)
					end
				end
			end
		end
	end
end

function SpectatorController:_focusOnTarget(targetPlayer: Player)
	local character = targetPlayer.Character
	if not character then
		self:_focusOnDeathPosition()
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		self:_focusOnDeathPosition()
		return
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		local offset = Constants.SPECTATOR_CAMERA_OFFSET
		camera.CFrame = CFrame.new(hrp.Position + offset, hrp.Position)
		camera.FieldOfView = Constants.SPECTATOR_FOV
	end

	self.TargetChanged:Fire(targetPlayer, targetPlayer.Name)
end

function SpectatorController:_focusOnDeathPosition()
	local camera = workspace.CurrentCamera
	if camera and self._deathPosition then
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.new(
			self._deathPosition + Constants.SPECTATOR_CAMERA_OFFSET,
			self._deathLookAt or self._deathPosition
		)
		camera.FieldOfView = Constants.SPECTATOR_FOV
	end

	self.TargetChanged:Fire(nil, nil)
end

------------------------------------------------------------------------
-- PRIVATE: Cycling
------------------------------------------------------------------------

function SpectatorController:_cycleNext()
	if not self._active then
		return
	end

	self:_refreshTargets()

	if #self._targets == 0 then
		self:_focusOnDeathPosition()
		return
	end

	self._currentIndex = (self._currentIndex % #self._targets) + 1
	self:_focusOnTarget(self._targets[self._currentIndex])
end

function SpectatorController:_cyclePrevious()
	if not self._active then
		return
	end

	self:_refreshTargets()

	if #self._targets == 0 then
		self:_focusOnDeathPosition()
		return
	end

	self._currentIndex = self._currentIndex - 1
	if self._currentIndex < 1 then
		self._currentIndex = #self._targets
	end
	self:_focusOnTarget(self._targets[self._currentIndex])
end

------------------------------------------------------------------------
-- PRIVATE: Input connections
------------------------------------------------------------------------

function SpectatorController:_connectInputs()
	-- Limpiar conexiones previas
	for _, conn in self._inputConnections do
		if type(conn) == "table" and type(conn.Disconnect) == "function" then
			conn:Disconnect()
		elseif typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
	end
	table.clear(self._inputConnections)

	-- PC: Q (previous), E (next)
	-- Consola: LT/L2 (previous), RT/R2 (next)
	table.insert(
		self._inputConnections,
		UserInputService.InputBegan:Connect(function(input, gameProcessed)
			if gameProcessed then
				return
			end
			if not self._active then
				return
			end

			-- PC keys
			if input.KeyCode == Enum.KeyCode.E then
				self:_cycleNext()
			elseif input.KeyCode == Enum.KeyCode.Q then
				self:_cyclePrevious()
			end

			-- Console: shoot (RT) → next, aim (LT) → previous
			if input.KeyCode == Enum.KeyCode.ButtonR2 then
				self:_cycleNext()
			elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
				self:_cyclePrevious()
			end

			-- Console bumpers as alternative
			if input.KeyCode == Enum.KeyCode.ButtonR1 then
				self:_cycleNext()
			elseif input.KeyCode == Enum.KeyCode.ButtonL1 then
				self:_cyclePrevious()
			end
		end)
	)
end

------------------------------------------------------------------------
-- PUBLIC API: Update (llamado desde heartbeat para smooth follow)
------------------------------------------------------------------------

function SpectatorController:Update(_dt: number)
	if not self._active then
		return
	end

	-- Smooth follow del target actual
	if self._currentIndex > 0 and self._currentIndex <= #self._targets then
		local target = self._targets[self._currentIndex]
		if target and target.Character then
			local hrp = target.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp then
				local camera = workspace.CurrentCamera
				if camera then
					local offset = Constants.SPECTATOR_CAMERA_OFFSET
					local targetCF = CFrame.new(hrp.Position + offset, hrp.Position)
					camera.CFrame = camera.CFrame:Lerp(targetCF, math.min(1, 8 * _dt))
				end
				return
			end
		end

		-- Target inválido → refrescar
		self:_refreshTargets()
		if #self._targets > 0 then
			self._currentIndex = math.clamp(self._currentIndex, 1, #self._targets)
			self:_focusOnTarget(self._targets[self._currentIndex])
		else
			self:_focusOnDeathPosition()
		end
	end
end

------------------------------------------------------------------------
-- PUBLIC API: hooks para UI móvil
------------------------------------------------------------------------

--- Hook: llamado por un botón de UI para ir al siguiente objetivo.
function SpectatorController:RequestNext()
	self:_cycleNext()
end

--- Hook: llamado por un botón de UI para ir al objetivo anterior.
function SpectatorController:RequestPrevious()
	self:_cyclePrevious()
end

--- Retorna si el modo espectador está activo.
function SpectatorController:IsActive(): boolean
	return self._active
end

--- Retorna el nombre del jugador observado actualmente (o nil).
function SpectatorController:GetCurrentTargetName(): string?
	if self._currentIndex > 0 and self._currentIndex <= #self._targets then
		return self._targets[self._currentIndex].Name
	end
	return nil
end

return SpectatorController
