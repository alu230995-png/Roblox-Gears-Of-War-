--[[
	RotationHandler.luau
	═══════════════════════════════════════════════════════════════
	Rotación del personaje según estado — estilo Gears of War
	═══════════════════════════════════════════════════════════════
	
	MODELO DE ROTACIÓN:
	
	1. COMBAT STANCE (Idle, Walking, Evading, Aiming, Firing):
	   El personaje SIEMPRE mira hacia el forward de la cámara.
	   El movimiento es strafe puro — presionar derecha = caminar de lado.
	   Esto garantiza que siempre esté listo para disparar donde mira la cámara.
	
	2. ROADIE RUN (RoadieRun):
	   - Quick Snap: al entrar, el personaje rota rápido hacia la dirección de input.
	   - Heavy Steering: después de 0.25s, la rotación se vuelve muy lenta/pesada.
	   El personaje se desacopla de la cámara y rota hacia donde empuja el input.
	
	3. COVER: rotación la gestiona el cover snap (no se toca aquí).
	
	4. LOCKED: ciertos estados bloquean la rotación (Mantling, Executing, Death).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local RotationHandler = {}
RotationHandler.__index = RotationHandler

--- Estados en los que la rotación está controlada por el cover snap / normal.
--- El input del jugador NO debe rotar al personaje en estos estados.
local COVER_LOCKED_STATES: { [string]: boolean } = table.freeze({
	Mantling = true,
	Executing = true,
	Death = true,
	CoverEntering = true,
	CoverSlide = true,
	CoverIdle = true,
	CoverWalking = true,
	CoverRunning = true,
	CoverCorners = true,
	CoverBlindFire = true,
	CoverExiting = true,
	CoverSwap = true,
	CoverAimHigh = true,
	CoverAim = true,
	CoverFiring = true,
})

function RotationHandler.new()
	local self = setmetatable({}, RotationHandler)
	self._player = Players.LocalPlayer
	self._aimingController = nil -- inyectado via SetAimingController (para Low Cover rotation override)
	self._coverHandler = nil -- inyectado via SetCoverHandler (para NoCollision en Low Cover front aim)
	self._roadieRunTimer = 0 -- tiempo en RoadieRun (para Quick Snap → Heavy Steering)
	self._lastState = ""
	self._lockedRunDirection = nil :: Vector3? -- Direction Caching: dirección fija durante Fase 1
	self._lowCoverNoCollision = {} :: { NoCollisionConstraint } -- constraints activas durante CoverAimLow (una por BasePart del personaje)
	self._lowCoverReturnActive = false -- true: rotando de vuelta tras salir de CoverAimLow, NoCollision aún necesaria

	-- Cache de character refs (evita FindFirstChild cada frame)
	self._cachedCharacter = nil :: Model?
	self._cachedHumanoid = nil :: Humanoid?
	self._cachedHRP = nil :: BasePart?

	-- Conexiones gestionadas (cleanup en Destroy)
	self._connections = {}

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

--- Desactiva AutoRotate del Humanoid (la rotación la maneja este handler).
--- Conecta CharacterAdded para repetir en respawn.
function RotationHandler:Start()
	local function disableAutoRotate(character: Model?)
		if not character then
			return
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.AutoRotate = false
		else
			task.spawn(function()
				local h = character:WaitForChild("Humanoid", 5)
				if h then
					h.AutoRotate = false
				end
			end)
		end
	end

	disableAutoRotate(self._player.Character)
	self._connections.characterAdded = self._player.CharacterAdded:Connect(function(character)
		disableAutoRotate(character)
	end)
end

function RotationHandler:Destroy()
	self:_cleanupLowCoverNoCollision()
	for _, conn in self._connections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		end
	end
	table.clear(self._connections)
end

--- Inyecta referencia al AimingController (para GetRotationOverride en Low Cover).
function RotationHandler:SetAimingController(aimingController)
	self._aimingController = aimingController
end

--- Inyecta referencia al CoverHandler (para NoCollision en Low Cover front aim).
function RotationHandler:SetCoverHandler(coverHandler)
	self._coverHandler = coverHandler
end

--- Cachea la dirección de movimiento para RoadieRun.
--- Llamado por MovementController al ejecutar StartRoadieRun o CancelSwapToRun.
--- @param direction Vector3? — dirección world-space calculada por ActionResolver
function RotationHandler:SetRoadieRunDirection(direction: Vector3?)
	self._lockedRunDirection = direction
end

--- Actualiza la rotación del personaje cada frame.
--- @param dt number — delta time
--- @param state string — estado actual del jugador
--- @param coverNormal Vector3? — normal de la pared de cover (nil si no está en cover)
function RotationHandler:Update(dt: number, state: string, coverNormal: Vector3?)
	local character = self._player.Character
	if not character then
		return
	end

	-- Actualizar cache si el character cambió (respawn) o si los parts aún no estaban listos
	if character ~= self._cachedCharacter then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if humanoid and hrp then
			-- Parts listos: cachear y continuar
			self._cachedCharacter = character
			self._cachedHumanoid = humanoid
			self._cachedHRP = hrp
		else
			-- Parts aún no cargados (race condition post-respawn): reintentar el frame siguiente
			return
		end
	end

	local humanoid = self._cachedHumanoid
	local hrp = self._cachedHRP
	if not humanoid or not hrp then
		return
	end

	-- Guardar prevState ANTES de actualizar _lastState
	local prevState = self._lastState

	-- Detectar entrada a RoadieRun para resetear timer
	if state == "RoadieRun" and prevState ~= "RoadieRun" then
		self._roadieRunTimer = 0
	end
	self._lastState = state

	-- COVER PEEK: rotar 90° según el lado del corner (mirando a lo largo de la pared)
	-- Right corner → personaje mira wallRight (+90° de coverNormal)
	-- Left corner  → personaje mira -wallRight (-90° de coverNormal)
	if state == "CoverPeek" then
		self._lowCoverReturnActive = false
		self:_cleanupLowCoverNoCollision()
		if coverNormal then
			-- Usar la dirección cacheada al inicio del peek (relativa a la cámara en ese momento).
			-- peekSide se determina con input relativo a la cámara, así que faceDir debe
			-- derivarse del right de la cámara en ese instante — no de wallRight recalculado,
			-- que puede ser opuesto al right visual dependiendo de si la cámara mira hacia
			-- adentro o hacia afuera de la cobertura.
			local faceDir: Vector3? = nil
			if self._aimingController then
				faceDir = self._aimingController:GetPeekFaceDir()
			end

			if not faceDir then
				-- Fallback: recalcular desde wallRight (comportamiento original)
				local peekSide = self._aimingController and self._aimingController:GetPeekSide()
				local wallRight = Vector3.yAxis:Cross(coverNormal)
				if wallRight.Magnitude >= 0.01 then
					wallRight = wallRight.Unit
					faceDir = if peekSide == "Right" then wallRight else -wallRight
				end
			end

			if faceDir then
				if Constants.DEBUG_MODE then
					print(`[RotationHandler] CoverPeek detected — applying peek rotation`)
				end
				self:_alignToDirection(dt, hrp, faceDir)
			end
		end
		return
	end

	-- COVER AIM LOW: ciclo de vida completo de NoCollision
	--   ENTRADA: activar NoCollision inmediatamente al entrar (antes de rotar)
	--   DURANTE: mantener NoCollision activa toda la duración
	--   SALIDA: mantener NoCollision mientras rota de vuelta a coverNormal, limpiar al alinear
	if state == "CoverAimLow" then
		self._lowCoverReturnActive = false
		if coverNormal then
			-- NoCollision activa durante todo CoverAimLow
			self:_ensureLowCoverNoCollision(hrp)
			if self._aimingController and self._aimingController:GetRotationOverride() == "CoverAimFront" then
				self:_alignToDirection(dt, hrp, -coverNormal)
			else
				self:_alignToDirection(dt, hrp, coverNormal)
			end
		end
		return
	end

	-- LOCKED: Cover y estados especiales — no tocar rotación
	if COVER_LOCKED_STATES[state] then
		-- Detectar salida de CoverAimLow → necesita rotación de vuelta con NoCollision
		if prevState == "CoverAimLow" then
			self._lowCoverReturnActive = true
		end

		if self._lowCoverReturnActive then
			if coverNormal then
				-- Mantener NoCollision mientras el personaje rota de vuelta hacia la pared
				self:_ensureLowCoverNoCollision(hrp)
				-- Verificar si ya está alineado con coverNormal
				local charLook = hrp.CFrame.LookVector
				local flatLook = Vector3.new(charLook.X, 0, charLook.Z)
				if flatLook.Magnitude > 0.01 then
					if flatLook.Unit:Dot(coverNormal) > 0.99 then
						-- Alineado (~8° de margen): limpiar NoCollision
						self._lowCoverReturnActive = false
						self:_cleanupLowCoverNoCollision()
					end
				end
			else
				self._lowCoverReturnActive = false
				self:_cleanupLowCoverNoCollision()
			end
		else
			self:_cleanupLowCoverNoCollision()
		end
		return
	end

	-- Estado fuera de cover: limpiar todo
	self._lowCoverReturnActive = false
	self:_cleanupLowCoverNoCollision()

	-- ROADIE RUN: rotación dictada por input (no cámara)
	if state == "RoadieRun" then
		self:_updateRoadieRun(dt, hrp, humanoid)
		return
	end

	-- COMBAT STANCE (Idle, Walking, Evading, Aiming, Firing, Reloading, etc.):
	-- El personaje SIEMPRE mira hacia el forward horizontal de la cámara (strafe)
	self:_alignToCamera(dt, hrp)
end

------------------------------------------------------------------------
-- INTERNAL: Combat Stance — alinear al forward de la cámara
------------------------------------------------------------------------

function RotationHandler:_alignToCamera(dt: number, hrp: BasePart)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local camLook = camera.CFrame.LookVector
	local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
	if flatLook.Magnitude < 0.01 then
		return
	end

	flatLook = flatLook.Unit
	local targetCFrame = CFrame.lookAt(hrp.Position, hrp.Position + flatLook)
	hrp.CFrame = hrp.CFrame:Lerp(targetCFrame, 1 - math.exp(-12 * dt))
end

--- Alinea la rotación del personaje hacia una dirección XZ explícita.
--- Usado para Low Cover aim: apunta hacia afuera de la pared (-coverNormal).
function RotationHandler:_alignToDirection(dt: number, hrp: BasePart, dir: Vector3)
	local flatDir = Vector3.new(dir.X, 0, dir.Z)
	if flatDir.Magnitude < 0.01 then
		return
	end
	flatDir = flatDir.Unit
	local targetCFrame = CFrame.lookAt(hrp.Position, hrp.Position + flatDir)
	hrp.CFrame = hrp.CFrame:Lerp(targetCFrame, 1 - math.exp(-12 * dt))
end

------------------------------------------------------------------------
-- INTERNAL: Low Cover NoCollision — evita clipping al rotar hacia afuera
------------------------------------------------------------------------

--- Crea o mantiene NoCollisionConstraints entre TODOS los BaseParts del personaje y el cover part.
--- Se llama cada frame durante CoverAimLow front-cone rotation.
--- Igual que EnteringCover._disableCoverCollision: cubre HRP + torso + arms + legs.
function RotationHandler:_ensureLowCoverNoCollision(_hrp: BasePart)
	local coverPart = self._coverHandler and self._coverHandler:GetCoverInstance()
	if not coverPart then
		self:_cleanupLowCoverNoCollision()
		return
	end

	-- Si ya tenemos constraints con la misma cover part, no recrear
	local existing = self._lowCoverNoCollision
	if #existing > 0 and existing[1].Parent ~= nil and existing[1].Part1 == coverPart then
		return
	end

	-- Limpiar constraints anteriores (puede ser de otra cover part)
	self:_cleanupLowCoverNoCollision()

	-- Crear NCC para cada BasePart del personaje (evita que torso/arms clippen con la pared al rotar)
	local character = self._player.Character
	if not character then
		return
	end
	for _, part in character:GetChildren() do
		if part:IsA("BasePart") then
			local noCol = Instance.new("NoCollisionConstraint")
			noCol.Name = "LowCoverAimNoCollision"
			noCol.Part0 = part
			noCol.Part1 = coverPart
			noCol.Parent = part
			table.insert(self._lowCoverNoCollision, noCol)
		end
	end
end

--- Destruye todas las NoCollisionConstraints del ciclo de CoverAimLow.
function RotationHandler:_cleanupLowCoverNoCollision()
	for _, ncc in self._lowCoverNoCollision do
		if ncc and ncc.Parent then
			ncc:Destroy()
		end
	end
	table.clear(self._lowCoverNoCollision)
end

------------------------------------------------------------------------
-- INTERNAL: Roadie Run — Dos Fases
------------------------------------------------------------------------

--- Fase 1 (Quick Snap): el personaje rota hacia _lockedRunDirection (cacheada al entrar).
---   La cámara se mueve independientemente a la espalda sin re-rotar al personaje.
--- Fase 2 (Steering): input lateral gira al personaje con radio de giro limitado.
---   El personaje siempre avanza hacia donde mira; no hay rotación absoluta.
function RotationHandler:_updateRoadieRun(dt: number, hrp: BasePart, humanoid: Humanoid)
	self._roadieRunTimer = self._roadieRunTimer + dt

	local inSnapPhase = self._roadieRunTimer < Constants.ROADIE_SNAP_DURATION

	if inSnapPhase then
		-- Fase 1: Quick Snap — rotar hacia dirección CACHEADA (no live input)
		local dir = self._lockedRunDirection
		if not dir or dir.Magnitude < 0.01 then
			-- Fallback: si no hay dirección cacheada, usar LookVector actual
			dir = hrp.CFrame.LookVector
		end
		local targetCFrame = CFrame.lookAt(hrp.Position, hrp.Position + dir)
		hrp.CFrame = hrp.CFrame:Lerp(targetCFrame, 1 - math.exp(-Constants.ROADIE_SNAP_SPEED * dt))
	else
		-- Fase 2: Steering — input lateral gira con radio de giro limitado
		if humanoid.MoveDirection.Magnitude < 0.1 then
			return
		end
		self:_applySteering(dt, hrp, humanoid)
	end
end

------------------------------------------------------------------------
-- INTERNAL: Steering (Fase 2 del Roadie Run)
------------------------------------------------------------------------

--- Extrae la componente lateral del input relativa al eje derecho del personaje
--- y aplica una rotación limitada en grados/segundo (volante de vehículo).
--- Sin giros instantáneos de 90° o 180°: el jugador tiene inercia y peso.
function RotationHandler:_applySteering(dt: number, hrp: BasePart, humanoid: Humanoid)
	-- Vector derecho del personaje (plano horizontal)
	local charRight = hrp.CFrame.RightVector
	local flatRight = Vector3.new(charRight.X, 0, charRight.Z)
	if flatRight.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	flatRight = flatRight.Unit

	-- Componente lateral del input: -1 (izquierda) a +1 (derecha)
	local lateralInput = humanoid.MoveDirection:Dot(flatRight)

	-- Aplicar velocidad de giro limitada (grados/segundo × dt)
	local steerAngle = lateralInput * Constants.ROADIE_STEER_RATE * dt
	hrp.CFrame = hrp.CFrame * CFrame.Angles(0, math.rad(-steerAngle), 0)
end

return RotationHandler
