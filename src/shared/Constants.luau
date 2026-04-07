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

Constants.DEBUG_MODE = false

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
-- Umbral de input forward (moveDir.Y) para mantle y otras comprobaciones
Constants.FORWARD_INPUT_THRESHOLD = 0.3
-- Umbral de input backward para WantsExitCover
Constants.EXIT_COVER_BACK_THRESHOLD = 0.5

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
Constants.COVER_SNAP_SPEED = 24 -- Velocidad máxima del snap en studs/segundo — qué tan rápido se mueve al inicio
Constants.COVER_SNAP_MIN_SPEED_FRAC = 0.6 -- Fracción mínima de esa velocidad al llegar — nunca baja de 24 × 0.6 = 14.4 studs/s
Constants.COVER_OFFSET = 1.8 -- Distancia en studs desde la pared hasta el centro del personaje — el gap entre espalda y cover
Constants.COVER_COMPLETION_XZ = 0.15 -- Radio de tolerancia en studs para considerar el snap "completado"
Constants.COVER_CORNER_MARGIN = 1.4 -- Margen en studs desde el borde del Part — evita que el snap quede en la arista

-- Walking / Running lateral
Constants.COVER_WALK_SPEED = 15
Constants.COVER_RUN_SPEED = 20

-- Wall-glue: corrección de posición contra la pared
Constants.COVER_GLUE_MAX_DIST = 0.3

-- Entering: rotación progresiva
Constants.COVER_START_ROTATION_BLEND = 0.7 -- empezar a rotar al 70% del recorrido
Constants.COVER_ROTATION_BLEND_MIN = 0.05 -- al entrar en la zona de rotación (t=0.7), el Lerp usa factor 8% — giro muy lento al inicio
Constants.COVER_ROTATION_BLEND_MAX = 0.32 -- al llegar al destino (t=1.0), el Lerp usa factor 35% — giro más agresivo al final
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

Constants.COVER_SCAN_RANGE = 32
Constants.COVER_FALLBACK_MIN_SIZE = 2 -- _isCoverObject: tamaño mínimo para fallback dev
Constants.COVER_HEIGHT_LOW_MAX = 3.5
Constants.COVER_RAY_ORIGIN_OFFSET = Vector3.new(0, 0.5, 0)
Constants.COVER_CORNER_DETECTION_RANGE = 2.0
Constants.COVER_CORNER_PUSH_IN = 2.0

-- EnvironmentSensor internals
Constants.ENV_FILTER_REFRESH_FRAMES = 45
Constants.ENV_CORNER_NORMAL_TIE_THRESHOLD = 0.15
Constants.ENV_CORNER_EPSILON = 0.01

------------------------------------------------------------------------
-- 8b. COVER SWAP — salto entre coberturas adyacentes en esquina
------------------------------------------------------------------------

-- Distancia máxima del rayo tangente (vector café) en studs
Constants.COVER_SWAP_MAX_DISTANCE = 14
-- Mínimo dot product entre tangentes geométricas para considerar coberturas alineadas
Constants.COVER_SWAP_ALIGNMENT_THRESHOLD = 0.95
-- Margen de seguridad: studs empujados hacia adentro desde el borde de la nueva cover
Constants.COVER_SWAP_SAFETY_MARGIN = 2
-- Velocidad del movimiento Bézier (flecha rosa) en studs/segundo
Constants.COVER_SWAP_SPEED = 18
-- Fracción de la distancia añadida como Y para el punto de control de la curva
Constants.COVER_SWAP_ARC_HEIGHT = 0.2
-- Máximo desfase de profundidad (studs) para considerar paredes coplanares
Constants.COVER_SWAP_COPLANARITY_THRESHOLD = 1.5

------------------------------------------------------------------------
-- 9. COVER ENTRY / EXIT
------------------------------------------------------------------------

Constants.COVER_ENTRY_CANCEL_DOT = 0.85
Constants.COVER_EXIT_DURATION = 0.15

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
-- 13b. INTENT LISTS — single source of truth
------------------------------------------------------------------------

--- Intents discretos (one-shot): se limpian cada frame en IntentMapper.
--- Incluye los Stop* porque también son one-shot (dispara y olvida).
Constants.DISCRETE_INTENTS = table.freeze({
	"WantsCover",
	"WantsEvade",
	"WantsMantle",
	"WantsReload",
	"WantsMelee",
	"WantsChainsaw",
	"WantsInteract",
	"WantsSwapWeapon",
	"WantsStopRoadieRun",
	"WantsStopShoot",
	"WantsStopAim",
	"WantsStopBlindFire",
	"WantsStopChainsaw",
	"WantsExitCover",
})

--- Subset de discretos que se buffean con TTL.
--- Los Stop* NO se buffean: son reacciones inmediatas, no anticipables.
Constants.BUFFERABLE_INTENTS = table.freeze({
	"WantsCover",
	"WantsEvade",
	"WantsMantle",
	"WantsReload",
	"WantsMelee",
	"WantsChainsaw",
	"WantsInteract",
	"WantsSwapWeapon",
	"WantsExitCover",
})

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
