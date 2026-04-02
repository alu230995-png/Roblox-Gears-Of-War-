--[[
	ServerInit.server.luau
	Punto de entrada del servidor.
	Inicializa la configuración de física y prepara los sistemas del servidor.
]]

local PhysicsConfig = require(script.Parent.Utils.PhysicsConfig)

-- Inicializar física GoW (gravedad, humanoid config al spawn)
PhysicsConfig.Initialize()

print("[Server] Gears of War — Physics initialized")
print(`[Server] Gravity: {workspace.Gravity}`)
