--[[
	SoundGroup.luau
	Enumeración de grupos de sonido del sistema de audio.
	
	Grupos:
	  - VFX: Efectos de sonido de gameplay (pasos, disparos, recargas, explosiones)
	  - Ambient: Sonidos ambientales del entorno (viento, lluvia, escombros)
	  - Music: Música del juego (menú, combate, victoria, derrota)
	  - Server: Sonidos disparados por el servidor (alarmas, countdown, anuncios)
]]

local SoundGroup = {
	VFX = "VFX",
	Ambient = "Ambient",
	Music = "Music",
	Server = "Server",
}

table.freeze(SoundGroup)

return SoundGroup
