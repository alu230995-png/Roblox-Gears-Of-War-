# Máquina de Estados Híbrida (HSM) — Diseño y Plan de Implementación

Este documento define cómo evolucionará la `StateMachine` actual (FSM plana)
hacia una **Hierarchical State Machine (HSM)** que soporte estados híbridos,
jerarquía padre-hijo, y regiones paralelas opcionales.

---

## Sección 1: Cómo Funcionan las Hierarchical State Machines

### 1.1 Concepto Fundamental

Una **Finite State Machine (FSM)** plana (como la actual) tiene N estados
todos al mismo nivel. Una **Hierarchical State Machine (HSM)** organiza esos
estados en una jerarquía de árbol, donde los estados padres contienen
subestados hijos.

```
FSM Plana (actual):
  Idle, CoverIdle, CoverAim, CoverBlindFire, Evading, DBNO...
  (15 estados al mismo nivel, todos se conocen entre sí)

HSM (propuesta):
  AliveGroup
  ├── FreeMovement
  │   ├── Idle
  │   ├── Walking
  │   ├── RoadieRun
  │   ├── Aiming
  │   ├── Firing
  │   ├── Reloading
  │   └── ActiveReloading
  ├── CoverGroup
  │   ├── CoverIdle
  │   ├── CoverAim
  │   ├── CoverBlindFire
  │   └── CoverSlide
  └── TransitionAction
      ├── Evading
      └── Mantling
  DBNO
  Executing
```

### 1.2 Herencia de Transiciones

En una HSM, un estado hijo **hereda** las transiciones del padre. Si `AliveGroup`
tiene una transición hacia `DBNO`, entonces `Idle`, `Walking`, `CoverIdle`
y todos sus estados hijos heredan automáticamente esa transición sin que
haya que declararla 15 veces.

```
Ejemplo de herencia:
  AliveGroup → DBNO          (definida una vez en el padre)
  ↓ hereda automáticamente:
  Idle → DBNO                (via herencia)
  CoverIdle → DBNO           (via herencia)
  Evading → DBNO             (via herencia)
  ... todos los hijos de AliveGroup
```

Sin herencia (FSM actual), `DBNO` debe estar en la tabla de transiciones
de cada uno de los 14 estados — 14 entradas redundantes.

### 1.3 Entry y Exit Jerárquicos

En una HSM, al entrar a un subestado se ejecutan las callbacks en orden
**top-down**: del padre al hijo.

```
Transición Walk → CoverIdle:

  Exit(Walk)               ← salida del estado hijo
  Exit(FreeMovement)       ← salida del grupo padre (si cambiamos de grupo)
  Enter(CoverGroup)        ← entrada al nuevo grupo padre
  Enter(CoverIdle)         ← entrada al estado hijo destino
```

Esto permite que `CoverGroup.OnEnter` configure propiedades compartidas
de todos los estados de cover (ej: activar la cámara de cover) sin
duplicar esa lógica en cada subestado (CoverIdle, CoverAim, CoverBlindFire).

### 1.4 History States

Un **History State** recuerda cuál subestado estaba activo la última vez
que se salió de un grupo. Permite regresar al "estado anterior" sin
hardcodear la lógica en todas partes.

```
Ejemplo sin History:
  Jugador en CoverAim → recibe daño → entra en Stagger animation
  → al terminar el Stagger, ¿a qué estado vuelve? Hay que decidirlo
    en cada posible origen.

Con History State:
  CoverGroup tiene un HistoryState.
  Al salir de CoverAim, CoverGroup.History = "CoverAim"
  Al volver a CoverGroup → va directo a CoverGroup.History (CoverAim)
```

### 1.5 Regiones Paralelas (Orthogonal Regions)

Las regiones paralelas permiten que el personaje esté en **dos estados
simultáneamente** en diferentes "dimensiones" independientes.

```
Región A: Locomotion     Región B: WeaponStatus
──────────────────       ────────────────────────
Walking              ‖   Idle (no recargando)
Walking              ‖   Reloading ← puede recargar mientras camina
CoverIdle            ‖   ActiveReloading
RoadieRun            ‖   Idle (no puede recargar corriendo = blocked)
```

La región B "WeaponStatus" puede estar activa independientemente de la
región A "Locomotion", pero con restricciones (RoadieRun bloquea Reloading).

---

## Sección 2: Limitaciones del FSM Actual

### 2.1 State Explosion

El FSM actual tiene 15 estados planos. A medida que se añaden mecánicas
(por ejemplo, añadir `Staggered`, `Sprinting_WithShield`, `PeekLeft`,
`PeekRight`), el número de estados crece y la tabla de transiciones explota
combinatoriamente.

Con la FSM actual: si añadimos 5 estados nuevos que todos pueden transicionar
a `DBNO`, hay que añadir `DBNO` a la lista de transiciones de los 5 nuevos
estados manualmente.

### 2.2 DBNO Listado 14 veces

En `PlayerState.luau`, la transición a `DBNO` aparece en la tabla de cada
uno de los 14 estados que son "alive". Esto es redundante y frágil — si
se añade un nuevo estado alive, hay que recordar añadirle `DBNO` manualmente.

```luau
-- PlayerState.luau actual (fragmento):
Transitions = {
    Idle            = { ... "DBNO" ... },
    Walking         = { ... "DBNO" ... },  -- ← duplicado
    RoadieRun       = { ... "DBNO" ... },  -- ← duplicado
    CoverIdle       = { ... "DBNO" ... },  -- ← duplicado
    -- ...× 14
}
```

### 2.3 No hay Recarga durante Movimiento

Con la FSM plana, el jugador está en `Reloading` O en `Walking` — no en ambos.
En GoW, el jugador puede recargar mientras camina lentamente. Esto requiere
regiones paralelas para modelarse correctamente.

### 2.4 Comportamiento Compartido Duplicado

Todos los estados de cover (CoverIdle, CoverAim, CoverBlindFire) comparten
comportamiento: la cámara debe estar en "cover perspective", el ADS reticle
debe mostrarse diferente, la protección de daño aplica. En la FSM plana,
esta lógica se duplica en cada uno de los tres estados o se hace con `if state == "CoverIdle" or state == "CoverAim" or...`.

Con un estado padre `CoverGroup`, esto se escribe una sola vez.

### 2.5 Árbol de Prioridades en ActionResolver es Frágil

El `ActionResolver` actual tiene una rama `if state == "CoverIdle" or state == "CoverAim" or state == "CoverBlindFire"` para agrupar la resolución
de estados de cover. Con una HSM, se puede preguntar `isInGroup("CoverGroup")`
directamente.

---

## Sección 3: Diseño Propuesto — HybridStateMachine para GoW

### 3.1 Jerarquía de 3 Niveles

```
Nivel 0 (Root Groups)
├── AliveGroup          ← Todo estado "vivo" hereda de aquí
│
│   Nivel 1 (Sub-groups dentro de Alive)
│   ├── FreeMovementGroup    ← Movimiento libre, sin cobertura
│   ├── CoverGroup           ← En cover (cualquier tipo)
│   └── ActionGroup          ← Acción comprometida (animación bloqueante)
│
│   Nivel 2 (Estados hoja — los 15 existentes redistribuidos)
│   ├── [bajo FreeMovementGroup]
│   │   ├── Idle
│   │   ├── Walking
│   │   ├── RoadieRun
│   │   ├── Aiming
│   │   └── Firing
│   ├── [bajo CoverGroup]
│   │   ├── CoverIdle
│   │   ├── CoverAim
│   │   ├── CoverBlindFire
│   │   └── CoverSlide
│   └── [bajo ActionGroup]
│       ├── Evading
│       └── Mantling
│
├── DBNO                ← Estado raíz (no es hijo de AliveGroup)
└── Executing           ← Estado raíz
```

Opcionales (nivel 2 futuras adiciones, sin romper lo existente):
```
[bajo FreeMovementGroup]
  ├── PeekLeft          ← Asomarse desde esquina izquierda
  ├── PeekRight
  └── Staggered         ← Hit reaction, interrumpe lo que estaba haciendo
[bajo CoverGroup]
  ├── SwatTurnLeft      ← Sliding entre coberturas
  └── SwatTurnRight
```

### 3.2 Herencia de Transiciones Propuesta

```
AliveGroup transiciones heredadas:
  → DBNO             (cualquier golpe mortal)
  → Executing        (enemigo ejecuta, solo desde DBNO del enemigo)

FreeMovementGroup transiciones heredadas:
  → CoverGroup       (entrar en cover en cualquier sub-estado libre)
  → ActionGroup      (iniciar evade/mantle)
  (inherits AliveGroup → DBNO, Executing)

CoverGroup transiciones heredadas:
  → FreeMovementGroup  (salir de cover)
  → ActionGroup        (evade desde cover)
  (inherits AliveGroup → DBNO, Executing)

ActionGroup transiciones heredadas:
  → FreeMovementGroup  (terminar animación → Idle)
  (inherits AliveGroup → DBNO, Executing)
  NOTE: No puede transicionar a CoverGroup durante acción bloqueante
```

### 3.3 Callbacks Jerárquicos (OnEnter/OnExit en grupos)

```
CoverGroup.OnEnter → activar cámara de cover, mostrar UI de cover
CoverGroup.OnExit  → desactivar cámara de cover, limpiar UI

CoverGroup.CoverIdle.OnEnter → posición idle en cover
CoverGroup.CoverAim.OnEnter  → pop-out aim, hacer visible el arma
CoverGroup.CoverAim.OnExit   → volver atrás del cover

FreeMovementGroup.OnEnter → restaurar cámara normal
FreeMovementGroup.OnExit  → (nada específico del grupo)
```

### 3.4 Regiones Paralelas (Locomotion ‖ WeaponStatus)

Región secundaria `WeaponStatus` para estados de arma que no afectan el
movimiento:

```
WeaponStatus Region:
  ├── WeaponIdle         ← Arma lista, sin acción de arma
  ├── Reloading          ← Recargando (puede coexistir con Walking)
  ├── ActiveReloading    ← Active Reload timing
  └── WeaponDrawing      ← Sacando/guardando arma (swap)

Restricciones entre regiones:
  Locomotion.RoadieRun   ‖ WeaponStatus.Reloading    → BLOQUEADO
  Locomotion.CoverAim    ‖ WeaponStatus.Firing        → PERMITIDO
  Locomotion.Evading     ‖ WeaponStatus.*             → BLOQUEADO (todo)
  Locomotion.Walking     ‖ WeaponStatus.Reloading     → PERMITIDO (velocidad reducida)
```

### 3.5 History State

Cada grupo tiene su propio history state para recordar el último subestado:

```
CoverGroup.History = last active child state
  Uso: al entrar a CoverGroup con historia disponible,
       ir directo al History state en vez de CoverIdle por defecto

FreeMovementGroup.History = last active child state
  Uso: al salir de un ActionGroup (Evading termina) →
       volver a Walking o Idle según lo que había antes
```

---

## Sección 4: Objetivos de Implementación

Estos son los **objetivos** de la refactorización, no el código. El agente
que implemente esto debe leer este documento como especificación.

### Objetivo 1: API Backward-Compatible
La nueva `HybridStateMachine` debe exponer la misma API que la FSM actual:
- `TransitionTo(state)` sigue funcionando igual desde el exterior
- `ForceState(state)` sigue funcionando
- `GetCurrentState()` devuelve el nombre del **estado hoja** activo (no el grupo)
- `RegisterState(name, callbacks)` sigue funcionando para estados hoja
- `StateChanged` signal sigue disparándose igual

Los sistemas existentes (`MovementController`, `ActionResolver`, `ClientInit`)
no deben necesitar cambios para usar la nueva StateMachine.

### Objetivo 2: Nuevo API para Grupos
Añadir nuevo API que no rompe lo existente:
- `RegisterGroup(groupName, callbacks, parentGroupName?)` — registrar un grupo
- `GetCurrentGroup(level?)` — obtener el grupo activo en un nivel de jerarquía
- `IsInGroup(groupName)` — check rápido para ActionResolver
- `GetHistory(groupName)` — obtener el history state de un grupo

### Objetivo 3: Herencia de Transiciones Automática
La tabla de transiciones en `PlayerState.luau` se refactoriza para
declarar transiciones en el nivel apropiado. Las transiciones heredadas
se resuelven automáticamente por la `HybridStateMachine`.

### Objetivo 4: Callbacks Jerárquicos
Cuando se produce una transición entre grupos, ejecutar los callbacks
en el orden correcto:
1. `Exit` del estado hoja origen
2. `Exit` de cada grupo padre, de child → root, hasta el ancestro común
3. `Enter` de cada grupo padre, de root → child, hasta el grupo destino
4. `Enter` del estado hoja destino

### Objetivo 5: Regiones Paralelas (WeaponStatus)
Crear una segunda región `WeaponStatus` que puede estar en su propio
subestado independientemente de la región `Locomotion` (con restricciones).
`GetCurrentState()` devuelve un struct con ambas regiones:
```
{ Locomotion = "Walking", WeaponStatus = "Reloading" }
```
Para backward compatibility, `GetCurrentState()` sin parámetros devuelve
solo el estado de Locomotion.

### Objetivo 6: Limpiar `PlayerState.luau`
Eliminar las 14+ entradas redundantes de `DBNO` en cada estado y reemplazarlas
con una sola entrada en `AliveGroup`. La tabla de transiciones resultante
debe ser significativamente más pequeña y más fácil de leer.

---

## Sección 5: Archivos a Modificar

### `shared/Utils/StateMachine.luau` — Refactor Core

**Qué cambiar**:
- Añadir soporte para `_groups`: tabla de grupos con jerarquía parent-child
- Añadir `_history`: tabla de último subestado por grupo
- Modificar `TransitionTo` para ejecutar callbacks jerárquicos (exit del
  ancestro común → enter del nuevo grupo)
- Añadir `RegisterGroup(name, callbacks, parentGroup?)`
- Añadir `IsInGroup(name)` — recorre ancestors del estado actual
- Añadir `GetHistory(groupName)`
- Segunda región: `_parallelStates` tabla con estados por región

**Qué NO tocar**:
- La API pública existente (`TransitionTo`, `ForceState`, `GetCurrentState`,
  `RegisterState`, `Lock`, `Unlock`, `StateChanged`) debe seguir igual.
- `STATE_MIN_DURATION` sigue aplicando al estado hoja, no al grupo.

**Riesgo**: Cambio fundamental en la FSM que puede romper todo si hay bugs.
Implementar en una rama separada y testear con todos los casos de cover +
evade + DBNO antes de mergear.

---

### `shared/Enums/PlayerState.luau` — Nueva Estructura Jerárquica

**Qué cambiar**:
- Añadir `Groups` tabla que define la jerarquía:
  ```luau
  PlayerState.Groups = {
      AliveGroup = { parent = nil, states = { "all leaf states" }, ... },
      FreeMovementGroup = { parent = "AliveGroup", states = {...} },
      CoverGroup = { parent = "AliveGroup", states = {...} },
      ...
  }
  ```
- Refactorizar `Transitions` para mover transiciones heredadas al grupo
  apropiado en vez de repetirlas en cada estado hoja.
- Mantener `States` tabla sin cambios — los capability flags siguen igual.

**Qué NO tocar**:
- `States` table con capability flags (canShoot, canMove, etc.) — sigue igual
- Los nombres de los 15 estados existentes — ningún renombre

---

### `client/Gameplay/ActionResolver.luau` — Usar IsInGroup

**Qué cambiar**:
- Reemplazar `if state == "CoverIdle" or state == "CoverAim" or state == "CoverBlindFire"` por `if self._stateMachine:IsInGroup("CoverGroup")`
- Usar `IsInGroup("ActionGroup")` para detectar estados bloqueantes en vez
  de la lista manual `if state == "Evading" or state == "Mantling" or ...`
- Usar `IsInGroup("AliveGroup")` en lugar de verificar que state != "DBNO"

**Qué NO tocar**:
- Los árboles de prioridad por estado — la lógica de resolución no cambia
- La API de `ActionResolved` Signal — sigue igual

---

### `shared/Types.luau` — Nuevos Tipos para HSM

**Qué añadir**:
```luau
export type StateGroup = {
    Name: string,
    Parent: string?,           -- nil si es root
    States: { string },        -- nombres de estados hoja en este grupo
}

export type HSMCallbacks = {
    OnEnter: ((fromState: string) -> ())?,
    OnExit: ((toState: string) -> ())?,
    -- No hay OnUpdate para grupos — solo para estados hoja
}

export type ParallelStateConfig = {
    Locomotion: PlayerState,         -- estado de locomoción
    WeaponStatus: WeaponState?,      -- estado de arma (opcional si no hay región)
}

export type WeaponState =
    "WeaponIdle" | "Reloading" | "ActiveReloading" | "WeaponDrawing"
```

**Qué NO tocar**:
- `PlayerState` type union — los 15 nombres siguen siendo válidos
- Todos los tipos existentes de input, environment, etc.

---

## Apéndice: Por Qué HSM y No Simplemente Más Estados

La alternativa a una HSM sería añadir más estados planos a la FSM y
gestionar la complejidad manualmente (como se hace ahora). El problema
es que la complejidad crece O(N×M) donde N es el número de estados y
M es el número de transiciones comunes. Con 15 estados actuales y ~5
transiciones globales (DBNO, Executing, Death, etc.), ya hay 75 entradas
redundantes. Con 25 estados (tras añadir peek, swat turn, stagger, etc.)
serían 125 entradas.

La HSM resuelve esto declarativamente: las transiciones globales se
declaran una sola vez en el grupo raíz apropiado.

El costo de implementación es real: la `StateMachine.luau` se vuelve
más compleja. Pero el costo se paga una sola vez, y todos los sistemas
que consumen la FSM (ActionResolver, MovementController, AnimationController,
CameraController) se simplican porque pueden preguntar por grupos en vez
de listas de estados.
