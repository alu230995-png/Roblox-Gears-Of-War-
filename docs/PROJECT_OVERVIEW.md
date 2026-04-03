# Gears of War — Roblox Studio: Visión del Proyecto

**Repositorio**: `Roblox-Gears-Of-War-`
**Motor**: Roblox Studio + Luau
**Workflow**: Rojo 7.6.1 (edición externa en VS Code)
**Fecha de inicio**: 2025

---

## ¿Qué es este proyecto?

Una reimplementación fiel de **Gears of War** dentro de Roblox Studio.
No pretende ser una copia exacta pixel-por-pixel — pretende capturar la
**sensación** del juego: movimiento pesado, cobertura táctica, combate
tenso y mecánicas de habilidad (Active Reload, Chainsaw).

El project está diseñado con arquitectura de producción desde el inicio:
separación cliente/servidor, input en capas, server authority, y signal-driven
communication. No hay dependencias externas (sin Knit, sin Roact, sin Janitor).
Todo el código es Luau puro con las APIs nativas de Roblox.

---

## Mecánicas de Gears of War Implementadas / Planeadas

### Cover System (cobertura táctica)
La mecánica más importante del juego. El botón A (Space en PC) es
contexto-sensitivo exactamente como en GoW original:
- **Cerca de una pared** → deslizarse a cover (CoverSlide → CoverIdle)
- **Sin cover cercano** → dodge roll (Evade)
- **En cover + movimiento hacia otra pared** → Swat Turn
- **En cover bajo** → vault/mantle al otro lado
- **En cover** (tap para salir) → ExitCover

El magnetismo de cover opera en radio de 8 studs con cono de 45°.
La hauteur de la cobertura determina si es `"High"` (protección total)
o `"Low"` (puede mantlearse, puede hacerse peak).

### Roadie Run (sprint de cobertura)
- Shift + WASD = RoadieRun (1.2x velocidad normal)
- Cámara hace camera bob en 2.5x intensidad durante roadie run
- No se puede disparar durante roadie run
- Se puede hacer cover-slide directo desde roadie run
- Ramp-up de 0.3s para llegar a velocidad máxima

### Evade / Roll
- Alt (sin cover) o salir de cover = dodge roll
- iFrames durante los primeros 0.25s
- Cooldown de 0.8s post-roll (ventana de vulnerabilidad)
- Impulso inicial de 30 studs/s con decaimiento exponencial
- Duración comprometida de 0.6s (no se puede cancelar)

### DBNO (Down But Not Out)
- Al llegar a 150 HP (de 600): caer al estado DBNO
- Puede arrastrarse a 3 studs/s mientras está tirado
- Aliados pueden revivir en un radio de 5 studs
- Timer de bleedout: 30 segundos hasta muerte definitiva
- Enemigos pueden ejecutar al jugador caído (curb stomp)
- El ejecutor también queda vulnerable durante la animación

### Active Reload
- Durante la recarga, presionar R en la ventana del 15% de la animación:
  - **Ventana acertada** → Active Reload: +8% daño por 4 segundos
  - **Antes de la ventana** → fallo, recarga reiniciada
  - **Sin presionar** → recarga normal, sin bonus
- Es una mecánica de habilidad clásica de GoW — recompensa timing preciso

### Chainsaw Duel
- Hold V con Lancer equipado = activar chainsaw
- Si hay enemigo en rango: inicia Chainsaw Duel (minijuego de inputs)
- Sin enemigo en rango: ataque chainsaw en cono frontal

### Sistema de Salud con Regen
- 600 HP total
- Regen automático: comienza 5 segundos después del último daño recibido
- Velocidad de regen: 60 HP/s
- No hay regen si está en DBNO

---

## Valores Físicos Clave

Todos en `shared/Constants.luau`.

| Valor | Cantidad | Justificación |
|---|---|---|
| `WALK_SPEED` | 12 studs/s | Roblox default es 16. GoW se siente MÁS pesado |
| `ROADIE_RUN_SPEED` | 14.4 studs/s | Solo ~1.2x walk. La cámara finge más velocidad |
| `COVER_SLIDE_SPEED` | 18 studs/s | Lo más rápido del juego — wall-bouncing |
| `EVADE_IMPULSE_SPEED` | 30 studs/s | Burst corto muy rápido, decae rápido |
| `GRAVITY` | 220 | Default Roblox es 196.2. Más gravedad = más peso |
| `JUMP_POWER` | 0 | Sin salto. El mantle lo reemplaza |
| `GROUND_FRICTION` | 2.0 | Default Roblox resbala demasiado |
| `MAX_HEALTH` | 600 | GoW original tiene muchos HP |
| `DBNO_THRESHOLD` | 150 | 25% HP = caer |

---

## Armas del Juego

| Arma | Rol | Munición | Característica especial |
|---|---|---|---|
| Lancer (Assault Rifle) | Principal / versátil | 60 balas | Chainsaw bayonet con hold V |
| Gnasher (Escopeta) | Cercanía / agresivo | 8 cartuchos | Daño masivo a corta distancia |
| Longshot (Sniper) | Largo alcance | 6 balas | One-hit headshot |
| Torque Bow | Área / habilidad | 6 flechas | Charge para explosión al impacto |
| Hammer of Dawn | Superpoder | 3 cargas | Solo funciona bajo cielo abierto |
| Boomshot (Lanzagranadas) | Área | 4 proyectiles | Explosión en radio |
| Snub (Pistola) | Sidearm / backup | 12 balas | Siempre disponible |

---

## Fases de Desarrollo

### ✅ Fase 1 — Física Base
- `PhysicsConfig.luau`: gravity=220, friction=2.0, JumpPower=0, WalkSpeed=12
- `CharacterService.luau`: configuración al spawn
- Sensación de peso implementada

### ✅ Fase 2 — Input System (5 Capas)
- **Capa 1**: `InputDetector` — detección de raw inputs con tap/hold detection
- **Capa 2**: `IntentMapper` — raw → semántica contexto-sensitiva (GoW A-button)
- **Capa 3**: `InputBuffer` — TTL buffer por tipo de intent (80-120ms windows)
- **Capa 4+5**: `ActionResolver` — árbol de prioridades por estado del jugador

### ✅ Fase 3 — Cover System + MovementController
- `EnvironmentSensor` — raycasts: frontal, diagonal, lateral, corner
- Clasificación cover: High/Low según altura (< 3.5 studs = Low)
- `MovementController` — ejecutor: WalkSpeed por estado, cover snap, evade impulse, timers
- `ClientInit` — orquestador Heartbeat: conecta las 5 capas + sensor + controller
- `StateMachine` — FSM con 15 estados, transiciones validadas, lock/unlock, callbacks

### 🔄 Fase 4 — Animaciones (próxima)
- `AnimationController` escucha `StateMachine.StateChanged`
- Crossfades entre estados
- Animaciones: idle, walk, roadie run, cover transitions, evade, reload, melee, DBNO

### 🔄 Fase 5 — Sistema de Cámara
- `CameraController`
- Dynamic FOV: 70 normal → 80 durante roadie run
- Camera bob: 8 ciclos/s, amplitudes configurables
- ADS zoom al apuntar
- Cover lean/peek al hacer pop-out
- Shake effects (daño recibido, explosiones)

### 🔄 Fase 6 — Red y Combate
- `ServerNetwork` — RemoteEvents, validaciones server-side
- `ClientNetwork` — wrapper de FireServer, Signals de respuesta
- `CombatService` — salud autoritativa, DBNO, regen, executes
- Estado de salud sincronizado cliente/servidor

### 🔄 Fase 7 — Armas y Daño
- `WeaponService` — munición autoritativa, fire rate, raycasts de daño
- Active Reload — timing validation en servidor
- Sistema de daño por arma (Gnasher damage falloff, Longshot headshot, etc.)
- Pickups de munición y armas del mapa

### 🔄 Fase 8 — UI / HUD
- Health bar con indicador de DBNO
- Munición display (current / reserve)
- Active Reload visual indicator (ventana timing)
- Bleedout timer display
- Crosshair contextual (varía según arma y estado)
- Minimap básico

---

## Arquitectura Técnica — Resumen Visual

```
┌─────────────────────────────────────────────────────┐
│                     CLIENTE                         │
│                                                     │
│  Input Pipeline (5 capas, Heartbeat)                │
│  Detector → Mapper → Buffer → Resolver → Controller │
│                          │                          │
│            StateMachine (15 estados)                │
│                          │                          │
│  AnimationController  CameraController              │
│  (Fase 4)             (Fase 5)                      │
│                          │                          │
│              ClientNetwork (wrapper)                │
└──────────────────────┬──────────────────────────────┘
                       │ RemoteEvents
┌──────────────────────┴──────────────────────────────┐
│                     SERVIDOR                        │
│                                                     │
│  ServerNetwork (validaciones + enrutado)            │
│         │              │              │             │
│  CombatService   WeaponService  CharacterService    │
│  (salud, DBNO)   (ammo, fire)   (spawn, physics)    │
│                                                     │
│  PhysicsConfig (autoritativo: gravity, walkspeed)   │
└─────────────────────────────────────────────────────┘
                       │
┌──────────────────────┴──────────────────────────────┐
│                    SHARED                           │
│  Constants   Types   Signal   StateMachine          │
│  Enums/PlayerState   Enums/WeaponType               │
└─────────────────────────────────────────────────────┘
```

---

## Decisiones de Diseño Técnico

### ¿Por qué sin dependencias externas?
Para mantener control total sobre el código, aprender los patrones
desde cero, y evitar actualizaciones de terceros que rompan el proyecto.
Knit, Roact y Janitor son excelentes, pero añaden complejidad a un proyecto
educativo y de exploración.

### ¿Por qué server-authoritative?
La seguridad en Roblox requiere que el servidor valide todo lo que afecte
a otros jugadores. Si el cliente controlara la munición o la salud,
cualquier exploit podría manipularlos. El servidor es el árbitro inexpugnable.

### ¿Por qué un pipeline de 5 capas para el input?
GoW tiene inputs contexto-sensitivos muy complejos (el botón A hace 8 cosas
distintas según el contexto). Un sistema de una sola capa se volvería
inmanejable. Las 5 capas permiten extender cada parte independientemente:
cambiar el buffer sin tocar el detector, etc.

### ¿Por qué StateMachine separada en shared/?
El servidor necesita saber el estado real del jugador para validar peticiones
(¿puede disparar ahora? ¿está en cover?). Al tener la StateMachine en shared,
tanto el servidor como el cliente pueden tener instancias del mismo sistema
sin duplicar lógica.

### ¿Por qué Signal.luau en vez de BindableEvent?
Los `BindableEvent` de Roblox son objetos de instancia que viven en el
árbol de instancias de Roblox. Crearlos y destruirlos tiene overhead.
`Signal.luau` es puro Luau, más rápido, sin riesgo de memory leak por
instancias colgadas, y más fácil de testar.
