--[[
	CoverHandler.luau
	═══════════════════════════════════════════════════════════════
	Cover Physics: snap magnético, entrada/salida, lateral, CoverSwap
	═══════════════════════════════════════════════════════════════
	
	Gestiona toda la lógica física de cover:
	  - Entrada por walk (EnterCover / CoverEntering):
	      • Movimiento por velocidad × dt (no lerp de posición)
	      • Rotación suave via slerp/lerp blend
	      • Cancelable si el jugador se mueve hacia atrás (dot > threshold)
	      • Cancelable por stuck timeout
	      • Cover chaining: re-dirige a otra cover mid-entry
	  - Entrada por slide desde RoadieRun (SlideIntoCover / CoverSlide)
	  - Movimiento lateral en CoverIdle: constrañido a la pared, bloqueado en esquinas
	  - CoverSwap: transición entre covers alineadas al llegar a una esquina
	  - Salida (ExitCover / CoverExiting): timer breve antes de Idle
	  - Pop-up aim / blind fire (transiciones de estado sin física extra)
	  - Vault sobre cover bajo (delegado parcialmente a EvadeHandler)
	
	NOTA: CoverHandler controla CFrame directamente durante entering/snap.
	WalkSpeed=0 durante CoverEntering (SpeedMap). EvadeHandler gestiona impulsos.
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
	CoverSwap = true,
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

	-- Cover state (persiste mientras está en cover)
	self._coverNormal = nil :: Vector3?
	self._coverPosition = nil :: Vector3?
	self._coverInstance = nil :: BasePart?
	self._coverType = nil :: string? -- "Low" | "High"
	self._wallRight = nil :: Vector3? -- Carril lateral (wallNormal × yAxis)

	-- Entering data (solo existe durante CoverEntering / CoverSlide / CoverSwap)
	-- Struct: { snapCFrame, wallNormal, wallRight, coverPart, startTime }
	self._entering = nil

	-- Flags de sub-estado dentro del handler
	self._isExiting = false -- true durante CoverExiting (timer)

	-- Timer interno para estados con duración fija (CoverSlide, CoverSwap, CoverExiting)
	self._timer = 0
	self._timerCallback = nil :: (() -> ())?

	-- Cuando el snap termina pero STATE_MIN_DURATION bloquea TransitionTo("CoverIdle"),
	-- este flag hace que Update() reintente la transición cada frame hasta que pase.
	self._pendingCoverIdleTransition = false

	-- Cuando cancel o ExitCover no pueden transicionar a Idle por STATE_MIN_DURATION,
	-- este flag reintenta cada frame hasta que pase.
	self._pendingIdleTransition = false

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

--- Actualiza entering snap, timers, y movimiento lateral cada frame.
--- @param dt number — delta time
--- @param envContext table? — EnvironmentContext del EnvironmentSensor (para chaining y lateral)
function CoverHandler:Update(dt: number, envContext: any?, wantsCoverRedirect: boolean?)
	-- Reintentar transición a CoverIdle si el snap terminó pero STATE_MIN_DURATION la bloqueó
	if self._pendingCoverIdleTransition then
		if self._stateMachine:TransitionTo("CoverIdle") then
			self._pendingCoverIdleTransition = false
		end
	end

	-- Reintentar transición a Idle si cancel/ExitCover fue bloqueado por STATE_MIN_DURATION
	if self._pendingIdleTransition then
		if self._stateMachine:TransitionTo("Idle") then
			self._pendingIdleTransition = false
		end
	end

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

	local character = self._player.Character
	if not character then
		return
	end

	local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not hrp then
		return
	end

	-- ENTERING: loop principal de movimiento + rotación + cancelación + chaining
	if self._entering then
		-- Cover chaining: si hay cover diferente durante la entrada, re-dirigir
		-- Solo se activa si el jugador pulsa el botón de cover de nuevo (intent explícito)
		if
			wantsCoverRedirect
			and envContext
			and envContext.HasCoverNearby
			and envContext.CoverInstance ~= self._entering.coverPart
		then
			local chainData = self:_tryChainCover(
				self._entering,
				envContext.CoverPosition,
				envContext.CoverNormal,
				envContext.CoverInstance,
				hrp
			)
			if chainData then
				self._entering = chainData
				self._coverNormal = chainData.wallNormal
				self._coverPosition = envContext.CoverPosition
				self._coverInstance = envContext.CoverInstance
				self._coverType = envContext.CoverType
				self._wallRight = chainData.wallRight

				if Constants.DEBUG_MODE then
					print("[GoW] CoverHandler: Chain — re-dirigido a nueva cover")
				end
			end
		end

		local result = self:_updateEntering(self._entering, hrp, humanoid, dt)

		if result == "cancel" then
			self._entering = nil
			self._coverNormal = nil
			self._coverPosition = nil
			self._coverInstance = nil
			self._coverType = nil
			self._wallRight = nil
			self:_cancelTimer()
			if not self._stateMachine:TransitionTo("Idle") then
				self._pendingIdleTransition = true
			end
		elseif result == "complete" then
			self._entering = nil
			-- Entrada completada → CoverIdle.
			-- STATE_MIN_DURATION puede bloquearlo si el snap fue muy rápido.
			-- Delegar al retry en Update() via _pendingCoverIdleTransition.
			self._pendingCoverIdleTransition = true
		end
		-- result == "continue" → no hacer nada, el loop sigue
	end

	-- Movimiento lateral constrañido en CoverIdle
	local currentState = self._stateMachine:GetCurrentState()
	if currentState == "CoverIdle" and self._coverNormal and self._wallRight then
		self:_updateLateralMovement(humanoid, envContext)
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

--- Retorna el vector lateral de la pared (para uso externo si se necesita).
function CoverHandler:GetWallRight(): Vector3?
	return self._wallRight
end

--- Retorna true si el entering está en progreso.
function CoverHandler:IsSnapping(): boolean
	return self._entering ~= nil
end

--- Limpia todo el estado de cover (usado por EvadeHandler al hacer RollOutOfCover).
function CoverHandler:ResetCover()
	self._entering = nil
	self._pendingCoverIdleTransition = false
	self._pendingIdleTransition = false
	self._isExiting = false
	self._coverNormal = nil
	self._coverPosition = nil
	self._coverInstance = nil
	self._coverType = nil
	self._wallRight = nil
	self:_cancelTimer()
end

------------------------------------------------------------------------
-- ACTION HANDLERS
------------------------------------------------------------------------

CoverHandler._handlers = {
	--- Entrada a cover caminando. Estado: CoverEntering (ActionGroup, cancelable).
	--- Calcula snapCFrame con corner clamp, inicia el loop de entering.
	EnterCover = function(self, data)
		if not data then
			return
		end

		self._coverNormal = data.coverNormal
		self._coverPosition = data.coverPos
		self._coverInstance = data.coverInstance
		self._coverType = data.coverType

		local character = self._player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			return
		end

		-- Eliminar inercia horizontal para que el snap sea limpio
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)

		self._entering = self:_buildEnteringData(data.coverInstance, data.coverPos, data.coverNormal, hrp)
		self._wallRight = self._entering.wallRight
	end,

	--- Slide rápido desde RoadieRun. Estado: CoverSlide (ActionGroup, no cancelable por movimiento).
	--- Usa el mismo entering loop pero con timer que fuerza CoverIdle al terminar.
	SlideIntoCover = function(self, data)
		if not data then
			return
		end

		self._coverNormal = data.coverNormal
		self._coverPosition = data.coverPos
		self._coverInstance = data.coverInstance
		self._coverType = data.coverType

		local character = self._player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			return
		end

		-- Eliminar inercia horizontal para que el snap sea limpio
		hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)

		self._entering = self:_buildEnteringData(data.coverInstance, data.coverPos, data.coverNormal, hrp)
		self._wallRight = self._entering.wallRight

		-- CoverSlide dura poco, luego transiciona a CoverIdle
		self:_startTimer(0.3, function()
			self._entering = nil
			if not self._stateMachine:TransitionTo("CoverIdle") then
				self._pendingCoverIdleTransition = true
			end
		end)
	end,

	--- Salida de cover. Estado: CoverExiting (ActionGroup, timer breve a Idle).
	ExitCover = function(self, _data)
		self._isExiting = true
		self._entering = nil
		self._coverNormal = nil
		self._coverPosition = nil
		self._coverInstance = nil
		self._coverType = nil
		self._wallRight = nil

		self:_startTimer(Constants.COVER_EXIT_DURATION, function()
			self._isExiting = false
			if not self._stateMachine:TransitionTo("Idle") then
				self._pendingIdleTransition = true
			end
		end)
	end,

	--- CoverSwap: transición entre covers alineadas (esquina → cover adyacente).
	--- Recibe datos de la nueva cover desde ActionResolver.
	CoverSwap = function(self, data)
		if not data then
			return
		end

		local envContext = data.envContext
		local direction = data.direction

		-- Obtener datos de la cover alineada según la dirección
		local newNormal, newPosition, newInstance
		if direction == "Left" and envContext then
			newNormal = envContext.AlignedCoverNormalLeft
			newPosition = envContext.AlignedCoverPositionLeft
			newInstance = envContext.AlignedCoverInstanceLeft
		elseif direction == "Right" and envContext then
			newNormal = envContext.AlignedCoverNormalRight
			newPosition = envContext.AlignedCoverPositionRight
			newInstance = envContext.AlignedCoverInstanceRight
		end

		if not newNormal or not newPosition then
			return
		end

		local character = self._player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			return
		end

		-- Actualizar datos de cover al destino
		self._coverNormal = newNormal
		self._coverPosition = newPosition
		self._coverInstance = newInstance
		self._coverType = nil -- se re-detectará

		self._entering = self:_buildEnteringData(newInstance, newPosition, newNormal, hrp)
		self._wallRight = self._entering.wallRight

		-- Timer: CoverSwap es un sprint corto expuesto entre covers
		self:_startTimer(Constants.COVER_SWAP_DURATION, function()
			self._entering = nil
			if not self._stateMachine:TransitionTo("CoverIdle") then
				self._pendingCoverIdleTransition = true
			end
		end)
	end,

	--- Pop-up aim: el personaje se levanta/asoma para apuntar desde cover.
	PopUpAim = function(_self, _data)
		-- Física: el personaje no se mueve, solo cambia postura.
		-- Animaciones se manejarán en AnimationController (Fase 4).
	end,

	--- Volver a CoverIdle desde CoverAim.
	ReturnToCover = function(_self, _data)
		-- Inverso de PopUpAim — sin física extra.
	end,

	--- Disparar sin asomarse (impreciso, protegido).
	BlindFire = function(_self, _data)
		-- Sin física extra — AnimationController manejará la postura.
	end,

	--- Dejar de disparar a ciegas — volver a CoverIdle.
	StopBlindFire = function(_self, _data)
		-- Sin física extra.
	end,

	--- Deslizar a la izquierda en cover (no cambia estado — movimiento continuo).
	CoverSlideLeft = function(_self, _data)
		-- El movimiento lateral se maneja en _updateLateralMovement cada frame.
	end,

	--- Deslizar a la derecha en cover (no cambia estado — movimiento continuo).
	CoverSlideRight = function(_self, _data)
		-- El movimiento lateral se maneja en _updateLateralMovement cada frame.
	end,

	--- Asomarse por esquina izquierda.
	PeekCornerLeft = function(_self, _data)
		-- Visual lean — AnimationController en Fase 4.
	end,

	--- Asomarse por esquina derecha.
	PeekCornerRight = function(_self, _data)
		-- Visual lean — AnimationController en Fase 4.
	end,

	--- Vault sobre cover bajo.
	Vault = function(self, _data)
		self._entering = nil
		self._coverType = nil
		self._wallRight = nil
		-- Vault no resetea coverNormal/Position — EvadeHandler/Coordinator lo gestionan
	end,
}

------------------------------------------------------------------------
-- INTERNAL: Corner Clamp — evita snap en la arista del Part
------------------------------------------------------------------------

--- Clampea un hitPos para que quede dentro de la cara del Part,
--- con un margen seguro desde las aristas.
---
--- @param coverPart BasePart — la pieza de cover
--- @param hitPos Vector3 — punto de contacto del raycast
--- @param wallNormal Vector3 — normal de la superficie (horizontal)
--- @param margin number — margen desde aristas (studs)
--- @return Vector3 — posición clampeada sobre la cara
function CoverHandler:_clampHitToFace(
	coverPart: BasePart,
	hitPos: Vector3,
	wallNormal: Vector3,
	margin: number
): Vector3
	local wallRight = wallNormal:Cross(Vector3.yAxis)
	if wallRight.Magnitude < 0.001 then
		return hitPos
	end
	wallRight = wallRight.Unit

	local cf = coverPart.CFrame
	local half = coverPart.Size * 0.5

	-- Extensión del OBB proyectada sobre wallRight
	local halfExt = math.abs(cf.RightVector:Dot(wallRight)) * half.X
		+ math.abs(cf.UpVector:Dot(wallRight)) * half.Y
		+ math.abs(cf.LookVector:Dot(wallRight)) * half.Z

	-- Proyectar hitPos relativo al centro del Part sobre wallRight
	local proj = (hitPos - coverPart.Position):Dot(wallRight)
	local clamped = math.clamp(proj, -(halfExt - margin), halfExt - margin)

	return hitPos + wallRight * (clamped - proj)
end

------------------------------------------------------------------------
-- INTERNAL: Build Entering Data
------------------------------------------------------------------------

--- A partir de un hit válido, produce todo lo que el estado ENTERING necesita.
--- Se llama UNA sola vez al iniciar la entrada.
---
--- @param coverPart BasePart — la pieza de cover
--- @param hitPos Vector3 — punto de contacto del raycast
--- @param wallNormal Vector3 — normal de la superficie (solo horizontal)
--- @param rootPart BasePart — HumanoidRootPart del jugador
--- @return table — { snapCFrame, wallNormal, wallRight, coverPart, startTime }
function CoverHandler:_buildEnteringData(coverPart: BasePart, hitPos: Vector3, wallNormal: Vector3, rootPart: BasePart)
	-- 1. Punto seguro sobre la cara (sin esquinas)
	-- NOTA: EnvironmentSensor ya aplica _snapNormalToFace con corner push-in,
	-- pero mantenemos clamp como red de seguridad.
	local safeHit = self:_clampHitToFace(coverPart, hitPos, wallNormal, Constants.COVER_CORNER_MARGIN)

	-- 2. Posición objetivo XZ: offset desde la pared
	local rawTarget = safeHit + wallNormal * Constants.COVER_OFFSET

	-- 3. Gravedad adaptativa: hip height dinámico para terreno irregular.
	-- Lanzamos rayos hacia abajo en la posición actual y en el destino para
	-- calcular la Y exacta, evitando flotar o atravesar el suelo en rampas/escaleras.
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Exclude
	local character = rootPart.Parent
	groundParams.FilterDescendantsInstances = if character then { character } else {}

	-- Medir hip height actual del jugador (distancia HRP → suelo)
	local playerGround = workspace:Raycast(rootPart.Position, Vector3.new(0, -10, 0), groundParams)
	local hipHeight = if playerGround then (rootPart.Position.Y - playerGround.Position.Y) else 3.0

	-- Medir altura del suelo en el destino (probe desde arriba)
	local destProbe = Vector3.new(rawTarget.X, rawTarget.Y + 5, rawTarget.Z)
	local destGround = workspace:Raycast(destProbe, Vector3.new(0, -15, 0), groundParams)
	local destGroundY = if destGround then destGround.Position.Y else (rootPart.Position.Y - hipHeight)

	local targetPos = Vector3.new(rawTarget.X, destGroundY + hipHeight, rawTarget.Z)

	-- 4. CFrame objetivo: mira hacia afuera de la pared (normal apunta away)
	local snapCFrame = CFrame.lookAt(targetPos, targetPos + wallNormal)

	-- 5. Carril lateral (se reutiliza en InCover para el slide)
	local wallRight = wallNormal:Cross(Vector3.yAxis)
	if wallRight.Magnitude < 0.001 then
		wallRight = Vector3.xAxis
	else
		wallRight = wallRight.Unit
	end

	-- 6. Distancia inicial (para calcular progreso normalizado del ease-out)
	local initialDist = (Vector3.new(targetPos.X, 0, targetPos.Z) - Vector3.new(rootPart.Position.X, 0, rootPart.Position.Z)).Magnitude
	-- Clamp mínimo para evitar división por cero si ya está muy cerca
	if initialDist < 0.5 then
		initialDist = 0.5
	end

	return {
		snapCFrame = snapCFrame,
		wallNormal = wallNormal,
		wallRight = wallRight,
		coverPart = coverPart,
		startTime = os.clock(),
		initialDist = initialDist,
	}
end

------------------------------------------------------------------------
-- INTERNAL: Update Entering (loop Heartbeat)
------------------------------------------------------------------------

--- Lógica de movimiento, rotación, cancelación y completado cada frame.
--- Devuelve "continue" | "complete" | "cancel".
---
--- @param data table — struct de _buildEnteringData
--- @param rootPart BasePart — HumanoidRootPart
--- @param humanoid Humanoid
--- @param dt number — deltaTime
--- @return string — resultado del frame
function CoverHandler:_updateEntering(data, rootPart: BasePart, humanoid: Humanoid, dt: number): string
	local currentPos = rootPart.Position
	local targetCF = data.snapCFrame
	local targetPos = targetCF.Position

	-- ── 1. CANCELACIÓN ────────────────────────────────────────────

	-- A) Jugador se aleja: su dirección de movimiento apunta FUERA de la pared
	local moveDir = humanoid.MoveDirection
	if moveDir.Magnitude > 0.1 then
		-- dot positivo = moviéndose en la misma dirección que la normal = alejándose
		local awayDot = moveDir:Dot(data.wallNormal)
		if awayDot > Constants.COVER_ENTRY_CANCEL_DOT then
			return "cancel"
		end
	end

	-- B) Timeout: lleva demasiado tiempo sin llegar (stuck, geometría rara)
	if (os.clock() - data.startTime) > Constants.COVER_STUCK_TIMEOUT then
		if Constants.DEBUG_MODE then
			print("[GoW] CoverHandler: Entering cancelado por stuck timeout")
		end
		return "cancel"
	end

	-- ── 2. MOVIMIENTO con ease-out (rápido al inicio, desacelera al llegar) ──

	-- Vector hacia el objetivo (ignoramos Y para el movimiento horizontal)
	local toTarget = Vector3.new(targetPos.X - currentPos.X, 0, targetPos.Z - currentPos.Z)
	local distXZ = toTarget.Magnitude

	-- Progreso normalizado: 0 = inicio, 1 = llegó
	local t = 1 - math.clamp(distXZ / data.initialDist, 0, 1)

	-- Ease-out cúbico (smoothstep): rápido al inicio → frena suave al final
	-- Curva: 1 - (1-t)^3  →  en t=0 factor=0, t=0.5 factor=0.875, t=1 factor=1
	local easeFactor = 1 - (1 - t) * (1 - t) * (1 - t)

	-- Velocidad interpolada: max al inicio, decae suavemente pero nunca baja del mínimo
	local speedFrac = 1 - easeFactor * (1 - Constants.COVER_SNAP_MIN_SPEED_FRAC)
	local currentSpeed = Constants.COVER_SNAP_SPEED * speedFrac
	local maxStep = currentSpeed * dt

	local newPos
	if distXZ <= maxStep then
		-- Llegamos este frame
		newPos = Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)
	else
		-- Avanzar un paso
		local step = toTarget.Unit * maxStep
		newPos = Vector3.new(currentPos.X + step.X, currentPos.Y, currentPos.Z + step.Z)
	end

	-- ── 3. ROTACIÓN progresiva (suave al inicio → agresiva al final) ──
	-- El personaje gira lentamente al principio y se compromete al acercarse

	local rotBlend = Constants.COVER_ROTATION_BLEND_MIN
		+ (Constants.COVER_ROTATION_BLEND_MAX - Constants.COVER_ROTATION_BLEND_MIN) * easeFactor

	local currentRot = rootPart.CFrame.Rotation
	local targetRot = targetCF.Rotation
	local blendedRot = currentRot:Lerp(targetRot, rotBlend)

	-- Aplicar posición + rotación combinada
	rootPart.CFrame = CFrame.new(newPos) * blendedRot

	-- ── 4. COMPROBACIÓN DE COMPLETADO ─────────────────────────────

	-- Solo importa la distancia horizontal (XZ), no la Y
	local finalDistXZ = Vector3.new(targetPos.X - newPos.X, 0, targetPos.Z - newPos.Z).Magnitude

	if finalDistXZ < Constants.COVER_COMPLETION_XZ then
		-- Snap final exacto al CFrame objetivo (con Y actual del jugador)
		rootPart.CFrame = CFrame.new(Vector3.new(targetPos.X, currentPos.Y, targetPos.Z)) * targetCF.Rotation
		return "complete"
	end

	return "continue"
end

------------------------------------------------------------------------
-- INTERNAL: Cover Chaining (Cover A → Cover B mid-entry)
------------------------------------------------------------------------

--- Durante ENTERING, si llega un WantsCover sobre una instancia DIFERENTE,
--- reconstruye los datos de entrada. La animación continúa sin interrupción.
---
--- @return table? — nuevo EnteringData si debe hacer chain, nil si no
function CoverHandler:_tryChainCover(
	currentData,
	newHitPos: Vector3,
	newNormal: Vector3,
	newPart: BasePart,
	rootPart: BasePart
)
	-- Solo permitir chain si es una instancia diferente
	if newPart == currentData.coverPart then
		return nil
	end

	-- Reconstruir datos para la nueva cover (startTime se reinicia)
	return self:_buildEnteringData(newPart, newHitPos, newNormal, rootPart)
end

------------------------------------------------------------------------
-- INTERNAL: Movimiento lateral en CoverIdle
------------------------------------------------------------------------

--- Constrañir el movimiento del jugador al eje lateral de la pared.
--- Bloquea movimiento en esquinas según el EnvironmentSensor.
--- Usa _wallRight calculado en BuildEnteringData (no recalcula cada frame).
function CoverHandler:_updateLateralMovement(humanoid: Humanoid, envContext: any?)
	local moveDir = humanoid.MoveDirection
	if moveDir.Magnitude < 0.01 then
		return
	end

	local wallRight = self._wallRight
	if not wallRight then
		return
	end

	-- Proyectar input sobre el eje lateral
	local lateralAmount = moveDir:Dot(wallRight)

	-- Bloquear movimiento en esquinas
	if envContext then
		if lateralAmount > 0 and envContext.IsAtCornerRight then
			lateralAmount = 0
		end
		if lateralAmount < 0 and envContext.IsAtCornerLeft then
			lateralAmount = 0
		end
	end

	-- Aplicar movimiento constrañido (solo lateral)
	if math.abs(lateralAmount) > 0.01 then
		local constrainedDir = wallRight * lateralAmount
		humanoid:Move(constrainedDir, false)
	else
		humanoid:Move(Vector3.zero, false)
	end
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
