--[[
	Helpers.luau
	═══════════════════════════════════════════════════════════════
	Funciones puras reutilizadas por múltiples tablas de reglas.
	Sin estado propio — todas reciben (resolver, ctx) o (intents).
	
	Incluye el scanner de Cover Swap (escaneo pasivo + gatillo manual)
	usado por CoverIdle y CoverWalking rules.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local Helpers = {}

------------------------------------------------------------------------
-- MOVEMENT
------------------------------------------------------------------------

--- Detecta si hay movimiento en los intents continuos.
function Helpers.hasMovementIntent(intents): boolean
	return intents:HasIntent("WantsMoveForward")
		or intents:HasIntent("WantsMoveBackward")
		or intents:HasIntent("WantsMoveLeft")
		or intents:HasIntent("WantsMoveRight")
end

------------------------------------------------------------------------
-- EVADE COOLDOWN
------------------------------------------------------------------------

--- Verifica que el cooldown del evade se haya cumplido.
function Helpers.isEvadeCooldownMet(resolver): boolean
	return (os.clock() - resolver._evadeStartTime) >= (Constants.EVADE_DURATION + Constants.EVADE_COOLDOWN)
end

------------------------------------------------------------------------
-- COVER SWAP SCANNER
------------------------------------------------------------------------
-- Arquitectura de 2 fases:
--   Fase A (Escaneo pasivo): Mientras el jugador está en esquina y mantiene
--     input lateral hacia el vacío, el sistema lanza el rayo de detección
--     frame a frame. No desplaza al jugador; solo reporta si hay cover válida.
--   Fase B (Gatillo manual): Al pulsar el botón de acción (Space tap /
--     WantsCover), el sistema evalúa:
--       - Si hay escaneo positivo → Cover Swap.
--       - Si no hay cover válida → se ignora (protección contra salto suicida).
------------------------------------------------------------------------

--- Convierte un Vector2 de input (WASD crudo) a dirección world-space via cámara.
--- @return Vector3? — dirección horizontal unitaria, nil si inválida
local function _computeMoveDirWorld(moveDir2D: Vector2): Vector3?
	if not moveDir2D or moveDir2D.Magnitude < Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		return nil
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local camCF = camera.CFrame
	local camRight = Vector3.new(camCF.RightVector.X, 0, camCF.RightVector.Z)
	local camForward = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
	if camRight.Magnitude > Constants.ZERO_MAGNITUDE then
		camRight = camRight.Unit
	end
	if camForward.Magnitude > Constants.ZERO_MAGNITUDE then
		camForward = camForward.Unit
	end

	local worldDir = camRight * moveDir2D.X + camForward * moveDir2D.Y
	if worldDir.Magnitude < Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		return nil
	end
	return worldDir.Unit
end

--- Fase A: Escaneo pasivo — se ejecuta cada frame cuando el jugador está
--- en esquina y tiene input lateral hacia el vacío.
--- @return table? swapData — { newPart, newNormal, hitPosition, moveDir } o nil
function Helpers.scanCoverSwap(resolver, ctx): any?
	local coverHandler = ctx.CoverHandler
	if not coverHandler or not ctx.EnvSensor then
		return nil
	end

	local coverNormal = coverHandler:GetNormal()
	local wallRight = coverHandler:GetWallRight()
	if not coverNormal or not wallRight then
		return nil
	end

	local moveDirWorld = _computeMoveDirWorld(ctx.Env.MoveDirection)
	if not moveDirWorld then
		return nil
	end

	local movementScale = moveDirWorld:Dot(wallRight)
	if math.abs(movementScale) < Constants.LATERAL_TRIGGER_THRESHOLD then
		return nil
	end

	-- Usar flags con histéresis de CornerCover (via CoverMain) en vez de los flags
	-- crudos del EnvironmentSensor. Esto garantiza que el scan de swap y el bloqueo
	-- de movimiento vean el MISMO estado de esquina, eliminando el flicker que
	-- causaba que el swap no se detectara al presionar hacia el vacío.
	local atCorner = (movementScale > 0 and coverHandler:IsAtCornerRight())
		or (movementScale < 0 and coverHandler:IsAtCornerLeft())

	if Constants.DEBUG_MODE then
		local now = os.clock()
		if now - resolver._swapDebugLastPrint > 0.3 then
			resolver._swapDebugLastPrint = now
			print(
				string.format(
					"[CoverSwap] Escaneo pasivo: scale=%.2f | esquina=%s (izq=%s, der=%s)",
					movementScale,
					tostring(atCorner),
					tostring(coverHandler:IsAtCornerLeft()),
					tostring(coverHandler:IsAtCornerRight())
				)
			)
		end
	end

	if not atCorner then
		return nil
	end

	-- Obtener HRP via EnvSensor cache (evita FindFirstChild redundante)
	local hrp = nil :: BasePart?
	local character = Players.LocalPlayer.Character
	if character then
		hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	if not hrp then
		return nil
	end

	local moveDir = if movementScale > 0 then 1 else -1
	local coverInstance = coverHandler:GetCoverInstance()
	if not coverInstance then
		return nil
	end

	local newPart, newNormal, hitPos =
		ctx.EnvSensor:CheckSwapCover(hrp, coverNormal, wallRight, moveDir, coverInstance, moveDirWorld)

	if newPart and newNormal and hitPos then
		if Constants.DEBUG_MODE then
			print(
				string.format(
					"[CoverSwap] Escaneo POSITIVO — newPart=%s | hitPos=(%.1f,%.1f,%.1f) | dir=%s",
					newPart.Name,
					hitPos.X,
					hitPos.Y,
					hitPos.Z,
					if moveDir > 0 then "→" else "←"
				)
			)
		end
		return {
			newPart = newPart,
			newNormal = newNormal,
			hitPosition = hitPos,
			moveDir = moveDir,
		}
	end

	return nil
end

--- Fase B: Check completo — escaneo pasivo + gatillo de botón (WantsCover tap).
--- Si el escaneo reporta cover válida Y el jugador presionó el botón → true.
--- Si no hay cover o no hay botón → false (protección contra salto suicida).
function Helpers.checkCoverSwap(resolver, ctx): boolean
	local scanData = Helpers.scanCoverSwap(resolver, ctx)
	if not scanData then
		return false
	end

	if not ctx.Buffer:HasIntent("WantsCover") then
		if Constants.DEBUG_MODE then
			local now = os.clock()
			if now - resolver._swapDebugLastPrint > 0.3 then
				resolver._swapDebugLastPrint = now
				print("[CoverSwap] Escaneo POSITIVO pero NO hay WantsCover — esperando botón…")
			end
		end
		return false
	end

	if Constants.DEBUG_MODE then
		print("[CoverSwap] GATILLO ACTIVADO — Escaneo + WantsCover → ejecutando Cover Swap!")
	end

	ctx._swapData = scanData
	return true
end

------------------------------------------------------------------------
-- CORNER EXIT HELPERS
------------------------------------------------------------------------

--- Retorna el valor absoluto del producto escalar entre la dirección de input
--- del jugador (world-space) y el vector lateral de la cover (wallRight).
--- 1.0 = movimiento puramente lateral; 0.0 = movimiento perpendicular a la pared.
--- Retorna 0 si no hay input válido o cover data.
--- @param ctx table — ResolverContext
--- @return number — [0, 1]
function Helpers.computeLateralScale(ctx): number
	local coverHandler = ctx.CoverHandler
	if not coverHandler then
		return 0
	end
	local wallRight = coverHandler:GetWallRight()
	if not wallRight then
		return 0
	end
	local moveDirWorld = _computeMoveDirWorld(ctx.Env.MoveDirection)
	if not moveDirWorld then
		return 0
	end
	print(math.abs(moveDirWorld:Dot(wallRight)))
	return math.abs(moveDirWorld:Dot(wallRight))
end

------------------------------------------------------------------------
-- VAULT HELPERS
------------------------------------------------------------------------

--- Pre-valida el safety check del vault desde la regla del ActionResolver.
--- Si es seguro, almacena el resultado en ctx._vaultData para VaultHandler.
--- Al hacerlo aquí (en el check de la regla) la transición de estado ocurre
--- SOLO si el vault es viable — evita el glitch de Vaulting+revert.
--- @param ctx table — ResolverContext
--- @param coverNormal Vector3 — normal de la cover a saltar
--- @param coverInstance BasePart — la pieza de cover
--- @return boolean isSafe
function Helpers.preCheckVault(ctx, coverNormal: Vector3, coverInstance: BasePart): boolean
	if not coverNormal or not coverInstance then
		return false
	end
	local forwardDir = -Vector3.new(coverNormal.X, 0, coverNormal.Z)
	if forwardDir.Magnitude < Constants.ZERO_MAGNITUDE then
		return false
	end
	forwardDir = forwardDir.Unit
	local character = Players.LocalPlayer.Character
	if not character then
		return false
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return false
	end
	local isSafe, landingPos, landingType =
		ctx.EnvSensor:CheckVaultSafety(hrp.Position, forwardDir, character, coverInstance)
	if not isSafe then
		return false
	end
	ctx._vaultData = { landingPos = landingPos, landingType = landingType }
	return true
end

--- Verifica que el humanoid se mueve hacia la cover (dot product contra -coverNormal).
--- Usa un margen de error para permitir ángulos no perfectamente perpendiculares.
--- @param ctx table — ResolverContext
--- @param handlerNormal Vector3? — normal de la cover desde CoverHandler (fiable en cover states)
function Helpers.isMovingIntoCover(ctx, handlerNormal: Vector3?): boolean
	-- Priorizar la normal del CoverHandler (la cover real en la que estamos)
	-- sobre ctx.Env.CoverNormal (que viene de _searchCover y puede ser otra pared).
	local coverNormal = handlerNormal or ctx.Env.CoverNormal
	if not coverNormal then
		return false
	end

	local character = Players.LocalPlayer.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.MoveDirection.Magnitude < Constants.MOVE_DIRECTION_THRESHOLD then
		return false
	end

	local moveDir3D = humanoid.MoveDirection
	-- Calcular dot sin allocation: intoCover = -coverNormal (aplanado, Y=0)
	-- dot(moveDir, intoCover) = -(moveDir.X * n.X + moveDir.Z * n.Z) / magnitude
	local nX, nZ = coverNormal.X, coverNormal.Z
	local nMag = math.sqrt(nX * nX + nZ * nZ)
	if nMag < Constants.ZERO_MAGNITUDE then
		return false
	end
	local dotResult = -(moveDir3D.X * nX + moveDir3D.Z * nZ) / nMag
	return dotResult > Constants.VAULT_FORWARD_DOT_THRESHOLD
end

return Helpers
