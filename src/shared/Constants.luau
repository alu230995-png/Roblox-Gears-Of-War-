--[[
	Constants.luau
	═══════════════════════════════════════════════════════════════
	Valores de referencia de física y movimiento basados en Gears of War.
	═══════════════════════════════════════════════════════════════

	Filosofía GoW:
	- El personaje es un soldado con ~40kg de equipo. Todo se siente PESADO.
	- WalkSpeed es deliberadamente lento.
	- RoadieRun es solo ~1.8x walk — la cámara finge más velocidad.
	- CoverSlide iguala walk (el impulso viene de la entrada, no del slide).
	- No hay bunny hopping. Gravedad alta, JumpPower bajo.

	Organización:
	  1. DEBUG
	  2. THRESHOLDS — guardas numéricas compartidas
	  3. MOVIMIENTO — velocidades activas
	  4. PHYSICS — gravedad, fricción, salto
	  5. CAMERA — FOV, bob, offsets por estado
	  6. COVER SYSTEM — snap, walking, running, wall-glue, entering
	  7. COVER TRANSITION — esquinas internas
	  8. COVER SCANNING — detección y raycast
	  9. COVER ENTRY / EXIT
	  10. EVADE / ROLL
	  11. ROADIE RUN
	  12. INPUT DETECTION
	  13. INPUT BUFFER TTL
	  14. TIMINGS DE ESTADOS
	  15–20. RESERVED — constantes de fases futuras (Combat, Reload, etc.)
]]

local Constants = {}

------------------------------------------------------------------------
-- 1. DEBUG
------------------------------------------------------------------------

Constants.DEBUG_MODE = true

------------------------------------------------------------------------
-- 2. THRESHOLDS — guardas numéricas compartidas
------------------------------------------------------------------------

-- Mínimo MoveDirection.Magnitude para contar como "moviéndose"
Constants.MOVE_DIRECTION_THRESHOLD = 0.1
-- Near-zero: detección de movimiento en cover walking (precisión alta)
Constants.MOVE_DIRECTION_THRESHOLD_LOW = 0.01
-- Guard de near-zero para normalización de vectores (evita div/0)
Constants.ZERO_MAGNITUDE = 0.001
-- Mínimo |movementScale| para disparar chequeo de esquina interna
Constants.LATERAL_TRIGGER_THRESHOLD = 0.1
-- Umbral de input forward (moveDir.Y) para generar intent de Mantle
Constants.ROADIE_RUN_INPUT_THRESHOLD = 0.3

------------------------------------------------------------------------
-- 3. MOVIMIENTO — velocidades activas (studs/segundo)
------------------------------------------------------------------------
-- Roblox default WalkSpeed = 16. GoW necesita sentirse más lento.

Constants.WALK_SPEED = 10
Constants.ROADIE_RUN_SPEED = 22
Constants.COVER_SLIDE_SPEED = 10 -- Velocidad del slide de entrada a cover (igual a walk)
Constants.EVADE_SPEED = 16

------------------------------------------------------------------------
-- 4. PHYSICS — gravedad, fricción, salto
------------------------------------------------------------------------

-- Fricción de suelo (PhysicalProperties)
-- Roblox default HumanoidRootPart es MUY resbaladizo.
Constants.GROUND_FRICTION = 2.0
Constants.GROUND_FRICTION_WEIGHT = 100
Constants.GROUND_ELASTICITY = 0
Constants.GROUND_DENSITY = 1.0

-- Gravedad alta + JumpPower bajo = sin bunny hopping
Constants.GRAVITY = 220
Constants.JUMP_POWER = 0

------------------------------------------------------------------------
-- 5. CAMERA — FOV, bob, offsets por estado
------------------------------------------------------------------------

-- FOV base y variantes
Constants.DEFAULT_FOV = 70
Constants.ROADIE_RUN_FOV = 80

-- Offsets de FOV por estado (sumados a DEFAULT_FOV)
Constants.CAMERA_FOV_COVER_AIM_OFFSET = -5
Constants.CAMERA_FOV_COVER_RUN_OFFSET = 3
Constants.CAMERA_FOV_AIM_OFFSET = -10
Constants.CAMERA_FOV_FIRING_OFFSET = -8
Constants.CAMERA_FOV_DBNO_OFFSET = -5
Constants.CAMERA_FOV_DEATH_OFFSET = -10

-- Camera Bob
Constants.CAMERA_BOB_ENABLED = true
Constants.CAMERA_BOB_FREQUENCY = 8
Constants.CAMERA_BOB_AMPLITUDE_X = 0.3
Constants.CAMERA_BOB_AMPLITUDE_Y = 0.5
Constants.CAMERA_BOB_ROADIE_MULTIPLIER = 2.5
Constants.CAMERA_BOB_WALK_MULTIPLIER = 1.0

------------------------------------------------------------------------
-- 6. COVER SYSTEM — snap, walking, running, wall-glue, entering
------------------------------------------------------------------------

-- Snap magnético
Constants.COVER_SNAP_SPEED = 24
Constants.COVER_SNAP_MIN_SPEED_FRAC = 0.8
Constants.COVER_OFFSET = 1.8
Constants.COVER_COMPLETION_XZ = 0.15
Constants.COVER_CORNER_MARGIN = 1.4

-- Walking / Running lateral
Constants.COVER_WALK_SPEED = 15
Constants.COVER_RUN_SPEED = 20

-- Wall-glue: corrección de posición contra la pared
Constants.COVER_GLUE_MAX_DIST = 0.3

-- Entering: rotación progresiva
Constants.COVER_ROTATION_BLEND_MIN = 0.08
Constants.COVER_ROTATION_BLEND_MAX = 0.35
Constants.COVER_STUCK_TIMEOUT = 1.8

-- Entering: raycasts de suelo para calcular Y del destino
Constants.COVER_GROUND_RAY_DOWN = 10
Constants.COVER_DEST_PROBE_UP = 5
Constants.COVER_DEST_RAY_DOWN = 15
Constants.COVER_DEFAULT_HIP_HEIGHT = 3.0
Constants.COVER_MIN_SNAP_DIST = 0.5

-- Auto-detección durante RoadieRun
Constants.COVER_AUTO_DETECT_DIST = 3.0
Constants.COVER_SPHERECAST_RADIUS = 0.2

------------------------------------------------------------------------
-- 7. COVER TRANSITION — esquinas internas
------------------------------------------------------------------------

Constants.COVER_TRANSITION_TRIGGER_DIST = 1.5
Constants.COVER_TRANSITION_DOT_THRESHOLD = 0.5
-- Velocidad del lerp de rotación al girar en esquina interna
-- Con 15, ~90% del giro se completa en ~0.15 s.
Constants.CORNER_TURN_SPEED = 15

------------------------------------------------------------------------
-- 8. COVER SCANNING — detección y raycast
------------------------------------------------------------------------

Constants.COVER_SCAN_RANGE = 30
Constants.COVER_HEIGHT_LOW_MAX = 3.5
Constants.COVER_RAY_ORIGIN_OFFSET = Vector3.new(0, 0.5, 0)
Constants.COVER_CORNER_DETECTION_RANGE = 2.0
Constants.COVER_CORNER_PUSH_IN = 1.0

-- EnvironmentSensor internals
Constants.ENV_FILTER_REFRESH_FRAMES = 45
Constants.ENV_CORNER_NORMAL_TIE_THRESHOLD = 0.15
Constants.ENV_CORNER_EPSILON = 0.01

------------------------------------------------------------------------
-- 8b. COVER SWAP — salto entre coberturas adyacentes en esquina
------------------------------------------------------------------------

-- Distancia máxima del rayo tangente (vector café) en studs
Constants.COVER_SWAP_MAX_DISTANCE = 6
-- Mínimo dot product entre tangentes geométricas para considerar coberturas alineadas
Constants.COVER_SWAP_ALIGNMENT_THRESHOLD = 0.9
-- Margen de seguridad: studs empujados hacia adentro desde el borde de la nueva cover
Constants.COVER_SWAP_SAFETY_MARGIN = 0.5
-- Duración del movimiento Bézier (flecha rosa) en segundos
Constants.COVER_SWAP_DURATION = 0.4
-- Fracción de la distancia añadida como Y para el punto de control de la curva
Constants.COVER_SWAP_ARC_HEIGHT = 0.2
-- Máximo desfase de profundidad (studs) para considerar paredes coplanares
Constants.COVER_SWAP_COPLANARITY_THRESHOLD = 1.0

------------------------------------------------------------------------
-- 9. COVER ENTRY / EXIT
------------------------------------------------------------------------

Constants.COVER_ENTRY_CANCEL_DOT = 0.85
Constants.COVER_EXIT_DURATION = 0.25

------------------------------------------------------------------------
-- 10. EVADE / ROLL
------------------------------------------------------------------------

Constants.EVADE_DURATION = 0.6
Constants.EVADE_COOLDOWN = 1.2
Constants.EVADE_IMPULSE_SPEED = 45
Constants.EVADE_DECELERATION = 4.0
Constants.EVADE_MIN_SPEED = 0.5

-- Duración de acciones de traversal (segundos)
Constants.MANTLE_DURATION = 0.6
Constants.VAULT_DURATION = 0.5

------------------------------------------------------------------------
-- 11. ROADIE RUN
------------------------------------------------------------------------

-- (ROADIE_RUN_FOV ya definida en sección 5 — CAMERA)

------------------------------------------------------------------------
-- 12. INPUT DETECTION
------------------------------------------------------------------------

Constants.HOLD_THRESHOLD = 0.15
Constants.MELEE_HOLD_THRESHOLD = 0.5

------------------------------------------------------------------------
-- 13. INPUT BUFFER TTL (segundos)
------------------------------------------------------------------------

Constants.BUFFER_TTL_COVER = 0.3
Constants.BUFFER_TTL_EVADE = 0.08
Constants.BUFFER_TTL_ROADIE_RUN = 0.05
Constants.BUFFER_TTL_SHOOT = 0.0
Constants.BUFFER_TTL_AIM = 0.0
Constants.BUFFER_TTL_RELOAD = 0.05
Constants.BUFFER_TTL_MELEE = 0.05
Constants.BUFFER_TTL_CHAINSAW = 0.05
Constants.BUFFER_TTL_BLIND_FIRE = 0.0
Constants.BUFFER_TTL_INTERACT = 0.1
Constants.BUFFER_TTL_MANTLE = 0.12
Constants.BUFFER_TTL_DEFAULT = 0.1

------------------------------------------------------------------------
-- 14. TIMINGS DE ESTADOS (segundos)
------------------------------------------------------------------------

Constants.STATE_TRANSITION_TIME = 0.15
Constants.STATE_MIN_DURATION = 0.1

------------------------------------------------------------------------
-- RESERVED — COMBAT (Phase 6)
------------------------------------------------------------------------

Constants.MAX_HEALTH = 600
Constants.HEALTH_REGEN_DELAY = 5.0
Constants.HEALTH_REGEN_RATE = 60
Constants.DBNO_HEALTH = 150
Constants.DBNO_BLEEDOUT_TIME = 30

------------------------------------------------------------------------
-- RESERVED — ACTIVE RELOAD (Phase 7)
------------------------------------------------------------------------

Constants.RELOAD_BAR_SPEED = 1.0
Constants.ACTIVE_RELOAD_WINDOW = 0.15
Constants.ACTIVE_RELOAD_BONUS_DAMAGE = 1.08
Constants.ACTIVE_RELOAD_BONUS_DURATION = 4.0
Constants.FAILED_RELOAD_PENALTY = 1.5

------------------------------------------------------------------------
-- RESERVED — MOVEMENT (Phase 3+)
------------------------------------------------------------------------

Constants.ACCELERATION = 8
Constants.DECELERATION = 6
Constants.JUMP_ENABLED = false

------------------------------------------------------------------------
-- RESERVED — EVADE (future)
------------------------------------------------------------------------

Constants.EVADE_IFRAMES_DURATION = 0.25

------------------------------------------------------------------------
-- RESERVED — ROADIE RUN (future)
------------------------------------------------------------------------

Constants.ROADIE_RUN_RAMP_UP = 0.3
Constants.ROADIE_RUN_MIN_DURATION = 0.2

------------------------------------------------------------------------
-- RESERVED — COVER (future)
------------------------------------------------------------------------

Constants.COVER_EXIT_SPEED = 10
Constants.COVER_CORNER_RAY_ANGLE = 60
Constants.MANTLE_MAX_HEIGHT = 5
Constants.COVER_MIN_HEIGHT = 3

return Constants
