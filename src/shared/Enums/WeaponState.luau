--[[
	WeaponState.luau
	Enumeración de estados del arma estilo Gears of War.
	Solo datos: transiciones válidas entre estados.

	═══════════════════════════════════════════════════════════════
	ESTADOS DEL ARMA (máquina interna, separada del PlayerState)
	═══════════════════════════════════════════════════════════════

	Unequipped   → El arma no está disponible.
	               Se activa durante estados que bloquean su uso:
	               RoadieRun, Evading, Mantling, Vaulting, CoverSlide, etc.
	               Al volver a un estado libre → transiciona a Equipping.

	Equipping    → Transición: el arma se está equipando.
	               Dura EQUIP_TIME segundos (cooldown).
	               No se puede disparar, recargar ni cambiar de arma.
	               Al completar el timer → Equipped.
	               Si se interrumpe (force unequip) → Unequipping.

	Equipped     → El arma está activa y lista para usar.
	               El jugador puede disparar, apuntar y recargar.

	Unequipping  → Transición: el arma se está guardando.
	               Dura UNEQUIP_TIME segundos (cooldown).
	               No se puede disparar, recargar ni cambiar de arma.
	               Al completar el timer → Unequipped.
	               Si se re-equipa antes → Equipping.

	Shooting     → El jugador está disparando activamente.
	               Detecta input de disparo (WantsShoot), ejecuta mientras
	               haya munición y el jugador mantenga el input.
	               Si la munición se agota → Reloading.
	               Si suelta el input → Equipped.

	Reloading    → Estado de transición/espera.
	               Ejecuta la animación de recarga.
	               Puede activar ActiveReload (timing window dentro de Reloading).
	               Al completar → Equipped.

	═══════════════════════════════════════════════════════════════
	MAPEO WeaponState ↔ PlayerState (referencia para WeaponController)
	═══════════════════════════════════════════════════════════════

	PlayerState              → WeaponState esperado
	─────────────────────────────────────────────────
	Idle, Walking            → Equipped
	Aiming                   → Equipped (accuracy boost activo)
	Firing                   → Shooting
	Reloading                → Reloading
	ActiveReloading          → Reloading (sub-fase dentro de Reloading)
	RoadieRun                → Unequipped
	Evading                  → Unequipped
	Mantling, Vaulting       → Unequipped
	CoverSlide, CoverEntering → Unequipped
	CoverIdle                → Equipped
	CoverAimHigh/Low, CoverPeek → Equipped (accuracy boost)
	CoverFiring              → Shooting
	CoverBlindFire           → Shooting (sin accuracy boost)
	DBNO                     → Unequipped
	Death                    → Unequipped

	═══════════════════════════════════════════════════════════════
	OBSERVADORES (el arma ESCUCHA, no decide)
	═══════════════════════════════════════════════════════════════

	El futuro WeaponController escuchará:
	- StateMachine.StateChanged → decidir Equipped/Unequipped
	- MovementController.ActionExecuted → detectar Shoot/Reload/StopShoot
	- PlayerState "Aiming" → mejorar precisión del arma (spread reduction)

	El arma NO controla al jugador. El jugador controla al arma.
]]

local WeaponState = {}

------------------------------------------------------------------------
-- TRANSITIONS
------------------------------------------------------------------------

WeaponState.Transitions = {
	Unequipped = { "Equipping" },
	Equipping = { "Equipped", "Unequipping" }, -- timer completo → Equipped, o cancelado → Unequipping
	Equipped = { "Unequipping", "Shooting", "Reloading" },
	Unequipping = { "Unequipped", "Equipping" }, -- timer completo → Unequipped, o re-equip → Equipping
	Shooting = { "Equipped", "Reloading", "Unequipping" },
	Reloading = { "Equipped", "Unequipping" },
}

return table.freeze(WeaponState)
