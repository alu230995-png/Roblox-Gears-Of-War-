--[[
	ServerApp.server.luau
	═══════════════════════════════════════════════════════════════
	ENTRY POINT DEL SERVIDOR — Solo bootstrapping
	═══════════════════════════════════════════════════════════════
	
	Responsabilidades:
	  1. Inicializar servicios del servidor
	  2. Configurar física GoW (gravedad, humanoid at spawn)
	  3. Preparar handlers de red (stubs para Fase 6)
	
	REGLA 05: El servidor es AUTORITATIVO.
	Toda lógica que toca HP, ammo, kill, inventory → servidor.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

------------------------------------------------------------------------
-- SERVER MODULES
------------------------------------------------------------------------
local CharacterService = require(script.Parent.Character.CharacterService)
local CombatService = require(script.Parent.Combat.CombatService)
local DBNOService = require(script.Parent.Combat.DBNOService)
local WeaponServer = require(script.Parent.Weapons.WeaponServer)
local SoundService = require(script.Parent.Sound.SoundService)
local RespawnService = require(script.Parent.Respawn.RespawnService)

------------------------------------------------------------------------
-- BOOTSTRAP
------------------------------------------------------------------------

-- Fase Init
CharacterService:Init()
CombatService:Init()
DBNOService:Init()
WeaponServer:Init()
SoundService:Init()
RespawnService:Init()

-- Fase Start
CharacterService:Start()
CombatService:Start()
DBNOService:Start()
WeaponServer:Start()
SoundService:Start()
RespawnService:Start()

------------------------------------------------------------------------
-- STARTUP LOG
------------------------------------------------------------------------
if Constants.DEBUG_MODE then
	print(
		"[GoW Server] ═══════════════════════════════════════"
	)
	print("[GoW Server] Gears of War — Server iniciado")
	print(`[GoW Server] Gravity: {workspace.Gravity}`)
	print("[GoW Server] Servicios: Character, Combat, Weapons, Sound, Respawn")
	print(
		"[GoW Server] ═══════════════════════════════════════"
	)
end
