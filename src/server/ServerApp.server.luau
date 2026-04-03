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
local ServerNetwork = require(script.Parent.Network.ServerNetwork)
local CombatService = require(script.Parent.Combat.CombatService)
local WeaponService = require(script.Parent.Combat.WeaponService)

------------------------------------------------------------------------
-- BOOTSTRAP
------------------------------------------------------------------------

-- Fase Init
CharacterService:Init()
ServerNetwork:Init()
CombatService:Init()
WeaponService:Init()

-- Fase Start
CharacterService:Start()
ServerNetwork:Start()
CombatService:Start()
WeaponService:Start()

------------------------------------------------------------------------
-- STARTUP LOG
------------------------------------------------------------------------
if Constants.DEBUG_MODE then
	print(
		"[GoW Server] ═══════════════════════════════════════"
	)
	print("[GoW Server] Gears of War — Server iniciado")
	print(`[GoW Server] Gravity: {workspace.Gravity}`)
	print("[GoW Server] Servicios: Character, Network, Combat, Weapon")
	print(
		"[GoW Server] ═══════════════════════════════════════"
	)
end
