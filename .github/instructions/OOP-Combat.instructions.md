---
applyTo: "src/server/Combat/**, src/client/Gameplay/**"
---

# OOP — Capa de Combate

Este documento cubre los sistemas de combate del juego: `CombatService`,
`WeaponService`, y el cliente `ActionResolver` en lo que respecta a
resolución de acciones de combate. Todo código en estas rutas debe seguir
estos patrones.

---

## 1. Principio Fundamental: Server-Authoritative

El cliente **predice** las acciones de combate localmente para responsividad
inmediata, pero el servidor es el árbitro final.

```
FLUJO DE COMBATE:
  Cliente: Jugador dispara
    → ActionResolver decide "Shoot"
    → MovementController ejecuta localmente (recoil visual, animación)
    → ClientNetwork:FireServer("WeaponFire", {weaponType, direction, timestamp})

  Servidor: Recibe "WeaponFire"
    → ServerNetwork valida (tipo, rate, ownership)
    → WeaponService valida (ammo, alive, fire rate)
    → CombatService aplica daño si hit es válido
    → Confirma o rechaza al cliente via RemoteEvent
```

**Nunca** aplicar daño real en el cliente. El cliente solo muestra efectos visuales.

---

## 2. Sistema de Salud — Mecánicas GoW

```
MAX_HEALTH = 600 HP (Constants.COMBAT_MAX_HEALTH)
DBNO_THRESHOLD = 150 HP (Constants.COMBAT_DBNO_THRESHOLD)
```

### Estados de salud

```
600 HP ──────────────────────── Full health
 │
 │  Regen automático:
 │    - Comienza 5s después del último daño
 │    - Velocidad: 60 HP/s (Constants.COMBAT_REGEN_RATE)
 │    - Solo si no está en DBNO
 │
 ▼
150 HP ──────────────────────── DBNO threshold
 │
 │  Al cruzar este umbral:
 │    - Jugador entra en estado DBNO (PlayerState "DBNO")
 │    - Puede arrastrarse lentamente (WalkSpeed = 3)
 │    - Comienza el Bleedout Timer: 30s (Constants.COMBAT_BLEEDOUT_TIME)
 │    - Aliados pueden revivir (interrumpe el timer)
 │    - Si el timer llega a 0 → muerte (estado "Dead")
 │
 ▼
0 HP ────────────────────────── Death (desde DBNO sin rescate)
```

### CombatService API (servidor)

```luau
-- Aplicar daño a un jugador (llamado por WeaponService tras validar)
CombatService:ApplyDamage(victim: Player, amount: number, attacker: Player)
-- Efectos:
--   • Reduce health en el servidor
--   • Si health <= DBNO_THRESHOLD: TransitionTo("DBNO") via ForceState
--   • Resetea el timer de regen
--   • Replica health al cliente via RemoteEvent

-- Intentar revivir a un jugador DBNO
CombatService:RequestRevive(victim: Player, rescuer: Player)
-- Valida: rescuer debe estar cerca (< 5 studs), victim en DBNO
-- Si válido: cancela bleedout, restaura a DBNO_THRESHOLD + 1, ForceState("Idle")

-- Ejecutar a un jugador en DBNO (curb stomp / brutal kill)
CombatService:ExecuteDBNO(victim: Player, executor: Player)
-- Valida: victim en estado DBNO, executor en estado adecuado
-- Inicia animación de ejecución, al final: victim muere
```

---

## 3. Sistema DBNO (Down But Not Out)

El DBNO es una mecánica central de GoW: en vez de morir, el jugador cae
al suelo y puede ser rescatado.

### Estados relacionados

| Estado | Descripción |
|---|---|
| `DBNO` | Caído, arrastrándose, esperando rescate o ejecutar |
| `Executing` | Siendo ejecutado (curb stomp) — transición final a muerte |

### Transiciones DBNO

```
Cualquier estado → DBNO      (cuando health <= 150)
DBNO → Idle                  (cuando aliado revive)
DBNO → Executing             (cuando enemigo ejecuta — inicia desde el enemigo)
Executing → Dead/Idle        (al terminar ejecución)
```

### Bleedout mechanic

```luau
-- CombatService.luau — Gestión del bleedout
self._bleedoutTimers = {}  -- { [userId] = bleedoutStartTime }

-- Al entrar DBNO:
self._bleedoutTimers[userId] = os.clock()

-- En tick del servidor (cada segundo):
for userId, startTime in self._bleedoutTimers do
    if os.clock() - startTime >= Constants.COMBAT_BLEEDOUT_TIME then
        self:_killPlayer(userId)
    end
end

-- Al revivir o ejecutar: limpiar timer
self._bleedoutTimers[userId] = nil
```

---

## 4. WeaponService — Armas Autoritativas

**El servidor es el único que sabe cuánta munición tiene el jugador.**
El cliente nunca decide si puede disparar — solo pide disparar.

### Armas del juego (WeaponType enum)

| Arma | Tipo | Munición | Fire Rate | Característica |
|---|---|---|---|---|
| `Lancer` | Assault rifle | 60/∞ | Auto | Chainsaw bayonet (hold V) |
| `Gnasher` | Shotgun | 8/∞ | Manual | Alta daño cercana |
| `Longshot` | Sniper | 6/∞ | Bolt-action | One-shot desde lejos |
| `TorqueBow` | Explosive bow | 6/∞ | Charge | Hold para carga |
| `HammerOfDawn` | Orbital laser | 3/∞ | Beam | Solo en cielo abierto |
| `Boomshot` | Grenade launcher | 4/∞ | Manual | Explosión en área |
| `Snub` | Pistol | 12/∞ | Semi-auto | Sidearm siempre disponible |

### WeaponService API (servidor)

```luau
-- Validar y ejecutar un disparo
WeaponService:ValidateFire(player: Player, weaponType: string, direction: Vector3) → boolean
-- Checks: jugador vivo, arma activa correcta, ammo > 0, fire rate respetado
-- Si válido: reduce ammo, calcula hit (raycast servidor), retorna resultado

-- Recargar arma
WeaponService:ValidateReload(player: Player) → boolean
-- Checks: jugador vivo, ammo < max, no está reloading ya
-- Inicia timer de recarga según el arma

-- Obtener estado de munición (para sincronizar cliente)
WeaponService:GetAmmoState(player: Player) → { current: number, reserve: number }
```

---

## 5. Active Reload

El Active Reload es una mecánica de habilidad de GoW: presionar R en una
ventana específica durante la animación da un bonus de daño.

```
Recarga normal: ──────────────────────────────────────────── [done]
                     ┌──────────────┐
Active window:        ████████████   15% de la duración total
                      ▲          ▲
                    start       end

Acciones posibles:
  • Presionar R antes del start   → falla (reinicia la recarga)
  • Presionar R dentro del window → Active Reload! bonus +8% daño por 4s
  • Presionar R después del end   → recarga normal completa sin bonus
  • No presionar R                → recarga normal completa
```

### Constantes

```luau
Constants.ACTIVE_RELOAD_WINDOW = 0.15  -- 15% de la duración de recarga
Constants.ACTIVE_RELOAD_BONUS = 0.08   -- +8% de daño bonus
Constants.ACTIVE_RELOAD_DURATION = 4.0 -- segundos que dura el bonus
```

### Implementación en WeaponService

```luau
-- El timing del Active Reload se valida en el servidor:
-- El cliente envía el timestamp de cuando presionó R
-- El servidor compara con el timestamp de inicio de recarga
WeaponService:ValidateActiveReload(player: Player, pressTimestamp: number) → "bonus" | "normal" | "fail"
```

---

## 6. ActionResolver — Resolución de Acciones de Combate

El `ActionResolver` (`src/client/Gameplay/ActionResolver.luau`) decide qué
acción de combate se ejecuta según el árbol de prioridades del estado actual.

### Árboles de prioridad por estado

#### Estado libre (Idle, Walking, Aiming, Firing)
```
Prioridad 1: WantsCover + HasCoverNearby    → EnterCover / SlideIntoCover
Prioridad 2: WantsMantle + HasLowCoverAhead → Mantle
Prioridad 3: WantsEvade + estado.canEvade   → Evade
Prioridad 4: WantsRoadieRun                 → StartRoadieRun
Prioridad 5: WantsAim + estado.canShoot     → StartAim
Prioridad 6: WantsShoot + estado.canShoot   → Shoot
Prioridad 7: WantsReload + !full ammo       → Reload
Prioridad 8: WantsChainsaw (hold V)         → Chainsaw
Prioridad 9: WantsMelee (tap V)             → Melee
```

#### Estado CoverIdle
```
Prioridad 1: WantsCover (tap, para salir)   → ExitCover
Prioridad 2: WantsEvade                     → RollOutOfCover
Prioridad 3: WantsMantle + HasLowCoverAhead → VaultCover
Prioridad 4: WantsSwatTurn + adjCover       → SwatTurn (left/right)
Prioridad 5: WantsAim                       → PopUpAim
Prioridad 6: WantsShoot (sin apuntar)       → BlindFire
Prioridad 7: WantsReload                    → Reload (en cover, más seguro)
```

### ¿Cómo añadir una nueva acción de combate? (checklist)
1. Añadir el nuevo `Intent` en `Types.luau` (ej: `"WantsTorqueBow"`).
2. Añadir la regla de mapeo en `IntentMapper` (qué input produce este intent).
3. Añadir el TTL en `InputBuffer` y en `Constants.luau`.
4. Añadir la prioridad en el árbol del estado correcto en `ActionResolver`.
5. Añadir el `ActionHandler` en `MovementController` (qué hace físicamente).
6. Para efectos de daño: añadir validación en `WeaponService` (servidor).
