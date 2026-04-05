--[[
	Constants.luau
	Valores de referencia de física y movimiento basados en Gears of War.
	
	Filosofía GoW:
	- El personaje es un soldado con ~40kg de equipo. Todo se siente PESADO.
	- WalkSpeed es deliberadamente lento.
	- RoadieRun es solo ~1.2x walk — la cámara finge más velocidad.
	- CoverSlide es la velocidad MÁS RÁPIDA del juego (permite wall-bouncing).
	- No hay bunny hopping. Gravedad alta, JumpPower bajo.
]]

local Constants = {}

------------------------------------------------------------------------
-- DEBUG
------------------------------------------------------------------------

Constants.DEBUG_MODE = true -- Cambiar a true para logs en consola

------------------------------------------------------------------------
-- MOVIMIENTO
------------------------------------------------------------------------

-- Velocidades base (studs/segundo en Roblox)
-- Roblox default WalkSpeed = 16. GoW necesita sentirse más lento.
Constants.WALK_SPEED = 10
Constants.ROADIE_RUN_SPEED = 22 -- ~1.8x walk
Constants.COVER_SLIDE_SPEED = 10 -- Más rápido que roadie run
Constants.EVADE_SPEED = 16 -- Corto y rápido, burst momentáneo

-- Aceleración / Desaceleración (studs/s²)
-- Valores bajos = sensación de peso, no se para instantáneo
Constants.ACCELERATION = 8
Constants.DECELERATION = 6

-- Fricción de suelo (PhysicalProperties)
-- Roblox default HumanoidRootPart es MUY resbaladizo.
-- Subir fricción para evitar deslizamiento excesivo.
Constants.GROUND_FRICTION = 2.0
Constants.GROUND_FRICTION_WEIGHT = 100
Constants.GROUND_ELASTICITY = 0
Constants.GROUND_DENSITY = 1.0

-- Gravedad y salto
-- Gravedad alta + JumpPower bajo = sin bunny hopping
Constants.GRAVITY = 220 -- workspace.Gravity default = 196.2
Constants.JUMP_POWER = 0 -- Salto deshabilitado (mantle lo reemplaza)
Constants.JUMP_ENABLED = false

------------------------------------------------------------------------
-- CAMERA BOB (Roadie Run)
------------------------------------------------------------------------

Constants.CAMERA_BOB_ENABLED = true
Constants.CAMERA_BOB_FREQUENCY = 8 -- Ciclos por segundo
Constants.CAMERA_BOB_AMPLITUDE_X = 0.3 -- Sway horizontal
Constants.CAMERA_BOB_AMPLITUDE_Y = 0.5 -- Bounce vertical
Constants.CAMERA_BOB_ROADIE_MULTIPLIER = 2.5 -- Intensidad durante roadie run
Constants.CAMERA_BOB_WALK_MULTIPLIER = 1.0

------------------------------------------------------------------------
-- COVER SYSTEM
------------------------------------------------------------------------
-- Velocidad del snap magnético hacia la pared (studs/seg)
Constants.COVER_SNAP_SPEED = 24
-- Velocidad al salir de cover
Constants.COVER_EXIT_SPEED = 10
-- Altura mínima de cover (studs) — si es menor, se puede mantlear
Constants.COVER_MIN_HEIGHT = 3
-- Altura para mantle (studs)
Constants.MANTLE_MAX_HEIGHT = 5
-- Distancia jugador ↔ pared de cover al hacer snap (studs)
Constants.COVER_OFFSET = 1.8
-- Margen desde aristas del Part para corner clamp (studs)
Constants.COVER_CORNER_MARGIN = 1.4
-- Tolerancia horizontal para considerar que el snap completó (studs)
Constants.COVER_COMPLETION_XZ = 0.15
-- Velocidad lateral en cover walking (studs/seg) — movimiento sobre el Tangent rail
Constants.COVER_WALK_SPEED = 15
-- Velocidad lateral en cover running (studs/seg) — un poco más rápido que walk
Constants.COVER_RUN_SPEED = 20
-- Distancia máxima pared↔jugador antes de corrección de posición (studs)
-- Wall-glue: si el motor de física empuja al personaje más allá de este umbral,
-- se fuerza la posición de vuelta al plano de la pared.
Constants.COVER_GLUE_MAX_DIST = 0.3
-- Velocidad mínima al final del ease-out (fracción del max, 0..1)
-- Evita que el personaje se arrastre los últimos studs
Constants.COVER_SNAP_MIN_SPEED_FRAC = 0.8
-- Blend de rotación al INICIO de entering (0..1) — empieza suave
Constants.COVER_ROTATION_BLEND_MIN = 0.08
-- Blend de rotación al FINAL de entering (0..1) — termina agresivo
Constants.COVER_ROTATION_BLEND_MAX = 0.35
-- Timeout antes de cancelar entering por atasco (segundos)
Constants.COVER_STUCK_TIMEOUT = 1.8
-- Distancia del spherecast de auto-detección mientras corre (studs)
Constants.COVER_AUTO_DETECT_DIST = 3.0
-- Radio del spherecast de detección de cover (studs)
Constants.COVER_SPHERECAST_RADIUS = 0.2

------------------------------------------------------------------------
-- COVER TRANSITION (cambio de riel en esquinas internas)
------------------------------------------------------------------------
-- Distancia del ray lateral para disparar la transición inner (studs)
Constants.COVER_TRANSITION_TRIGGER_DIST = 1.5
-- Umbral de |dot(N_old, N_new)| para considerar paredes perpendiculares
Constants.COVER_TRANSITION_DOT_THRESHOLD = 0.5
-- Velocidad del lerp de rotación al girar en esquina interna (mayor = más rápido)
-- Con 15, ~90% del giro se completa en ~0.15 s → suave pero responsivo.
Constants.CORNER_TURN_SPEED = 15

------------------------------------------------------------------------
-- EVADE / ROLL
------------------------------------------------------------------------

-- Duración del dodge roll (segundos)
Constants.EVADE_DURATION = 0.6
-- Cooldown después del roll (segundos) — ventana de vulnerabilidad
Constants.EVADE_COOLDOWN = 1.2
-- El jugador es invulnerable durante los primeros frames del roll
Constants.EVADE_IFRAMES_DURATION = 0.25
-- Velocidad inicial del impulso de evade (studs/s) — burst fuerte que decae
Constants.EVADE_IMPULSE_SPEED = 45
-- Factor de deceleración por segundo (mayor = frena más rápido)
Constants.EVADE_DECELERATION = 4.0

------------------------------------------------------------------------
-- ROADIE RUN
------------------------------------------------------------------------

-- Delay antes de alcanzar velocidad máxima de roadie (segundos)
Constants.ROADIE_RUN_RAMP_UP = 0.3
-- Tiempo mínimo corriendo antes de poder cancelar (segundos)
Constants.ROADIE_RUN_MIN_DURATION = 0.2
-- FOV durante roadie run (grados) — efecto de velocidad
Constants.ROADIE_RUN_FOV = 80
-- FOV normal
Constants.DEFAULT_FOV = 70

------------------------------------------------------------------------
-- COMBATE (referencias para futuras fases)
------------------------------------------------------------------------

Constants.MAX_HEALTH = 600
Constants.HEALTH_REGEN_DELAY = 5.0 -- Segundos sin recibir daño para regen
Constants.HEALTH_REGEN_RATE = 60 -- HP por segundo durante regen
Constants.DBNO_HEALTH = 150 -- HP en estado DBNO antes de morir
Constants.DBNO_BLEEDOUT_TIME = 30 -- Segundos antes de morir en DBNO

------------------------------------------------------------------------
-- ACTIVE RELOAD (referencias para futuras fases)
------------------------------------------------------------------------

Constants.RELOAD_BAR_SPEED = 1.0 -- Velocidad del cursor en la barra
Constants.ACTIVE_RELOAD_WINDOW = 0.15 -- Tamaño de la zona perfecta (%)
Constants.ACTIVE_RELOAD_BONUS_DAMAGE = 1.08 -- 8% más daño
Constants.ACTIVE_RELOAD_BONUS_DURATION = 4.0 -- Segundos del boost
Constants.FAILED_RELOAD_PENALTY = 1.5 -- Multiplicador de tiempo de recarga

------------------------------------------------------------------------
-- TIMINGS DE ESTADOS (segundos)
------------------------------------------------------------------------

-- Tiempo de transición entre estados (interpolación de animación)
Constants.STATE_TRANSITION_TIME = 0.15
-- Tiempo mínimo en un estado antes de poder cambiar
Constants.STATE_MIN_DURATION = 0.1

------------------------------------------------------------------------
-- INPUT DETECTION
------------------------------------------------------------------------

-- Hold vs Tap threshold (segundos)
-- Si se suelta antes de este tiempo = Tap, si se mantiene más = Hold
Constants.HOLD_THRESHOLD = 0.15 -- 150ms para CoverButton (Space/A)
Constants.MELEE_HOLD_THRESHOLD = 0.5 -- 500ms para chainsaw vs melee

------------------------------------------------------------------------
-- INPUT BUFFER TTL (segundos)
-- Ventana de tiempo que un intent permanece válido en el buffer.
-- Permite inputs ligeramente anticipados (ej: presionar cover 80ms
-- antes de llegar a la pared).
------------------------------------------------------------------------

Constants.BUFFER_TTL_COVER = 0.3 -- 300ms — magnetismo generoso estilo GoW
Constants.BUFFER_TTL_EVADE = 0.08 -- 80ms — menos tolerante
Constants.BUFFER_TTL_ROADIE_RUN = 0.05 -- 50ms — casi inmediato
Constants.BUFFER_TTL_SHOOT = 0.0 -- inmediato, sin buffer
Constants.BUFFER_TTL_AIM = 0.0 -- inmediato
Constants.BUFFER_TTL_RELOAD = 0.05
Constants.BUFFER_TTL_MELEE = 0.05
Constants.BUFFER_TTL_CHAINSAW = 0.05
Constants.BUFFER_TTL_BLIND_FIRE = 0.0 -- inmediato
Constants.BUFFER_TTL_INTERACT = 0.1
Constants.BUFFER_TTL_MANTLE = 0.12 -- igual que cover
Constants.BUFFER_TTL_DEFAULT = 0.1

------------------------------------------------------------------------
-- COVER SCANNING (distancias de detección cercana)
------------------------------------------------------------------------

-- Rango inmediato para entrar en cover (studs)
Constants.COVER_SCAN_RANGE = 30
-- Altura máxima de cover bajo — vault-able (studs)
Constants.COVER_HEIGHT_LOW_MAX = 3.5
-- Offset vertical del raycast desde HumanoidRootPart (ligero offset hacia torso)
Constants.COVER_RAY_ORIGIN_OFFSET = Vector3.new(0, 0.5, 0)
-- Cantidad de rayos laterales para detección de esquinas
Constants.COVER_CORNER_RAY_ANGLE = 60 -- grados
-- Rango de detección de esquinas (peek corners), studs
Constants.COVER_CORNER_DETECTION_RANGE = 2.0
-- Push-in (studs) cuando el hit cae justo en el borde del Part (anti-esquina)
Constants.COVER_CORNER_PUSH_IN = 1.0

------------------------------------------------------------------------
-- COVER ENTRY / EXIT / SWAP
------------------------------------------------------------------------

-- Dot product threshold para cancelar CoverEntering con movimiento trasero.
-- Valor positivo = jugador alejándose de la cover (moveDir · coverNormal > umbral).
Constants.COVER_ENTRY_CANCEL_DOT = 0.85
-- Duración de la animación de salida de cover (segundos).
Constants.COVER_EXIT_DURATION = 0.25

return Constants
