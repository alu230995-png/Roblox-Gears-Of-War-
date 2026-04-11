--[[
	WeaponType.luau
	Enumeración de tipos de arma de Gears of War.
	Cada arma tiene propiedades base para balanceo.
]]

local WeaponType = {}

WeaponType.Types = {
	Lancer = {
		Name = "Lancer",
		Category = "Assault",
		IsDefault = true,
		HasChainsaw = true,
	},

	Gnasher = {
		Name = "Gnasher",
		Category = "Shotgun",
		IsDefault = true,
		HasChainsaw = false,
	},

	Longshot = {
		Name = "Longshot",
		Category = "Sniper",
		IsDefault = false,
		HasChainsaw = false,
	},

	TorqueBow = {
		Name = "TorqueBow",
		Category = "Explosive",
		IsDefault = false,
		HasChainsaw = false,
	},

	HammerOfDawn = {
		Name = "HammerOfDawn",
		Category = "Heavy",
		IsDefault = false,
		HasChainsaw = false,
	},

	Boomshot = {
		Name = "Boomshot",
		Category = "Explosive",
		IsDefault = false,
		HasChainsaw = false,
	},

	Snub = {
		Name = "Snub",
		Category = "Pistol",
		IsDefault = true,
		HasChainsaw = false,
	},
}

table.freeze(WeaponType.Types)

return table.freeze(WeaponType)
