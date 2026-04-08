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
		"rbxassetid://86515006936488",
		"rbxassetid://100334711376180",
		"rbxassetid://95939420328974",
		"rbxassetid://79307768470377",
		"rbxassetid://126380801612911",
		"rbxassetid://133621117309123",
	},
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.4,
	MaxDistance = 40,
	PitchVariation = 0.2,
}

SoundConfig.VFX_Footstep_Concrete = {
	Ids = { "rbxassetid://92257857206687", "rbxassetid://92257857206688", "rbxassetid://92257857206689" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.5,
	MaxDistance = 60,
	PitchVariation = 0.08,
}

SoundConfig.VFX_Footstep_Metal = {
	Ids = { "rbxassetid://92257857206690", "rbxassetid://92257857206691" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.6,
	MaxDistance = 70,
	PitchVariation = 0.1,
}

SoundConfig.VFX_RoadieRun_Breath = {
	Ids = {
		"rbxassetid://86515006936488",
		"rbxassetid://100334711376180",
		"rbxassetid://95939420328974",
		"rbxassetid://79307768470377",
		"rbxassetid://126380801612911",
		"rbxassetid://133621117309123",
	},
	Random = true,
	Looped = false,
	Scope = "Player",
	Group = "VFX",
	Volume = 0.3,
	PitchVariation = 0.05,
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
	Ids = { "rbxassetid://92257857206686", "rbxassetid://92257857206687" },
	Random = true,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.6,
	MaxDistance = 35,
}

SoundConfig.VFX_Evade_Roll = {
	Ids = { "rbxassetid://0", "rbxassetid://0" },
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
-- VFX — Sonidos de estado que faltaban (placeholders)
------------------------------------------------------------------------

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
	Ids = { "rbxassetid://0" },
	Random = false,
	Looped = false,
	Scope = "Global",
	Group = "VFX",
	Volume = 0.8,
	MaxDistance = 50,
}

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
