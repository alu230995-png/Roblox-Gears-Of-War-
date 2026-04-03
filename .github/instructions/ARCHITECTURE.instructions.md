---
applyTo: "**/*.luau"
---

# Arquitectura del Proyecto — Gears of War Roblox

Este documento es la referencia principal de arquitectura. Cualquier archivo
`.luau` nuevo que se cree debe respetar estas reglas sin excepción.

---

## 1. Estructura de Directorios y Responsabilidades

```
src/
  client/   → Código que solo corre en el cliente (StarterPlayerScripts)
  server/   → Código que solo corre en el servidor (ServerScriptService)
  shared/   → Código reutilizable por ambos (ReplicatedStorage)
```

### Reglas de `require` entre carpetas

| Módulo origen | Puede hacer require de |
|---|---|
| `client/` | `shared/` únicamente |
| `server/` | `shared/` únicamente |
| `shared/` | `shared/` únicamente |
| ❌ `client/` | **Nunca** `server/` |
| ❌ `server/` | **Nunca** `client/` |

`shared/` nunca hace `require` de `client/` ni `server/`. Todo lo que
necesite comunicación bidireccional usa `Signal` o `RemoteEvent`.

---

## 2. Mapa de Rojo (project.json mappings)

```
src/shared  → ReplicatedStorage.Shared
src/server  → ServerScriptService.Server
src/client  → StarterPlayer.StarterPlayerScripts.Client
```

Rutas correctas de require dentro de scripts:

```luau
-- Desde cualquier script (client o server):
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

-- Desde client (self-referential):
local Client = script.Parent  -- o script dependiendo del nivel
local MyModule = require(Client:WaitForChild("NombreModulo"))

-- Desde server:
local Server = game:GetService("ServerScriptService"):WaitForChild("Server")
local PhysicsConfig = require(Server:WaitForChild("Utils"):WaitForChild("PhysicsConfig"))
```

---

## 3. Patrón OOP Estándar del Proyecto

**Todo módulo con estado interno** usa este patrón exacto:

```luau
local MiSistema = {}
MiSistema.__index = MiSistema

-- Constructor: sin side-effects, sin conexiones a eventos
function MiSistema.new(dep1, dep2)
    local self = setmetatable({}, MiSistema)
    self._dep1 = dep1        -- dependencias inyectadas
    self._privado = false    -- estado interno (prefijo _)
    -- Señales propias se crean aquí:
    self.MiSignal = Signal.new()
    return self
end

-- FASE 1: configuración pura, sin side-effects
function MiSistema:Init()
end

-- FASE 2: conectar eventos, signals, RunService
function MiSistema:Start()
end

-- Limpieza de todas las conexiones y signals
function MiSistema:Destroy()
    if self.MiSignal then self.MiSignal:Destroy() end
    -- desconectar todas las conexiones guardadas en _connections
end

return MiSistema
```

### Convenciones de nombres

| Elemento | Convención | Ejemplo |
|---|---|---|
| Módulos / Clases | `PascalCase` | `MovementController` |
| Instancias (variables) | `camelCase` | `movementController` |
| Campos privados | `_camelCase` | `self._locked` |
| Constantes de módulo | `SCREAMING_SNAKE_CASE` | `Constants.WALK_SPEED` |
| Señales públicas | `PascalCase` | `self.StateChanged` |
| Métodos privados | `_camelCase` | `self:_resolveDBNO()` |

---

## 4. Lifecycle: Init → Start → Destroy

Todos los sistemas son registrados en `ServiceLocator` y siguen estas fases:

```
Phase 1 — ServiceLocator:InitAll()
  └─ Init() se llama en TODOS los sistemas antes de que alguno llame Start()
  └─ Regla: NUNCA conectar eventos, signals ni RunService en Init()
  └─ Init() es solo configuración interna (look-up de dependencias, etc.)

Phase 2 — ServiceLocator:StartAll()
  └─ Start() conecta RunService.Heartbeat, signals, RemoteEvents
  └─ En este punto TODOS los sistemas ya fueron inicializados

Phase 3 — ServiceLocator:DestroyAll() (en CharacterRemoving, etc.)
  └─ Destroy() en orden inverso al registro
  └─ Obligatorio: desconectar TODAS las conexiones y destruir todos los signals
```

---

## 5. Comunicación Entre Sistemas

### ✅ Correcto — Signal event-driven (loose coupling)

```luau
-- Sistema A emite
self.ActionResolved:Fire("EnterCover", "CoverSlide", data)

-- Sistema B escucha (no sabe que A existe)
actionResolver.ActionResolved:Connect(function(action, targetState, data)
    self:_handleAction(action, targetState, data)
end)
```

### ✅ Correcto — ServiceLocator para acceso nombrado

```luau
local sm = serviceLocator:Get("StateMachine")
```

### ❌ Incorrecto — require directo de otro sistema en la misma capa

```luau
-- MAL: MovementController no debe hacer require de ActionResolver directamente
local ActionResolver = require(script.Parent.Gameplay.ActionResolver)
```

### ❌ Incorrecto — polling activo desde un sistema a otro

```luau
-- MAL en Heartbeat: preguntar por estado interno de otro sistema cada frame
if actionResolver._lastAction == "EnterCover" then ...
```

---

## 6. Señales (Signal.luau)

Todas las señales del proyecto usan `shared/Signal.luau`. **No usar
`BindableEvent` de Roblox** para comunicación interna.

```luau
local Signal = require(Shared:WaitForChild("Signal"))

-- Crear
self.MiEvento = Signal.new()

-- Conectar (guardar conexión para limpiar)
local conn = self.MiEvento:Connect(function(arg1, arg2) end)

-- Disparar
self.MiEvento:Fire(arg1, arg2)

-- Limpiar conexión individual
conn:Disconnect()

-- Destruir señal completa (en Destroy())
self.MiEvento:Destroy()
```

---

## 7. StateMachine — Reglas de Uso

La `StateMachine` (en `shared/Utils/StateMachine.luau`) es la fuente de
verdad del estado del jugador. Ningún sistema tiene su propio estado paralelo.

- `TransitionTo(state)` — valida la transición (directa + heredada por grupo), respeta tiempo mínimo
- `ForceState(state)` — solo para correcciones del servidor (omite validación)
- `Lock()` / `Unlock()` — para animaciones que no deben interrumpirse
- `StateChanged` Signal — todos los sistemas reaccionan a cambios de estado
- `RegisterGroup(name, config)` — registrar grupo jerárquico con parent/states
- `IsInGroup(groupName)` — check rápido de pertenencia (reemplaza listas de estados)
- `GetCurrentGroup(level?)` — grupo activo por nivel de jerarquía
- `GetHistory(groupName)` — último subestado activo de un grupo

**Estados son strings.** Los valores válidos están en `shared/Types.luau`
como `export type PlayerState`.

Los 15 estados válidos están en `shared/Enums/PlayerState.luau` junto con
sus capability flags (`canShoot`, `canMove`, etc.), su tabla de transiciones
válidas, y la definición de grupos jerárquicos (`PlayerState.Groups`).

---

## 8. Client-Side: Pipeline de 5 Capas

El input del jugador pasa por exactamente este pipeline cada frame (Heartbeat):

```
InputDetector  →  IntentMapper  →  InputBuffer  →  ActionResolver  →  MovementController
   (Capa 1)         (Capa 2)        (Capa 3)         (Capa 4+5)           (Ejecutor)
  Raw Events     Intenciones      TTL Buffer       Árbol prioridad       Velocidades
```

Cada capa **nunca salta**: capa N solo recibe de N-1 y entrega a N+1.
Las capas no se conocen entre sí salvo a través de sus APIs públicas.

---

## 9. Server Authority

- El servidor es **autoritativo** sobre física (`PhysicsConfig.luau`), salud, y armas.
- El cliente predice localmente para responsividad inmediata.
- El servidor puede enviar `ForceState` para corregir predicciones incorrectas.
- Toda validación de daño, munición y fire rate ocurre **solo en el servidor**.
- Nunca confiar en datos que envía el cliente sin validar: tipo, rango, rate, ownership.

---

## 10. Cómo Crear un Nuevo Módulo

1. **¿Va en `client/`, `server/` o `shared/`?** — Si lo usa solo el cliente, va en client. Si lo valida el servidor, va en server. Si lo usan ambos, va en shared.
2. Copiar el template de la sección 3 de este documento.
3. Registrar en `ServiceLocator` si es un sistema activo con lifecycle.
4. Si comunica eventos a otros sistemas, crear un `Signal` público en el constructor.
5. Añadir el módulo al mapa de dependencias en `ClientInit.client.luau` o `ServerApp.server.luau`.
6. Nunca añadir `require` circulares — si dos módulos se necesitan mutuamente, uno debe depender de una interfaz (Signal) en vez del módulo.

---

## 11. Archivos de Referencia Clave

| Archivo | Propósito |
|---|---|
| `shared/Constants.luau` | Todos los valores numéricos (velocidades, físicas, timers) |
| `shared/Types.luau` | Todas las definiciones de tipo (PlayerState, Intent, etc.) |
| `shared/Signal.luau` | Sistema de señales interno |
| `shared/Utils/StateMachine.luau` | HSM del jugador (jerarquía, herencia, history) |
| `shared/Enums/PlayerState.luau` | 15 estados con capability flags, transiciones y Groups |
| `client/Core/ServiceLocator.luau` | Registry de sistemas del cliente |
| `client/ClientApp.client.luau` | Bootstrap: conecta todo, registra grupos HSM, Heartbeat |
| `server/Utils/PhysicsConfig.luau` | Físicas autoritativas por estado |
