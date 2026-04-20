--[[
	WeaponConstants.luau
	═══════════════════════════════════════════════════════════════
	Configuración completa de todas las armas del juego.
	═══════════════════════════════════════════════════════════════

	Cada arma se define con: Identity, Stats, Ammo, Ballistics, Mechanics.
	La clave DEBE coincidir con el nombre del Tool en Roblox.

	Estructura:
	  Identity   — nombre, tipo de disparo, descripción, IsHeavy
	  Stats      — daño base, cadencia, alcance, auto-fire
	  Ammo       — capacidad total, munición inicial, cargador, recarga, active reload
	  Ballistics — falloff (caída de daño), explosive (explosión), spread pattern
	  Mechanics  — SphereCastRadius (aim-assist server), HoldingBreath (hold-to-fire)
]]

local WeaponConstants = {}

------------------------------------------------------------------------
-- TIMINGS — equip/unequip
------------------------------------------------------------------------

WeaponConstants.EQUIP_TIME = 0.4
WeaponConstants.UNEQUIP_TIME = 0.3

------------------------------------------------------------------------
-- WEAPONS — configuración completa por arma
------------------------------------------------------------------------

WeaponConstants.WEAPONS = table.freeze({

	------------------------------------------------------------------------
	-- LANCER — Rifle de asalto con sierra (arma default)
	------------------------------------------------------------------------
	Lancer = table.freeze({
		Identity = table.freeze({
			Name = "Lancer",
			Type = "Hitscan",
			Description = "Rifle de asalto versátil con sierra integrada.",
			IsHeavy = false,
		}),
		Stats = table.freeze({
			BaseDamage = 20,
			FireRate = 0.12,
			Range = 200,
			AutoFire = true,
		}),
		Ammo = table.freeze({
			MaxCapacity = 360,
			CurrentAmmo = 240,
			ClipSize = 60,
			ReloadTime = 2.5,
			ActiveReloadWindowStart = 0.30,
			ActiveReloadWindowDuration = 0.15,
		}),
		Ballistics = table.freeze({
			Falloff = table.freeze({
				Enabled = true,
				StartDistance = 80,
				DamagePerUnit = 0.05,
				Spread = 1.5,
			}),
			Explosive = table.freeze({
				Enabled = false,
				Radius = 0,
			}),
			SpreadPattern = table.freeze({
				[1] = UDim2.new(0.5, 0, 0.5, 0),
			}),
		}),
		Mechanics = table.freeze({
			SphereCastRadius = 1.5,
			HoldingBreath = table.freeze({
				Enabled = false,
				Duration = 0,
				CancelOnRelease = false,
			}),
		}),
	}),

	------------------------------------------------------------------------
	-- GNASHER — Escopeta táctica de corto alcance (arma default)
	------------------------------------------------------------------------
	Gnasher = table.freeze({
		Identity = table.freeze({
			Name = "Gnasher",
			Type = "Hitscan",
			Description = "Escopeta devastadora de corto alcance. Icónica de Gears of War.",
			IsHeavy = false,
		}),
		Stats = table.freeze({
			BaseDamage = 62,
			FireRate = 1.2,
			Range = 200,
			AutoFire = false,
		}),
		Ammo = table.freeze({
			MaxCapacity = 32,
			CurrentAmmo = 24,
			ClipSize = 12,
			ReloadTime = 2.8,
			ActiveReloadWindowStart = 0.35,
			ActiveReloadWindowDuration = 0.15,
		}),
		Ballistics = table.freeze({
			Falloff = table.freeze({
				Enabled = true,
				StartDistance = 0.5,
				DamagePerUnit = 5,
				Spread = 8.0,
			}),
			Explosive = table.freeze({
				Enabled = false,
				Radius = 0,
			}),
			SpreadPattern = table.freeze({
				[1] = UDim2.new(0.5, 0, 0.5, 0),
				[2] = UDim2.new(0.4, 0, 0.35, 0),
				[3] = UDim2.new(0.6, 0, 0.35, 0),
				[4] = UDim2.new(0.35, 0, 0.5, 0),
				[5] = UDim2.new(0.65, 0, 0.5, 0),
				[6] = UDim2.new(0.4, 0, 0.65, 0),
				[7] = UDim2.new(0.6, 0, 0.65, 0),
				[8] = UDim2.new(0.5, 0, 0.3, 0),
				[9] = UDim2.new(0.5, 0, 0.7, 0),
			}),
		}),
		Mechanics = table.freeze({
			SphereCastRadius = 0.2,
			HoldingBreath = table.freeze({
				Enabled = false,
				Duration = 0,
				CancelOnRelease = false,
			}),
		}),
	}),

	------------------------------------------------------------------------
	-- LONGSHOT — Sniper de alto daño, un tiro por cargador
	------------------------------------------------------------------------
	Longshot = table.freeze({
		Identity = table.freeze({
			Name = "Longshot",
			Type = "Hitscan",
			Description = "Rifle de francotirador de alto daño. Letal en cabeza.",
			IsHeavy = false,
		}),
		Stats = table.freeze({
			BaseDamage = 500,
			FireRate = 1.5,
			Range = 500,
			AutoFire = false,
		}),
		Ammo = table.freeze({
			MaxCapacity = 12,
			CurrentAmmo = 12,
			ClipSize = 1,
			ReloadTime = 3.0,
			ActiveReloadWindowStart = 0.25,
			ActiveReloadWindowDuration = 0.12,
		}),
		Ballistics = table.freeze({
			Falloff = table.freeze({
				Enabled = false,
				StartDistance = 0,
				DamagePerUnit = 0,
				Spread = 0.2,
			}),
			Explosive = table.freeze({
				Enabled = false,
				Radius = 0,
			}),
			SpreadPattern = table.freeze({
				[1] = UDim2.new(0.5, 0, 0.5, 0),
			}),
		}),
		Mechanics = table.freeze({
			SphereCastRadius = 1.0,
			HoldingBreath = table.freeze({
				Enabled = false,
				Duration = 0,
				CancelOnRelease = false,
			}),
		}),
	}),

	------------------------------------------------------------------------
	-- TORQUE BOW — Arco explosivo, requiere carga antes de disparar
	------------------------------------------------------------------------
	TorqueBow = table.freeze({
		Identity = table.freeze({
			Name = "TorqueBow",
			Type = "Hitscan",
			Description = "Arco explosivo que requiere carga. Devastador al impactar.",
			IsHeavy = false,
		}),
		Stats = table.freeze({
			BaseDamage = 800,
			FireRate = 2.0,
			Range = 300,
			AutoFire = false,
		}),
		Ammo = table.freeze({
			MaxCapacity = 6,
			CurrentAmmo = 6,
			ClipSize = 1,
			ReloadTime = 3.5,
			ActiveReloadWindowStart = 0.30,
			ActiveReloadWindowDuration = 0.10,
		}),
		Ballistics = table.freeze({
			Falloff = table.freeze({
				Enabled = true,
				StartDistance = 1,
				DamagePerUnit = 20,
				Spread = 0.0,
			}),
			Explosive = table.freeze({
				Enabled = true,
				Radius = 10,
			}),
			SpreadPattern = table.freeze({
				[1] = UDim2.new(0.5, 0, 0.5, 0),
			}),
		}),
		Mechanics = table.freeze({
			SphereCastRadius = 1.0,
			HoldingBreath = table.freeze({
				Enabled = true,
				Duration = 8,
				CancelOnRelease = false,
				MaxChargeSpread = 15,
			}),
		}),
	}),

	------------------------------------------------------------------------
	-- HAMMER OF DAWN — Arma pesada orbital, requiere carga
	------------------------------------------------------------------------
	HammerOfDawn = table.freeze({
		Identity = table.freeze({
			Name = "HammerOfDawn",
			Type = "Hitscan",
			Description = "Arma orbital devastadora. Requiere carga y línea de visión al cielo.",
			IsHeavy = true,
		}),
		Stats = table.freeze({
			BaseDamage = 1000,
			FireRate = 5.0,
			Range = 999,
			AutoFire = false,
		}),
		Ammo = table.freeze({
			MaxCapacity = 1,
			CurrentAmmo = 1,
			ClipSize = 1,
			ReloadTime = 0,
		}),
		Ballistics = table.freeze({
			Falloff = table.freeze({
				Enabled = false,
				StartDistance = 0,
				DamagePerUnit = 0,
				Spread = 0.0,
			}),
			Explosive = table.freeze({
				Enabled = true,
				Radius = 15,
			}),
			SpreadPattern = table.freeze({
				[1] = UDim2.new(0.5, 0, 0.5, 0),
			}),
		}),
		Mechanics = table.freeze({
			SphereCastRadius = 1.0,
			HoldingBreath = table.freeze({
				Enabled = true,
				Duration = 2.0,
				CancelOnRelease = true,
			}),
		}),
	}),

	------------------------------------------------------------------------
	-- BOOMSHOT — Lanzagranadas pesado, explosivo
	------------------------------------------------------------------------
	Boomshot = table.freeze({
		Identity = table.freeze({
			Name = "Boomshot",
			Type = "Hitscan",
			Description = "Lanzagranadas pesado. Daño explosivo en área.",
			IsHeavy = true,
		}),
		Stats = table.freeze({
			BaseDamage = 1200,
			FireRate = 2.0,
			Range = 150,
			AutoFire = false,
		}),
		Ammo = table.freeze({
			MaxCapacity = 4,
			CurrentAmmo = 4,
			ClipSize = 1,
			ReloadTime = 3.0,
			ActiveReloadWindowStart = 0.30,
			ActiveReloadWindowDuration = 0.12,
		}),
		Ballistics = table.freeze({
			Falloff = table.freeze({
				Enabled = true,
				StartDistance = 1,
				DamagePerUnit = 100,
				Spread = 0.0,
			}),
			Explosive = table.freeze({
				Enabled = true,
				Radius = 25,
			}),
			SpreadPattern = table.freeze({
				[1] = UDim2.new(0.5, 0, 0.5, 0),
			}),
		}),
		Mechanics = table.freeze({
			SphereCastRadius = 1.0,
			HoldingBreath = table.freeze({
				Enabled = false,
				Duration = 0,
				CancelOnRelease = false,
			}),
		}),
	}),

	------------------------------------------------------------------------
	-- SNUB — Pistola secundaria (arma default)
	------------------------------------------------------------------------
	Snub = table.freeze({
		Identity = table.freeze({
			Name = "Snub",
			Type = "Hitscan",
			Description = "Pistola secundaria confiable. Buena precisión a media distancia.",
			IsHeavy = false,
		}),
		Stats = table.freeze({
			BaseDamage = 30,
			FireRate = 0.2,
			Range = 100,
			AutoFire = false,
		}),
		Ammo = table.freeze({
			MaxCapacity = 48,
			CurrentAmmo = 36,
			ClipSize = 12,
			ReloadTime = 1.8,
			ActiveReloadWindowStart = 0.25,
			ActiveReloadWindowDuration = 0.15,
		}),
		Ballistics = table.freeze({
			Falloff = table.freeze({
				Enabled = true,
				StartDistance = 40,
				DamagePerUnit = 0.1,
				Spread = 2.0,
			}),
			Explosive = table.freeze({
				Enabled = false,
				Radius = 0,
			}),
			SpreadPattern = table.freeze({
				[1] = UDim2.new(0.5, 0, 0.5, 0),
			}),
		}),
		Mechanics = table.freeze({
			SphereCastRadius = 1.5,
			HoldingBreath = table.freeze({
				Enabled = false,
				Duration = 0,
				CancelOnRelease = false,
			}),
		}),
	}),
})

return table.freeze(WeaponConstants)
