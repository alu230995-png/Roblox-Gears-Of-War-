---
name: new-mechanics
description: "Implementar, retocar, refactorizar o eliminar mecánicas de gameplay en Gears of War (Roblox/Luau). Usar cuando: crear una mecánica nueva, modificar una existente, eliminar código muerto, o reestructurar flujos de estado/input/acción manteniendo escalabilidad."
argument-hint: "Acción + mecánica (ej: 'agregar execution', 'retocar roadie run', 'eliminar código muerto en cover', 'refactorizar aiming')"
---

# Mechanics Engineering — Implementar, Retocar, Eliminar

## Cuándo usar esta skill

| Escenario | Ejemplo |
|-----------|---------|
| **Mecánica nueva** | Execution, grenade, revive, chainsaw |
| **Retocar mecánica existente** | Ajustar timings de cover, cambiar reglas de evade, tunear velocidades |
| **Eliminar código muerto** | Quitar handler obsoleto, limpiar estados no usados, remover signals huérfanas |
| **Refactorizar** | Extraer sub-handler, reorganizar reglas, mejorar escalabilidad de un sistema |

---

## Arquitectura del proyecto (referencia rápida)

### Estructura de directorios

```
src/
├── client/
│   ├── Input/              → InputDetector, IntentMapper, InputBuffer, PlayerBindings, MouseInput
│   ├── Gameplay/
│   │   ├── ActionResolver/ → init.luau (coordinador), FreeStateRules, RoadieRunRules, DBNORules, Helpers
│   │   │   └── CoverRules/ → init.luau, AimRules, MovementRules, SharedRules, TransitionRules
│   │   └── Aiming/         → AimingController, AimAngleUtil
│   ├── Character/
│   │   └── Movement/       → MovementController (coordinador), EvadeHandler, RotationHandler, SpeedMap, VaultHandler
│   │       └── Cover/      → CoverRunning, EnteringCover, CornerCover, etc., init.luau
│   ├── Weapons/            → WeaponClient (coordinador), ShootingHandler, ReloadHandler, HoldBreathHandler
│   ├── Animation/          → AnimationController
│   ├── Camera/             → CameraController
│   ├── Sound/              → SoundController, SoundPlayer, RobloxSoundDisabler
│   ├── Effects/            → EffectsController, ParticlePool, TrailPool, Blood/Muzzle/Bullet/Explosion/ScreenShake/Impact
│   ├── Core/               → ServiceLocator (DI container)
│   ├── World/              → EnvironmentSensor, RaycastUtils, SwapDetector, VaultSafety
│   ├── Spectator/          → SpectatorController
│   ├── Presentation/       → ScopeRenderer
│   └── ClientApp.client.luau  ← ENTRY POINT cliente
│
├── server/
│   ├── Character/          → CharacterService
│   ├── Combat/             → CombatService
│   ├── Respawn/            → RespawnService
│   ├── Sound/              → SoundService
│   ├── Weapons/            → WeaponServer, ShotValidator, ReloadHandler, DamageHandler, HealthStateManager, ServerRaycast
│   ├── Utils/              → PhysicsConfig
│   └── ServerApp.server.luau  ← ENTRY POINT servidor
│
└── shared/
    ├── Enums/              → PlayerState, WeaponState, WeaponType, SoundGroup, SoundScope
    ├── Utils/              → StateMachine (HSM), PlayerStateUtils
    ├── Signal.luau         → Sistema de eventos (Connect/Once/Fire/Disconnect)
    ├── Types.luau          → Definiciones de tipos
    ├── Constants.luau      → Constantes generales
    ├── SoundConfig.luau    → Registro de sonidos
    ├── WeaponConstants.luau
    ├── EffectsConfig.luau / EffectsConstants.luau
    ├── BallisticsUtils.luau
    └── CharacterModifier.luau
```

### Patrones fundamentales

**1. Dependency Injection via ServiceLocator**
```lua
-- ClientApp.client.luau registra todos los servicios
locator:Register("ActionResolver", actionResolver)
locator:InitAll()   -- Fase 1: setup sin side-effects
locator:StartAll()  -- Fase 2: wiring de conexiones
```

**2. Módulos tipo clase (constructor pattern)**
```lua
local Module = {}
Module.__index = Module

function Module.new(dep1, dep2) -- DI por constructor
    local self = setmetatable({
        _connections = {},  -- SIEMPRE: tabla para limpiar conexiones
    }, Module)
    return self
end

function Module:Init() end   -- setup sin side-effects
function Module:Start() end  -- wiring de conexiones
function Module:Destroy()    -- limpieza obligatoria
    for _, conn in self._connections do conn:Disconnect() end
end
```

**3. Comunicación por Signal (nunca polling)**
```lua
-- Emisor
self.ActionResolved = Signal.new()  -- declarar en constructor
self.ActionResolved:Fire(action, targetState, data)  -- emitir

-- Receptor
table.insert(self._connections, emitter.ActionResolved:Connect(function(action, state, data)
    -- manejar
end))
```

**4. Estado jerárquico (HSM con grupos)**
```
Groups: AliveGroup > FreeMovementGroup, CoverGroup, ActionGroup
                   > DBNOGroup
        InactiveGroup
```
Las transiciones se declaran a nivel de grupo y los hijos las heredan. El HSM recuerda el último sub-estado activo por grupo.

---

## Pipeline de una mecánica (flujo completo)

```
Hardware Input (tecla/botón/touch)
  → InputDetector          (Capa 1: raw events)
    → IntentMapper         (Capa 2: raw → intent semántico, ej: "WantsCover")
      → InputBuffer        (Capa 3: TTL buffering, previene pérdida entre frames)
        → ActionResolver   (Capa 4: intent + state + environment → acción)
          ├→ MovementController / WeaponClient  (handler ejecuta lógica)
          ├→ StateMachine                       (transición de estado)
          ├→ AnimationController                (via Signal StateChanged)
          ├→ SoundController                    (via Signal StateChanged)
          ├→ EffectsController                  (via Signal específica)
          └→ RemoteEvent al servidor            (si afecta a otros jugadores)
```

---

## A. IMPLEMENTAR MECÁNICA NUEVA

### Paso 1: Diseñar el estado

1. **¿Requiere nuevo `PlayerState`?** → Añadir en `src/shared/Enums/PlayerState.luau`
   - Definir `validTransitions` desde y hacia el nuevo estado
   - Asignar al grupo HSM correcto (FreeMovementGroup, CoverGroup, ActionGroup, DBNOGroup)
   - Si es sub-estado de uno existente (ej: `CoverAiming` dentro de CoverGroup), no crear estado de primer nivel
2. **Actualizar `PlayerStateUtils.luau`** si el nuevo estado necesita clasificación (isMoving, isAiming, etc.)

### Paso 2: Registrar input (si el jugador lo activa)

1. **Keybinding** → Añadir entrada en `src/client/Input/PlayerBindings.luau`
2. **Intent semántico** → Mapear raw → intent en `src/client/Input/IntentMapper.luau`
3. **Buffer TTL** → Definir duración en `src/client/Input/InputBuffer.luau` (si es bufferable)

### Paso 3: Escribir regla en ActionResolver

Ubicación según estado actual del jugador:

| Estado actual | Archivo de reglas |
|---------------|-------------------|
| En pie (libre) | `src/client/Gameplay/ActionResolver/FreeStateRules.luau` |
| Roadie Run | `src/client/Gameplay/ActionResolver/RoadieRunRules.luau` |
| En cobertura | `src/client/Gameplay/ActionResolver/CoverRules/*.luau` |
| Caído (DBNO) | `src/client/Gameplay/ActionResolver/DBNORules.luau` |
| Estado nuevo | Crear `*Rules.luau` en `ActionResolver/` y registrar en `init.luau` |

**Formato de regla (table-driven):**
```lua
{
    id = "NombreAccion",
    check = function(_resolver, ctx)
        return ctx.Buffer:HasIntent("WantsX")
            and ctx.Env.condicion
            and ctx.StateConfig.permisoRelevante
    end,
    execute = function(_resolver, ctx)
        ctx.Buffer:Consume("WantsX")
        return "NombreAccion", "TargetState", { data }
    end,
}
```

- Insertar en la **posición de prioridad correcta** dentro del array (primera regla que pasa gana)
- La regla es **pura**: sin side-effects, sin allocaciones innecesarias

### Paso 4: Implementar handler (cliente)

- **Movimiento** → Handler en `src/client/Character/Movement/` (sub-directorio si es complejo)
  - MovementController orquesta: escucha `ActionResolved`, delega al handler apropiado
- **Armas** → Handler en `src/client/Weapons/`
  - WeaponClient orquesta: misma lógica de delegación
- **Patrón obligatorio:**
  ```lua
  function Handler.new(dependencies)
      local self = setmetatable({ _connections = {} }, Handler)
      return self
  end
  function Handler:Start()
      -- wiring de signals aquí
  end
  function Handler:Destroy()
      for _, c in self._connections do c:Disconnect() end
  end
  ```
- **Registrar** en ServiceLocator si es un servicio nuevo, o inyectar en el coordinador existente

### Paso 5: Servidor — validar y replicar

1. **Handler** → Crear en `src/server/` bajo el directorio semántico correcto (Combat/, Character/, Weapons/)
2. **Validar** precondiciones server-side: cooldown, estado, distancia, rate-limiting
3. **Replicar** resultado a otros clientes via RemoteEvent si es necesario
4. **Registrar** en `ServerApp.server.luau` siguiendo el patrón Init/Start existente

### Paso 6: Animación, sonido y efectos

- **Animación** → `src/client/Animation/AnimationController.luau`: escucha `StateChanged` o Signal específica
- **Sonido** → Registrar entradas en `src/shared/SoundConfig.luau`, `SoundController` escucha signals
- **Efectos** → Registrar en `src/shared/EffectsConfig.luau`, `EffectsController` maneja via signals

---

## B. RETOCAR MECÁNICA EXISTENTE

### Protocolo de modificación segura

1. **Diagnóstico primero**: Leer los archivos involucrados ANTES de proponer cambios
   - Identificar todas las señales (Signals) que emite y escucha el módulo
   - Mapear qué otros módulos dependen de él (buscar `require` y `:Connect`)
   - Leer las reglas del ActionResolver que activan la mecánica

2. **Clasificar el cambio:**

| Tipo de cambio | Impacto | Precauciones |
|----------------|---------|--------------|
| **Tunear valores** (velocidad, cooldown, TTL) | Bajo | Solo tocar Constants/Config. No requiere cambios estructurales |
| **Cambiar condiciones** (reglas de activación) | Medio | Verificar que no rompe prioridad de otras reglas en el array |
| **Modificar transiciones** (nuevo estado destino) | Alto | Actualizar `validTransitions` en PlayerState + verificar que el estado destino maneja la entrada |
| **Cambiar API de un módulo** (firma de método, nueva Signal) | Alto | Buscar TODOS los call-sites con Grep antes de modificar |

3. **Ejecutar el cambio:**
   - Para valores: editar la constante en su archivo de configuración correspondiente
   - Para lógica: modificar el handler/regla específica, no el coordinador
   - Para API: actualizar todos los consumidores en el mismo commit

4. **Verificar integridad:**
   - Grep por el nombre de la Signal/método modificado → confirmar que todos los receptores siguen compatibles
   - Revisar que `_connections` sigue limpiando todo en `Destroy()`

---

## C. ELIMINAR CÓDIGO MUERTO

### Protocolo de eliminación segura

1. **Identificar candidato**: código que se sospecha sin uso (handler, estado, signal, regla)

2. **Verificar que es muerto** (los 3 checks son obligatorios):
   ```
   a) Grep por el nombre del export/función/signal en TODO el proyecto
   b) Grep por el nombre del archivo (sin extensión) en requires
   c) Si es un PlayerState: grep en validTransitions, ActionResolver rules, y StateMachine callbacks
   ```

3. **Categoría de eliminación:**

| Qué eliminar | Cómo |
|--------------|------|
| **Módulo completo** | Borrar archivo + require en coordinador/ServiceLocator + entrada en Rojo project si aplica |
| **PlayerState no usado** | Quitar de Enums + quitar de validTransitions + quitar reglas asociadas en ActionResolver |
| **Signal huérfana** | Quitar declaración + quitar todos los `:Connect` y `:Fire` |
| **Regla de ActionResolver** | Quitar del array de reglas. Verificar que no hay intent que queda sin consumir |
| **Handler obsoleto** | Quitar del coordinador + quitar registro en ServiceLocator + quitar conexiones |
| **Constante no referenciada** | Quitar de Constants/Config correspondiente |

4. **Post-eliminación**: Verificar que ningún `require` quedó roto (grep por el nombre del módulo eliminado)

---

## D. REFACTORIZAR PARA ESCALABILIDAD

### Cuándo extraer

- Un handler tiene >200 líneas → extraer sub-handlers por responsabilidad
- Un archivo de reglas tiene >10 reglas → subdividir por categoría (como CoverRules/)
- Un coordinador maneja >5 handlers → evaluar si alguno puede ser servicio independiente

### Patrón de extracción segura

1. **Crear el nuevo módulo** siguiendo el constructor pattern (`.new()` + `Init/Start/Destroy`)
2. **Mover la lógica** sin cambiar comportamiento (refactor puro, sin features nuevas)
3. **Inyectar como dependencia** en el coordinador existente
4. **Verificar**: mismas señales emitidas, mismos estados alcanzados, misma limpieza en Destroy

### Reglas de escalabilidad

- **Un archivo = una responsabilidad**. Si tiene "and" en la descripción, considerar split
- **Nuevas mecánicas no modifican coordinadores** — solo agregan handlers/reglas que los coordinadores descubren
- **Config separada de lógica** — valores tuneables en `shared/` (Constants, Config), lógica en `client/` o `server/`
- **Signal como contrato** — cambiar la firma de una Signal es un breaking change; agregar una Signal nueva no lo es

---

## Checklist universal (aplica a TODO cambio)

### Antes del cambio
- [ ] Leí los archivos que voy a modificar
- [ ] Identifiqué qué Signals se emiten/escuchan
- [ ] Identifiqué qué módulos dependen del código que voy a tocar (grep require + Connect)

### Durante el cambio
- [ ] Sin allocaciones por frame (`{}`, `.new()`) en hot-path (Update/Heartbeat)
- [ ] Todas las conexiones van a `self._connections` y se limpian en `Destroy()`
- [ ] Validación autoritativa en servidor, predicción visual en cliente
- [ ] Comunicación por Signal, nunca polling
- [ ] Reglas de ActionResolver son funciones puras (sin side-effects en `check`)

### Después del cambio
- [ ] Grep por nombres de módulos/Signals modificados → ningún receptor roto
- [ ] Si añadí estado: `validTransitions` completas (entrada Y salida)
- [ ] Si eliminé código: ningún `require` roto, ningún `:Connect` huérfano
- [ ] El cambio es **aditivo** cuando es posible (agregar, no reescribir)

---

## Referencia rápida de constructores

```lua
-- Input
InputDetector.new()
IntentMapper.new(inputDetector, bindings?)  -- bindings default: PlayerBindings.DEFAULT
InputBuffer.new()

-- Gameplay
ActionResolver.new(stateMachine, inputBuffer, intentMapper, environmentSensor)
AimingController.new(...)

-- Movement
MovementController.new(stateMachine, actionResolver, environmentSensor)

-- Weapons
WeaponClient.new(player, tool)
-- Luego: wc:Init(stateMachine, actionExecutedSignal, ScopeRendererClass)
--         wc:Start()

-- Audio/Visual
SoundController.new(stateMachine)
AnimationController.new(...)
CameraController.new(stateMachine, movementController.ActionExecuted, mouseInput)
EffectsController.new(...)
```

## Señales principales (bus de comunicación)

| Signal | Emisor | Consumidores típicos |
|--------|--------|---------------------|
| `ActionResolver.ActionResolved` | ActionResolver | MovementController, AnimationController, CameraController |
| `StateMachine.StateChanged` | StateMachine | SoundController, HealthObserver, AnimationController |
| `MovementController.ActionExecuted` | MovementController | AnimationController, CameraController, AimingController |
| `WeaponClient.ShotFired` | WeaponClient | CameraController, EffectsController |
| `WeaponClient.WeaponEquipped` | WeaponClient | EffectsController |
| `CoverHandler.CoverSettleChanged` | CoverHandler | CameraController |
| `CoverHandler.ShoulderSideChanged` | CoverHandler | CameraController |
