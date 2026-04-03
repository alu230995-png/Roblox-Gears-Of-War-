---
applyTo: "src/client/Network/**, src/server/Network/**"
---

# OOP — Capa de Red (Client ↔ Server)

Este documento cubre la capa de comunicación entre cliente y servidor.
Todo código en `src/client/Network/` y `src/server/Network/` debe seguir
estos patrones estrictamente para mantener la seguridad y el server authority.

---

## 1. Principios Fundamentales

### Regla de oro: nunca `FireServer` directo desde gameplay

```luau
-- ❌ MAL: un sistema de gameplay llama directamente al RemoteEvent
game:GetService("ReplicatedStorage").Events.WeaponFire:FireServer(data)

-- ✅ BIEN: toda comunicación pasa por ClientNetwork
clientNetwork:Send("WeaponFire", { direction = dir, weaponType = "Lancer" })
```

`ClientNetwork` es el **único punto de salida** del cliente hacia el servidor.
Esto permite: rate limiting centralizado, logging, formato consistente, y
facilita tests.

### División de responsabilidades

```
ClientNetwork.luau (cliente)
  → Encapsula TODOS los FireServer
  → Expone Signals para respuestas del servidor
  → NO tiene lógica de juego

ServerNetwork.luau (servidor)
  → Recibe TODOS los eventos del cliente
  → Primera línea de validación (tipo, formato, ownership)
  → Enruta a los Services correspondientes
  → NO tiene lógica de juego
```

---

## 2. Eventos Definidos (RemoteEvents en ReplicatedStorage.Events)

### Cliente → Servidor

| Evento | Datos enviados | Descripción |
|---|---|---|
| `PlayerStateUpdate` | `{ state: string, timestamp: number }` | Cliente reporta su estado predicho |
| `WeaponFire` | `{ weaponType: string, direction: Vector3, timestamp: number }` | Solicitar disparo |
| `WeaponReload` | `{ weaponType: string, timestamp: number }` | Iniciar recarga |
| `ActiveReloadAttempt` | `{ pressTimestamp: number }` | Intentar Active Reload |
| `CoverRequest` | `{ normal: Vector3, position: Vector3 }` | Entrar en cover |
| `ReviveRequest` | `{ victimUserId: number }` | Intentar revivir aliado |
| `MeleeRequest` | `{ direction: Vector3 }` | Golpe de melee |
| `ChainsawRequest` | `{ targetId: number? }` | Chainsaw (con o sin target) |
| `InteractRequest` | `{ interactableId: number }` | Interactuar con objeto del mundo |

### Servidor → Cliente

| Evento | Datos recibidos | Descripción |
|---|---|---|
| `StateCorrection` | `{ state: string }` | Servidor corrige estado predicho |
| `HitConfirmed` | `{ targetId: number, damage: number }` | Daño confirmado |
| `HitDenied` | `{ reason: string }` | Disparo rechazado |
| `AmmoUpdate` | `{ current: number, reserve: number }` | Sincronizar munición |
| `HealthUpdate` | `{ health: number }` | Sincronizar salud |
| `DBNOStarted` | `{ bleedoutTime: number }` | Notificar inicio DBNO |
| `ActiveReloadResult` | `{ result: "bonus" \| "normal" \| "fail" }` | Resultado del Active Reload |
| `ReviveResult` | `{ success: boolean, rescuerId: number? }` | Resultado del rescate |

---

## 3. ClientNetwork — Implementación

### API pública

```luau
-- Enviar un evento al servidor
ClientNetwork:Send(eventName: string, data: table)

-- Signals que se disparan al recibir respuestas del servidor:
clientNetwork.HitConfirmed       -- (targetId, damage)
clientNetwork.HitDenied          -- (reason)
clientNetwork.StateCorrection    -- (newState)
clientNetwork.AmmoUpdated        -- (current, reserve)
clientNetwork.HealthUpdated      -- (health)
clientNetwork.DBNOStarted        -- (bleedoutTime)
clientNetwork.ActiveReloadResult -- (result)
clientNetwork.ReviveResult       -- (success, rescuerId)
```

### Template de implementación

```luau
local ClientNetwork = {}
ClientNetwork.__index = ClientNetwork

function ClientNetwork.new()
    local self = setmetatable({}, ClientNetwork)
    self._events = {}     -- referencias a RemoteEvents
    self._connections = {}

    -- Signals públicas para que otros sistemas escuchen respuestas del servidor
    self.HitConfirmed       = Signal.new()
    self.HitDenied          = Signal.new()
    self.StateCorrection    = Signal.new()
    self.AmmoUpdated        = Signal.new()
    self.HealthUpdated      = Signal.new()
    self.DBNOStarted        = Signal.new()
    self.ActiveReloadResult = Signal.new()
    self.ReviveResult       = Signal.new()
    return self
end

function ClientNetwork:Init()
    -- Obtener referencias a todos los RemoteEvents
    local eventsFolder = ReplicatedStorage:WaitForChild("Events")
    for _, eventName in EVENT_NAMES do
        self._events[eventName] = eventsFolder:WaitForChild(eventName)
    end
end

function ClientNetwork:Start()
    -- Conectar OnClientEvent → Signals internas
    local conn = self._events["HitConfirmed"].OnClientEvent:Connect(function(data)
        self.HitConfirmed:Fire(data.targetId, data.damage)
    end)
    table.insert(self._connections, conn)
    -- ... resto de eventos
end

function ClientNetwork:Send(eventName: string, data: table)
    local event = self._events[eventName]
    if event then
        event:FireServer(data)
    else
        warn("[ClientNetwork] Evento no encontrado: " .. eventName)
    end
end
```

---

## 4. ServerNetwork — Validaciones Obligatorias

Cada evento recibido del cliente **debe pasar todas estas validaciones** antes
de ser reenviado a un Service. Si alguna falla, rechazar silenciosamente
(no informar al cliente el motivo exacto por seguridad).

### Checklist de validación por evento

```luau
-- 1. Validación de tipo (type check)
-- Verificar que cada campo tiene el tipo esperado
if type(data.direction) ~= "Vector3" then return end

-- 2. Validación de rango (range check)
-- Verificar que los valores son físicamente posibles
if data.direction.Magnitude > 1.01 then return end  -- debe ser unit vector
if math.abs(data.timestamp - os.clock()) > 1.0 then return end  -- no más de 1s de diferencia

-- 3. Validación de rate (rate limit)
-- El cliente no puede enviar el mismo evento demasiado rápido
local lastFire = self._lastEventTime[player][eventName] or 0
if os.clock() - lastFire < MIN_INTERVAL then return end
self._lastEventTime[player][eventName] = os.clock()

-- 4. Validación de ownership
-- El jugador solo puede actuar sobre sí mismo o interactuar en rango
if data.victimUserId == player.UserId then return end  -- no puede revivirse a sí mismo
```

### Rate limits por evento

| Evento | Intervalo mínimo | Razón |
|---|---|---|
| `WeaponFire` | Según fire rate del arma | Anti-autoclicker |
| `WeaponReload` | 1.5s | Duración mínima de recarga |
| `CoverRequest` | 0.5s | Anti-spam |
| `ReviveRequest` | 0.3s | Polling durante rescate |
| `MeleeRequest` | 1.0s | Cooldown de melee |
| `ChainsawRequest` | 2.0s | Animación larga |
| `PlayerStateUpdate` | 0.05s | Max 20 updates/s desde el cliente |

### Template ServerNetwork (enrutar a Services)

```luau
-- ServerNetwork.luau — Recibir y enrutar
function ServerNetwork:_onWeaponFire(player: Player, data: table)
    -- Validar
    if not self:_validateWeaponFire(player, data) then return end
    -- Enrutar al service correcto
    self._weaponService:ValidateFire(player, data.weaponType, data.direction)
end

function ServerNetwork:_onReviveRequest(player: Player, data: table)
    if not self:_validateReviveRequest(player, data) then return end
    self._combatService:RequestRevive(
        game:GetService("Players"):GetPlayerByUserId(data.victimUserId),
        player
    )
end
```

---

## 5. Creación de RemoteEvents

Los RemoteEvents son creados **por el servidor** en `ServerNetwork:Init()`.
El cliente los busca con `WaitForChild()` en `ClientNetwork:Init()`.

```luau
-- En ServerNetwork:Init() (servidor):
local eventsFolder = Instance.new("Folder")
eventsFolder.Name = "Events"
eventsFolder.Parent = ReplicatedStorage

for _, eventName in ALL_EVENT_NAMES do
    local event = Instance.new("RemoteEvent")
    event.Name = eventName
    event.Parent = eventsFolder
end
```

**Nunca** crear RemoteEvents desde el cliente — es una vulnerabilidad de seguridad.

---

## 6. Anti-Patrones de Seguridad

```luau
-- ❌ MAL: confiar en el estado que reporta el cliente
if data.state == "CoverIdle" then  -- el cliente puede mentir
    applyDamageReduction()

-- ✅ BIEN: verificar el estado real del servidor
local serverState = stateMachines[player]:GetCurrentState()
if serverState == "CoverIdle" then
    applyDamageReduction()

-- ❌ MAL: el cliente controla la munición
player.leaderstats.Ammo.Value = player.leaderstats.Ammo.Value - 1

-- ✅ BIEN: solo el servidor controla munición
weaponService:SpendAmmo(player, 1)

-- ❌ MAL: ejecutar daño desde el cliente
humanoid.Health -= 50

-- ✅ BIEN: solo el servidor aplica daño
-- (el cliente nunca debe tocar la salud de otros jugadores)
```

---

## 7. Sincronización de Estado

Para estados que deben estar sincronizados (salud, munición, estado del jugador):

```
ESTRATEGIA: Optimistic client prediction + server correction

1. Cliente predice localmente (inmediato, sin lag)
2. Servidor valida y aplica
3. Si el servidor rechaza: envía StateCorrection al cliente
4. Cliente recibe StateCorrection → llama ForceState() para corregir
```

`StateCorrection` se recibe en `ClientNetwork`, que dispara la Signal
`StateCorrection`. `CharacterController` escucha esta Signal y llama
`stateMachine:ForceState(newState)`. El cliente nunca ignora correcciones del servidor.
