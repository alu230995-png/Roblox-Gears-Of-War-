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

	local character = Players.LocalPlayer.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChild("Humanoid") :: Humanoid?
	if not humanoid or humanoid.MoveDirection.Magnitude < Constants.MOVE_DIRECTION_THRESHOLD_LOW then
		return nil
	end

	local movementScale = humanoid.MoveDirection:Dot(wallRight)
	if math.abs(movementScale) < Constants.LATERAL_TRIGGER_THRESHOLD then
		return nil
	end

	local env = ctx.Env
	local atCorner = (movementScale > 0 and env.IsAtCornerRight) or (movementScale < 0 and env.IsAtCornerLeft)

	if Constants.DEBUG_MODE then
		local now = os.clock()
		if now - resolver._swapDebugLastPrint > 0.3 then
			resolver._swapDebugLastPrint = now
			print(
				string.format(
					"[CoverSwap] Escaneo pasivo: scale=%.2f | esquina=%s (izq=%s, der=%s)",
					movementScale,
					tostring(atCorner),
					tostring(env.IsAtCornerLeft),
					tostring(env.IsAtCornerRight)
				)
			)
		end
	end

	if not atCorner then
		return nil
	end

	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil
	end

	local moveDir = if movementScale > 0 then 1 else -1
	local coverInstance = coverHandler:GetCoverInstance()
	if not coverInstance then
		return nil
	end

	local newPart, newNormal, hitPos =
		ctx.EnvSensor:CheckSwapCover(hrp, coverNormal, wallRight, moveDir, coverInstance, humanoid.MoveDirection)

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

return Helpers
