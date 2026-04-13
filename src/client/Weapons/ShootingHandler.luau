--[[
	ShootingHandler.luau
	═══════════════════════════════════════════════════════════════
	Lógica pura de disparo: raycast por pellet desde la cámara
	a través de las posiciones del scope en pantalla.
	═══════════════════════════════════════════════════════════════

	Uso:
	  local result = ShootingHandler.FireOneShot(player, scopeContainer, stats)
	  -- result = { Origin: Vector3, HitPositions: { [string]: Vector3 }, HitParts: { [string]: string } }
	  --   o nil si no se pudo disparar

	El handler NO muta estado — es una función pura que devuelve datos
	del disparo para que WeaponClient envíe al servidor.
]]

local Workspace = game:GetService("Workspace")

local ShootingHandler = {}

------------------------------------------------------------------------
-- PRIVATE — RaycastParams cache (evita allocar uno nuevo por disparo)
------------------------------------------------------------------------

local _cachedParams: RaycastParams = RaycastParams.new()
_cachedParams.FilterType = Enum.RaycastFilterType.Exclude
_cachedParams.IgnoreWater = true

--- Actualiza el filter del RaycastParams cacheado con el character actual.
local function _refreshRaycastParams(player: Player)
	local character = player.Character
	if character then
		_cachedParams.FilterDescendantsInstances = { character }
	else
		_cachedParams.FilterDescendantsInstances = {}
	end
end

------------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------------

--- Ejecuta un disparo: raycast por cada pellet del scope.
--- @param player Player — jugador local
--- @param scopeContainer Frame? — contenedor del ScopeRenderer con dots
--- @param stats table — WeaponConstants.WEAPONS[weaponName].Stats
--- @return table? — { Origin: Vector3, HitPositions: { [string]: Vector3 }, HitParts: { [string]: string } } o nil
function ShootingHandler.FireOneShot(player: Player, scopeContainer: Frame?, stats: any): any?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end

	if not scopeContainer then
		return nil
	end

	local range = stats.Range or 200
	_refreshRaycastParams(player)

	local origin = camera.CFrame.Position
	local hitPositions: { [string]: Vector3 } = {}
	local hitParts: { [string]: string } = {}
	local hitCount = 0

	for _, dot in scopeContainer:GetChildren() do
		if not dot:IsA("GuiObject") or dot:IsA("UIConstraint") then
			continue
		end

		-- Obtener posición absoluta del dot en pantalla
		local absPos = dot.AbsolutePosition
		local absSize = dot.AbsoluteSize
		local screenX = absPos.X + absSize.X * 0.5
		local screenY = absPos.Y + absSize.Y * 0.5

		-- Convertir posición de pantalla a rayo 3D
		local unitRay = camera:ScreenPointToRay(screenX, screenY)

		-- Disparo: raycast desde la posición de la cámara en la dirección del rayo
		local direction = unitRay.Direction * range
		local result = Workspace:Raycast(unitRay.Origin, direction, _cachedParams)

		local pelletName = dot.Name

		if result then
			hitPositions[pelletName] = result.Position
			-- Guardar nombre de la parte impactada (para BallisticsUtils)
			if result.Instance then
				hitParts[pelletName] = result.Instance.Name
			end
			hitCount += 1
		else
			-- Sin hit: punto final del rayo
			hitPositions[pelletName] = unitRay.Origin + direction
		end
	end

	return {
		Origin = origin,
		HitPositions = hitPositions,
		HitParts = hitParts,
	}
end

return table.freeze(ShootingHandler)
