--[[
	CharacterService.luau
	═══════════════════════════════════════════════════════════════
	Servicio autoritativo de personaje en el servidor.
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades:
	- Configurar física GoW al spawn (gravedad, WalkSpeed, JumpPower, fricción)
	- Manejar spawn/respawn de personajes
	- Asegurar configuración autoritativa del Humanoid
	
	Delegación: Usa PhysicsConfig para la configuración concreta.
	
	Valores de referencia:
	- GRAVITY = 220 (default Roblox = 196.2, más alto = más peso)
	- WALK_SPEED = 12 (soldado con 40kg de equipo)
	- JUMP_POWER = 0 (sin salto, mantle lo reemplaza)
	- MAX_HEALTH = 600 (health pool grande como buffer de cobertura)
]]

local PhysicsConfig = require(script.Parent.Parent.Utils.PhysicsConfig)

local CharacterService = {}

function CharacterService:Init()
	-- Sin side-effects
end

function CharacterService:Start()
	-- Inicializar física GoW (gravedad, humanoid config al spawn)
	PhysicsConfig.Initialize()
end

function CharacterService:Destroy()
	-- Sin conexiones propias que limpiar
	-- (PhysicsConfig.Initialize crea conexiones permanentes en el servidor)
end

return CharacterService
