--[[
	CoverHandler.luau
	═══════════════════════════════════════════════════════════════
	Cover Physics: snap magnético, entrada/salida, lateral, peek
	═══════════════════════════════════════════════════════════════
	
	Gestiona toda la lógica física de cover:
	  - Snap magnético hacia la pared (interpolación por frame)
	  - Entrada por walk (EnterCover) y slide desde RoadieRun (SlideIntoCover)
	  - Salida (ExitCover), roll (RollOutOfCover delegado a EvadeHandler)
	  - Swat turn entre covers adyacentes
	  - Pop-up aim / blind fire (transiciones de estado)
	  - Vault sobre cover bajo
	  - Lateral slide y corner peek (sin cambio de estado)
	
	NOTA: CoverHandler NO modifica WalkSpeed ni dispara AssemblyLinearVelocity
	de impulso; eso queda en EvadeHandler y el coordinator.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local CoverHandler = {}
CoverHandler.__index = CoverHandler

------------------------------------------------------------------------
-- Set de acciones que este handler puede manejar
------------------------------------------------------------------------

local COVER_ACTIONS: { [string]: boolean } = {
	EnterCover = true,
	SlideIntoCover = true,
	ExitCover = true,
	SwatTurn = true,
	PopUpAim = true,
	ReturnToCover = true,
	BlindFire = true,
	StopBlindFire = true,
	CoverSlideLeft = true,
	CoverSlideRight = true,
	PeekCornerLeft = true,
	PeekCornerRight = true,
	Vault = true,
}

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function CoverHandler.new(stateMachine)
	local self = setmetatable({}, CoverHandler)

	self._stateMachine = stateMachine
	self._player = Players.LocalPlayer

	-- Cover state
	self._coverNormal = nil :: Vector3?
	self._coverPosition = nil :: Vector3?
	self._coverType = nil :: string? -- "Low" | "High"
	self._isSnappingToCover = false

	-- Timer interno para estados con duración fija (CoverSlide, SwatTurn)
	self._timer = 0
	self._timerCallback = nil :: (() -> ())?

	return self
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Intenta manejar una acción de cover.
--- Retorna true si la acción fue manejada, false si no es competencia de este handler.
function CoverHandler:HandleAction(action: string, data: any?): boolean
	if not COVER_ACTIONS[action] then
		return false
	end

	local handler = self._handlers[action]
	if handler then
		handler(self, data)
	end
	return true
end

--- Actualiza cover snap y timers cada frame.
function CoverHandler:Update(dt: number)
	-- Timer de estados temporales
	if self._timer > 0 then
		self._timer -= dt
		if self._timer <= 0 then
			self._timer = 0
			if self._timerCallback then
				self._timerCallback()
				self._timerCallback = nil
			end
		end
	end

	-- Cover snap continuo
	if self._isSnappingToCover then
		self:_updateCoverSnap(dt)
	end
end

--- Retorna la normal de la pared de cover actual (nil si no está en cover).
function CoverHandler:GetNormal(): Vector3?
	return self._coverNormal
end

--- Retorna la posición de contacto con la pared de cover (nil si no está en cover).
function CoverHandler:GetPosition(): Vector3?
	return self._coverPosition
end

--- Retorna el tipo de cover actual: "Low", "High", o nil.
function CoverHandler:GetCoverType(): string?
	return self._coverType
end

--- Retorna true si el cover snap está en progreso.
function CoverHandler:IsSnapping(): boolean
	return self._isSnappingToCover
end

--- Limpia todo el estado de cover (usado por EvadeHandler al hacer RollOutOfCover).
function CoverHandler:ResetCover()
	self._isSnappingToCover = false
	self._coverNormal = nil
	self._coverPosition = nil
	self._coverType = nil
	self:_cancelTimer()
end

------------------------------------------------------------------------
-- ACTION HANDLERS
------------------------------------------------------------------------

CoverHandler._handlers = {
	EnterCover = function(self, data)
		if data then
			self._coverNormal = data.coverNormal
			self._coverPosition = data.coverPos
			self._coverType = data.coverType
		end
		self._isSnappingToCover = true
	end,

	SlideIntoCover = function(self, data)
		if data then
			self._coverNormal = data.coverNormal
			self._coverPosition = data.coverPos
			self._coverType = data.coverType
		end
		self._isSnappingToCover = true

		-- CoverSlide dura poco, luego transiciona a CoverIdle
		self:_startTimer(0.3, function()
			self._stateMachine:TransitionTo("CoverIdle")
		end)
	end,

	ExitCover = function(self, _data)
		self._isSnappingToCover = false
		self._coverNormal = nil
		self._coverPosition = nil
		self._coverType = nil
	end,

	SwatTurn = function(self, _data)
		-- Timer: swat turn es un sprint corto expuesto entre covers
		self:_startTimer(0.4, function()
			self._stateMachine:TransitionTo("CoverIdle")
		end)
	end,

	PopUpAim = function(self, _data)
		-- El personaje se levanta/asoma para apuntar
		-- Animaciones se manejarán en fase de animación
	end,

	ReturnToCover = function(self, _data)
		-- Volver a CoverIdle desde CoverAim
	end,

	BlindFire = function(self, _data)
		-- Disparar sin asomarse (impreciso, protegido)
	end,

	StopBlindFire = function(self, _data)
		-- Volver a CoverIdle
	end,

	CoverSlideLeft = function(self, _data)
		-- Deslizar a la izquierda en cover
	end,

	CoverSlideRight = function(self, _data)
		-- Deslizar a la derecha en cover
	end,

	PeekCornerLeft = function(self, _data)
		-- Asomarse por esquina izquierda
	end,

	PeekCornerRight = function(self, _data)
		-- Asomarse por esquina derecha
	end,

	Vault = function(self, _data)
		self._isSnappingToCover = false
		self._coverType = nil
		-- Vault no resetea coverNormal/Position — EvadeHandler/Coordinator lo gestionan
	end,
}

------------------------------------------------------------------------
-- INTERNAL: Cover Snap
------------------------------------------------------------------------

function CoverHandler:_updateCoverSnap(dt: number)
	if not self._coverPosition or not self._coverNormal then
		self._isSnappingToCover = false
		return
	end

	local character = self._player.Character
	if not character then
		return
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return
	end

	-- Calcular posición objetivo: offset desde la pared
	local offsetDistance = 2.5 -- studs de separación del personaje a la pared
	local targetPos = self._coverPosition + self._coverNormal * offsetDistance

	-- Solo snap horizontal (mantener Y actual)
	targetPos = Vector3.new(targetPos.X, hrp.Position.Y, targetPos.Z)

	-- Interpolar hacia la posición
	local currentPos = hrp.Position
	local diff = targetPos - currentPos
	local distance = diff.Magnitude

	if distance < 0.1 then
		-- Ya llegamos, mantener posición
		self._isSnappingToCover = false
		return
	end

	-- Mover hacia el cover con velocidad de snap
	local moveStep = math.min(Constants.COVER_SNAP_SPEED * dt, distance)
	local newPos = currentPos + diff.Unit * moveStep
	hrp.CFrame = CFrame.new(newPos) * CFrame.Angles(0, math.atan2(-self._coverNormal.X, -self._coverNormal.Z), 0)
end

------------------------------------------------------------------------
-- INTERNAL: Timer
------------------------------------------------------------------------

function CoverHandler:_startTimer(duration: number, callback: () -> ())
	self._timer = duration
	self._timerCallback = callback
end

function CoverHandler:_cancelTimer()
	self._timer = 0
	self._timerCallback = nil
end

return CoverHandler
