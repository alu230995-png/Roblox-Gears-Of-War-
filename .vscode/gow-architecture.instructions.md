---
applyTo: "**/*.luau"
---

# Gears of War — Roblox Clone: Arquitectura y Reglas de Proyecto

> **Archivo de solo lectura.** No modificar sin revisión del lead. Define la filosofía,
> arquitectura objetivo y reglas de trabajo del proyecto.

---

## 1. Arquitectura Actual (Estado Real del Proyecto)

### Descripción

El proyecto implementa un **pipeline de input de 5 capas** en el cliente con un servidor
mínimo. La comunicación entre sistemas es por **llamadas directas** entre instancias,
no por eventos.

```
CLIENT (StarterPlayerScripts)
│
├── ClientInit.client.luau          ← Orquestador + registro de callbacks de FSM (mezclado)
│   └── Heartbeat (7 pasos en orden):
│       1. EnvironmentSensor:Update(moveDir)
│       2. IntentMapper:Update()              → activeIntents
│       3. InputBuffer:PushFromIntents()
│       4. InputBuffer:CleanExpired()
│       5. ActionResolver:Resolve()           → action, targetState, data
│       6. MovementController:ExecuteAction()
│       7. MovementController:Update(dt)
│       8. StateMachine:Update(dt)
│
├── Input/
│   ├── InputDetector.luau          Capa 1 — UIS raw → event queue + polling WASD
│   ├── IntentMapper.luau           Capa 2 — eventos + env → intenciones semánticas
│   └── InputBuffer.luau            Capa 3 — TTL buffering (120ms cover, 80ms evade...)
│
├── ActionResolver.luau             Capa 5 — intent + FSM state + env → una sola acción
├── EnvironmentSensor.luau          — Raycast: cover nearby, type, normal, corners, mantle
└── MovementController.luau         — Ejecutor: AssemblyLinearVelocity, WalkSpeed,
                                      cover snap, rotación, timers de estados

SERVER (ServerScriptService)
├── ServerInit.server.luau          ← Llama PhysicsConfig.Initialize()
└── Utils/
    └── PhysicsConfig.luau          — Gravity, Humanoid config at spawn, PhysicalProperties

SHARED (ReplicatedStorage)
├── Constants.luau                  — Todos los valores numéricos GoW
├── Types.luau                      — Tipos Luau exportados
├── StateMachine.luau               — FSM genérica: 15 estados, transiciones, lock/unlock
├── Signal.luau                     — Observer mínimo (sin uso activo aún)
└── Enums/
    └── PlayerState.luau            — 15 estados + propiedades + tabla de transiciones
```

### Problemas identificados en la arquitectura actual

| # | Nivel | Problema |
|---|-------|----------|
| 1 | Mayor | `ClientInit` actúa como orquestador Y registra callbacks de FSM inline — mezcla boot con lógica |
| 2 | Mayor | `MovementController` tiene 5 responsabilidades: física, cover snap, rotación, dispatch de acciones, timers |
| 3 | Mayor | No existe `CharacterController` — no hay manejo de respawn ni cleanup de conexiones |
| 4 | Mayor | `Signal.luau` existe pero ningún sistema lo usa — todos se comunican por llamadas directas |
| 5 | Mayor | El servidor no valida nada — sin red, sin RemoteEvents, sin anti-exploit |
| 6 | Menor | `DEBUG_MODE = true` hardcodeado en el entry point |
| 7 | Menor | Los sistemas se construyen directamente en `ClientInit` — sin lifecycle `Init → Start` |
| 8 | Menor | No existe cámara ni animaciones — sus callbacks en FSM están vacíos |

---

## 2. Arquitectura Objetivo (Profesional)

### Filosofía de diseño

Un juego de producción en Roblox no escala con un archivo orquestador que lo sabe todo.
Cada capa debe ser **ciega a las capas adyacentes** y comunicarse exclusivamente por
contratos bien definidos (Signals o interfaces estables). Nadie "tira del hilo" de otro.

```
PRINCIPIOS
  1. Single Responsibility  — un módulo, una razón para cambiar
  2. Lifecycle explícito    — Init() sin side-effects, Start() con conexiones
  3. Event-driven           — Signal para comunicación entre sistemas
  4. Character ownership    — CharacterController crea/destruye subsistemas al respawn
  5. Server authority       — toda la lógica de gameplay se valida en el servidor
  6. No acoplamiento directo entre capas sin pasar por un contrato
```

### Estructura de archivos objetivo

```
src/
│
├── client/
│   ├── ClientApp.client.luau           ← Entry point - solo bootstrapping
│   │
│   ├── Core/
│   │   └── ServiceLocator.luau         ← Registry singleton de todos los sistemas
│   │
│   ├── Character/
│   │   ├── CharacterController.luau    ← Owner de todos los subsistemas del personaje
│   │   │                                 Escucha CharacterAdded/Removing → Init y Destroy
│   │   ├── MovementSystem.luau         ← Solo física: AssemblyLinearVelocity, WalkSpeed
│   │   ├── RotationSystem.luau         ← Solo rotación: cover, aim, movimiento libre
│   │   └── CoverSystem.luau            ← Cover snap, entrada, salida, corners
│   │
│   ├── Input/
│   │   ├── InputDetector.luau          ← Sin cambios — ya cumple SRP
│   │   ├── IntentMapper.luau           ← Sin cambios
│   │   └── InputBuffer.luau            ← Sin cambios
│   │
│   ├── World/
│   │   └── EnvironmentSensor.luau      ← Sin cambios — ya cumple SRP
│   │
│   ├── Gameplay/
│   │   └── ActionResolver.luau         ← Sin cambios — ya cumple SRP
│   │
│   ├── Camera/
│   │   └── CameraController.luau       ← FOV, camera bob, ADS, cover lean
│   │
│   ├── Animation/
│   │   └── AnimationController.luau    ← AnimationTrack por estado FSM
│   │
│   └── Network/
│       └── ClientNetwork.luau          ← Encapsula todos los RemoteEvent:FireServer
│
├── server/
│   ├── ServerApp.server.luau           ← Entry point - solo bootstrapping
│   │
│   ├── Character/
│   │   └── CharacterService.luau       ← Spawn, respawn, PhysicsConfig
│   │
│   ├── Combat/
│   │   ├── CombatService.luau          ← Daño autoritativo, health, kill feed
│   │   └── WeaponService.luau          ← Ammo, fire rate, hit validation
│   │
│   └── Network/
│       └── ServerNetwork.luau          ← Handlers de RemoteEvents con validación completa
│
└── shared/
    ├── Constants.luau                  ← Sin cambios
    ├── Types.luau                      ← Expandir: WeaponConfig, CombatResult, NetworkPayload
    ├── Signal.luau                     ← Usado activamente por todos los sistemas
    ├── Enums/
    │   ├── PlayerState.luau            ← Sin cambios
    │   └── WeaponType.luau             ← Lancer, Gnasher, Longshot, Torque Bow...
    └── Utils/
        └── StateMachine.luau           ← Sin cambios
```

### Cómo funciona el bootstrap

```
ClientApp.client.luau
  │
  ├── ServiceLocator:Register("InputDetector", InputDetector.new())
  ├── ServiceLocator:Register("EnvironmentSensor", EnvironmentSensor.new())
  ├── ServiceLocator:Register("StateMachine", StateMachine.new(...))
  ├── ServiceLocator:Register("InputBuffer", InputBuffer.new())
  ├── ServiceLocator:Register("IntentMapper", IntentMapper.new(...))
  ├── ServiceLocator:Register("ActionResolver", ActionResolver.new(...))
  ├── ServiceLocator:Register("CharacterController", CharacterController.new(...))
  ├── ServiceLocator:Register("CameraController", CameraController.new(...))
  │
  ├── -- FASE 1: Init (sin side-effects, sin conexiones)
  │   for each service → service:Init()
  │
  └── -- FASE 2: Start (conecta signals, arranca heartbeat)
      for each service → service:Start()
```

### Cómo CharacterController maneja el respawn

```lua
-- CharacterController:Start()
Players.LocalPlayer.CharacterAdded:Connect(function(character)
    self:_destroySubsystems()     -- Limpia conexiones del personaje anterior
    self:_createSubsystems(character)  -- Crea MovementSystem, RotationSystem, CoverSystem
    -- Cada subsistema recibe el character como argumento, no lo busca globalmente
end)
```

### Cómo se comunican los sistemas (Signal en vez de llamadas directas)

```
ANTES (acoplamiento directo):
  ClientInit ────calls────► MovementController:ExecuteAction()
  MovementController ──calls──► StateMachine:TransitionTo()

DESPUÉS (event-driven):
  ActionResolver ──fires──► Signals.ActionResolved(action, targetState, data)
  MovementSystem  ──listens──► Signals.ActionResolved → aplica física
  AnimationController ──listens──► Signals.ActionResolved → reproduce animación
  CameraController ──listens──► Signals.ActionResolved → ajusta FOV/bob
  StateMachine ──listens──► Signals.ActionResolved → transiciona estado
```

Todos escuchan el mismo evento. Ninguno sabe que los otros existen.

### Heartbeat en la arquitectura objetivo

```
RunService.Heartbeat:
  1. InputDetector es event-driven (UIS connections), no necesita Update
  2. EnvironmentSensor:Update(dt)
  3. IntentMapper:Update()         → fires Signals.IntentsUpdated
  4. InputBuffer:Update()          → consume TTLs
  5. ActionResolver:Resolve()      → fires Signals.ActionResolved
  -- Los sistemas reaccionan al Signal, no son llamados secuencialmente
```

### Red cliente-servidor (contrato de validación)

```
CLIENTE                                    SERVIDOR
  ClientNetwork:RequestFire(weaponId) ──►  ServerNetwork:_onFireRequest(player, weaponId)
                                             WeaponService:ValidateFire(player, weaponId)
                                               ✓ ¿tiene esa arma?
                                               ✓ ¿tiene munición?
                                               ✓ ¿rate of fire respetado?
                                               ✓ ¿jugador está vivo?
                                             CombatService:ProcessHit(...)
                                               → Authoritative damage
                                  ◄──────  ClientNetwork:OnHitConfirmed(result)
```

**Regla absoluta**: el cliente NUNCA modifica HP, munición ni estado de inventario.
Solo genera predicciones visuales y espera confirmación del servidor.

---

## 3. Reglas del Proyecto

### Reglas de código (no negociables)

```
REGLA 01 — Nomenclatura
  Clases/Módulos:    PascalCase       → CharacterController, CoverSystem
  Métodos públicos:  PascalCase       → character:TakeDamage(), weapon:Fire()
  Métodos privados:  _camelCase       → self:_applyImpulse(), self:_cleanConnections()
  Variables locales: camelCase        → currentAmmo, coverNormal, evadeSpeed
  Constantes:        UPPER_SNAKE_CASE → MAX_HEALTH, EVADE_IMPULSE_SPEED
  Tipos:             PascalCase       → WeaponConfig, CoverContext, NetworkPayload
  Los nombres revelan intención. Sin abreviaciones: no "dm", no "flag", no "tmp"

REGLA 02 — Single Responsibility
  Un módulo resuelve UN problema. Si describes lo que hace con "y también...", se divide.
  MovementSystem solo mueve. RotationSystem solo rota. No cruzar.

REGLA 03 — Lifecycle
  Todo sistema tiene Init() y Start(). Init() no crea conexiones ni tiene side-effects.
  Start() crea conexiones. Destroy() las limpia todas.
  Nunca dejar conexiones huérfanas al respawn.

REGLA 04 — Sin estado global
  Prohibido _G y module-level mutable state fuera de clases.
  Si se necesita un singleton, registrarlo en ServiceLocator.

REGLA 05 — Seguridad cliente-servidor
  El cliente predice. El servidor decide.
  Toda lógica que toca HP, ammo, kill, inventory, puntuación → servidor.
  Todo RemoteEvent del cliente se valida en el servidor: tipo, rango, rate, ownership.
  El cliente nunca recibe de vuelta información que no le corresponde.

REGLA 06 — Signal para comunicación entre sistemas
  Los sistemas no se llaman directamente entre capas no adyacentes.
  Usan Signals definidos en un contrato compartido.
  Excepción: sistemas en la misma capa (ej: MovementSystem puede leer StateMachine).

REGLA 07 — Sin magia de timing
  No usar task.wait() para sincronizar lógica de gameplay. Usar timers explícitos
  (el patrón _stateTimer + _stateTimerCallback del proyecto es correcto).
  task.wait() solo para inicialización (WaitForChild) o efectos visuales no críticos.

REGLA 08 — Sin frameworks externos
  Solo Luau nativo y servicios de Roblox. Sin dependencias de npm/wally que no sean
  aprobadas por el lead. El proyecto debe funcionar con Rojo + rokit solamente.

REGLA 09 — Debug controlado
  DEBUG_MODE debe ser una constante en Constants.luau, no un literal booleano.
  En builds de producción debe ser false por defecto.
  No dejar print() permanentes en rutas de Heartbeat — destruyen performance.

REGLA 10 — Física en el cliente
  Para predicción del cliente usar AssemblyLinearVelocity directamente en HumanoidRootPart.
  No usar humanoid:Move() + WalkSpeed para impulsos — el PlayerModule puede sobreescribirlo.
  WalkSpeed se usa únicamente para velocidad sostenida (Walking, RoadieRun base, Cover).
  Evade, empujones, knockback → siempre AssemblyLinearVelocity.
```

### Reglas de arquitectura

```
ARQREG 01 — La carpeta client/ no tiene lógica autoritativa de gameplay.
            Solo predicción, visualización e input.

ARQREG 02 — La carpeta server/ no tiene lógica de input ni UI.

ARQREG 03 — La carpeta shared/ no tiene referencias a client/ ni server/.
            Shared solo puede depender de sí mismo.

ARQREG 04 — No hay dependencias circulares. Si A requiere B y B requiere A,
            uno de los dos está mal diseñado — extraer la dependencia común a shared/.

ARQREG 05 — CharacterController es el único dueño del personaje en el cliente.
            Ningún otro sistema guarda referencias directas al Model del personaje
            más allá de su propio frame de Update.

ARQREG 06 — El Heartbeat central (en ClientApp o CharacterController) es el único
            lugar donde se llama Update(dt) de los sistemas. Dos Heartbeats
            compitiendo sobre el mismo personaje es un bug de arquitectura.
```

### Orden de implementación sugerido (fases)

```
✅  Fase 1 — Input System 5 capas (COMPLETA)
✅  Fase 2 — StateMachine + EnvironmentSensor + MovementController básico (COMPLETA)
🔄  Fase 3 — Refactor: CharacterController + lifecycle Init/Start + Signal-driven
⬜  Fase 4 — AnimationController (tracks por estado FSM)
⬜  Fase 5 — CameraController (FOV, bob, ADS, cover lean)
⬜  Fase 6 — Red: ClientNetwork + ServerNetwork + CombatService base
⬜  Fase 7 — WeaponSystem: Lancer, Gnasher (fire, reload, active reload)
⬜  Fase 8 — DBNO + Execution system
⬜  Fase 9 — Horde Mode / Multiplayer
```

---

## 4. Valores de referencia GoW (recordatorio rápido)

| Constante | Valor | Nota |
|-----------|-------|------|
| `WALK_SPEED` | 12 | Deliberadamente lento (soldado con 40kg de equipo) |
| `ROADIE_RUN_SPEED` | 14.4 | Solo 1.2x walk — la cámara finge más velocidad |
| `COVER_SLIDE_SPEED` | 18 | La velocidad MÁS rápida del juego |
| `EVADE_IMPULSE_SPEED` | 30 | Burst fuerte que decae exponencialmente |
| `EVADE_DECELERATION` | 4.0 | Factor por segundo (`speed *= (1 - factor * dt)`) |
| `GRAVITY` | 220 | Default Roblox es 196.2 — más alto = más peso |
| `JUMP_POWER` | 0 | Sin salto. El mantle lo reemplaza |
| `MAX_HEALTH` | 600 | GoW tiene health pool grande como buffer de cobertura |
| `STATE_MIN_DURATION` | 0.1s | Anti-flickering entre estados |
| `COVER_SNAP_SPEED` | 30 | Studs/s del snap magnético a la pared |
