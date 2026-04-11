---
name: project-layers
description: "Arquitectura por capas del proyecto Gears of War (Roblox/Luau). Usar cuando: incorporar un módulo nuevo respetando la separación de capas, resolver conflictos entre capas, auditar si un módulo está en la capa correcta, entender qué capa es responsable de qué, ajustar dependencias entre capas para mantener el flujo unidireccional."
argument-hint: "Capa o módulo a revisar/ajustar (ej: InputDetector, ActionResolver, WeaponService)"
---

# Project Layers — Coexistencia del Proyecto

## Arquitectura de capas (flujo unidireccional)

```
┌─────────────────────────────────────────────────────────┐
│  CAPA 1 — Input                                         │
│  src/client/Input/                                      │
│  InputDetector → IntentMapper → InputBuffer             │
│  Responsabilidad: capturar input crudo y convertirlo    │
│  en intenciones semánticas con TTL                      │
├─────────────────────────────────────────────────────────┤
│  CAPA 2 — Contexto del mundo                            │
│  src/client/World/                                      │
│  EnvironmentSensor, RaycastUtils, SwapDetector          │
│  Responsabilidad: leer el mundo (raycasts, proximidad)  │
│  y publicar EnvironmentContext sin lógica de gameplay   │
├─────────────────────────────────────────────────────────┤
│  CAPA 3 — Resolución de acciones                        │
│  src/client/Gameplay/ActionResolver/                    │
│  init, *Rules, Helpers                                  │
│  Responsabilidad: combinar intent + estado + contexto   │
│  → emitir acción concreta (string)                      │
├─────────────────────────────────────────────────────────┤
│  CAPA 4 — Handlers de acción                            │
│  src/client/Character/Movement/                         │
│  src/client/Weapons/                                    │
│  MovementController, EvadeHandler, CoverHandler, etc.   │
│  Responsabilidad: ejecutar la acción física/visual      │
│  en el cliente + notificar al servidor                  │
├─────────────────────────────────────────────────────────┤
│  CAPA 5 — Presentación                                  │
│  src/client/Animation/  src/client/Camera/              │
│  src/client/Sound/                                      │
│  Responsabilidad: reaccionar a cambios de estado y      │
│  acciones para animar, mover cámara y reproducir audio  │
├─────────────────────────────────────────────────────────┤
│  CAPA 6 — Autoridad (servidor)                          │
│  src/server/                                            │
│  CharacterService, WeaponService, PhysicsConfig         │
│  Responsabilidad: validar todo lo que el cliente pide,  │
│  aplicar daño, propiedades físicas autoritativas        │
└─────────────────────────────────────────────────────────┘
```

---

## Reglas de dependencia entre capas

| Desde \ Hacia    | Input | Mundo | Resolver | Handlers | Presentación | Servidor |
|------------------|-------|-------|----------|----------|--------------|----------|
| Input            | ✓     | ✗     | ✗        | ✗        | ✗            | ✗        |
| Mundo            | ✗     | ✓     | ✗        | ✗        | ✗            | ✗        |
| Resolver         | ✓     | ✓     | ✓        | ✗        | ✗            | ✗        |
| Handlers         | ✓     | ✓     | ✓        | ✓        | ✗            | ✓        |
| Presentación     | ✗     | ✗     | ✗        | ✓        | ✓            | ✗        |
| Servidor         | ✗     | ✗     | ✗        | ✗        | ✗            | ✓        |

**Violación común**: un handler de Capa 4 leyendo directamente el `InputBuffer` (Capa 1) en lugar de recibir la acción ya resuelta por el `ActionResolver`.

---

## Shared: infraestructura transversal

`src/shared/` no pertenece a ninguna capa: es infraestructura disponible para todas.

| Módulo             | Uso correcto                                          |
|--------------------|-------------------------------------------------------|
| `Constants.luau`   | Valores numéricos solo, sin lógica                    |
| `Types.luau`       | Tipos exportados, sin instanciación                   |
| `StateMachine.luau`| FSM genérica, instanciada por los handlers de Capa 4  |
| `Signal.luau`      | Comunicación entre módulos de la misma capa           |
| `Enums/`           | Solo enums, sin lógica                                |

---

## `ServiceLocator` — registro de servicios

- `src/client/Core/ServiceLocator.luau` es el punto de inyección de dependencias del cliente
- Todo módulo que otros necesiten **debe registrarse** en `ClientApp.client.luau` al inicio
- Los módulos no deben llamar `require` de otro servicio fuera de la inicialización

---

## Procedimiento para añadir un módulo nuevo

1. **Determinar la capa** según la tabla de responsabilidades
2. **Verificar dependencias**: ¿el módulo solo depende de capas anteriores o iguales?
3. Registrar en `ServiceLocator` si es un servicio que otros módulos necesitan
4. Si cruza capas: introducir un evento (`Signal`) entre ambas en lugar de una dependencia directa
5. Auditar con la skill `audit-optimization` (si existe) antes de conectar al hot-path

---

## Señales de alerta — módulo en la capa incorrecta
- Un módulo en `Input/` que hace raycasts → mover a `World/`
- Un módulo en `World/` que toma decisiones de gameplay → mover a `ActionResolver/`
- Un módulo en `ActionResolver/` que modifica física → mover a `Movement/`
- Cualquier módulo cliente que aplica daño directamente → mover o delegar al servidor
