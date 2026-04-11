--[[
	ExitCoverHandler.luau
	═══════════════════════════════════════════════════════════════
	Salida lateral física desde esquina exterior (CornerExit)
	═══════════════════════════════════════════════════════════════
	
	Aplica un empuje físico suave en la dirección de salida y al
	terminar encadena automáticamente al estado libre correcto
	(Idle / Walking / RoadieRun) según el input del jugador.
	
	Se activa SOLO cuando CoverRules emite "ExitCover" con data.Direction
	(CornerExit). Las salidas normales (botón de cover) no pasan por aquí.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local ExitCoverHandler = {}
ExitCoverHandler.__index = ExitCoverHandler

function ExitCoverHandler.new(stateMachine)
	local self = setmetatable({}, ExitCoverHandler)

	self._stateMachine = stateMachine
	self._player = Players.LocalPlayer

	-- Timer interno
	self._timer = 0
	self._timerCallback = nil :: (() -> ())?

	-- Estado activo
	self._isActive = false

	-- Cache de character refs
	self._cachedCharacter = nil :: Model?
	self._cachedHumanoid = nil :: Humanoid?
	self._cachedHRP = nil :: BasePart?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Ejecuta la salida lateral con física real.
--- @param data { Direction: Vector3, IsRunning: boolean }
function ExitCoverHandler:Execute(data: { Direction: Vector3, IsRunning: boolean })
	self:_refreshCache()
	local hrp = self._cachedHRP
	local humanoid = self._cachedHumanoid
	if not hrp or not humanoid then
		return
	end

	local dir = data.Direction
	if not dir or dir.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end

	self._isActive = true

	-- Congelar WalkSpeed durante la salida (el empuje físico controla el movimiento)
	humanoid.WalkSpeed = 0

	-- Empuje físico suave en la dirección de salida (preservar Y para gravedad)
	local flatDir = Vector3.new(dir.X, 0, dir.Z)
	if flatDir.Magnitude < Constants.ZERO_MAGNITUDE then
		flatDir = Vector3.new(0, 0, 1)
	else
		flatDir = flatDir.Unit
	end

	hrp.AssemblyLinearVelocity = Vector3.new(
		flatDir.X * Constants.CORNER_EXIT_PUSH_SPEED,
		hrp.AssemblyLinearVelocity.Y,
		flatDir.Z * Constants.CORNER_EXIT_PUSH_SPEED
	)

	-- Al terminar el timer, encadenar al estado libre según input actual
	self:_startTimer(Constants.CORNER_EXIT_DURATION, function()
		self._isActive = false
		-- Transicionar a Idle: el siguiente frame el ActionResolver evaluará
		-- el input actual y resolverá Walking/RoadieRun si corresponde.
		self._stateMachine:TransitionTo("Idle")
	end)
end

--- Update cada frame — tick del timer interno.
function ExitCoverHandler:Update(dt: number)
	if self._timer > 0 then
		self._timer -= dt
		if self._timer <= 0 then
			self._timer = 0
			if self._timerCallback then
				local cb = self._timerCallback
				self._timerCallback = nil
				cb()
			end
		end
	end
end

--- Retorna true si la salida lateral está en progreso.
function ExitCoverHandler:IsActive(): boolean
	return self._isActive
end

------------------------------------------------------------------------
-- INTERNAL
------------------------------------------------------------------------

function ExitCoverHandler:_startTimer(duration: number, callback: () -> ())
	self._timer = duration
	self._timerCallback = callback
end

function ExitCoverHandler:_refreshCache()
	local character = self._player.Character
	if character ~= self._cachedCharacter then
		self._cachedCharacter = character
		self._cachedHumanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
		self._cachedHRP = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
end

return ExitCoverHandler
