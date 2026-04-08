--[[
	SoundScope.luau
	Enumeración de scope de reproducción de sonido.
	
	Scopes:
	  - Player: Sonido 2D tipo UI/efecto. Se reproduce directo en el jugador.
	            No tiene posición 3D. Ideal para: HUD, reload confirm, hit markers.
	  - Global: Sonido 3D posicional. Requiere una posición de origen (Vector3).
	            Se atenúa con distancia. Ideal para: disparos, explosiones, pasos ajenos.
]]

local SoundScope = {
	Player = "Player",
	Global = "Global",
}

table.freeze(SoundScope)

return SoundScope
