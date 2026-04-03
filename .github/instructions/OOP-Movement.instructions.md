---
applyTo: "src/client/MovementController.luau, src/client/World/**, src/client/Character/**, src/server/Utils/**"
---

# OOP — Capa de Movimiento y Mundo

Este documento cubre todos los sistemas que **ejecutan** acciones físicas:
`MovementController`, `EnvironmentSensor`, `CharacterController` y
`PhysicsConfig` (servidor). Todo código en estas rutas debe seguir estos patrones.

---

## 1. MovementController — El Ejecutor

`MovementController` es el **único sistema** autorizado para modificar
`Humanoid.WalkSpeed`, `AssemblyLinearVelocity`, y la posición del personaje
en el cliente. Ningún otro módulo cliente toca la física directamente.

### Responsabilidad única
- Escuchar `ActionResolver.ActionResolved` Signal.
- Ejecutar el ActionHandler correspondiente a la acción recibida.
- Gestionar timers de estado (duración de animaciones comprometidas).
- Aplicar cover snap (interpolación hacia la pared).
- Gestionar el decaimiento del impulso de evade.

### API pública

```luau
-- Constructor: recibe la instancia del personaje y la StateMachine
MovementController.new(character: Model, stateMachine: StateMachine) → MovementController

-- Conectar al signal de ActionResolver (llamado en Start())
MovementController:ConnectToResolver(actionResolver: ActionResolver)

-- Llamar en Heartbeat para actualizar snap, impulso, timers
MovementController:Update(dt: number)
```

### Cómo está organizado internamente

```luau
-- Tabla de handlers registrados por nombre de acción:
self._actionHandlers = {
    -- Movimiento libre
    ["StartWalking"]     = function(self, data) ... end,
    ["StopWalking"]      = function(self, data) ... end,
    ["StartRoadieRun"]   = function(self, data) ... end,
    ["StopRoadieRun"]    = function(self, data) ... end,
    -- Cover
    ["EnterCover"]       = function(self, data) ... end,
    ["SlideIntoCover"]   = function(self, data) ... end,
    ["ExitCover"]        = function(self, data) ... end,
    ["PopUpAim"]         = function(self, data) ... end,
    ["BlindFire"]        = function(self, data) ... end,
    -- Evade
    ["Evade"]            = function(self, data) ... end,
    ["RollOutOfCover"]   = function(self, data) ... end,
    -- Combate
    ["Shoot"]            = function(self, data) ... end,
    ["Reload"]           = function(self, data) ... end,
    ["Melee"]            = function(self, data) ... end,
    ["Chainsaw"]         = function(self, data) ... end,
}
```

### ¿Cómo añadir un nuevo ActionHandler? (checklist)
1. Añadir la nueva acción como key en `self._actionHandlers` en el constructor.
2. Implementar la función: modifica WalkSpeed, aplica impulso, o inicia snap.
3. Si la acción empieza un estado con duración fija (animación comprometida),
   usar `self:_startStateTimer(duration, nextState)` para auto-transicionar al terminar.
4. Llamar `self._stateMachine:TransitionTo(targetState)` dentro del handler.
5. Si el handler necesita información del mundo (posición de pared), recibir via `data`.

---

## 2. Velocidades por Estado (Speed Map)

El servidor (`PhysicsConfig.luau`) y el cliente (`MovementController`) usan
la misma tabla de referencia definida en `Constants.luau`:

```
Estado          WalkSpeed         Notas
──────────────────────────────────────────────────────
Idle            0                 Humanoid se detiene
Walking         12                Soldado pesado (default GoW)
RoadieRun       14.4              ~1.2x walk (cámara finge más)
CoverSlide      18                Más rápido del juego
CoverIdle       6                 Movimiento lateral lento en cover
CoverAim        0                 Estático al hacer pop-out
CoverBlindFire  0                 Estático, disparando a ciegas
Evading         0 (impulse)       Velocidad por AssemblyLinearVelocity
Mantling        0                 Animación comprometida
Reloading       8                 Puede moverse lento mientras recarga
ActiveReloading 8                 Igual que Reloading
Aiming          4                 ADS: muy lento
Firing          8                 Puede moverse disparando
DBNO            3                 Rastreo muy lento
```

**Regla**: Nunca hardcodear velocidades. Siempre usar `Constants.WALK_SPEED`,
`Constants.ROADIE_RUN_SPEED`, etc.

---

## 3. Timers de Estado

Los estados con duración fija (animaciones comprometidas) usan timers
internos en `MovementController`:

```luau
-- Iniciar un timer que auto-transiciona al terminar
self:_startStateTimer(duration: number, nextState: string)

-- Cancelar un timer activo (ej: interrumpir evade con cover)
self:_cancelStateTimer()
```

Estados con timer fijo:

| Estado | Duración | Siguiente estado |
|---|---|---|
| `CoverSlide` | 0.3s | `CoverIdle` |
| `Evading` | `Constants.EVADE_DURATION` (0.6s) | `Idle` |
| `Mantling` | Depende de animación | `Idle` |
| `Executing` | Depende de animación | `Idle` |

Estos estados son **bloqueantes**: `ActionResolver` retorna `NoAction` mientras
estén activos. **No cancelar sus timers desde fuera** salvo death/DBNO.

---

## 4. Cover Snap

El cover snap es la interpolación magnética del personaje hacia la pared.
Solo `MovementController` gestiona esto.

```luau
-- Datos recibidos desde ActionResolver via Signal:
data = {
    CoverNormal: Vector3,   -- Normal de la superficie (apunta hacia adentro del cover)
    CoverPosition: Vector3, -- Punto de contacto del raycast
    CoverType: string,      -- "High" | "Low"
}

-- En Update(dt), mientras _isSnappingToCover == true:
local targetPos = data.CoverPosition + data.CoverNormal * COVER_OFFSET
hrp.CFrame = hrp.CFrame:Lerp(CFrame.new(targetPos), dt * Constants.COVER_SNAP_SPEED)
-- Parar snap cuando la distancia al target < 0.1 studs
```

**Constantes de cover** (`Constants.luau`):
- `COVER_SNAP_SPEED = 30` — multiplicador de Lerp
- `COVER_MIN_HEIGHT = 3` — menor que esto → cover bajo (se puede mantlear)
- `COVER_DETECTION_RANGE = 8` — rango de raycast del EnvironmentSensor

---

## 5. Evade Impulse

El evade no usa `WalkSpeed` — usa `AssemblyLinearVelocity` con decaimiento
exponencial:

```luau
-- Al iniciar el evade (en handler "Evade"):
local direction = data.direction or self._lastMoveDir
self._evadeVelocity = direction * Constants.EVADE_IMPULSE_SPEED  -- 30 studs/s

-- En Update(dt), mientras _evadeVelocity.Magnitude > 0.1:
self._evadeVelocity = self._evadeVelocity * (1 - dt * Constants.EVADE_DECELERATION)
hrp.AssemblyLinearVelocity = Vector3.new(
    self._evadeVelocity.X, hrp.AssemblyLinearVelocity.Y, self._evadeVelocity.Z
)
```

**Constantes**:
- `EVADE_IMPULSE_SPEED = 30` — velocidad inicial del burst
- `EVADE_DECELERATION = 4.0` — factor de decaimiento por segundo
- `EVADE_IFRAMES_DURATION = 0.25` — segundos de invulnerabilidad al inicio

---

## 6. EnvironmentSensor — Detección de Mundo

`EnvironmentSensor` hace raycasts para detectar cover y obstáculos.
Solo lee el mundo, **nunca modifica estado de juego**.

### API pública

```luau
-- Actualizar detección (llamar en Heartbeat con dirección actual)
EnvironmentSensor:Update(moveDirection: Vector3)

-- Obtener el contexto actual
EnvironmentSensor:GetContext() → EnvironmentContext
```

### EnvironmentContext (tipo en Types.luau)

```luau
type EnvironmentContext = {
    HasCoverNearby: boolean,      -- Hay cover dentro de DETECTION_RANGE
    CoverType: string?,           -- "High" | "Low" | nil
    CoverNormal: Vector3?,        -- Normal de la superficie
    CoverPosition: Vector3?,      -- Punto de contacto
    HasAdjacentCoverLeft: boolean, -- Hay cover lateral izquierdo (swat turn)
    HasAdjacentCoverRight: boolean,
    HasLowCoverAhead: boolean,    -- Cover bajo frente (puede mantlear)
    IsAtCornerLeft: boolean,      -- En esquina izquierda (peek)
    IsAtCornerRight: boolean,     -- En esquina derecha (peek)
}
```

### Raycasts que hace EnvironmentSensor

| Raycast | Dirección | Propósito |
|---|---|---|
| Frontal | `moveDir * DETECTION_RANGE` | Detect cover directo |
| Diagonal izquierda | 45° izquierda del movimiento | Cover en arco |
| Diagonal derecha | 45° derecha del movimiento | Cover en arco |
| Lateral izquierda | 90° izquierda | Adjacent cover (swat turn) |
| Lateral derecha | 90° derecha | Adjacent cover (swat turn) |
| Corner izquierda | Desde costado hacia adelante | Peek detection |
| Corner derecha | Desde costado hacia adelante | Peek detection |

### Clasificación de cover

Los objetos son cover si tienen:
- **Tag**: `CollectionService:HasTag(part, "CoverObject") == true`
- **Atributo**: `part:GetAttribute("IsCover") == true`

Altura < `Constants.COVER_MIN_HEIGHT` (3 studs) → `CoverType = "Low"` (mantleable)
Altura >= `Constants.COVER_MIN_HEIGHT` → `CoverType = "High"`

### ¿Cómo añadir un nuevo tipo de raycast? (checklist)
1. Añadir el nuevo campo booleano en `EnvironmentContext` type (`Types.luau`).
2. Añadir el raycast en `EnvironmentSensor:_performRaycasts()`.
3. Poblar el nuevo campo en `self._context` tras el raycast.
4. Usar el nuevo campo en `IntentMapper` o `ActionResolver` donde sea necesario.

---

## 7. PhysicsConfig (Servidor)

`PhysicsConfig.luau` es autoritativo. Se ejecuta en el servidor al spawn
de cada personaje. **El cliente NO modifica estas propiedades directamente.**

```luau
-- Llamado en CharacterService cuando el personaje aparece:
PhysicsConfig:ConfigureCharacter(character: Model)
-- Aplica:
--   Humanoid.WalkSpeed = 12
--   Humanoid.JumpPower = 0      (salto deshabilitado)
--   Humanoid.AutoRotate = false  (rotación manual)
--   HumanoidRootPart PhysicalProperties: Friction=2.0, Weight=100
--   workspace.Gravity = 220     (más alto que default 196.2)

-- Devuelve WalkSpeed correcto para un estado dado (usado para sincronización)
PhysicsConfig:GetSpeedForState(state: string) → number
```

El cliente puede cambiar `Humanoid.WalkSpeed` como predicción local,
pero si el servidor detecta inconsistencia, envía corrección via `ForceState`.

---

## 8. CharacterController (Fase 3)

`CharacterController` es el propietario de todos los subsistemas del personaje.

```luau
-- Escucha CharacterAdded / CharacterRemoving automáticamente
CharacterController.new(player: Player, serviceLocator: ServiceLocator)

-- Al CharacterAdded: crea MovementController, conecta todo, inicia lifecycle
-- Al CharacterRemoving: destruye todo, libera referencias
```

**Regla**: `MovementController`, `AnimationController`, y `CameraController`
son creados y destruidos **por** `CharacterController`. Nunca se crean standalone.
Esto garantiza que no haya memory leaks al respawn.
