--[[
	PhysicsConfig.luau
	Configuración de física del servidor para emular el peso de Gears of War.
	
	Responsabilidades:
	- Ajustar Workspace.Gravity
	- Configurar Humanoid al spawn (WalkSpeed, JumpPower, etc.)
	- Aplicar PhysicalProperties al HumanoidRootPart para fricción correcta
	
	IMPORTANTE: Esta lógica es AUTORITATIVA del servidor.
	El cliente NO debe modificar estos valores directamente.
]]

local Players = game:GetService("Players")

-- No usar require relativo aquí — en Rojo, shared está en ReplicatedStorage
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local PhysicsConfig = {}

--- Aplica la configuración de gravedad al workspace.
--- Llamar una vez al iniciar el servidor.
function PhysicsConfig.Initialize()
	-- Gravedad más alta que default (196.2) para sensación de peso
	workspace.Gravity = Constants.GRAVITY

	-- Escuchar nuevos jugadores para configurar su Humanoid
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character)
			PhysicsConfig.ConfigureCharacter(character)
		end)

		-- Si ya tiene personaje (rejoin)
		if player.Character then
			PhysicsConfig.ConfigureCharacter(player.Character)
		end
	end)
end

--- Configura el Humanoid y HumanoidRootPart de un personaje.
--- @param character Model
function PhysicsConfig.ConfigureCharacter(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local rootPart = character:WaitForChild("HumanoidRootPart") :: BasePart

	-- Velocidad base: GoW walk es lento y pesado
	humanoid.WalkSpeed = Constants.WALK_SPEED

	-- Deshabilitar salto — en GoW el salto no existe, se usa mantle
	humanoid.JumpPower = Constants.JUMP_POWER
	humanoid.JumpHeight = 0
	humanoid.UseJumpPower = true

	-- Aplicar PhysicalProperties al HumanoidRootPart
	-- Roblox default es MUY resbaladizo — necesitamos alta fricción
	rootPart.CustomPhysicalProperties = PhysicalProperties.new(
		Constants.GROUND_DENSITY, -- Density
		Constants.GROUND_FRICTION, -- Friction
		Constants.GROUND_ELASTICITY, -- Elasticity
		Constants.GROUND_FRICTION_WEIGHT, -- FrictionWeight
		0 -- ElasticityWeight
	)

	-- Auto-rotate off — lo controlaremos manualmente para cover y aim
	humanoid.AutoRotate = false
end

--- Ajusta la WalkSpeed del Humanoid según el estado actual.
--- Llamado desde el servidor cuando el estado cambia.
function PhysicsConfig.SetMovementForState(humanoid: Humanoid, stateName: string)
	if stateName == "Idle" then
		humanoid.WalkSpeed = 0
	elseif stateName == "Walking" then
		humanoid.WalkSpeed = Constants.WALK_SPEED
	elseif stateName == "RoadieRun" then
		humanoid.WalkSpeed = Constants.ROADIE_RUN_SPEED
	elseif stateName == "CoverSlide" then
		humanoid.WalkSpeed = Constants.COVER_SLIDE_SPEED
	elseif stateName == "Evading" then
		humanoid.WalkSpeed = Constants.EVADE_SPEED
	elseif stateName == "CoverIdle" then
		humanoid.WalkSpeed = Constants.WALK_SPEED * 0.5 -- Movimiento lateral reducido en cover
	elseif stateName == "CoverAim" or stateName == "CoverBlindFire" then
		humanoid.WalkSpeed = 0
	elseif stateName == "CoverAimHigh" or stateName == "CoverAimLow" or stateName == "CoverPeek" then
		humanoid.WalkSpeed = 0
	elseif stateName == "Mantling" then
		humanoid.WalkSpeed = 0
	elseif stateName == "DBNO" then
		humanoid.WalkSpeed = Constants.WALK_SPEED * 0.2 -- Arrastrarse
	elseif stateName == "Executing" then
		humanoid.WalkSpeed = 0
	elseif stateName == "Aiming" then
		humanoid.WalkSpeed = Constants.WALK_SPEED * 0.6 -- Movimiento reducido al apuntar
	elseif stateName == "Firing" then
		humanoid.WalkSpeed = Constants.WALK_SPEED * 0.5 -- Aún más lento disparando
	elseif stateName == "Reloading" or stateName == "ActiveReloading" then
		humanoid.WalkSpeed = Constants.WALK_SPEED * 0.8
	end
end

return PhysicsConfig
