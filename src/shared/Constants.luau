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
Constants.WALK_SPEED = 12
Constants.ROADIE_RUN_SPEED = 14.4 -- ~1.2x walk
Constants.COVER_SLIDE_SPEED = 18 -- Más rápido que roadie run
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

-- Rango de detección de covertura (studs)
Constants.COVER_DETECTION_RANGE = 8
-- Velocidad del snap magnético hacia la pared
Constants.COVER_SNAP_SPEED = 30
-- Ángulo de magnetismo (grados) — cono frente al jugador
Constants.COVER_MAGNETISM_ANGLE = 45
-- Velocidad al salir de cover
Constants.COVER_EXIT_SPEED = 10
-- Altura mínima de cover (studs) — si es menor, se puede mantlear
Constants.COVER_MIN_HEIGHT = 3
-- Altura para mantle (studs)
Constants.MANTLE_MAX_HEIGHT = 5

------------------------------------------------------------------------
-- EVADE / ROLL
------------------------------------------------------------------------

-- Duración del dodge roll (segundos)
Constants.EVADE_DURATION = 0.6
-- Cooldown después del roll (segundos) — ventana de vulnerabilidad
Constants.EVADE_COOLDOWN = 0.8
-- El jugador es invulnerable durante los primeros frames del roll
Constants.EVADE_IFRAMES_DURATION = 0.25
-- Velocidad inicial del impulso de evade (studs/s) — burst fuerte que decae
Constants.EVADE_IMPULSE_SPEED = 30
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

Constants.BUFFER_TTL_COVER = 0.12 -- 120ms
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
Constants.COVER_SCAN_RANGE = 2.5
-- Altura máxima de cover bajo — vault-able (studs)
Constants.COVER_HEIGHT_LOW_MAX = 3.5
-- Rango para detectar cover adyacente (swat turn)
Constants.COVER_ADJACENT_SCAN_RANGE = 5.0
-- Offset vertical del raycast desde HumanoidRootPart
Constants.COVER_RAY_ORIGIN_OFFSET = Vector3.new(0, 0, 0)
-- Cantidad de rayos laterales para detección de esquinas
Constants.COVER_CORNER_RAY_ANGLE = 60 -- grados

return Constants
