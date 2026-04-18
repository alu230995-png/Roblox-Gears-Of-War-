--[[
	EffectsConfig.luau
	═══════════════════════════════════════════════════════════════
	Registro central de configuraciones de efectos visuales (VFX).
	═══════════════════════════════════════════════════════════════

	Estructura paralela a SoundConfig pero para partículas, trails,
	flashes y screen shakes. Cada arma tiene un perfil de efectos.

	Convención:
	  - Las claves de WEAPONS coinciden con WeaponConstants.WEAPONS.
	  - Colores usan Color3.fromRGB().
	  - Tiempos en segundos, distancias en studs.
	  - Path (opcional): string O tabla de strings con rutas a instancias
	    pre-hechas en el árbol de juego.
	      Path = "ReplicatedStorage.Particles.LancerMuzzle"     -- una sola
	      Path = { "ReplicatedStorage.Particles.Flash",          -- varias
	               "ReplicatedStorage.Particles.Smoke" }
	    Si Path ~= nil, se clona(n) y el resto de parámetros es IGNORADO.
	  - PathDelay (opcional, number): segundos de espera entre cada
	    entrada de Path cuando es tabla.
	      PathDelay = nil / 0  →  todos emiten al mismo tiempo
	      PathDelay = 0.1      →  secuencial, 0.1s entre cada uno

	Este módulo es de solo lectura (frozen).
]]

local EffectsConfig = {}

------------------------------------------------------------------------
-- WEAPONS — Perfil de VFX por arma
------------------------------------------------------------------------

EffectsConfig.WEAPONS = {

	Lancer = {
		MuzzleFlash = {
			Path = "ReplicatedStorage.Assets.Effects.Bullets.Lanzer.Explocion", -- string | {string} | nil. e.g. {"RS.Particles.Flash", "RS.Particles.Smoke"}
			PathDelay = nil, -- seconds between each Path entry (nil/0 = all at once)
			Duration = 0.05,
			Scale = 1.0,
			Color = Color3.fromRGB(255, 200, 80),
			LightRange = 8,
			LightBrightness = 2,
		},
		BulletTrail = {
			Path = {
				"ReplicatedStorage.Assets.Effects.Bullets.Lanzer.Beam1",
				"ReplicatedStorage.Assets.Effects.Bullets.Lanzer.Beam2",
			},
			ParticlePath = "ReplicatedStorage.Assets.Effects.Bullets.Lanzer.BulletGlow",
			SmokePath = "ReplicatedStorage.Assets.Effects.Bullets.Lanzer.Smoke",
			PathDelay = 0,
			Speed = 500,
		},
		ActiveReloadEffects = {
			MuzzleFlash = {
				Path = nil,
				PathDelay = nil,
				Duration = 0.06,
				Scale = 1.1,
				Color = Color3.fromRGB(70, 170, 255),
				LightRange = 10,
				LightBrightness = 3,
			},
			BulletTrail = {
				Path = {
					"ReplicatedStorage.Assets.Effects.Bullets.Lanzer.Beam1R",
					"ReplicatedStorage.Assets.Effects.Bullets.Lanzer.Beam2R",
				},
				ParticlePath = {
					"ReplicatedStorage.Assets.Effects.Bullets.Lanzer.BulletGlowR1",
					"ReplicatedStorage.Assets.Effects.Bullets.Lanzer.BulletGlowR2",
				},
				SmokePath = "ReplicatedStorage.Assets.Effects.Bullets.Lanzer.SmokeR",
				PathDelay = 0,
				Speed = 550,
			},
		},
		ShellEjection = {
			Path = nil,
			PathDelay = nil,
			Enabled = true,
			Velocity = 8,
			AngularVelocity = 12,
		},
		ScreenShake = {
			FireX = 0.008,
			FireY = 0.003,
		},
	},

	Gnasher = {
		MuzzleFlash = {
			Path = nil,
			PathDelay = nil,
			Duration = 0.08,
			Scale = 1.8,
			Color = Color3.fromRGB(255, 180, 50),
			LightRange = 12,
			LightBrightness = 3,
		},
		BulletTrail = {
			Path = nil,
			PathDelay = nil,
			Width = 0.08,
			Lifetime = 0.1,
			Color = Color3.fromRGB(255, 200, 80),
			FadeTime = 0.08,
			Speed = 80,
			TrailDelay = 0.08,
			HoldTime = 0.2,
			SmokeColor = Color3.fromRGB(210, 200, 180),
			SmokeWidth = 0.05,
		},
		ShellEjection = {
			Path = nil,
			PathDelay = nil,
			Enabled = true,
			Velocity = 6,
			AngularVelocity = 10,
		},
		ScreenShake = {
			FireX = 0.025,
			FireY = 0.015,
		},
	},

	Longshot = {
		MuzzleFlash = {
			Path = nil,
			PathDelay = nil,
			Duration = 0.06,
			Scale = 1.2,
			Color = Color3.fromRGB(200, 220, 255),
			LightRange = 10,
			LightBrightness = 3,
		},
		BulletTrail = {
			Path = nil,
			PathDelay = nil,
			Width = 0.04,
			Lifetime = 0.25,
			Color = Color3.fromRGB(200, 220, 255),
			FadeTime = 0.15,
			Speed = 150,
			TrailDelay = 0.25,
			HoldTime = 0.6,
			SmokeColor = Color3.fromRGB(180, 190, 210),
			SmokeWidth = 0.03,
		},
		ShellEjection = {
			Path = nil,
			PathDelay = nil,
			Enabled = true,
			Velocity = 10,
			AngularVelocity = 8,
		},
		ScreenShake = {
			FireX = 0.035,
			FireY = 0.02,
		},
	},

	TorqueBow = {
		MuzzleFlash = {
			Path = nil,
			PathDelay = nil,
			Duration = 0.04,
			Scale = 0.6,
			Color = Color3.fromRGB(100, 150, 255),
			LightRange = 6,
			LightBrightness = 2,
		},
		BulletTrail = {
			Path = nil,
			PathDelay = nil,
			Width = 0.1,
			Lifetime = 0.4,
			Color = Color3.fromRGB(100, 150, 255),
			FadeTime = 0.2,
			Speed = 100,
			TrailDelay = 0.2,
			HoldTime = 0.5,
			SmokeColor = Color3.fromRGB(120, 140, 200),
			SmokeWidth = 0.06,
		},
		ShellEjection = {
			Path = nil,
			PathDelay = nil,
			Enabled = false,
			Velocity = 0,
			AngularVelocity = 0,
		},
		ScreenShake = {
			FireX = 0.02,
			FireY = 0.01,
		},
	},

	HammerOfDawn = {
		MuzzleFlash = {
			Path = nil,
			PathDelay = nil,
			Duration = 0.1,
			Scale = 2.0,
			Color = Color3.fromRGB(255, 100, 50),
			LightRange = 20,
			LightBrightness = 5,
		},
		BulletTrail = {
			Path = nil,
			PathDelay = nil,
			Width = 0.3,
			Lifetime = 0.8,
			Color = Color3.fromRGB(255, 100, 50),
			FadeTime = 0.4,
			Speed = 60,
			TrailDelay = 0.3,
			HoldTime = 0.8,
			SmokeColor = Color3.fromRGB(255, 150, 80),
			SmokeWidth = 0.2,
		},
		ShellEjection = {
			Path = nil,
			PathDelay = nil,
			Enabled = false,
			Velocity = 0,
			AngularVelocity = 0,
		},
		ScreenShake = {
			FireX = 0.05,
			FireY = 0.03,
		},
	},

	Boomshot = {
		MuzzleFlash = {
			Path = nil,
			PathDelay = nil,
			Duration = 0.08,
			Scale = 2.0,
			Color = Color3.fromRGB(255, 160, 30),
			LightRange = 15,
			LightBrightness = 4,
		},
		BulletTrail = {
			Path = nil,
			PathDelay = nil,
			Width = 0.15,
			Lifetime = 0.3,
			Color = Color3.fromRGB(255, 160, 30),
			FadeTime = 0.15,
			Speed = 70,
			TrailDelay = 0.15,
			HoldTime = 0.4,
			SmokeColor = Color3.fromRGB(220, 180, 100),
			SmokeWidth = 0.1,
		},
		ShellEjection = {
			Path = nil,
			PathDelay = nil,
			Enabled = false,
			Velocity = 0,
			AngularVelocity = 0,
		},
		ScreenShake = {
			FireX = 0.04,
			FireY = 0.025,
		},
	},

	Snub = {
		MuzzleFlash = {
			Path = nil,
			PathDelay = nil,
			Duration = 0.04,
			Scale = 0.6,
			Color = Color3.fromRGB(255, 220, 120),
			LightRange = 5,
			LightBrightness = 1.5,
		},
		BulletTrail = {
			Path = nil,
			PathDelay = nil,
			Width = 0.04,
			Lifetime = 0.12,
			Color = Color3.fromRGB(255, 220, 120),
			FadeTime = 0.08,
			Speed = 110,
			TrailDelay = 0.1,
			HoldTime = 0.25,
			SmokeColor = Color3.fromRGB(200, 200, 190),
			SmokeWidth = 0.03,
		},
		ShellEjection = {
			Path = nil,
			PathDelay = nil,
			Enabled = true,
			Velocity = 7,
			AngularVelocity = 14,
		},
		ScreenShake = {
			FireX = 0.012,
			FireY = 0.006,
		},
	},
}

------------------------------------------------------------------------
-- IMPACTS — Partículas por tipo de superficie
------------------------------------------------------------------------

EffectsConfig.IMPACTS = {

	Default = {
		Path = nil,
		PathDelay = nil,
		ParticleCount = 6,
		Spread = 15,
		Lifetime = 0.6,
		Speed = 8,
		Color = Color3.fromRGB(180, 170, 150),
		DecalLifetime = 8.0,
	},

	Metal = {
		Path = nil,
		PathDelay = nil,
		ParticleCount = 8,
		Spread = 20,
		Lifetime = 0.4,
		Speed = 12,
		Color = Color3.fromRGB(255, 200, 80),
		DecalLifetime = 8.0,
	},

	Concrete = {
		Path = nil,
		PathDelay = nil,
		ParticleCount = 8,
		Spread = 18,
		Lifetime = 0.5,
		Speed = 10,
		Color = Color3.fromRGB(160, 155, 145),
		DecalLifetime = 8.0,
	},

	Wood = {
		Path = nil,
		PathDelay = nil,
		ParticleCount = 5,
		Spread = 12,
		Lifetime = 0.7,
		Speed = 6,
		Color = Color3.fromRGB(140, 100, 60),
		DecalLifetime = 8.0,
	},

	Flesh = {
		Path = "ReplicatedStorage.Assets.Effects.Blood.Gore",
		PathDelay = nil,
		ParticleCount = 8,
		Spread = 25,
		Lifetime = 0.8,
		Speed = 8,
		Color = Color3.fromRGB(180, 20, 20),
		DecalLifetime = 0,
	},
}

------------------------------------------------------------------------
-- DEATH — Efectos de muerte por tipo
------------------------------------------------------------------------

EffectsConfig.DEATH = {

	Standard = {
		BloodBurst = {
			Path = "ReplicatedStorage.Assets.Effects.Blood.Blood",
			PathDelay = nil,
			ParticleCount = 1,
			Spread = 30,
			Lifetime = 1.0,
			Speed = 6,
			Color = Color3.fromRGB(180, 20, 20),
		},
		ScreenShake = {
			X = 0.02,
			Y = 0.015,
		},
		Sound = "VFX_Death_Standard",
	},

	Headshot = {
		BloodBurst = {
			Path = "ReplicatedStorage.Assets.Effects.Blood.Blood",
			PathDelay = nil,
			ParticleCount = 1,
			Spread = 45,
			Lifetime = 1.2,
			Speed = 12,
			Color = Color3.fromRGB(200, 10, 10),
		},
		ScreenShake = {
			X = 0.04,
			Y = 0.03,
		},
		Sound = "VFX_Death_Headshot",
	},

	Dismember = {
		BloodBurst = {
			Path = "ReplicatedStorage.Assets.Effects.Blood.Blood",
			PathDelay = nil,
			ParticleCount = 1,
			Spread = 60,
			Lifetime = 1.5,
			Speed = 15,
			Color = Color3.fromRGB(200, 10, 10),
		},
		ScreenShake = {
			X = 0.06,
			Y = 0.04,
		},
		Sound = "VFX_Death_Dismember",
	},

	Bleedout = {
		BloodBurst = {
			Path = "ReplicatedStorage.Assets.Effects.Blood.Gore",
			PathDelay = nil,
			ParticleCount = 8,
			Spread = 15,
			Lifetime = 0.8,
			Speed = 3,
			Color = Color3.fromRGB(150, 20, 20),
		},
		ScreenShake = {
			X = 0.01,
			Y = 0.008,
		},
		Sound = "VFX_Death_Standard",
	},
}

------------------------------------------------------------------------
-- EXPLOSION — VFX de explosión (Boomshot, TorqueBow, HammerOfDawn)
------------------------------------------------------------------------

EffectsConfig.EXPLOSION = {

	FireBall = {
		Path = nil,
		PathDelay = nil,
		ParticleCount = 20,
		Lifetime = 0.6,
		Speed = 15,
		Color = Color3.fromRGB(255, 140, 20),
		SecondaryColor = Color3.fromRGB(200, 50, 10),
	},

	ShockwaveRing = {
		Path = nil,
		PathDelay = nil,
		Duration = 0.3,
		MaxScale = 1.5,
		Color = Color3.fromRGB(255, 200, 100),
		Transparency = 0.5,
	},

	Debris = {
		Path = nil,
		PathDelay = nil,
		Count = 8,
		Spread = 25,
		Lifetime = 1.5,
		Speed = 20,
		Color = Color3.fromRGB(100, 90, 80),
	},

	ScreenShake = {
		MaxX = 0.08,
		MaxY = 0.06,
		FalloffStart = 20,
		FalloffEnd = 80,
	},
}

------------------------------------------------------------------------
-- FREEZE
------------------------------------------------------------------------

-- Deep freeze todas las sub-tablas
for _, weaponEffects in EffectsConfig.WEAPONS do
	for _, subTable in weaponEffects do
		if type(subTable) == "table" then
			for _, nestedSubTable in subTable do
				if type(nestedSubTable) == "table" then
					table.freeze(nestedSubTable)
				end
			end
			table.freeze(subTable)
		end
	end
	table.freeze(weaponEffects)
end
table.freeze(EffectsConfig.WEAPONS)

for _, impactConfig in EffectsConfig.IMPACTS do
	table.freeze(impactConfig)
end
table.freeze(EffectsConfig.IMPACTS)

for _, deathConfig in EffectsConfig.DEATH do
	for _, subTable in deathConfig do
		if type(subTable) == "table" then
			table.freeze(subTable)
		end
	end
	table.freeze(deathConfig)
end
table.freeze(EffectsConfig.DEATH)

for _, explosionConfig in EffectsConfig.EXPLOSION do
	if type(explosionConfig) == "table" then
		table.freeze(explosionConfig)
	end
end
table.freeze(EffectsConfig.EXPLOSION)

table.freeze(EffectsConfig)

return EffectsConfig
