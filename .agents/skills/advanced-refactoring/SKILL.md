---
name: advanced-refactoring
description: "Refactorización avanzada de módulos Luau en el proyecto Gears of War (Roblox). Usar cuando: dividir un módulo que creció demasiado, extraer lógica duplicada a helpers compartidos, migrar dependencias directas a inyección via ServiceLocator o Signal, convertir state-spaghetti a StateMachine, aplanar jerarquías de herencia excesiva, renombrar símbolos con consistencia en todo el proyecto."
argument-hint: "Módulo o área a refactorizar (ej: MovementController, CoverHandler, ActionResolver)"
---

# Advanced Refactoring

## Cuándo usar esta skill
- Un módulo supera ~300 líneas y mezcla responsabilidades
- Lógica idéntica duplicada en 2+ archivos
- Dependencias circulares o cruzadas entre capas
- State-spaghetti con flags booleanos en lugar de `StateMachine`
- Necesidad de renombrar masivamente con consistencia

---

## Principios de refactoring para este proyecto

1. **Responsabilidad única por módulo**: cada `.luau` hace UNA cosa bien
2. **Coordinadores delgados**: `MovementController`, `ClientApp` solo delegan — sin lógica propia
3. **Datos separados de lógica**: tablas de configuración (`SpeedMap`, `Constants`) separadas de handlers
4. **Comunicación entre capas via Signal**, no `require` directo entre capas alejadas
5. **Sin estado global**: `_G` y `shared` están prohibidos

---

## Recetas de refactoring frecuentes

### Módulo demasiado grande → dividir
1. Identificar grupos de funciones relacionadas (por responsabilidad, no por tamaño)
2. Extraer cada grupo a un archivo en la misma carpeta
3. El archivo original se convierte en coordinador: requiere los sub-módulos y delega
4. Revisar que todas las referencias externas sigan apuntando al coordinador
5. Verificar que no se creen dependencias circulares

### Lógica duplicada → helper puro
1. Extraer a `Helpers.luau` o `Utils/` de la capa correspondiente
2. La función debe ser **pura**: mismas entradas → misma salida, sin efectos secundarios
3. Importar desde ambos módulos originales
4. Borrar las copias duplicadas

### Flags booleanos → `StateMachine`
1. Identificar todos los flags que representan estados mutuamente excluyentes
2. Mapear transiciones válidas entre esos estados
3. Instanciar `StateMachine` (de `shared/Utils/StateMachine.luau`) con los estados
4. Reemplazar cada `if self._isAiming and not self._isReloading` por `self._fsm:GetState() == "Aiming"`
5. Añadir callbacks `OnEnter` / `OnExit` para efectos secundarios que antes estaban en los `if`

### Dependencia directa entre módulos alejados → Signal
1. Identificar qué dato o evento necesita cruzar capas
2. Crear o reutilizar un `Signal` en el módulo productor
3. El consumidor se conecta al `Signal` en lugar de leer directamente
4. Guardar la conexión en `self._connections` para limpiar en `Destroy()`

### Renombrar símbolo en todo el proyecto
1. Grep por el nombre actual para inventariar todos los usos
2. Actualizar la definición primero
3. Actualizar todos los archivos que lo importan o usan
4. Actualizar `Types.luau` si el símbolo es un tipo
5. Verificar que `sourcemap.json` y `default.project.json` no referencien el nombre antiguo

---

## Proceso de refactoring seguro

```
1. Leer el módulo completo antes de modificar
2. Escribir qué responsabilidades tiene actualmente
3. Decidir cuáles quedan y cuáles se mueven
4. Crear los nuevos archivos ANTES de modificar el original
5. Migrar función por función, verificando que el módulo compile
6. Ejecutar los tests (skill: advanced-testing) después de cada movimiento
7. Borrar código dead (funciones sin llamadas) solo al final
```

---

## Checklist post-refactoring
- [ ] Ningún módulo supera 300 líneas con responsabilidades mixtas
- [ ] No hay lógica duplicada entre módulos
- [ ] Todas las conexiones en `self._connections`, limpias en `Destroy()`
- [ ] Sin `_G` ni `shared`
- [ ] `ServiceLocator` actualizado si se cambió el nombre o ruta de un servicio
- [ ] `Types.luau` actualizado si se añadieron o modificaron tipos
- [ ] Tests siguen pasando (o se actualizaron si cambió la API)
