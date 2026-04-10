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
-- 5. CAMERA
------------------------------------------------------------------------

-- FOV
Constants.DEFAULT_FOV = 70
Constants.ROADIE_RUN_FOV = 80
Constants.CAMERA_FOV_LERP_SPEED = 5

-- Offsets de FOV por estado (sumados a DEFAULT_FOV)
Constants.CAMERA_FOV_COVER_AIM_OFFSET = -5
Constants.CAMERA_FOV_COVER_RUN_OFFSET = 3
Constants.CAMERA_FOV_AIM_OFFSET = -10
Constants.CAMERA_FOV_FIRING_OFFSET = -8
Constants.CAMERA_FOV_DBNO_OFFSET = -5
Constants.CAMERA_FOV_DEATH_OFFSET = -10

-- Camera offsets por estado (Vector3)
Constants.CAMERA_DEFAULT_OFFSET = Vector3.new(1.5, 2, -4)
Constants.CAMERA_COVER_OFFSET = Vector3.new(0, 2, -3)
Constants.CAMERA_AIM_OFFSET = Vector3.new(0, 1.5, -2)
Constants.CAMERA_DBNO_OFFSET = Vector3.new(0, 1, -2)
Constants.CAMERA_DEATH_OFFSET = Vector3.new(0, 3, -6)

-- Sensibilidad de cámara por estado (multiplicador sobre delta del mouse)
Constants.CAM_SENSITIVITY_DEFAULT = 1.0
Constants.CAM_SENSITIVITY_WALK = 1.0
Constants.CAM_SENSITIVITY_ROADIE = 0.2
Constants.CAM_SENSITIVITY_COVER = 1.0
Constants.CAM_SENSITIVITY_AIM = 0.5
Constants.CAM_SENSITIVITY_DBNO = 0.4

-- Base multiplier applied to mouse delta (internal scaling)
Constants.CAM_MOUSE_SENSITIVITY_BASE = 0.3

-- Camera bob
Constants.CAMERA_BOB_ENABLED = true
Constants.CAMERA_BOB_FREQUENCY = 8
Constants.CAMERA_BOB_AMPLITUDE_X = 0.3
Constants.CAMERA_BOB_AMPLITUDE_Y = 0.5
Constants.CAMERA_BOB_ROADIE_MULTIPLIER = 2.5
Constants.CAMERA_BOB_WALK_MULTIPLIER = 1.0
Constants.CAM_BOB_LERP_SPEED = 6
Constants.CAM_BOB_VELOCITY_THRESHOLD = 1.0

-- Spring Arm (anti-colisión)
Constants.CAM_ARM_LENGTH = 8.0
Constants.CAM_ARM_SPHERE_RADIUS = 0.3
Constants.CAM_ARM_PULL_SPEED = 20
Constants.CAM_ARM_PUSH_SPEED = 6
Constants.CAM_ARM_PIVOT_OFFSET = Vector3.new(0, 1.5, 0)

-- Shoulder Offset
Constants.CAM_SHOULDER_RIGHT = 1.5
Constants.CAM_SHOULDER_LEFT = -1.5
Constants.CAM_SHOULDER_LERP_SPEED = 4

-- Dynamic Framing en Cover
Constants.CAM_COVER_PITCH = -8
Constants.CAM_COVER_FRAME_SPEED = 3

-- Camera Shakes — Impulse
Constants.CAM_SHAKE_IMPULSE_DECAY = 5.0
Constants.CAM_SHAKE_IMPULSE_ATTACK = 18
-- Camera Shakes — Noise Loop
Constants.CAM_SHAKE_NOISE_SPEED = 12
Constants.CAM_SHAKE_NOISE_ROADIE_X = 0.04
Constants.CAM_SHAKE_NOISE_ROADIE_Y = 0.03

-- Camera Shakes — State-entry impulses (radianes)
Constants.CAM_SHAKE_EVADE_X = 0.012 -- temblor leve al iniciar evading
Constants.CAM_SHAKE_EVADE_Y = 0.018
Constants.CAM_SHAKE_COVER_ENTER_X = 0.04 -- micro-temblor al entrar en cover
Constants.CAM_SHAKE_COVER_ENTER_Y = 0.03

-- Movement follow-yaw (la cámara rota suavemente hacia la dirección de movimiento)
Constants.CAM_FOLLOW_YAW_WALK = 0 -- walking: cámara no sigue (strafe puro)
Constants.CAM_FOLLOW_YAW_RUN = 2 -- roadie run: fallback (no usado directamente)
Constants.CAM_FOLLOW_YAW_RUN_SNAP = 8 -- Fase 1: cámara sigue agresivamente durante Quick Snap
Constants.CAM_FOLLOW_YAW_RUN_STEER = 15 -- Fase 2: hard follow — cámara bloqueada detrás del personaje
Constants.CAM_FOLLOW_YAW_EVADE = 0 -- evade: cámara no sigue (strafe-locked)
Constants.CAM_FOLLOW_YAW_COVER_WALK = 0.0 -- no seguir en cover (el snap controla)

-- RoadieRun rotation — sistema de dos fases
Constants.ROADIE_SNAP_SPEED = 25 -- Fase 1 (Quick Snap): velocidad de rotación al iniciar roadie run
Constants.ROADIE_STEER_SPEED = 1.8 -- Legacy fallback (no usado directamente en steering)
Constants.ROADIE_SNAP_DURATION = 0.25 -- Duración de la Fase 1 antes de pasar a Fase 2 (Steering)
Constants.ROADIE_STEER_RATE = 90 -- Fase 2: grados/segundo máximos de giro (radio de giro amplio, inercia pesada)
Constants.ROADIE_SHOULDER_X = 0 -- Shoulder offset = 0 durante roadie run (cámara centrada a la espalda)

-- Sensibilidad de cámara durante Fase 2 (steering) — sin cámara libre
Constants.CAM_SENSITIVITY_ROADIE_STEER = 0.0

-- Pitch damping al correr (multiplicador extra sobre pitch, más bajo = más pesado)
Constants.CAM_PITCH_DAMP_WALK = 0.7
Constants.CAM_PITCH_DAMP_ROADIE = 0.35

-- Mouse rotation pitch clamp (grados)
Constants.CAM_PITCH_MIN = -80
Constants.CAM_PITCH_MAX = 80

------------------------------------------------------------------------
-- 6. COVER SYSTEM — snap, walking, running, wall-glue, entering
------------------------------------------------------------------------

-- Snap magnético
Constants.COVER_SNAP_SPEED = 24 -- Velocidad máxima del snap en studs/segundo — qué tan rápido se mueve al inicio
Constants.COVER_SNAP_MIN_SPEED_FRAC = 0.6 -- Fracción mínima de esa velocidad al llegar — nunca baja de 24 × 0.6 = 14.4 studs/s
Constants.COVER_OFFSET = 2 -- Distancia en studs desde la pared hasta el centro del personaje — el gap entre espalda y cover
Constants.COVER_COMPLETION_XZ = 1 -- Radio de tolerancia en studs para considerar el snap "completado"
Constants.COVER_CORNER_MARGIN = 1.4 -- Margen en studs desde el borde del Part — evita que el snap quede en la arista

-- Walking / Running lateral
Constants.COVER_WALK_SPEED = 15
Constants.COVER_RUN_SPEED = 20

-- Wall-glue: corrección de posición contra la pared
Constants.COVER_GLUE_MAX_DIST = 0.3
Constants.COVER_GLUE_CORRECTION_SPEED = 60 -- Velocidad proporcional de corrección basada en velocidad (converge en 2-3 frames)

-- Entering: rotación en dos fases
Constants.COVER_APPROACH_ROT_SPEED = 12 -- Fase 1: velocidad de rotación hacia el punto de impacto
Constants.COVER_NORMAL_ROT_START = 0.8 -- Fase 2: empezar a rotar hacia la normal al 80% del recorrido
Constants.COVER_ROTATION_BLEND_MIN = 0.05 -- al entrar en la zona de rotación (t=0.8), el Lerp usa factor 8% — giro muy lento al inicio
Constants.COVER_ROTATION_BLEND_MAX = 0.32 -- al llegar al destino (t=1.0), el Lerp usa factor 35% — giro más agresivo al final
Constants.COVER_STUCK_TIMEOUT = 1.8
Constants.COVER_SETTLE_DURATION = 0.3

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
Constants.COVER_TRANSITION_DOT_THRESHOLD = 0.87 -- cos(30°) ≈ 0.866 → permite esquinas de 30° a 90°
-- Velocidad del lerp de rotación al girar en esquina interna
-- Con 15, ~90% del giro se completa en ~0.15 s.
Constants.CORNER_TURN_SPEED = 15
-- Crossover push: studs que se empuja al personaje al cruzar una esquina interna
-- para evitar ping-pong entre paredes. Debe ser ≥ COVER_TRANSITION_TRIGGER_DIST.
Constants.CORNER_CROSSOVER_PUSH = 1.8
-- Cooldown (segundos) tras una transición de esquina interna antes de permitir otra
Constants.CORNER_TRANSITION_COOLDOWN = 0.25
-- Frames de histéresis para bloqueo de esquinas (activación instantánea, desactivación retardada)
Constants.CORNER_HYSTERESIS_FRAMES = 5
-- Fracción del delta-yaw que se aplica a la cámara al girar en esquina interna (0-1)
Constants.CAM_CORNER_YAW_FRACTION = 0.45
-- Velocidad del lerp del yaw nudge de cámara en esquina interna
Constants.CAM_CORNER_YAW_SPEED = 8

------------------------------------------------------------------------
-- 8. COVER SCANNING — detección y raycast
------------------------------------------------------------------------

Constants.COVER_SCAN_RANGE = 32
Constants.COVER_FALLBACK_MIN_SIZE = 2 -- _isCoverObject: tamaño mínimo para fallback dev
Constants.COVER_HEIGHT_LOW_MAX = 6
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

-- Vault over low cover — Bezier 3D
Constants.VAULT_FORWARD_DIST = 4
Constants.VAULT_ARC_HEIGHT = 2
Constants.VAULT_FORWARD_DOT_THRESHOLD = 0.9 -- mínimo dot entre input forward y dirección al cover para permitir vault
Constants.VAULT_OVERHEAD_RAY_HEIGHT = 2.5
Constants.VAULT_LANDING_RAY_DOWN = 10
Constants.VAULT_LANDING_RAY_UP = 3
Constants.VAULT_COLLISION_RESTORE_PROGRESS = 0.85

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
