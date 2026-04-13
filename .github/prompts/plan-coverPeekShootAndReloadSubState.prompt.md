## Plan: Shooting from CoverPeek + Reload como Sub-estado de Armas

Dos cambios: (1) habilitar disparo desde CoverPeek añadiendo la transición faltante y ruta de retorno, (2) que la recarga en cover no cambie PlayerState — solo dispara la acción + animación overlay.

---

### Cambio 1: Habilitar disparo desde CoverPeek

**Causa raíz**: `CoverRules.Peek` YA tiene la regla `ShootFromPeek` (prioridad 4) que emite `"Shoot" → "CoverFiring"`. PERO `PlayerState.luau` define `CoverPeek = { "CoverAimHigh", "CoverAimLow", "CoverIdle" }` — `CoverFiring` NO es destino válido. La StateMachine rechaza la transición silenciosamente.

**Pasos**:

1. `PlayerState.luau` — Añadir `"CoverFiring"` a las transiciones de `CoverPeek`
2. `PlayerState.luau` — Añadir `"CoverPeek"` a las transiciones de `CoverFiring` (ruta de retorno)
3. `CoverRules.luau` — Modificar la regla `StopCoverFiring` para que retorne a `CoverPeek` si el peek handler sigue activo (via `coverHandler:GetPeekHandler():IsActive()`), en vez de ir a CoverAimHigh/Low. Esto preserva la posición desplazada del peek entre ráfagas.

---

### Cambio 2: Recarga como sub-estado del arma (solo cover)

**Causa raíz**: `ReloadInCover.execute` transiciona a `"Reloading"` (FreeMovementGroup), sacando al jugador del CoverGroup.

**Pasos**:

4. `CoverRules.luau` — Cambiar `ReloadInCover.execute` para retornar `"Reload", nil, nil` (targetState = nil → sin cambio de PlayerState)
5. `PlayerState.luau` — Remover `"Reloading"` de las transiciones de `CoverIdle` (ya no se necesita desde cover)
6. Sin cambios en `WeaponClient` — `HandleAction("Reload")` ya llama a `_startReload()` que maneja timer, munición y notificación al server independientemente del PlayerState
7. Sin cambios en `AnimationController` — ya escucha acciones y tiene el placeholder one-shot para `"Reload"` como animación overlay

---

### Archivos relevantes
- `src/shared/Enums/PlayerState.luau` — Transiciones de CoverPeek, CoverFiring, CoverIdle (pasos 1, 2, 5)
- `src/client/Gameplay/ActionResolver/CoverRules.luau` — Lógica StopCoverFiring + ReloadInCover (pasos 3, 4)

### Verificación
1. Entrar en CoverPeek (hold aim + lateral en esquina), presionar disparo → debe transicionar a CoverFiring y disparar
2. Soltar disparo manteniendo aim + lateral → debe volver a CoverPeek (no a CoverAimHigh/Low)
3. Desde CoverIdle, presionar recarga → debe quedarse en CoverIdle, timer de recarga corre, munición se recarga
4. CoverWalking + recarga → se queda en CoverWalking, puede moverse mientras recarga
5. No disparar durante recarga → `WeaponClient._startFiring` bloqueado por guard `_isReloading`
6. Correr tests existentes (CoverEnteringTest) para verificar que no hay regresión

### Decisiones
- La eliminación de Reloading como estado es **solo para cover**. Free movement (Idle/Walking/Aiming/Firing) siguen usando `Reloading` PlayerState para preservar el flujo de Active Reload
- El retorno CoverFiring → CoverPeek es automático cuando el peek handler sigue activo

### Limitación conocida
- Si el jugador pulsa disparo mientras recarga en cover aim, el ActionResolver puede emitir `"Shoot" → "CoverFiring"` (WeaponClient lo ignora, no dispara, pero el estado cambia brevemente). Fix proper: exponer `IsReloading` en el contexto del resolver para bloquear reglas de disparo durante recarga. Tarea de follow-up.

### Consideraciones
1. **Recarga en free state**: ¿Debería `Reloading`/`ActiveReloading` también dejar de ser PlayerState para movimiento libre? Recomendación: diferir a tarea separada para no romper Active Reload.
2. **Recargar desde Peek/Aim**: Actualmente solo CoverIdle/Walking/Running tienen regla de recarga. En GoW típico se vuelve a idle para recargar. Mantener así salvo indicación contraria.

## Agrega tambien que entering aunque no se pueda apuntar si se pueda disparar