---
name: advanced-testing
description: "Diseño e implementación de tests avanzados para el proyecto Gears of War (Roblox/Luau). Usar cuando: escribir tests de integración para la StateMachine, verificar reglas del ActionResolver, testear handlers de movimiento y cobertura, validar flujos de input hasta acción, detectar regresiones en mecánicas existentes, diseñar test fixtures para módulos con dependencias de Roblox."
argument-hint: "Módulo o mecánica a testear (ej: ActionResolver, CoverHandler, StateMachine)"
---

# Advanced Testing

## Cuándo usar esta skill
- Escribir tests para un módulo nuevo o refactorizado
- Verificar que una mecánica no rompe otra al integrarla
- Crear test de regresión después de encontrar un bug
- Diseñar fixtures que aíslen módulos de las APIs de Roblox

---

## Estructura de tests

```
src/
  client/
    Tests/
      CoverEnteringTest.client.luau    ← ya existe
      <NuevoTest>.client.luau          ← tests de cliente (acceso a LocalPlayer, Character)
  shared/
    Tests/                             ← tests de módulos shared (sin APIs de cliente/servidor)
      StateMachineTest.luau
      ActionResolverTest.luau
```

Los tests de cliente usan `.client.luau` para ejecutarse en `StarterPlayerScripts`.

---

## Patrón de test en Luau (sin framework externo)

```luau
-- tests/NombreTest.client.luau
local passed = 0
local failed = 0

local function test(name: string, fn: () -> ())
    local ok, err = pcall(fn)
    if ok then
        passed += 1
        print("[PASS]", name)
    else
        failed += 1
        warn("[FAIL]", name, "->", err)
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq failed") .. ": expected " .. tostring(b) .. " got " .. tostring(a), 2)
    end
end

local function assert_truthy(v, msg)
    if not v then error(msg or "expected truthy, got falsy", 2) end
end

-- ── Tests ───────────────────────────────────────────────────────────────────

test("descripción del test", function()
    -- Arrange
    -- Act
    -- Assert
end)

-- ── Resumen ─────────────────────────────────────────────────────────────────
print(string.format("Results: %d passed, %d failed", passed, failed))
```

---

## Recetas por módulo

### `StateMachine`
- Verificar transición válida: `fsm:Transition(estado)` no lanza error
- Verificar transición inválida: `pcall(fsm.Transition, fsm, estadoInvalid)` devuelve `false`
- Verificar callbacks `OnEnter` / `OnExit` se llaman exactamente una vez
- Verificar que `GetState()` refleja el estado correcto después de cada transición

### `ActionResolver`
- Construir un `ResolverContext` de prueba con valores controlados
- Llamar `resolver:Resolve(context)` directamente sin Heartbeat
- Verificar que devuelve la acción esperada para cada combinación de (intent, estado, entorno)
- Verificar prioridad: acción de mayor prioridad gana cuando hay 2 intents activos

### `InputBuffer`
- Simular `Push(intent, timestamp)` y verificar `Pop()` devuelve el más reciente
- Verificar que un intent expirado (TTL vencido) no se devuelve
- Verificar que intentos de tipo diferente no interfieren entre sí

### `CoverHandler` / `EvadeHandler`
- Mockear `EnvironmentSensor` retornando `EnvironmentContext` fijo
- Verificar que el handler transiciona el estado correctamente
- Verificar cleanup: después de `Destroy()`, no hay conexiones activas (el Signal ya no dispara)

### `ActionResolver` — test de regresión
- Para cada bug encontrado: crear un test que reproduce exactamente el contexto del bug
- El test falla con el bug present, pasa después del fix

---

## Fixtures y mocks para APIs de Roblox

Cuando un módulo usa `workspace`, `Players`, `UserInputService`, etc.:

```luau
-- Inyectar mock via constructor en lugar de require directo
local handler = CoverHandler.new({
    character = mockCharacter,   -- tabla con los campos que usa el handler
    sensor = mockSensor,         -- objeto con método :GetContext()
    fsm = realStateMachine,      -- usar la StateMachine real
})
```

Si el módulo hace `require` interno de APIs, extráer esas dependencias al constructor antes de testear (forma parte de `advanced-refactoring`).

---

## Checklist de test completo para un módulo
- [ ] Test de inicialización: `new()` no lanza, estado inicial correcto
- [ ] Test del flujo feliz: input válido → salida esperada
- [ ] Test de edge cases: input vacío, nil, valores límite
- [ ] Test de cleanup: `Destroy()` desconecta todo, segunda llamada no lanza
- [ ] Test de regresión: uno por cada bug que se haya encontrado en este módulo
- [ ] Sin efectos secundarios entre tests (cada test crea su propia instancia)
