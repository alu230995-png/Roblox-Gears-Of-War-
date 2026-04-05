--[[
	CoverEnteringTest.client.luau
	================================================================
	Test suite intensivo del sistema de Entering Cover.
	================================================================
	
	7 tests:
	  1. Simple EnterCover (quieto, cover enfrente)
	  2. Running -> EnterCover (caminando hacia cover)
	  3. Cancel por movimiento trasero (dot > threshold)
	  4. Cancel por stuck timeout (cover inalcanzable)
	  5. Corner clamp (snap no cae en arista del Part)
	  6. Cover chaining (cambiar de cover mid-entry)
	  7. Exit cover + re-enter (ciclo completo)
	
	Para ejecutar: Rojo sync -> play en Studio.
	Resultados en Output con prefijo [CoverTest].
]]
--[[

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local StateMachine = require(Shared:WaitForChild("Utils"):WaitForChild("StateMachine"))
local PlayerState = require(Shared:WaitForChild("Enums"):WaitForChild("PlayerState"))

local Client = script.Parent.Parent
local CoverHandler = require(Client:WaitForChild("Character"):WaitForChild("Movement"):WaitForChild("CoverHandler"))

local player = Players.LocalPlayer

------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------

local LOG_PREFIX = "[CoverTest]"
local testResults: { { name: string, passed: boolean, reason: string? } } = {}

local function log(...)
	print(LOG_PREFIX, ...)
end

local function logSeparator(title: string)
	print("\n" .. string.rep("=", 60))
	print(LOG_PREFIX, title)
	print(string.rep("=", 60))
end

local function record(name: string, passed: boolean, reason: string?)
	table.insert(testResults, { name = name, passed = passed, reason = reason })
	if passed then
		log("   >> PASS:", name)
	else
		log("   >> FAIL:", name, reason or "")
	end
end

local function waitForCharacter(): (Model, Humanoid, BasePart)
	local character = player.Character or player.CharacterAdded:Wait()
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local hrp = character:WaitForChild("HumanoidRootPart") :: BasePart
	task.wait(0.5)
	return character, humanoid, hrp
end

--- Espera a que pase STATE_MIN_DURATION para que TransitionTo no sea rechazada.
local function waitMinDuration(sm)
	local remaining = Constants.STATE_MIN_DURATION - sm:GetTimeInState()
	if remaining > 0 then
		task.wait(remaining + 0.02)
	end
end

local function createTestWall(hrp: BasePart, distance: number, height: number, width: number?): BasePart
	local wall = Instance.new("Part")
	wall.Name = "TestCoverWall"
	wall.Size = Vector3.new(width or 12, height, 1.5)
	wall.Anchored = true
	wall.CanCollide = true
	wall.BrickColor = BrickColor.new("Dark stone grey")
	wall.Material = Enum.Material.Concrete

	local lookFlat = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit
	local wallPos = hrp.Position + lookFlat * distance + Vector3.new(0, height * 0.5 - 1, 0)
	wall.CFrame = CFrame.lookAt(wallPos, wallPos - lookFlat)

	wall:SetAttribute("IsCover", true)
	CollectionService:AddTag(wall, "CoverObject")
	wall.Parent = workspace
	return wall
end

--- Crea una pared de cover en una posicion absoluta con orientacion dada.
local function createWallAt(pos: Vector3, normal: Vector3, size: Vector3): BasePart
	local wall = Instance.new("Part")
	wall.Name = "TestCoverWallAbsolute"
	wall.Size = size
	wall.Anchored = true
	wall.CanCollide = true
	wall.BrickColor = BrickColor.new("Dark stone grey")
	wall.Material = Enum.Material.Concrete
	wall.CFrame = CFrame.lookAt(pos, pos + normal)
	wall:SetAttribute("IsCover", true)
	CollectionService:AddTag(wall, "CoverObject")
	wall.Parent = workspace
	return wall
end

local function createStateMachine()
	local sm = StateMachine.new("Idle", PlayerState.Transitions)
	for groupName, groupConfig in PlayerState.Groups do
		sm:RegisterGroup(groupName, {
			Parent = groupConfig.Parent,
			States = groupConfig.States,
		})
	end
	sm:BuildGroupHierarchy()
	return sm
end

local function scanCover(hrp: BasePart, wall: BasePart): (Vector3?, Vector3?, BasePart?)
	local origin = hrp.Position
	local lookFlat = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { wall }

	local result = workspace:Spherecast(origin, Constants.COVER_SPHERECAST_RADIUS, lookFlat * 20, rayParams)
	if result then
		local n = result.Normal
		local wallNormal = Vector3.new(n.X, 0, n.Z)
		if wallNormal.Magnitude > 0.001 then
			return result.Position, wallNormal.Unit, result.Instance :: BasePart
		end
	end
	return nil, nil, nil
end

--- Scanea cover usando una direccion arbitraria (no usa lookVector).
local function scanCoverDir(origin: Vector3, direction: Vector3, wall: BasePart): (Vector3?, Vector3?, BasePart?)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Include
	rayParams.FilterDescendantsInstances = { wall }

	local result = workspace:Spherecast(origin, Constants.COVER_SPHERECAST_RADIUS, direction.Unit * 20, rayParams)
	if result then
		local n = result.Normal
		local wallNormal = Vector3.new(n.X, 0, n.Z)
		if wallNormal.Magnitude > 0.001 then
			return result.Position, wallNormal.Unit, result.Instance :: BasePart
		end
	end
	return nil, nil, nil
end

local function classifyCover(part: BasePart): string
	if part.Size.Y <= Constants.COVER_HEIGHT_LOW_MAX then
		return "Low"
	end
	return "High"
end

--- Transiciona a CoverEntering respetando STATE_MIN_DURATION.
--- Hace Idle primero si es necesario.
local function transitionToCoverEntering(sm): boolean
	local state = sm:GetCurrentState()
	-- Si ya estamos en CoverEntering, ok
	if state == "CoverEntering" then
		return true
	end
	-- Desde ActionGroup, necesitamos pasar por Idle primero
	if state ~= "Idle" and state ~= "Walking" and state ~= "RoadieRun" then
		waitMinDuration(sm)
		sm:TransitionTo("Idle")
		waitMinDuration(sm)
	else
		waitMinDuration(sm)
	end
	return sm:TransitionTo("CoverEntering")
end

--- Ejecuta el loop de entering y retorna resultado.
local function runEnteringLoop(coverHandler, dt_source, maxSeconds: number?): (string, number)
	local maxFrames = math.ceil((maxSeconds or 3) * 60)
	local frameCount = 0
	while frameCount < maxFrames do
		local dt = dt_source()
		frameCount += 1
		coverHandler:Update(dt, nil)
		if not coverHandler:IsSnapping() then
			if coverHandler._pendingCoverIdleTransition then
				return "complete", frameCount
			else
				return "cancel", frameCount
			end
		end
	end
	return "timeout", frameCount
end

------------------------------------------------------------------------
-- TEST 1: Simple EnterCover (quieto, cover enfrente)
------------------------------------------------------------------------

local function test1_SimpleEnterCover(): boolean
	logSeparator("TEST 1: Simple EnterCover (quieto)")

	local _character, humanoid, hrp = waitForCharacter()
	local wall = createTestWall(hrp, 6, 5)
	task.wait(0.2)

	local sm = createStateMachine()
	local coverHandler = CoverHandler.new(sm)

	local hitPos, wallNormal, coverPart = scanCover(hrp, wall)
	if not hitPos or not wallNormal or not coverPart then
		log("   No se detecto cover")
		wall:Destroy()
		record("T1: Cover detectada", false, "Spherecast no impacto")
		return false
	end
	record("T1: Cover detectada", true)
	log("   hitPos:", hitPos, "dist:", (hitPos - hrp.Position).Magnitude)

	-- FIX: Esperar STATE_MIN_DURATION antes de transicionar
	waitMinDuration(sm)

	local transOk = transitionToCoverEntering(sm)
	if not transOk then
		log("   TransitionTo CoverEntering rechazada desde:", sm:GetCurrentState())
		wall:Destroy()
		record("T1: Transicion a CoverEntering", false, "SM rechazo: " .. sm:GetCurrentState())
		return false
	end
	record("T1: Transicion a CoverEntering", true)

	coverHandler:HandleAction("EnterCover", {
		coverNormal = wallNormal,
		coverPos = hitPos,
		coverInstance = coverPart,
		coverType = classifyCover(coverPart),
	})
	record("T1: HandleAction acepta", coverHandler:IsSnapping())

	local startPos = hrp.Position
	humanoid:Move(Vector3.zero, false)

	-- Loop de entering usando Heartbeat real
	local result, frames = runEnteringLoop(coverHandler, function()
		return RunService.Heartbeat:Wait()
	end, 3)

	-- Transicionar a CoverIdle si completo
	if result == "complete" then
		waitMinDuration(sm)
		sm:TransitionTo("CoverIdle")
	end

	local endPos = hrp.Position
	local finalDist = (Vector3.new(endPos.X, 0, endPos.Z) - Vector3.new(hitPos.X, 0, hitPos.Z)).Magnitude
	local travelDist = (Vector3.new(endPos.X, 0, endPos.Z) - Vector3.new(startPos.X, 0, startPos.Z)).Magnitude

	log("   Frames:", frames, "Resultado:", result)
	log("   Distancia recorrida:", string.format("%.3f", travelDist))
	log("   Distancia final a cover:", string.format("%.3f", finalDist))
	log("   Estado SM:", sm:GetCurrentState())

	record("T1: Entering completa", result == "complete", "result=" .. result)
	record(
		"T1: Distancia ~ COVER_OFFSET",
		math.abs(finalDist - Constants.COVER_OFFSET) < 0.5,
		string.format("%.3f vs %.3f", finalDist, Constants.COVER_OFFSET)
	)

	-- Verificar rotacion: jugador mira en direccion de wallNormal
	local lookDir = hrp.CFrame.LookVector
	local lookDot = Vector3.new(lookDir.X, 0, lookDir.Z).Unit:Dot(wallNormal)
	record("T1: Rotacion correcta (dot>0.85)", lookDot > 0.85, string.format("dot=%.3f", lookDot))

	-- Verificar que el coverHandler guardo la normal
	local storedNormal = coverHandler:GetNormal()
	record("T1: Normal guardada", storedNormal ~= nil)

	wall:Destroy()
	return result == "complete"
end

------------------------------------------------------------------------
-- TEST 2: Running -> EnterCover (caminando hacia cover)
------------------------------------------------------------------------

local function test2_RunningEnterCover(): boolean
	logSeparator("TEST 2: Running -> EnterCover")

	local _character, humanoid, hrp = waitForCharacter()
	local wall = createTestWall(hrp, 10, 6)
	task.wait(0.2)

	local sm = createStateMachine()
	local coverHandler = CoverHandler.new(sm)

	log("   Fase 1: Caminando hacia cover 0.5s...")
	waitMinDuration(sm)
	sm:TransitionTo("Walking")
	local lookFlat = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit
	humanoid.WalkSpeed = Constants.WALK_SPEED
	humanoid:Move(lookFlat, false)

	local walkTime = 0
	while walkTime < 0.5 do
		local dt = RunService.Heartbeat:Wait()
		walkTime += dt
		humanoid:Move(lookFlat, false)
	end
	humanoid:Move(Vector3.zero, false)

	log(
		"   Pos despues de caminar:",
		string.format("(%.2f, %.2f, %.2f)", hrp.Position.X, hrp.Position.Y, hrp.Position.Z)
	)

	local hitPos, wallNormal, coverPart = scanCover(hrp, wall)
	if not hitPos or not wallNormal or not coverPart then
		wall:Destroy()
		record("T2: Cover detectada", false, "No hay cover tras caminar")
		return false
	end
	record("T2: Cover detectada", true)

	local transOk = transitionToCoverEntering(sm)
	if not transOk then
		wall:Destroy()
		record("T2: Transicion a CoverEntering", false, "Desde " .. sm:GetCurrentState())
		return false
	end
	record("T2: Transicion a CoverEntering", true)

	coverHandler:HandleAction("EnterCover", {
		coverNormal = wallNormal,
		coverPos = hitPos,
		coverInstance = coverPart,
		coverType = classifyCover(coverPart),
	})

	local result, frames = runEnteringLoop(coverHandler, function()
		return RunService.Heartbeat:Wait()
	end, 3)

	if result == "complete" then
		waitMinDuration(sm)
		sm:TransitionTo("CoverIdle")
	end

	local endPos = hrp.Position
	local finalDist = (Vector3.new(endPos.X, 0, endPos.Z) - Vector3.new(hitPos.X, 0, hitPos.Z)).Magnitude

	log("   Frames:", frames, "Resultado:", result)
	log("   Distancia final:", string.format("%.3f", finalDist))
	log("   Estado SM:", sm:GetCurrentState())

	record("T2: Entering completa", result == "complete", "result=" .. result)
	record(
		"T2: Distancia ~ COVER_OFFSET",
		math.abs(finalDist - Constants.COVER_OFFSET) < 0.5,
		string.format("%.3f vs %.3f", finalDist, Constants.COVER_OFFSET)
	)

	local lookDotVal = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit:Dot(wallNormal)
	record("T2: Rotacion correcta", lookDotVal > 0.85, string.format("dot=%.3f", lookDotVal))

	wall:Destroy()
	return result == "complete"
end

------------------------------------------------------------------------
-- TEST 3: Cancel por movimiento trasero
------------------------------------------------------------------------

local function test3_CancelByMovement(): boolean
	logSeparator("TEST 3: Cancel por movimiento trasero (dot)")

	local _character, humanoid, hrp = waitForCharacter()
	local wall = createTestWall(hrp, 8, 5)
	task.wait(0.2)

	local sm = createStateMachine()
	local coverHandler = CoverHandler.new(sm)

	local hitPos, wallNormal, coverPart = scanCover(hrp, wall)
	if not hitPos or not wallNormal or not coverPart then
		wall:Destroy()
		record("T3: Cover detectada", false)
		return false
	end

	local transOk = transitionToCoverEntering(sm)
	if not transOk then
		wall:Destroy()
		record("T3: Transicion", false)
		return false
	end

	coverHandler:HandleAction("EnterCover", {
		coverNormal = wallNormal,
		coverPos = hitPos,
		coverInstance = coverPart,
		coverType = classifyCover(coverPart),
	})
	record("T3: Entering iniciado", coverHandler:IsSnapping())

	-- Dejar avanzar unos frames para que empiece a moverse
	for _ = 1, 5 do
		local dt = RunService.Heartbeat:Wait()
		coverHandler:Update(dt, nil)
	end

	-- Ahora mover al humanoid AWAY de la cover (misma dir que wallNormal = alejandose)
	-- Esto deberia disparar la cancelacion por dot > COVER_ENTRY_CANCEL_DOT
	log("   Moviendo jugador AWAY de la cover (dir = wallNormal)...")
	humanoid:Move(wallNormal, false)

	-- Loop: esperar que se cancele
	local result = "timeout"
	local frames = 0
	for _ = 1, 120 do
		local dt = RunService.Heartbeat:Wait()
		frames += 1
		humanoid:Move(wallNormal, false) -- mantener movimiento away
		coverHandler:Update(dt, nil)
		if not coverHandler:IsSnapping() then
			if coverHandler._pendingCoverIdleTransition then
				result = "complete" -- no deberia pasar, deberia cancelar
			else
				result = "cancel"
			end
			break
		end
	end
	humanoid:Move(Vector3.zero, false)

	log("   Resultado:", result, "en", frames, "frames")
	log("   Estado SM:", sm:GetCurrentState())

	record("T3: Entering fue cancelado", result == "cancel", "result=" .. result)
	-- Verificar que no quedo en CoverIdle (sino en Idle tras cancel)
	record("T3: No quedo en CoverIdle", sm:GetCurrentState() ~= "CoverIdle")
	-- Verificar que el handler limpio su estado
	record("T3: Normal limpiada", coverHandler:GetNormal() == nil)
	record("T3: IsSnapping false", not coverHandler:IsSnapping())

	wall:Destroy()
	return result == "cancel"
end

------------------------------------------------------------------------
-- TEST 4: Cancel por stuck timeout
------------------------------------------------------------------------

local function test4_StuckTimeout(): boolean
	logSeparator("TEST 4: Stuck Timeout (cover inalcanzable)")

	local _character, humanoid, hrp = waitForCharacter()

	-- Crear pared MUY lejos pero pasar hitPos como si estuviera cerca
	-- Esto simula geometria rara donde el spherecast impacta pero
	-- hay obstaculos entre el jugador y la cover real.
	local wall = createTestWall(hrp, 6, 5)
	task.wait(0.2)

	local sm = createStateMachine()
	local coverHandler = CoverHandler.new(sm)

	-- Scan real para obtener datos validos
	local hitPos, wallNormal, coverPart = scanCover(hrp, wall)
	if not hitPos or not wallNormal or not coverPart then
		wall:Destroy()
		record("T4: Cover detectada", false)
		return false
	end

	-- Ahora mover la pared muy lejos para que sea "inalcanzable"
	-- pero el entering data ya fue calculado con la pos original
	local transOk = transitionToCoverEntering(sm)
	if not transOk then
		wall:Destroy()
		record("T4: Transicion", false)
		return false
	end

	-- Fabricar datos falsos: coverPos a 500 studs (inalcanzable en timeout)
	local fakeHitPos = hrp.Position + Vector3.new(0, 0, -500)
	coverHandler:HandleAction("EnterCover", {
		coverNormal = wallNormal,
		coverPos = fakeHitPos,
		coverInstance = coverPart,
		coverType = "High",
	})
	record("T4: Entering con pos falsa iniciado", coverHandler:IsSnapping())
	humanoid:Move(Vector3.zero, false)

	-- Loop: debe cancelarse por COVER_STUCK_TIMEOUT (1.8s)
	local startTime = os.clock()
	local result = "timeout"
	local elapsed = 0
	while elapsed < Constants.COVER_STUCK_TIMEOUT + 1 do
		local dt = RunService.Heartbeat:Wait()
		elapsed = os.clock() - startTime
		coverHandler:Update(dt, nil)
		if not coverHandler:IsSnapping() then
			if coverHandler._pendingCoverIdleTransition then
				result = "complete"
			else
				result = "cancel"
			end
			break
		end
	end

	log("   Resultado:", result, "a los", string.format("%.2f", elapsed), "segundos")

	record("T4: Se cancelo por timeout", result == "cancel", "result=" .. result)
	record(
		"T4: Tiempo correcto (~STUCK_TIMEOUT)",
		elapsed >= Constants.COVER_STUCK_TIMEOUT - 0.1 and elapsed <= Constants.COVER_STUCK_TIMEOUT + 0.5,
		string.format("%.2fs vs expected %.2fs", elapsed, Constants.COVER_STUCK_TIMEOUT)
	)
	record("T4: Estado limpio", coverHandler:GetNormal() == nil)

	wall:Destroy()
	return result == "cancel"
end

------------------------------------------------------------------------
-- TEST 5: Corner Clamp (snap no cae en arista)
------------------------------------------------------------------------

local function test5_CornerClamp(): boolean
	logSeparator("TEST 5: Corner Clamp (arista del Part)")

	local _character, humanoid, hrp = waitForCharacter()

	-- Crear pared ESTRECHA (3 studs de ancho) para forzar corner clamp
	local wall = createTestWall(hrp, 6, 5, 3)
	task.wait(0.2)

	local sm = createStateMachine()
	local coverHandler = CoverHandler.new(sm)

	local hitPos, wallNormal, coverPart = scanCover(hrp, wall)
	if not hitPos or not wallNormal or not coverPart then
		wall:Destroy()
		record("T5: Cover detectada", false)
		return false
	end

	local transOk = transitionToCoverEntering(sm)
	if not transOk then
		wall:Destroy()
		record("T5: Transicion", false)
		return false
	end

	coverHandler:HandleAction("EnterCover", {
		coverNormal = wallNormal,
		coverPos = hitPos,
		coverInstance = coverPart,
		coverType = classifyCover(coverPart),
	})
	humanoid:Move(Vector3.zero, false)

	-- Loop de entering
	local result, frames = runEnteringLoop(coverHandler, function()
		return RunService.Heartbeat:Wait()
	end, 3)

	if result == "complete" then
		waitMinDuration(sm)
		sm:TransitionTo("CoverIdle")
	end

	-- Verificar que la posicion final esta dentro de los bounds del Part
	local endPos = hrp.Position
	local wallRight = wallNormal:Cross(Vector3.yAxis).Unit
	local relativeToWall = (endPos - wall.Position):Dot(wallRight)
	local halfWidth = wall.Size.X * 0.5

	log("   Frames:", frames, "Resultado:", result)
	log("   Pos relativa al centro:", string.format("%.3f", relativeToWall))
	log("   Half width:", halfWidth, "Margin:", Constants.COVER_CORNER_MARGIN)
	log("   Limite:", halfWidth - Constants.COVER_CORNER_MARGIN)

	local withinBounds = math.abs(relativeToWall) <= (halfWidth - Constants.COVER_CORNER_MARGIN + 0.1)
	record("T5: Entering completa", result == "complete", "result=" .. result)
	record(
		"T5: Dentro de bounds clampeados",
		withinBounds,
		string.format("rel=%.3f limit=%.3f", relativeToWall, halfWidth - Constants.COVER_CORNER_MARGIN)
	)

	wall:Destroy()
	return result == "complete" and withinBounds
end

------------------------------------------------------------------------
-- TEST 6: Cover Chaining (cambiar mid-entry)
------------------------------------------------------------------------

local function test6_CoverChaining(): boolean
	logSeparator("TEST 6: Cover Chaining (Cover A -> Cover B mid-entry)")

	local _character, humanoid, hrp = waitForCharacter()

	-- Cover A: lejos (8 studs)
	local wallA = createTestWall(hrp, 8, 5)
	task.wait(0.1)

	-- Cover B: mas cerca (4 studs), ligeramente a la derecha
	local lookFlat = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit
	local rightFlat = Vector3.new(hrp.CFrame.RightVector.X, 0, hrp.CFrame.RightVector.Z).Unit
	local wallBpos = hrp.Position + lookFlat * 4 + rightFlat * 2 + Vector3.new(0, 1.5, 0)
	local wallB = createWallAt(wallBpos, -lookFlat, Vector3.new(6, 5, 1.5))
	task.wait(0.1)

	local sm = createStateMachine()
	local coverHandler = CoverHandler.new(sm)

	-- Scan cover A
	local hitA, normalA, partA = scanCover(hrp, wallA)
	if not hitA or not normalA or not partA then
		wallA:Destroy()
		wallB:Destroy()
		record("T6: Cover A detectada", false)
		return false
	end
	record("T6: Cover A detectada", true)

	local transOk = transitionToCoverEntering(sm)
	if not transOk then
		wallA:Destroy()
		wallB:Destroy()
		record("T6: Transicion", false)
		return false
	end

	-- Iniciar entering hacia Cover A
	coverHandler:HandleAction("EnterCover", {
		coverNormal = normalA,
		coverPos = hitA,
		coverInstance = partA,
		coverType = classifyCover(partA),
	})
	humanoid:Move(Vector3.zero, false)

	-- Avanzar unos frames
	for _ = 1, 5 do
		local dt = RunService.Heartbeat:Wait()
		coverHandler:Update(dt, nil)
	end

	record("T6: Entering hacia A iniciado", coverHandler:IsSnapping())

	-- Ahora scan Cover B y simular chaining via envContext
	local hitB, normalB, partB = scanCoverDir(hrp.Position, lookFlat, wallB)
	if hitB and normalB and partB then
		record("T6: Cover B detectada", true)

		-- Simular envContext con cover B
		local fakeEnvCtx = {
			HasCoverNearby = true,
			CoverInstance = partB,
			CoverPosition = hitB,
			CoverNormal = normalB,
			CoverType = classifyCover(partB),
		}

		-- Loop de entering CON envContext (deberia triggear chaining)
		local result = "timeout"
		local frames = 0
		for _ = 1, 180 do
			local dt = RunService.Heartbeat:Wait()
			frames += 1
			coverHandler:Update(dt, fakeEnvCtx)
			if not coverHandler:IsSnapping() then
				if coverHandler._pendingCoverIdleTransition then
					result = "complete"
				else
					result = "cancel"
				end
				break
			end
		end

		log("   Frames:", frames, "Resultado:", result)
		record("T6: Chain+Entering completa", result == "complete", "result=" .. result)

		-- Si completo, verificar que la cover guardada es B, no A
		local storedInstance = coverHandler._coverInstance
		record(
			"T6: Cover final es B (no A)",
			storedInstance == partB,
			"Es partA: " .. tostring(storedInstance == partA)
		)
	else
		record("T6: Cover B detectada", false, "No se pudo scanear B")
	end

	wallA:Destroy()
	wallB:Destroy()
	return true
end

------------------------------------------------------------------------
-- TEST 7: Exit + Re-enter (ciclo completo)
------------------------------------------------------------------------

local function test7_ExitAndReenter(): boolean
	logSeparator("TEST 7: Exit Cover + Re-enter (ciclo completo)")

	local _character, humanoid, hrp = waitForCharacter()
	local wall = createTestWall(hrp, 6, 5)
	task.wait(0.2)

	local sm = createStateMachine()
	local coverHandler = CoverHandler.new(sm)

	-- FASE 1: Entrar en cover
	local hitPos, wallNormal, coverPart = scanCover(hrp, wall)
	if not hitPos or not wallNormal or not coverPart then
		wall:Destroy()
		record("T7: Phase1 cover detectada", false)
		return false
	end

	local transOk = transitionToCoverEntering(sm)
	if not transOk then
		wall:Destroy()
		record("T7: Phase1 transicion", false)
		return false
	end

	coverHandler:HandleAction("EnterCover", {
		coverNormal = wallNormal,
		coverPos = hitPos,
		coverInstance = coverPart,
		coverType = classifyCover(coverPart),
	})
	humanoid:Move(Vector3.zero, false)

	local result1, _ = runEnteringLoop(coverHandler, function()
		return RunService.Heartbeat:Wait()
	end, 3)

	if result1 == "complete" then
		waitMinDuration(sm)
		sm:TransitionTo("CoverIdle")
	end
	record("T7: Phase1 Entering completa", result1 == "complete", "result=" .. result1)

	-- FASE 2: Salir de cover
	log("   Fase 2: Saliendo de cover...")
	waitMinDuration(sm)
	local exitOk = sm:TransitionTo("CoverExiting")
	if not exitOk then
		-- CoverGroup tiene transicion a CoverExiting
		log("   TransitionTo CoverExiting fallo desde:", sm:GetCurrentState())
		record("T7: Phase2 transicion exit", false, "Desde " .. sm:GetCurrentState())
		wall:Destroy()
		return false
	end

	coverHandler:HandleAction("ExitCover", nil)
	record("T7: Phase2 ExitCover iniciado", true)

	-- Esperar que el timer de exit complete
	local exitTime = 0
	while exitTime < Constants.COVER_EXIT_DURATION + 0.5 do
		local dt = RunService.Heartbeat:Wait()
		exitTime += dt
		coverHandler:Update(dt, nil)
		if sm:GetCurrentState() == "Idle" then
			break
		end
	end

	-- Si el timer interno hizo TransitionTo("Idle") pero STATE_MIN_DURATION lo bloqueo
	-- intentamos manualmente
	waitMinDuration(sm)
	if sm:GetCurrentState() ~= "Idle" then
		sm:TransitionTo("Idle")
	end

	log("   Estado tras exit:", sm:GetCurrentState())
	record("T7: Phase2 volvio a Idle", sm:GetCurrentState() == "Idle", "state=" .. sm:GetCurrentState())

	-- Verificar que cover state se limpio
	record("T7: Phase2 normal limpiada", coverHandler:GetNormal() == nil)
	record("T7: Phase2 IsSnapping false", not coverHandler:IsSnapping())

	-- FASE 3: Re-entrar en cover
	log("   Fase 3: Re-entrando en cover...")
	task.wait(0.3) -- Dar tiempo al humanoid a estabilizarse

	-- Tras salir de cover, el jugador mira AWAY de la pared (lookVec ≈ wallNormal).
	-- Re-orientar hacia la pared para que scanCover (que usa LookVector) la detecte.
	local toWall = (wall.Position - hrp.Position)
	local dirToWall = Vector3.new(toWall.X, 0, toWall.Z)
	if dirToWall.Magnitude > 0.01 then
		dirToWall = dirToWall.Unit
		hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + dirToWall)
	end
	task.wait(0.1)

	local hitPos2, wallNormal2, coverPart2 = scanCover(hrp, wall)
	if not hitPos2 or not wallNormal2 or not coverPart2 then
		wall:Destroy()
		record("T7: Phase3 cover re-detectada", false)
		return false
	end
	record("T7: Phase3 cover re-detectada", true)

	local transOk2 = transitionToCoverEntering(sm)
	if not transOk2 then
		wall:Destroy()
		record("T7: Phase3 transicion re-entry", false, "Desde " .. sm:GetCurrentState())
		return false
	end

	coverHandler:HandleAction("EnterCover", {
		coverNormal = wallNormal2,
		coverPos = hitPos2,
		coverInstance = coverPart2,
		coverType = classifyCover(coverPart2),
	})
	record("T7: Phase3 re-entering iniciado", coverHandler:IsSnapping())
	humanoid:Move(Vector3.zero, false)

	local result3, _ = runEnteringLoop(coverHandler, function()
		return RunService.Heartbeat:Wait()
	end, 3)

	if result3 == "complete" then
		waitMinDuration(sm)
		sm:TransitionTo("CoverIdle")
	end

	log("   Resultado re-entry:", result3)
	record("T7: Phase3 Re-entering completa", result3 == "complete", "result=" .. result3)
	record("T7: Ciclo completo exitoso", result1 == "complete" and result3 == "complete")

	wall:Destroy()
	return result1 == "complete" and result3 == "complete"
end

------------------------------------------------------------------------
-- RUNNER
------------------------------------------------------------------------

task.wait(2)

logSeparator("COVER ENTERING TEST SUITE (INTENSIVO)")
log("Constantes clave:")
log("   COVER_SNAP_SPEED:", Constants.COVER_SNAP_SPEED)
log("   COVER_OFFSET:", Constants.COVER_OFFSET)
log("   COVER_CORNER_MARGIN:", Constants.COVER_CORNER_MARGIN)
log("   COVER_ROTATION_BLEND:", Constants.COVER_ROTATION_BLEND)
log("   COVER_COMPLETION_XZ:", Constants.COVER_COMPLETION_XZ)
log("   COVER_STUCK_TIMEOUT:", Constants.COVER_STUCK_TIMEOUT)
log("   COVER_ENTRY_CANCEL_DOT:", Constants.COVER_ENTRY_CANCEL_DOT)
log("   STATE_MIN_DURATION:", Constants.STATE_MIN_DURATION)

test1_SimpleEnterCover()
task.wait(0.5)

test2_RunningEnterCover()
task.wait(0.5)

test3_CancelByMovement()
task.wait(0.5)

test4_StuckTimeout()
task.wait(0.5)

test5_CornerClamp()
task.wait(0.5)

test6_CoverChaining()
task.wait(0.5)

test7_ExitAndReenter()

------------------------------------------------------------------------
-- RESUMEN FINAL
------------------------------------------------------------------------

logSeparator("RESUMEN FINAL")
local passed = 0
local failed = 0
for _, r in testResults do
	if r.passed then
		passed += 1
		log("   PASS:", r.name)
	else
		failed += 1
		log("   FAIL:", r.name, r.reason or "")
	end
end
log("")
log(string.format("   Total: %d | Passed: %d | Failed: %d", passed + failed, passed, failed))
print(string.rep("=", 60))
-- FIN DEL TEST SUITE]]