--[[
	SoundConfig.luau
	═══════════════════════════════════════════════════════════════
	Registro central de TODOS los sonidos del juego.
	═══════════════════════════════════════════════════════════════
	
	Cada entrada define:
	  - Ids: { string } — Lista de asset IDs ("rbxassetid://XXXXX")
	  - Random: boolean — true = selección aleatoria, false = secuencial
	  - Looped: boolean — true = loop continuo (solo permite 1 Id)
	  - Scope: "Player" | "Global"
	      Player = sonido 2D directo al jugador (UI, feedback)
	      Global = sonido 3D posicional (requiere posición de origen)
	  - Group: "VFX" | "Ambient" | "Music" | "Server"
	  - Volume: number — Volumen base (0..1), default 1
	  - MaxDistance: number? — Solo para Scope="Global", distancia máxima de audición
	  - PitchVariation: number? — Variación aleatoria de pitch (±valor). 0 = sin variación
	
	Convención de nombres:
	  GRUPO_CATEGORIA_VARIANTE
	  Ejemplo: VFX_Footstep_Concrete, Music_Combat_01
	
	NOTA: Reemplaza los IDs placeholder ("rbxassetid://0") con tus assets reales.
]]

local SoundConfig = {}

------------------------------------------------------------------------
-- VFX — Efectos de sonido de gameplay
------------------------------------------------------------------------

SoundConfig.VFX_Footstep_Default = {
	Ids = {
		"rbxassetid://113824261411922",
		"rbxassetid://96838481971398",
		"rbxassetid://74613570357402",
		"rbxassetid://115467805684506",
		"rbxassetid://139667774868914",
	},
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.4,
	MaxDistance = 40,
	PitchVariation = 0.2,
}

------------------------------------------------------------------------
-- MATERIAL → FOOTSTEP SOUND MAP
-- Tabla que mapea Enum.Material de Roblox al nombre del sonido de pasos.
-- Si el material no está en la tabla, usa VFX_Footstep_Default como fallback.
------------------------------------------------------------------------

SoundConfig.FootstepMaterialMap = {
	-- Concreto / Piedra
	[Enum.Material.Concrete] = "VFX_Footstep_Concrete",
	[Enum.Material.Brick] = "VFX_Footstep_Concrete",
	[Enum.Material.Cobblestone] = "VFX_Footstep_Concrete",
	[Enum.Material.Slate] = "VFX_Footstep_Concrete",
	[Enum.Material.Granite] = "VFX_Footstep_Concrete",
	[Enum.Material.Marble] = "VFX_Footstep_Concrete",
	[Enum.Material.Basalt] = "VFX_Footstep_Concrete",
	[Enum.Material.Pavement] = "VFX_Footstep_Concrete",
	[Enum.Material.Asphalt] = "VFX_Footstep_Concrete",
	[Enum.Material.Rock] = "VFX_Footstep_Concrete",
	[Enum.Material.Sandstone] = "VFX_Footstep_Concrete",

	-- Metal
	[Enum.Material.Metal] = "VFX_Footstep_Metal",
	[Enum.Material.CorrodedMetal] = "VFX_Footstep_Metal",
	[Enum.Material.DiamondPlate] = "VFX_Footstep_Metal",

	-- Plástico / Genérico (suelos de Roblox por defecto)
	[Enum.Material.Plastic] = "VFX_Footstep_Default",
	[Enum.Material.SmoothPlastic] = "VFX_Footstep_Default",
	[Enum.Material.Neon] = "VFX_Footstep_Default",
	[Enum.Material.Glass] = "VFX_Footstep_Metal",

	-- Madera
	[Enum.Material.Wood] = "VFX_Footstep_Wood",
	[Enum.Material.WoodPlanks] = "VFX_Footstep_Wood",

	-- Terreno / Exterior
	[Enum.Material.Grass] = "VFX_Footstep_Default",
	[Enum.Material.LeafyGrass] = "VFX_Footstep_Default",
	[Enum.Material.Sand] = "VFX_Footstep_Default",
	[Enum.Material.Mud] = "VFX_Footstep_Default",
	[Enum.Material.Snow] = "VFX_Footstep_Default",
	[Enum.Material.Ice] = "VFX_Footstep_Default",
	[Enum.Material.Ground] = "VFX_Footstep_Default",
}

SoundConfig.VFX_Footstep_Concrete = {
	Ids = {
		"rbxassetid://80761632071414",
		"rbxassetid://76353333185990",
		"rbxassetid://78911742598635",
		"rbxassetid://74355740947839",
		"rbxassetid://76917027608612",
	},
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.5,
	MaxDistance = 60,
	PitchVariation = 0.08,
}

SoundConfig.VFX_Footstep_Wood = {
	Ids = {
		"rbxassetid://140525304232464",
		"rbxassetid://136048161800254",
		"rbxassetid://126265702355433",
		"rbxassetid://112726790019701",
		"rbxassetid://92923866257079",
	},
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.5,
	MaxDistance = 50,
	PitchVariation = 0.1,
}

SoundConfig.VFX_Footstep_Metal = {
	Ids = {
		"rbxassetid://140728903346385",
		"rbxassetid://122747308545707",
		"rbxassetid://106405856376224",
	},
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.6,
	MaxDistance = 70,
	PitchVariation = 0.1,
}

SoundConfig.VFX_RoadieRun_Breath = {
	Ids = { "rbxassetid://135925258529833" },
	Random = true,
	Looped = false,
	Scope = "Player",
	Group = "VFX",
	Volume = 0.3,
	PitchVariation = 0.5,
}

SoundConfig.VFX_CoverSlide = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.7,
	MaxDistance = 40,
}

SoundConfig.VFX_CoverEnter = {
	Ids = { "rbxassetid://85551641202362", "rbxassetid://80466288495322" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.3,
	MaxDistance = 35,
}

SoundConfig.VFX_CoverImpact = {
	Ids = { "rbxassetid://110891318354053", "rbxassetid://81870089611551", "rbxassetid://101811697795422" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.5,
	MaxDistance = 35,
	PitchVariation = 0.08,
}

SoundConfig.VFX_Evade_Roll = {
	Ids = { "rbxassetid://117181583797374" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.6,
	MaxDistance = 30,
}

SoundConfig.VFX_Mantle = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.6,
	MaxDistance = 30,
}

SoundConfig.VFX_Vault = {
	Ids = { "rbxassetid://120950121400483" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.55,
	MaxDistance = 35,
	PitchVariation = 0.04,
}

SoundConfig.VFX_Weapon_Lancer_Fire = {
	Ids = { "rbxassetid://0", "rbxassetid://0", "rbxassetid://0" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.8,
	MaxDistance = 120,
	PitchVariation = 0.05,
}

SoundConfig.VFX_Weapon_Gnasher_Fire = {
	Ids = { "rbxassetid://0", "rbxassetid://0" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.9,
	MaxDistance = 100,
	PitchVariation = 0.04,
}

SoundConfig.VFX_Weapon_Reload = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.5,
	MaxDistance = 25,
}

SoundConfig.VFX_Weapon_ActiveReload_Success = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "VFX",
	Volume = 0.7,
}

SoundConfig.VFX_Weapon_ActiveReload_Fail = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "VFX",
	Volume = 0.5,
}

SoundConfig.VFX_Weapon_Chainsaw_Loop = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = true,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.8,
	MaxDistance = 50,
}

SoundConfig.VFX_Impact_Bullet_Default = {
	Ids = { "rbxassetid://0", "rbxassetid://0", "rbxassetid://0" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.4,
	MaxDistance = 50,
	PitchVariation = 0.15,
}

SoundConfig.VFX_Hit_Flesh = {
	Ids = { "rbxassetid://0", "rbxassetid://0" },
	Random = true,
	Looped = false,
	Scope = "Player",
	Group = "VFX",
	Volume = 0.5,
}

SoundConfig.VFX_Hit_Marker = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "VFX",
	Volume = 0.3,
}

SoundConfig.VFX_DBNO_Down = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.7,
	MaxDistance = 40,
}

SoundConfig.VFX_Execution = {
	Ids = { "rbxassetid://0", "rbxassetid://0" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.8,
	MaxDistance = 35,
}

SoundConfig.VFX_Grenade_Throw = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.5,
	MaxDistance = 40,
}

SoundConfig.VFX_Grenade_Explosion = {
	Ids = { "rbxassetid://0", "rbxassetid://0" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 1.0,
	MaxDistance = 150,
}

------------------------------------------------------------------------
-- AMBIENT — Sonidos ambientales del entorno
------------------------------------------------------------------------

SoundConfig.Ambient_Wind_Loop = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = true,
	Scope = "Player",
	Group = "Ambient",
	Volume = 0.15,
}

SoundConfig.Ambient_Rain_Loop = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = true,
	Scope = "Player",
	Group = "Ambient",
	Volume = 0.2,
}

SoundConfig.Ambient_Debris_Random = {
	Ids = { "rbxassetid://0", "rbxassetid://0", "rbxassetid://0" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "Ambient",
	Volume = 0.3,
	MaxDistance = 80,
}

SoundConfig.Ambient_DistantBattle = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = true,
	Scope = "Player",
	Group = "Ambient",
	Volume = 0.1,
}

------------------------------------------------------------------------
-- MUSIC — Música del juego
------------------------------------------------------------------------

SoundConfig.Music_Menu = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = true,
	Scope = "Player",
	Group = "Music",
	Volume = 0.4,
}

SoundConfig.Music_Combat = {
	Ids = { "rbxassetid://0", "rbxassetid://0" },
	Random = true,
	Looped = true,
	Scope = "Player",
	Group = "Music",
	Volume = 0.3,
}

SoundConfig.Music_Victory = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "Music",
	Volume = 0.5,
}

SoundConfig.Music_Defeat = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "Music",
	Volume = 0.5,
}

------------------------------------------------------------------------
-- SERVER — Sonidos disparados por el servidor
------------------------------------------------------------------------

SoundConfig.Server_RoundStart = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "Server",
	Volume = 0.7,
}

SoundConfig.Server_RoundEnd_Warning = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "Server",
	Volume = 0.8,
}

SoundConfig.Server_Alarm_Loop = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = true,
	Scope = "Player",
	Group = "Server",
	Volume = 0.6,
}

SoundConfig.Server_Countdown_Tick = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "Server",
	Volume = 0.6,
}

SoundConfig.Server_LastManStanding = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "Server",
	Volume = 0.7,
}

SoundConfig.Server_TeamEliminated = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Player",
	Group = "Server",
	Volume = 0.8,
}

SoundConfig.Server_Announcement_Generic = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "Server",
	Volume = 0.9,
	MaxDistance = 200,
}

------------------------------------------------------------------------
-- VFX — Sonidos de estado adicionales
------------------------------------------------------------------------

SoundConfig.VFX_CoverExit = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.5,
	MaxDistance = 30,
}

SoundConfig.VFX_CoverSwap = {
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.5,
	MaxDistance = 30,
}

------------------------------------------------------------------------
-- FREEZE & EXPORT
------------------------------------------------------------------------

-- Freeze cada entrada individual para evitar mutación accidental
for _, entry in SoundConfig do
	if type(entry) == "table" then
		table.freeze(entry)
	end
end

table.freeze(SoundConfig)

return SoundConfig
