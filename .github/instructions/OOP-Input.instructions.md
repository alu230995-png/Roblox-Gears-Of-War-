---
applyTo: "src/client/Input/**"
---

# OOP — Capa de Input (Pipeline 5 Capas)

Este documento describe cómo está implementada la capa de input y cómo
extenderla correctamente. Todo código en `src/client/Input/` debe seguir
estos patrones.

---

## 1. Visión General del Pipeline

El input del jugador pasa por 5 capas **secuenciales** cada Heartbeat.
**Cada capa es un módulo OOP independiente.** Ninguna capa conoce la
implementación interna de las demás — solo usa sus APIs públicas.

```
┌─────────────────┐
│  InputDetector  │  Capa 1: Raw hardware events (KeyCode, UserInputType)
│   (Capa 1)      │  Output: Cola de RawInputEvent, polling GetMoveDirection()
└────────┬────────┘
         │ DrainEvents() → []RawInputEvent
┌────────▼────────┐
│  IntentMapper   │  Capa 2: Raw → Semántica (WantsCover, WantsEvade, etc.)
│   (Capa 2)      │  Usa EnvironmentSensor para intents contexto-sensitivos
└────────┬────────┘
         │ GetActiveIntents() → {[Intent]: IntentEntry}
┌────────▼────────┐
│  InputBuffer    │  Capa 3: Buffering con TTL por tipo de intent
│   (Capa 3)      │  Permite "input early" (presionar antes de estar listo)
└────────┬────────┘
         │ HasIntent(n), Consume(n), Update(dt)
┌────────▼────────┐
│  ActionResolver │  Capas 4+5: Árbol de prioridad → una sola acción por frame
│   (Capas 4-5)   │  Output: ActionResolved Signal → (action, targetState, data)
└─────────────────┘
```

---

## 2. Capa 1 — InputDetector

**Responsabilidad**: Detectar hechos físicos. No interpreta significado.

### API pública

```luau
-- Vacía la cola de eventos acumulados desde el último frame
InputDetector:DrainEvents() → { RawInputEvent }

-- Devuelve Vector2 de dirección de movimiento (WASD / stick izquierdo)
-- x: -1=izquierda, 1=derecha | y: -1=atrás, 1=adelante
InputDetector:GetMoveDirection() → Vector2

-- Devuelve si un raw input está held ahora mismo
InputDetector:IsRawHeld(rawName: string) → boolean
```

### Tipos de evento (RawInputEvent.Mode)

| Mode | Descripción |
|---|---|
| `"Tap"` | Press + release en < `HOLD_THRESHOLD` ms (150ms) |
| `"HoldStart"` | Tecla held por >= `HOLD_THRESHOLD` ms |
| `"Release"` | Tecla soltada (después de HoldStart) |
| `"Pressed"` | Tecla presionada (inmediato, para botones sin distinción tap/hold) |
| `"Released"` | Tecla soltada (para botones sin distinción tap/hold) |

### Raw input names (string)

```
CoverButton       → Space / GamepadA (tap/hold context-sensitive)
SprintModifier    → LeftShift / GamepadLeftStick-click
EvadeButton       → LeftAlt / GamepadB
FireButton        → MouseButton1 / GamepadR2
AimButton         → MouseButton2 / GamepadL2
ReloadButton      → R / GamepadX
BlindFireButton   → Q / GamepadLB
MeleeButton       → V / GamepadRB (tap/hold: golpe vs chainsaw)
InteractButton    → E o F / GamepadY
SwapWeapon        → 1/2/3 / DPadLeft
```

### ¿Cómo añadir un nuevo input? (checklist)
1. Añadir el `KeyCode` o `UserInputType` a `self._keyToRaw` en el constructor.
2. Añadir el equivalente de gamepad en `self._gamepadToRaw`.
3. Si necesita distinción tap/hold, usar `_holdThresholds` con el valor en ms.
4. Añadir el nuevo raw name a la sección de comentarios arriba.
5. El resto del pipeline lo recibe automáticamente vía `DrainEvents()`.

---

## 3. Capa 2 — IntentMapper

**Responsabilidad**: Traducir raw inputs a intenciones de alto nivel del jugador.
La misma tecla puede crear intents distintos según el contexto (GoW A-button).

### API pública

```luau
-- Procesa los eventos crudos y devuelve intents activos este frame
-- Requiere: lista de raw events + EnvironmentContext actual
IntentMapper:GetActiveIntents(rawEvents, envContext) → { [string]: IntentEntry }
```

### Reglas de mapeo contexto-sensitivo

```
CoverButton.Tap + HasCoverNearby = true   → WantsCover
CoverButton.Tap + HasCoverNearby = false  → WantsEvade
CoverButton.HoldStart (desde cover)       → WantsMantle (si cover bajo)
MeleeButton.Tap                           → WantsMelee
MeleeButton.HoldStart                     → WantsChainsaw
InteractButton.Pressed + DBNO nearby      → WantsRevive
InteractButton.Pressed (otherwise)        → WantsInteract
SprintModifier.Pressed                    → WantsRoadieRun
SprintModifier.Released                   → WantsStopRoadieRun
```

### ¿Cómo añadir un nuevo intent? (checklist)
1. Añadir el tipo string a `export type Intent` en `shared/Types.luau`.
2. Añadir la constante TTL en `shared/Constants.luau` (ej: `BUFFER_TTL_NEWINTENT = 80`).
3. Añadir la regla de mapeo en `IntentMapper:GetActiveIntents()`.
4. Si es contexto-sensitivo, usar `envContext` para la condición.
5. Añadir el TTL al mapa de TTLs en `InputBuffer` (ver sección 3.3).
6. Si tiene prioridad en el árbol de resolución, añadir en `ActionResolver` (ver OOP-Movement).

### IntentEntry (estructura interna del mapper)

```luau
type IntentEntry = {
    Active: boolean,
    Data: any?,         -- datos adicionales (ej: dirección del evade)
    Timestamp: number,  -- os.clock() cuando se generó
}
```

---

## 4. Capa 3 — InputBuffer

**Responsabilidad**: Buffering temporal de intents. Permite que el jugador
presione hasta 120ms antes de que las condiciones se cumplan y el intent
llegue igualmente al resolver.

### API pública

```luau
-- Añade los intents activos al buffer (reemplaza si ya existe el mismo tipo)
InputBuffer:PushFromIntents(intents: { [string]: IntentEntry })

-- Devuelve true si el intent está en buffer y no ha expirado
InputBuffer:HasIntent(intentName: string) → boolean

-- Marca el intent como consumido (no se puede usar de nuevo este frame)
InputBuffer:Consume(intentName: string)

-- Llamar en Heartbeat para expirar intents vencidos
InputBuffer:Update(dt: number)
```

### TTLs por intent (en `Constants.luau`)

| Intent | TTL | Razón |
|---|---|---|
| `WantsCover` | 120ms | Magnetismo de pared: ventana generosa |
| `WantsEvade` | 80ms | Debe sentirse reactivo pero no accidental |
| `WantsReload` | 50ms | Timing exacto en Active Reload |
| `WantsMelee` | 60ms | Golpe de melee, ventana corta |
| `WantsChainsaw` | 200ms | Hold largo, ventana más amplia |
| `WantsShoot` | 0ms | Inmediato, no se buferea |
| `WantsRoadieRun` | 0ms | Continuo, no necesita buffer |

### Regla de unicidad
Solo puede haber **un intent por tipo** en el buffer. Si llega uno nuevo
del mismo tipo, reemplaza al anterior (timestamp renovado, TTL reiniciado).

---

## 5. Arquitectura de Datos entre Capas

El flujo de datos entre capas es **unidireccional** siempre. Ninguna capa
modifica datos de la capa anterior ni posterior.

```
Layer 1 → Layer 2: []RawInputEvent     (array de structs, inmutables)
Layer 2 → Layer 3: {Intent: Entry}     (dict, inmutable tras entrega)
Layer 3 → Layer 4: HasIntent / Consume (API de acceso controlado)
Layer 4 → Fuera:   Signal.Fire()       (event-driven, no retorno directo)
```

### ❌ Anti-patrones prohibidos

```luau
-- MAL: una capa accediendo al estado interno de otra
local rawKeys = inputDetector._heldKeys  -- acceso a privado

-- MAL: saltarse una capa
local intents = inputDetector:GetActiveIntents()  -- DrainEvents() va a mapper primero

-- MAL: el buffer leyendo la cámara para decidir expiración
if camera:IsAimingDown() then buffer:ExtendTTL(...)  -- separación de concerns violada
```

---

## 6. Tests Mentales (Ejemplos de Flujo)

### Ejemplo: Cover desde RoadieRun (wall-bounce)

```
Frame N-3: Jugador corre con RoadieRun
Frame N-2: Jugador presiona Space (80ms antes de llegar a la pared)
           → InputDetector: cola ["CoverButton.Tap"]
           → IntentMapper: HasCoverNearby=false → WantsEvade (no hay pared aún)
           → InputBuffer: buffer WantsEvade TTL=80ms
           → ActionResolver: estado RoadieRun, WantsEvade → "RoadieEvade"

Frame N:   Jugador llega a la pared
           → IntentMapper: HasCoverNearby=true, SprintHeld=true
           → expira WantsEvade (80ms pasaron), crea WantsCover
           → InputBuffer: buffer WantsCover TTL=120ms
           → ActionResolver: RoadieRun + WantsCover + env.HasCoverNearby
           → "SlideIntoCover" → CoverSlide
```

### Ejemplo: Active Reload timing

```
Frame N:   Jugador pulsa R durante la animación de recarga
           → InputDetector: "ReloadButton.Pressed"
           → IntentMapper: WantsActiveReload (solo si ya está en Reloading)
           → InputBuffer: TTL=50ms (ventana exacta)
           → ActionResolver: Reloading + WantsActiveReload + timing en ventana
           → "ActiveReload" bonus aplicado
```
