# Plan: Diagnóstico Sistema de Cover

## Flujo Bottom → Top (cómo debería funcionar)

```
 Capa 0 ─ PhysicsConfig (Servidor)
           WalkSpeed=12, JumpPower=0, AutoRotate=false, Gravity=220
 
 Capa 1 ─ InputDetector
           Space presionado → evento "CoverButton" en cola
           Si < 150ms → Tap, Si ≥ 150ms → HoldStart
 
 Capa 2 ─ EnvironmentSensor (cada frame)
           Spherecast adelante desde HRP center, radio 0.2, rango 2.5 studs
           Si golpea CoverObject/IsCover → HasCoverNearby=true, CoverNormal, CoverPos
 
 Capa 3 ─ IntentMapper (procesa eventos del frame)
           CoverButton.Tap + HasCoverNearby=true  → WantsCover
           CoverButton.Tap + HasCoverNearby=false → WantsEvade (CONTEXTUAL)
 
 Capa 4 ─ InputBuffer (WantsCover guardado con TTL 120ms)
 
 Capa 5 ─ ActionResolver (si estado NOT en ActionGroup)
           FREE_STATE_RULES: Buffer.WantsCover + Env.HasCoverNearby + canTakeCover
           → Fire ActionResolved("EnterCover", "CoverEntering", {normal, pos, inst, type})
 
 Capa 6 ─ MovementController (escucha ActionResolved signal)
           → TransitionTo("CoverEntering")
           → CoverHandler:HandleAction("EnterCover", data)
           → _applyMovementSpeed() → WalkSpeed = 0
 
 Capa 7 ─ CoverHandler entering loop (cada frame)
           Avanza HRP hacia snapCFrame a 42 studs/s (velocidad×dt, no lerp)
           Mezcla rotación con slerp blend 0.18 por frame
           Cancel: moveDir · CoverNormal > 0.4 → volver a Idle
           Complete: dist XZ < 0.12 → pendingCoverIdleTransition=true → CoverIdle
 
 Capa 8 ─ CoverIdle / CoverGroup
           ActionResolver corre COVER_IDLE_RULES
           Lateral: CoverHandler._updateLateralMovement → humanoid:Move(wallRight×amount)
           ExitCover: WantsExitCover + backward input → CoverExiting (0.25s) → Idle
```

---

## Bugs Identificados

### BUG A — (BLOQUEANTE) Jugador atrapado en cover para siempre

`IntentMapper._processContinuousState` genera `WantsExitCover` solo si:
```lua
if env.HasCoverNearby and moveDir.Y < -0.5 then
```
En `CoverIdle`, el personaje mira **hacia afuera** de la pared (`lookVector = wallNormal`). El `EnvironmentSensor` escanea hacia adelante (dirección donde el personaje mira = el área abierta, no la pared). La pared queda atrás. **`env.HasCoverNearby` siempre es `false`** cuando estás en cover. Condición nunca cumplida. El jugador nunca puede salir.

**Fix:** Eliminar la guarda `env.HasCoverNearby` de la condición. El ActionResolver ya filtra por estado (solo aplica `COVER_IDLE_RULES` cuando en `CoverGroup`).

```lua
-- ANTES:
if env.HasCoverNearby and moveDir.Y < -0.5 then

-- DESPUÉS:
if moveDir.Y < -0.5 then
```

**Archivo:** `src/client/Input/IntentMapper.luau`

---

### BUG B — (BLOQUEANTE) Cover no se detecta a tiempo

- `COVER_SCAN_RANGE = 2.5` studs (muy corto)
- `BUFFER_TTL_COVER = 0.12s` → a `WalkSpeed=10`, cubre solo 1.2 studs
- El jugador debe pulsar Space cuando está a ≤ **3.7 studs** de la pared
- Si pulsa antes (natural — GoW tiene magnetismo generoso), `HasCoverNearby = false` en ese momento → `CoverButton Tap` genera `WantsEvade` en vez de `WantsCover`
- El intent equivocado se guarda en el buffer y el jugador hace un roll en vez de entrar en cover

**Fix:** Aumentar rango y TTL.

```lua
-- ANTES:
Constants.COVER_SCAN_RANGE = 2.5
Constants.BUFFER_TTL_COVER = 0.12

-- DESPUÉS:
Constants.COVER_SCAN_RANGE = 5.0
Constants.BUFFER_TTL_COVER = 0.3
```

**Archivo:** `src/shared/Constants.luau`

---

### BUG C — (BLOQUEANTE) CoverNormal con componente Y

`EnvironmentSensor` guarda la normal tal cual llega del spherecast:
```lua
ctx.CoverNormal = frontResult.Normal  -- Normal cruda, puede tener Y ≠ 0
```
El test de cobertura (`CoverEnteringTest.client.luau`) **sí horizontaliza**: `Vector3.new(n.X, 0, n.Z).Unit`. El sensor de producción no. Cuando el spherecast golpea un borde o superficie levemente inclinada, `wallNormal.Y ≠ 0`, lo que causa:
- `wallNormal:Cross(Vector3.yAxis)` → `wallRight` incorrecto
- `snapCFrame` apunta en ángulo incorrecto
- El personaje snappea torcido o el slide lateral falla

**Fix:** Horizontalizar la normal en todos los puntos donde se asigna `ctx.CoverNormal`.

```lua
-- Helper en EnvironmentSensor:
local function horizontalNormal(n: Vector3): Vector3?
    local h = Vector3.new(n.X, 0, n.Z)
    if h.Magnitude < 0.001 then return nil end
    return h.Unit
end

-- En cada asignación:
ctx.CoverNormal = horizontalNormal(frontResult.Normal)
-- (si nil → no contar como cover válido)
```

**Archivo:** `src/client/World/EnvironmentSensor.luau`

---

### BUG D — (BLOQUEANTE) Velocidad residual al entrar en cover

Al iniciar `CoverEntering`, `_applyMovementSpeed()` pone `WalkSpeed = 0` (correcto), pero **no limpia `AssemblyLinearVelocity`**. El personaje venía caminando o en roadie run. La inercia física en los substeps de Roblox sigue empujando al personaje contra/a través de la pared entre las escrituras de `CFrame` del entering loop.

**Fix:** En el handler `EnterCover` (y `SlideIntoCover`), cero la velocidad XZ inmediatamente.

```lua
EnterCover = function(self, data)
    -- ... código existente ...

    local character = self._player.Character
    local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not hrp then return end

    -- Eliminar inercia horizontal para que el snap sea limpio
    hrp.AssemblyLinearVelocity = Vector3.new(0, hrp.AssemblyLinearVelocity.Y, 0)

    self._entering = self:_buildEnteringData(data.coverInstance, data.coverPos, data.coverNormal, hrp)
    self._wallRight = self._entering.wallRight
end,
```

**Archivo:** `src/client/Character/Movement/CoverHandler.luau`

---

## Bugs Secundarios

### BUG E — `cornerRange` hardcodeado

```lua
-- EnvironmentSensor.luau línea ~250:
local cornerRange = 2.0 -- studs
```
Debería venir de `Constants` para ser ajustable sin buscar en el código.

**Fix:** Añadir `Constants.COVER_CORNER_DETECTION_RANGE = 2.0` y usarlo.

---

### BUG F — `COVER_RAY_ORIGIN_OFFSET = Vector3.zero`

El spherecast sale desde el centro exacto del HRP (cadera). Una pared cuya geometría solo existe en la mitad inferior (ej. barandales, muros bajos) puede producir resultados inconsistentes a esa altura.

**Fix sugerido:** `Constants.COVER_RAY_ORIGIN_OFFSET = Vector3.new(0, 0.5, 0)` — ligero offset hacia arriba para capturar el torso.

---

### BUG G — Script por defecto de Roblox pisa `humanoid:Move()`

En `CoverIdle`, `CoverHandler._updateLateralMovement` llama `humanoid:Move(constrainedDir, false)`. Sin embargo el `LocalScript` por defecto de Roblox (`PlayerModule`) también llama `humanoid:Move()` en su propio Heartbeat. Si corre **después** del nuestro, pisa la dirección constrañida.

**Fix:** Verificar que el default character scripts estén deshabilitados, o añadir `humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, false)` durante `CoverGroup` y re-habilitarlo al salir.

---

## Orden de Implementación Recomendado

| Prioridad | Bug | Archivo | Impacto |
|-----------|-----|---------|---------|
| 1 | D — limpiar velocidad XZ | `CoverHandler.luau` | Snap estable |
| 2 | C — horizontalizar normal | `EnvironmentSensor.luau` | Ángulo correcto |
| 3 | B — aumentar rango/TTL | `Constants.luau` | Cover se detecta a tiempo |
| 4 | A — quitar HasCoverNearby de exit | `IntentMapper.luau` | Jugador puede salir |
| 5 | E — cornerRange a Constants | `Constants.luau` + `EnvironmentSensor.luau` | Mantenimiento |
| 6 | F — offset vertical raycast | `Constants.luau` | Detección más robusta |
| 7 | G — conflicto PlayerModule | `ClientApp.client.luau` o `CoverHandler.luau` | Movimiento lateral correcto |


## Extra
aparte de lso bugs mencionados yo econtre estos por mi cuenta

primer bug grande econtrado uno para la normal de la cover se estan pasando numero demasdiado grandes enviados por EnvitormentSensor

Segundo bug fix la distance cuando se trata de detectar covers debe ser mucho mas grande en constans asigna ya que en este momento solo es de 2

bueno otro error el snaping del cover se debe aplicar antes de entrar entering cover para que la animacion no vaya hacia la esquina de la cover 

Conversión al Espacio Local: Convertimos el punto de impacto y la normal al espacio local de la pieza de cobertura. Es decir, ignoramos cómo está rotada la pieza en el mundo; para el código, la pieza ahora está perfectamente alineada a los ejes X, Y y Z con su centro en (0,0,0).

Detección del Eje Dominante (El Desempate):
Comparamos el valor absoluto de la normal en X y en Z.

Si |Z| > |X|, golpeaste la cara Lateral.

Si |X| > |Z|, golpeaste la cara Frontal o Trasera.

Regla AAA (Tie-breaker): Si el impacto fue justo en la esquina (la diferencia entre X y Z es mínima, ej. un ángulo de 45°), el código elige la cara física más larga de la cobertura para que tengas más espacio para deslizarte.

La Normal Snapped:
Una vez que decidimos el eje, destruimos la normal original. Si ganaste en el eje Z positivo, tu nueva normal local es (0, 0, 1). Totalmente pura. Esto garantiza que el jugador mire exactamente perpendicular a la pared.

Corner Push-In (Anti-Esquinas):
Limitamos el punto de impacto para que no exceda el tamaño físico de la caja (math.clamp). Pero si el jugador golpeó justo el límite (la esquina), el sistema aplica un PushIn y empuja las coordenadas hacia el centro de la pieza por 1 stud. Así evitamos que el personaje quede "colgando" en el vacío.

FASE 3: El Carril de Deslizamiento (CoverAxis)

Una vez que sabemos exactamente en qué cara plana estás (SnappedNormal), necesitamos calcular hacia dónde te puedes mover. No puedes moverte hacia adentro de la pared, solo de izquierda a derecha a lo largo de ella.

Para calcular este carril (el CoverAxis), usamos una operación matemática llamada Producto Cruz (Cross Product).

Tomamos la SnappedNormal (que ya convertimos de vuelta al espacio del mundo).

Tomamos el vector UpVector del mundo (Y = 1).

Multiplicamos ambos con Normal:Cross(Vector3.yAxis).

El resultado es un tercer vector que es perfectamente paralelo a la pared y perpendicular a la normal. Este vector es el riel de tren invisible sobre el cual tu personaje se deslizará al moverse de izquierda a derecha. Al usar la normal pura y no la del impacto crudo, garantizamos que el carril no esté inclinado.

FASE 4: Gravedad Adaptativa (Terreno Irregular)
Ya tenemos la posición X y Z perfecta (pegada a la pared) y el carril. Ahora falta la altura (Y).
Si el piso frente a la cobertura tiene escombros, escaleras o rampas, un punto Y estático haría que el personaje atraviese el piso o flote.

Calculamos el HipHeight Dinámico: Justo en el momento en que inicias la entrada, lanzamos un rayo hacia abajo para saber exactamente a cuántos studs está tu cintura/HRP del suelo en ese momento.

En el punto de destino (pegado a la pared), lanzamos otro rayo hacia abajo.

Sumamos la altura del suelo de destino + tu HipHeight dinámico.

El resultado es un punto destino 3D (SnapPoint) que está matemáticamente pegado a la pared, empujado hacia adentro si era esquina, y ajustado a la altura exacta del terreno.