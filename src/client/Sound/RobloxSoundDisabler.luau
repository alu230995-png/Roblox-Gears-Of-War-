--[[
	RobloxSoundDisabler.luau
	═══════════════════════════════════════════════════════════════
	Desactiva TODOS los sonidos default de Roblox para reemplazarlos
	con el sistema de sonido propio del proyecto.
	═══════════════════════════════════════════════════════════════
	
	Sonidos que se desactivan:
	  - Character sounds (pasos, salto, landing, swimming, climbing, dying, etc.)
	    → Roblox los inyecta vía "RbxCharacterSounds" LocalScript en cada personaje
	  - Sonidos de herramientas default
	  - SoundService ambient sounds
	
	Método:
	  1. Eliminar el script "RbxCharacterSounds" del StarterPlayerScripts
	  2. Limpiar cualquier Sound preexistente en HumanoidRootPart al spawn
	  3. Silenciar SoundService.AmbientReverb y RespectFilteringEnabled
	  4. Observar nuevos personajes para limpiarlos también
]]

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local StarterPlayer = game:GetService("StarterPlayer")

local RobloxSoundDisabler = {}

------------------------------------------------------------------------
-- Nombres de los sonidos default de Roblox en HumanoidRootPart
------------------------------------------------------------------------

local ROBLOX_SOUND_NAMES = {
	"Running",
	"Climbing",
	"Died",
	"FreeFalling",
	"GettingUp",
	"Jumping",
	"Landing",
	"Splash",
	"Swimming",
}

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Llama una vez en Init. Desactiva todos los sonidos default de Roblox.
function RobloxSoundDisabler.Disable()
	-- 1. Eliminar RbxCharacterSounds del StarterPlayerScripts
	RobloxSoundDisabler._removeStarterSoundScript()

	-- 2. Configurar SoundService para nuestro sistema
	SoundService.AmbientReverb = Enum.ReverbType.NoReverb
	SoundService.DistanceFactor = 1
	SoundService.RespectFilteringEnabled = true

	-- 3. Limpiar personajes existentes
	local localPlayer = Players.LocalPlayer
	if localPlayer then
		if localPlayer.Character then
			RobloxSoundDisabler._cleanCharacterSounds(localPlayer.Character)
		end

		-- 4. Limpiar futuros personajes
		localPlayer.CharacterAdded:Connect(function(character)
			-- Esperar a que Roblox inserte sus sonidos, luego limpiar
			task.defer(function()
				RobloxSoundDisabler._cleanCharacterSounds(character)
			end)
		end)
	end
end

------------------------------------------------------------------------
-- INTERNAL
------------------------------------------------------------------------

--- Elimina el script RbxCharacterSounds del StarterPlayerScripts.
--- Este script es el que inyecta los sonidos de pasos, salto, etc.
function RobloxSoundDisabler._removeStarterSoundScript()
	local starterScripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
	if not starterScripts then
		return
	end

	local soundScript = starterScripts:FindFirstChild("RbxCharacterSounds")
	if soundScript then
		soundScript:Destroy()
	end
end

--- Limpia todos los sonidos default de Roblox en un personaje.
--- Los elimina de HumanoidRootPart y del Head.
function RobloxSoundDisabler._cleanCharacterSounds(character: Model)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart then
		-- Eliminar sonidos por nombre conocido
		for _, soundName in ROBLOX_SOUND_NAMES do
			local sound = rootPart:FindFirstChild(soundName)
			if sound and sound:IsA("Sound") then
				sound:Destroy()
			end
		end

		-- Eliminar CUALQUIER Sound residual en HumanoidRootPart
		for _, child in rootPart:GetChildren() do
			if child:IsA("Sound") then
				child.Volume = 0
				child.PlayOnRemove = false
				child:Destroy()
			end
		end
	end

	-- También limpiar Head (algunos sonidos como "Died" pueden estar ahí)
	local head = character:FindFirstChild("Head")
	if head then
		for _, child in head:GetChildren() do
			if child:IsA("Sound") then
				child.Volume = 0
				child.PlayOnRemove = false
				child:Destroy()
			end
		end
	end

	-- Observar adiciones futuras de sonidos al rootPart (Roblox a veces los re-inserta)
	if rootPart then
		rootPart.ChildAdded:Connect(function(child)
			if child:IsA("Sound") then
				-- Verificar si es un sonido de Roblox (no nuestro)
				local isRobloxSound = false
				for _, name in ROBLOX_SOUND_NAMES do
					if child.Name == name then
						isRobloxSound = true
						break
					end
				end

				if isRobloxSound then
					child.Volume = 0
					child.PlayOnRemove = false
					child:Destroy()
				end
			end
		end)
	end
end

return RobloxSoundDisabler
