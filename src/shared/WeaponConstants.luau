--[[
	WeaponConstants.luau
	═══════════════════════════════════════════════════════════════
	Constantes exclusivas del sistema de armas.
	═══════════════════════════════════════════════════════════════

	Separado de Constants.luau para mantener la tabla principal limpia.
	Contiene:
	  1. TIMINGS — equip, unequip, drop
	  2. WEAPON_STATS — stats base por arma (daño, cadencia, cargador, etc.)
	  3. WEAPON_EFFECTS — IDs de sonido/partículas por arma (placeholder)

	Convención de nombres: las claves de WEAPON_STATS coinciden
	con WeaponType.Types[key].Name (Lancer, Gnasher, Longshot, etc.)
]]

local WeaponConstants = {}

------------------------------------------------------------------------
-- 1. TIMINGS — equip/unequip/drop
------------------------------------------------------------------------

-- Duración (segundos) de la animación de equipar/desequipar
WeaponConstants.EQUIP_TIME = 0.4
WeaponConstants.UNEQUIP_TIME = 0.3

-- Elevación (studs) del modelo dropeado respecto al HRP al morir
WeaponConstants.DROP_HEIGHT_OFFSET = 2
-- Fuerza aplicada al modelo dropeado al morir (studs/s en la dirección forward)
WeaponConstants.DROP_IMPULSE = 10
-- Tiempo (segundos) antes de destruir el drop del mundo (0 = nunca)
WeaponConstants.DROP_LIFETIME = 60

------------------------------------------------------------------------
-- 2. WEAPON_STATS — stats base por arma
------------------------------------------------------------------------

--- Campos por arma:
---   Damage       — daño base por impacto (por pellet en escopetas)
---   FireRate     — segundos entre disparos
---   MagazineSize — balas por cargador
---   ReloadTime   — segundos de recarga
---   Range        — alcance máximo en studs
---   Spread       — grados de dispersión base (cono)
---   FireMode     — "Auto" | "Semi" | "Burst"
WeaponConstants.STATS = table.freeze({
	Lancer = table.freeze({
		Damage = 20,
		FireRate = 0.1,
		MagazineSize = 60,
		ReloadTime = 2.5,
		Range = 200,
		Spread = 1.5,
		FireMode = "Auto",
	}),

	Gnasher = table.freeze({
		Damage = 100,
		FireRate = 0.8,
		MagazineSize = 8,
		ReloadTime = 2.8,
		Range = 30,
		Spread = 8.0,
		FireMode = "Semi",
	}),

	Longshot = table.freeze({
		Damage = 500,
		FireRate = 1.5,
		MagazineSize = 1,
		ReloadTime = 3.0,
		Range = 500,
		Spread = 0.2,
		FireMode = "Semi",
	}),

	TorqueBow = table.freeze({
		Damage = 600,
		FireRate = 2.0,
		MagazineSize = 1,
		ReloadTime = 3.5,
		Range = 300,
		Spread = 0.0,
		FireMode = "Semi",
	}),

	HammerOfDawn = table.freeze({
		Damage = 1000,
		FireRate = 5.0,
		MagazineSize = 1,
		ReloadTime = 0,
		Range = 999,
		Spread = 0.0,
		FireMode = "Semi",
	}),

	Boomshot = table.freeze({
		Damage = 800,
		FireRate = 2.0,
		MagazineSize = 1,
		ReloadTime = 3.0,
		Range = 150,
		Spread = 0.0,
		FireMode = "Semi",
	}),

	Snub = table.freeze({
		Damage = 30,
		FireRate = 0.2,
		MagazineSize = 12,
		ReloadTime = 1.8,
		Range = 100,
		Spread = 2.0,
		FireMode = "Semi",
	}),
})

------------------------------------------------------------------------
-- 3. WEAPON_EFFECTS — IDs placeholder de sonido/partículas
-- Reemplazar "rbxassetid://0" por asset IDs reales al importar
------------------------------------------------------------------------

WeaponConstants.EFFECTS = table.freeze({
	Lancer = table.freeze({
		FireSound = "rbxassetid://0",
		ReloadSound = "rbxassetid://0",
		EquipSound = "rbxassetid://0",
		MuzzleFlash = "rbxassetid://0",
		ChainsawSound = "rbxassetid://0",
	}),
	Gnasher = table.freeze({
		FireSound = "rbxassetid://0",
		ReloadSound = "rbxassetid://0",
		EquipSound = "rbxassetid://0",
		MuzzleFlash = "rbxassetid://0",
	}),
	Longshot = table.freeze({
		FireSound = "rbxassetid://0",
		ReloadSound = "rbxassetid://0",
		EquipSound = "rbxassetid://0",
		MuzzleFlash = "rbxassetid://0",
	}),
	Snub = table.freeze({
		FireSound = "rbxassetid://0",
		ReloadSound = "rbxassetid://0",
		EquipSound = "rbxassetid://0",
		MuzzleFlash = "rbxassetid://0",
	}),
})

return table.freeze(WeaponConstants)
