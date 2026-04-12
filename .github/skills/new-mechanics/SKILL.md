---
name: new-mechanics
description: "Implementación de nuevas mecánicas de gameplay en el proyecto Gears of War (Roblox/Luau). Usar cuando: diseñar e integrar una mecánica que no existe aún (executions, grenade toss, chainsaw, DBNO recovery, revive, co-op específico), definir sus estados, transiciones, reglas de ActionResolver y sincronización cliente-servidor."
argument-hint: "Nombre o descripción de la mecánica a implementar (ej: execution, revive, grenade)"
---

# New Mechanics Implementation

## Cuándo usar esta skill
- Implementar una mecánica de gameplay que no existe en el proyecto
- Añadir nuevos `PlayerState` sin romper las transiciones existentes
- Diseñar e integrar el flujo completo: input → intent → acción → estado → animación → sonido
- Sincronizar la mecánica entre cliente y servidor

---

## Pipeline de integración de una mecánica nueva

```
Input (InputDetector)
  → Intent semántico (IntentMapper)
    → Buffered intent (InputBuffer)
      → Regla en ActionResolver
        → Acción emitida
          → Handler en MovementController / WeaponController
            → Transición de estado (StateMachine)
              → Animación (AnimationController)
              → Sonido (SoundController)
              → Replicación al servidor (RemoteEvent)
```

---

## Procedimiento

### 1. Diseñar el estado
- ¿Requiere un nuevo `PlayerState`? → añadir en `src/shared/Enums/PlayerState.luau`
- Definir `validTransitions` desde y hacia el nuevo estado
- Si es sub-estado de uno existente (ej: `CoverAiming`), no crear estado de primer nivel

### 2. Añadir el intent
- Si hay input del jugador: registrar keybinding en `PlayerBindings.luau`
- Añadir mapeo raw → intent semántico en `IntentMapper.luau`
- Definir TTL del intent en `InputBuffer.luau` (si es bufferable)

### 3. Escribir la regla en `ActionResolver`
- Identificar en qué archivo va la regla según el estado actual del jugador:
  - `FreeStateRules.luau` → jugador en pie
  - `CoverRules.luau` → jugador en cobertura
  - `DBNORules.luau` → jugador caído
  - Crear nuevo archivo `*Rules.luau` solo si es un estado completamente nuevo
- La regla es una función pura: `(context: ResolverContext) → string?`
- Insertar en la posición de prioridad correcta dentro del array de reglas

### 4. Implementar el handler
- Crear handler en `src/client/Character/Movement/` o `src/client/Weapons/`
- El handler escucha `ActionResolved` y ejecuta la lógica de cliente (física, impulso, animación)
- Notificar al servidor via `RemoteEvent` si afecta a otros jugadores o al estado autoritativo

### 5. Servidor: validar y replicar
- Añadir handler en `ServerApp.server.luau` o en un nuevo `Service`
- Validar precondiciones (cooldown, estado, distancia) antes de aplicar efectos
- Replicar resultado a otros clientes si es necesario

### 6. Animación y sonido
- Registrar entradas en `SoundConfig.luau`
- `AnimationController` escucha `StateChanged` o el evento específico de la mecánica

---

## Checklist de integración
- [ ] Nuevo estado (si aplica) añadido con `validTransitions` completas
- [ ] Regla añadida al `ActionResolver` en posición de prioridad correcta
- [ ] Handler crea sus conexiones en `self._connections`, limpia en `Destroy()`
- [ ] Sin allocaciones por frame (no `{}` ni `RaycastParams.new()` en hot-path)
- [ ] Validación autoritativa en servidor, predicción visual en cliente
- [ ] Sonido y animación conectados via eventos, no polling
