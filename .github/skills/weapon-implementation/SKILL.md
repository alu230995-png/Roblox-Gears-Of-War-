---
name: weapon-implementation
description: "Implementación de armas en el proyecto Gears of War (Roblox/Luau). Usar cuando: añadir nuevas armas, definir stats, implementar lógica de disparo, recarga, munición, swap de armas, integrar con StateMachine y ActionResolver, conectar animaciones y sonidos de arma."
argument-hint: "Nombre del arma o mecánica a implementar (ej: Lancer, pistol, grenades)"
---

# Weapon Implementation

## Cuándo usar esta skill
- Añadir una nueva arma al juego
- Implementar lógica de disparo (hitscan, projectile)
- Crear sistema de recarga y munición
- Implementar swap/equip de armas
- Integrar arma con el `ActionResolver` y la `StateMachine`
- Conectar efectos de sonido y animaciones a eventos de arma

---

## Estructura de capas para armas

```
src/
  client/
    Weapons/
      WeaponController.luau      ← Coordinator: equip/unequip, disparo, recarga
      WeaponAnimator.luau        ← Maneja AnimationTracks específicos de arma
      <NombreArma>/
        init.luau                ← Stats + lógica específica del arma
  server/
    Weapons/
      WeaponService.luau         ← Autoridad: valida disparo, aplica daño
  shared/
    Enums/
      WeaponType.luau            ← Enum de tipos de arma (ya existe)
    Types.luau                   ← Añadir WeaponData, ShotResult types
    Constants.luau               ← Stats base de armas (daño, cadencia, munición)
```

---

## Procedimiento

### 1. Definir stats en `Constants.luau`
- Añadir tabla `WEAPON_STATS[WeaponType]` con: `damage`, `fireRate`, `magazineSize`, `reloadTime`, `range`, `spread`
- Para armas cuerpo a cuerpo: `damage`, `swingRate`, `range`

### 2. Crear el módulo del arma en `src/client/Weapons/<Nombre>/init.luau`
- Hereda estructura base con `new(weaponType)`, `Equip()`, `Unequip()`, `Fire()`, `Reload()`, `Destroy()`
- Guarda todas las conexiones en `self._connections` para limpieza en `Destroy()`

### 3. Registrar estados de arma en la `StateMachine`
- Estados de arma deben convivir con `PlayerState`
- Disparar transiciones: `Idle → Aiming`, `Aiming → Firing`, `Firing → Reloading`
- No bloquear transiciones de movimiento (cover, evade) desde `ActionResolver`

### 4. Añadir reglas al `ActionResolver`
- Archivo correspondiente según estado del jugador:
  - `FreeStateRules.luau` → disparo en pie
  - `CoverRules.luau` → blind fire, peek + disparo
- Regla recibe `ResolverContext` y retorna acción o `nil`

### 5. Conectar con `WeaponService` (servidor)
- `RemoteEvent` para: `RequestFire`, `RequestReload`, `RequestSwap`
- Servidor valida: cooldown, munición, estado del jugador antes de aplicar daño
- Rate limiting: rechazar si `os.clock() - lastFire < fireRate`

### 6. Sonidos y animaciones
- Añadir entradas en `SoundConfig.luau` con nombres únicos por arma
- `WeaponAnimator` escucha `WeaponController.OnFired`, `OnReloaded`, `OnEquipped`

---

## Convenciones del proyecto
- Sin `_G` ni `shared` — todo pasa por `ServiceLocator` o `require`
- Todas las conexiones en `self._connections = {}` → desconectar en `Destroy()`
- `RaycastParams` creado una sola vez en el constructor, no por frame
- Validación autoritativa siempre en servidor; cliente solo predice visualmente
