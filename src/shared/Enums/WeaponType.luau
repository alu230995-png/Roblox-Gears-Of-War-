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

function WeaponType.GetWeapon(weaponName: string)
	return WeaponType.Types[weaponName]
end

function WeaponType.GetDefaultWeapons(): { string }
	local defaults = {}
	for name, config in WeaponType.Types do
		if config.IsDefault then
			table.insert(defaults, name)
		end
	end
	return defaults
end

return WeaponType
