--[[
	EnvironmentSensor.luau
	═══════════════════════════════════════════════════════════════
	Detección de entorno mediante Raycast — State-Driven
	═══════════════════════════════════════════════════════════════

	Orquestador que delega a sub-módulos especializados:
	  - RaycastUtils: funciones puras (snap normal, clasificar, identificar cover)
	  - SwapDetector: detección de cover adyacente para Cover Swap
	  - VaultSafety: validación de seguridad para vault

	Escaneo condicional según el estado del jugador:
	  - wantsCoverSearch → _searchCover() (ray + sphere fallback)
	  - RoadieRun        → _scanRoadieRunCover() (forward, rango corto)
	  - CoverIdle/Walk/Run → _detectCorners() (2 rays laterales)
	  - Otros estados    → 0 raycasts (solo passthrough de MoveDirection)

	Los objetos de cover deben tener el tag "CoverObject" de CollectionService
	o el atributo IsCover = true para ser detectados.

	API pública permanece idéntica para todos los consumidores.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

-- Sub-módulos (hermanos en World/)
local RaycastUtils = require(script.Parent.RaycastUtils)
local SwapDetector = require(script.Parent.SwapDetector)
local VaultSafety = require(script.Parent.VaultSafety)

local EnvironmentSensor = {}
EnvironmentSensor.__index = EnvironmentSensor

------------------------------------------------------------------------
-- CONSTRUCTOR
------------------------------------------------------------------------

function EnvironmentSensor.new()
	local self = setmetatable({}, EnvironmentSensor)

	self._player = Players.LocalPlayer

	-- RaycastParams principal (Include mode: solo cover objects)
	self._rayParams = RaycastParams.new()
	self._rayParams.FilterType = Enum.RaycastFilterType.Include
	self._rayParams.FilterDescendantsInstances = {}

	-- Cache de filtro (se reconstruye cuando cambian tags)
	self._filterDirty = true
	self._filterFrameCounter = 0

	self._tagAddedConn = CollectionService:GetInstanceAddedSignal("CoverObject"):Connect(function()
		self._filterDirty = true
	end)
	self._tagRemovedConn = CollectionService:GetInstanceRemovedSignal("CoverObject"):Connect(function()
		self._filterDirty = true
	end)

	-- Sub-módulos especializados
	self._swapDetector = SwapDetector.new()
	self._vaultSafety = VaultSafety.new()

	-- Contexto actual (actualizado cada frame según estado)
	self._context = {
		HasCoverNearby = false,
		CoverType = nil,
		CoverNormal = nil,
		CoverPosition = nil,
		CoverInstance = nil,
		IsAtCornerLeft = false,
		IsAtCornerRight = false,
		MoveDirection = Vector2.zero,
		-- Corner exit system
		IsAtOuterCorner = false,
		CornerExitDirection = nil :: Vector3?,
		RawMovementDirection = nil :: Vector3?,

		-- ════════════════════════════════════════════════════════════
		-- ACTIVE COVER STATE (publicado por CoverMain, Capa 4)
		-- Estos campos representan el estado ACTUAL de cover del jugador,
		-- NO la detección de covers cercanas. ActionResolver (Capa 3) lee
		-- estos campos en vez de acceder directamente al CoverHandler.
		-- ════════════════════════════════════════════════════════════
		ActiveCoverNormal = nil :: Vector3?,
		ActiveCoverType = nil :: string?, -- "Low" | "High"
		ActiveCoverInstance = nil :: BasePart?,
		ActiveWallRight = nil :: Vector3?,
		ActiveAtCornerLeft = false,
		ActiveAtCornerRight = false,
		IsPeekActive = false,
		IsInActiveCover = false,
	}

	-- Cache de character refs (evita FindFirstChild cada frame)
	self._cachedCharacter = nil :: Model?
	self._cachedHRP = nil :: BasePart?
	self._cachedHumanoid = nil :: Humanoid?

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------

function EnvironmentSensor:Destroy()
	if self._tagAddedConn then
		self._tagAddedConn:Disconnect()
		self._tagAddedConn = nil
	end
	if self._tagRemovedConn then
		self._tagRemovedConn:Disconnect()
		self._tagRemovedConn = nil
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Retorna el EnvironmentContext actual (read-only snapshot).
function EnvironmentSensor:GetContext()
	return self._context
end

------------------------------------------------------------------------
-- ACTIVE COVER STATE API (llamado por CoverMain, Capa 4)
-- Permite que el CoverHandler publique su estado sin que las capas
-- superiores (ActionResolver) necesiten una dependencia directa.
------------------------------------------------------------------------

--- Actualiza el estado de cover activo. Llamado por CoverMain cuando
--- entra en cover o cuando cambian los datos de cover.
function EnvironmentSensor:SetActiveCoverData(
	coverNormal: Vector3?,
	coverType: string?,
	coverInstance: BasePart?,
	wallRight: Vector3?
)
	local ctx = self._context
	ctx.ActiveCoverNormal = coverNormal
	ctx.ActiveCoverType = coverType
	ctx.ActiveCoverInstance = coverInstance
	ctx.ActiveWallRight = wallRight
	ctx.IsInActiveCover = coverNormal ~= nil
end

--- Actualiza el estado de esquinas. Llamado por CoverMain/CornerCover
--- cuando detecta cambios en la posición de esquina.
function EnvironmentSensor:SetActiveCornerState(atLeft: boolean, atRight: boolean)
	local ctx = self._context
	ctx.ActiveAtCornerLeft = atLeft
	ctx.ActiveAtCornerRight = atRight
end

--- Actualiza el estado de peek. Llamado por CoverMain/PeekHandler.
function EnvironmentSensor:SetPeekActive(active: boolean)
	self._context.IsPeekActive = active
end

--- Limpia todo el estado de cover activo. Llamado por CoverMain al
--- salir de cover (ExitCover, ResetCover).
function EnvironmentSensor:ClearActiveCoverData()
	local ctx = self._context
	ctx.ActiveCoverNormal = nil
	ctx.ActiveCoverType = nil
	ctx.ActiveCoverInstance = nil
	ctx.ActiveWallRight = nil
	ctx.ActiveAtCornerLeft = false
	ctx.ActiveAtCornerRight = false
	ctx.IsPeekActive = false
	ctx.IsInActiveCover = false
end

--- Actualizar el sensor según el estado actual del jugador.
--- Solo lanza raycasts cuando el estado lo requiere.
--- @param state string — estado actual de la StateMachine
--- @param coverNormal Vector3? — normal de la cover actual (solo en cover states)
--- @param wantsCoverSearch boolean — true si el buffer tiene WantsCover
--- @param moveDirection Vector2 — dirección de input del jugador
function EnvironmentSensor:Update(
	state: string,
	coverNormal: Vector3?,
	wantsCoverSearch: boolean,
	moveDirection: Vector2
)
	self:_resetContext(moveDirection)

	local character = self._player.Character
	if not character then
		return
	end

	-- Actualizar cache si el character cambió (respawn)
	if character ~= self._cachedCharacter then
		self._cachedCharacter = character
		self._cachedHRP = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		self._cachedHumanoid = character:FindFirstChildOfClass("Humanoid")
	end

	local hrp = self._cachedHRP
	if not hrp then
		return
	end

	-- Actualizar filtro solo cuando tags cambiaron o refresco periódico
	self._filterFrameCounter += 1
	if self._filterDirty or self._filterFrameCounter >= Constants.ENV_FILTER_REFRESH_FRAMES then
		self:_updateRayFilter(character)
		self._filterDirty = false
		self._filterFrameCounter = 0
	end

	-- Rama por estado: solo lanzar raycasts cuando es necesario
	local inCoverState = (
		state == "CoverIdle"
		or state == "CoverWalking"
		or state == "CoverRunning"
		or state == "CoverCorners"
		or state == "CoverAimHigh"
		or state == "CoverAimLow"
		or state == "CoverFiring"
		or state == "CoverAim"
		or state == "CoverPeek"
		or state == "CoverBlindFire"
	)

	if wantsCoverSearch then
		self:_searchCover(hrp)
	elseif state == "RoadieRun" then
		self:_scanRoadieRunCover(hrp)
	end

	-- Detectar esquinas siempre que estés en cover
	if inCoverState and coverNormal then
		self:_detectCorners(hrp, coverNormal)

		-- Calcular RawMovementDirection (world-space) desde input Vector2 + cámara
		-- Solo en cover states donde las reglas de esquina lo necesitan
		if moveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD_LOW then
			local camera = workspace.CurrentCamera
			if camera then
				local camCF = camera.CFrame
				local camRight = Vector3.new(camCF.RightVector.X, 0, camCF.RightVector.Z)
				local camForward = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
				if camRight.Magnitude > Constants.ZERO_MAGNITUDE then
					camRight = camRight.Unit
				end
				if camForward.Magnitude > Constants.ZERO_MAGNITUDE then
					camForward = camForward.Unit
				end
				local worldDir = camRight * moveDirection.X + camForward * moveDirection.Y
				if worldDir.Magnitude > Constants.ZERO_MAGNITUDE then
					self._context.RawMovementDirection = worldDir.Unit
				end
			end
		end
	end
end

--- Chequea si hay una esquina interna en la dirección de movimiento.
--- @param hrp BasePart — HumanoidRootPart
--- @param currentNormal Vector3 — normal actual de la cover
--- @param wallParallel Vector3 — vector paralelo a la pared (Unit)
--- @param movementScale number — dot product del movimiento sobre wallParallel
--- @return Vector3? newNormal
--- @return Vector3? newPosition
--- @return BasePart? newInstance
function EnvironmentSensor:CheckInnerCorner(
	hrp: BasePart,
	currentNormal: Vector3,
	wallParallel: Vector3,
	movementScale: number
): (Vector3?, Vector3?, BasePart?)
	if math.abs(movementScale) < Constants.LATERAL_TRIGGER_THRESHOLD then
		return nil, nil, nil
	end

	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET
	local rayDirection = wallParallel * math.sign(movementScale)

	local rayResult = self:_castRay(origin, rayDirection, Constants.COVER_TRANSITION_TRIGGER_DIST)
	if not rayResult or not RaycastUtils.isCoverObject(rayResult.Instance) then
		return nil, nil, nil
	end

	-- Verificar ángulo significativo
	local newNormal, newPosition =
		RaycastUtils.snapNormalToFace(rayResult.Instance, rayResult.Position, rayResult.Normal)
	if not newNormal then
		return nil, nil, nil
	end

	-- Normales muy similares = misma pared, no es transición
	if math.abs(currentNormal:Dot(newNormal)) > Constants.COVER_TRANSITION_DOT_THRESHOLD then
		return nil, nil, nil
	end

	return newNormal, newPosition, rayResult.Instance
end

--- Delega al SwapDetector: chequea cover adyacente para Cover Swap.
--- API idéntica al método original — ningún consumer cambia.
function EnvironmentSensor:CheckSwapCover(
	hrp: BasePart,
	coverNormal: Vector3,
	wallRight: Vector3,
	moveDir: number,
	currentCoverInstance: BasePart,
	inputDirection: Vector3
): (BasePart?, Vector3?, Vector3?)
	return self._swapDetector:Check(hrp, coverNormal, wallRight, moveDir, currentCoverInstance, inputDirection)
end

--- Delega al VaultSafety: verifica que la instancia de cover exista.
function EnvironmentSensor:ValidateCoverInstance(instance: BasePart?): boolean
	return self._vaultSafety:ValidateInstance(instance)
end

--- Delega al VaultSafety: raycasts de seguridad para vault.
function EnvironmentSensor:CheckVaultSafety(
	startPos: Vector3,
	forwardDir: Vector3,
	character: Model,
	coverInstance: BasePart
): (boolean, Vector3?, string?)
	return self._vaultSafety:CheckSafety(startPos, forwardDir, character, coverInstance)
end

--- Re-sondea la pared de cover en la posición actual del jugador.
--- Lanza un rayo corto desde el HRP hacia la pared (-coverNormal).
--- Retorna la part impactada y su clasificación ("Low" / "High"),
--- o nil si no hay cover válida enfrente.
--- @param hrpPos Vector3 — posición del HumanoidRootPart
--- @param coverNormal Vector3 — normal actual de la cover
--- @return BasePart? hitInstance
--- @return string? coverType — "Low" | "High"
function EnvironmentSensor:RecheckCoverWall(hrpPos: Vector3, coverNormal: Vector3): (BasePart?, string?)
	local origin = hrpPos + Constants.COVER_RAY_ORIGIN_OFFSET
	local direction = -coverNormal
	local distance = Constants.COVER_OFFSET + 1

	local result = self:_castRay(origin, direction, distance)
	if not result or not RaycastUtils.isCoverObject(result.Instance) then
		return nil, nil
	end

	return result.Instance, RaycastUtils.classifyCover(result.Instance)
end

------------------------------------------------------------------------
-- INTERNAL: Scan Methods
------------------------------------------------------------------------

--- Búsqueda on-demand de cover cercana (petición del jugador).
--- Dirección: moveDirection si hay input, sino lookVector del rootpart.
--- Método: ray primero, spherecast como fallback.
function EnvironmentSensor:_searchCover(hrp: BasePart)
	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET

	local searchDir = self:_getSearchDirection(hrp)
	if not searchDir then
		return
	end

	-- Intento 1: Raycast preciso
	local rayResult = self:_castRay(origin, searchDir, Constants.COVER_SCAN_RANGE)
	if rayResult and RaycastUtils.isCoverObject(rayResult.Instance) then
		if RaycastUtils.populateCoverContext(self._context, rayResult) then
			return
		end
	end

	-- Intento 2: Spherecast (más tolerante en bordes y ángulos rasantes)
	local sphereResult = self:_castSphere(origin, searchDir, Constants.COVER_SCAN_RANGE)
	if sphereResult and RaycastUtils.isCoverObject(sphereResult.Instance) then
		RaycastUtils.populateCoverContext(self._context, sphereResult)
	end
end

--- Escaneo per-frame durante RoadieRun. Rango corto (auto-entry).
function EnvironmentSensor:_scanRoadieRunCover(hrp: BasePart)
	local origin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET

	local lookDir = hrp.CFrame.LookVector
	local flatLook = Vector3.new(lookDir.X, 0, lookDir.Z)
	if flatLook.Magnitude < Constants.ZERO_MAGNITUDE then
		return
	end
	flatLook = flatLook.Unit

	-- Intento 1: Raycast preciso a rango corto
	local rayResult = self:_castRay(origin, flatLook, Constants.COVER_AUTO_DETECT_DIST)
	if rayResult and RaycastUtils.isCoverObject(rayResult.Instance) then
		if RaycastUtils.populateCoverContext(self._context, rayResult) then
			return
		end
	end

	-- Intento 2: Spherecast a rango corto
	local sphereResult = self:_castSphere(origin, flatLook, Constants.COVER_AUTO_DETECT_DIST)
	if sphereResult and RaycastUtils.isCoverObject(sphereResult.Instance) then
		RaycastUtils.populateCoverContext(self._context, sphereResult)
	end
end

--- Detecta esquinas izquierda/derecha de la pared de cover actual.
function EnvironmentSensor:_detectCorners(hrp: BasePart, coverNormal: Vector3)
	local playerOrigin = hrp.Position + Constants.COVER_RAY_ORIGIN_OFFSET
	local ctx = self._context

	-- Vector paralelo a la pared: Up × N → apunta a la DERECHA del jugador
	local wallParallel = Vector3.yAxis:Cross(coverNormal)
	if wallParallel.Magnitude < Constants.ZERO_MAGNITUDE then
		wallParallel = Vector3.xAxis
	else
		wallParallel = wallParallel.Unit
	end

	local cornerRange = Constants.COVER_CORNER_DETECTION_RANGE
	local rayDistanceToWall = Constants.COVER_OFFSET + 1

	-- Sensor izquierdo: rayo hacia la pared desde la izquierda del jugador
	local leftOrigin = playerOrigin + (-wallParallel * cornerRange)
	local leftResult = self:_castRay(leftOrigin, -coverNormal, rayDistanceToWall)
	ctx.IsAtCornerLeft = not leftResult or not RaycastUtils.isCoverObject(leftResult.Instance)

	-- Sensor derecho: rayo hacia la pared desde la derecha del jugador
	local rightOrigin = playerOrigin + (wallParallel * cornerRange)
	local rightResult = self:_castRay(rightOrigin, -coverNormal, rayDistanceToWall)
	ctx.IsAtCornerRight = not rightResult or not RaycastUtils.isCoverObject(rightResult.Instance)

	-- Corner exit system: publicar tangente y dirección de salida cuando hay esquina exterior
	ctx.IsAtOuterCorner = ctx.IsAtCornerLeft or ctx.IsAtCornerRight
	if ctx.IsAtOuterCorner then
		ctx.CornerExitDirection = coverNormal -- la normal ya apunta al espacio abierto
	end
end

------------------------------------------------------------------------
-- INTERNAL: Helpers
------------------------------------------------------------------------

--- Determina la dirección de búsqueda de cover: input o lookVector.
--- @return Vector3? — dirección horizontal unitaria (nil si inválida)
function EnvironmentSensor:_getSearchDirection(hrp: BasePart): Vector3?
	local humanoid = self._cachedHumanoid
	local searchDir: Vector3
	if humanoid and humanoid.MoveDirection.Magnitude > Constants.MOVE_DIRECTION_THRESHOLD then
		searchDir = humanoid.MoveDirection
	else
		searchDir = hrp.CFrame.LookVector
	end

	local flatDir = Vector3.new(searchDir.X, 0, searchDir.Z)
	if flatDir.Magnitude < Constants.ZERO_MAGNITUDE then
		return nil
	end
	return flatDir.Unit
end

--- Resetea todos los campos del contexto al inicio de cada frame.
function EnvironmentSensor:_resetContext(moveDirection: Vector2)
	local ctx = self._context
	ctx.HasCoverNearby = false
	ctx.CoverType = nil
	ctx.CoverNormal = nil
	ctx.CoverPosition = nil
	ctx.CoverInstance = nil
	ctx.IsAtCornerLeft = false
	ctx.IsAtCornerRight = false
	ctx.MoveDirection = moveDirection
	-- Corner exit system
	ctx.IsAtOuterCorner = false
	ctx.CornerExitDirection = nil
	ctx.RawMovementDirection = nil

	-- Mantener el estado de cover activo (NO se resetea cada frame,
	-- solo lo actualiza CoverMain cuando cambia el estado de cover).
	-- Los campos Active* persisten entre frames.
end

------------------------------------------------------------------------
-- INTERNAL: Raycast Infrastructure
------------------------------------------------------------------------

--- Raycast usando los params principales (Include mode: solo cover objects).
function EnvironmentSensor:_castRay(origin: Vector3, direction: Vector3, distance: number): RaycastResult?
	return workspace:Raycast(origin, direction * distance, self._rayParams)
end

--- Spherecast horizontal para detección más robusta.
function EnvironmentSensor:_castSphere(origin: Vector3, direction: Vector3, distance: number): RaycastResult?
	local dir2D = Vector3.new(direction.X, 0, direction.Z)
	if dir2D.Magnitude < Constants.ZERO_MAGNITUDE then
		return nil
	end
	dir2D = dir2D.Unit * distance
	return workspace:Spherecast(origin, Constants.COVER_SPHERECAST_RADIUS, dir2D, self._rayParams)
end


--- Reconstruye el filtro de Include para los RaycastParams.
--- Solo usa CollectionService:GetTagged() — O(n) en vez de O(n²).
--- Si no hay cover objects taggeados → Exclude mode (fallback dev).
function EnvironmentSensor:_updateRayFilter(character: Model)
	local coverObjects = CollectionService:GetTagged("CoverObject")

	-- Set para dedup O(1)
	local filterSet = {}
	local filterList = {}

	for _, obj in coverObjects do
		if obj:IsA("BasePart") and not filterSet[obj] then
			filterSet[obj] = true
			table.insert(filterList, obj)
		end
	end

	-- Si no hay cover objects taggeados → Exclude mode como fallback.
	-- En este modo, _isCoverObject del RaycastUtils valida cada hit
	-- (tag, attribute, o fallback de tamaño si COVER_FALLBACK_ENABLED).
	if #filterList == 0 then
		self._rayParams.FilterType = Enum.RaycastFilterType.Exclude
		self._rayParams.FilterDescendantsInstances = { character }
	else
		self._rayParams.FilterType = Enum.RaycastFilterType.Include
		self._rayParams.FilterDescendantsInstances = filterList
	end
end

return EnvironmentSensor
