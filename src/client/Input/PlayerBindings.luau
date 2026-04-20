--[[
	PlayerBindings.luau
	═══════════════════════════════════════════════════════════════
	Perfil completo de bindings: hardware + intents + mobile
	═══════════════════════════════════════════════════════════════

	Single source of truth para TODA la configuración de input.
	Tanto InputDetector (Capa 1) como IntentMapper (Capa 2) leen de aquí.

	Estructura del perfil:
	  .Keyboard       → KeyCode/UserInputType → RawName  (InputDetector)
	  .Gamepad        → KeyCode → RawName                (InputDetector)
	  .MoveKeys       → KeyCode → Vector2 dirección      (InputDetector)
	  .HoldThresholds → RawName → segundos               (InputDetector)
	  .WeaponSlots    → KeyCode → slot number             (InputDetector)
	  .Intents        → IntentName → bind(s)              (IntentMapper)
	  .MobileButtons  → Definiciones de botones touch     (UI futuro)

	Para rebind de controles:
	  1. Copiar el perfil: local custom = deepCopy(PlayerBindings.DEFAULT)
	  2. Modificar lo que quieras
	  3. inputDetector:RebuildBindings(custom)
	     intentMapper:RebuildBindings(custom.Intents)

	Para agregar botones móviles:
	  Leer .MobileButtons desde el módulo UI → crear ScreenGui
	  → al presionar/soltar → inputDetector:FireUIButton(RawInput, Mode)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

local PlayerBindings = {}

PlayerBindings.DEFAULT = {
	------------------------------------------------------------------------
	-- CAPA 1: Mapeo físico → RawName (consumido por InputDetector)
	------------------------------------------------------------------------

	--- Teclado + Mouse → RawName
	Keyboard = {
		-- Contexto-sensitivo (tap/hold como GoW A button)
		[Enum.KeyCode.Space] = "CoverButton",

		-- Sprint separado (Shift = RoadieRun)
		[Enum.KeyCode.LeftShift] = "SprintModifier",

		-- Evade separado (Alt = Roll)
		[Enum.KeyCode.K] = "EvadeButton",

		-- Combate
		[Enum.UserInputType.MouseButton1] = "FireButton",
		[Enum.UserInputType.MouseButton2] = "AimButton",
		[Enum.KeyCode.R] = "ReloadButton",
		[Enum.KeyCode.Q] = "BlindFireButton",

		-- Melee (tap = golpe, hold = chainsaw)
		[Enum.KeyCode.V] = "MeleeButton",

		-- Interacción
		[Enum.KeyCode.E] = "InteractButton",
		[Enum.KeyCode.F] = "InteractButton",

		-- Swap weapon
		[Enum.KeyCode.One] = "SwapWeapon",
		[Enum.KeyCode.Two] = "SwapWeapon",
		[Enum.KeyCode.Three] = "SwapWeapon",
	},

	--- Gamepad → RawName (contexto-sensitivo como GoW original)
	Gamepad = {
		[Enum.KeyCode.ButtonA] = "CoverButton",
		[Enum.KeyCode.ButtonR2] = "FireButton",
		[Enum.KeyCode.ButtonL2] = "AimButton",
		[Enum.KeyCode.ButtonR1] = "ReloadButton",
		[Enum.KeyCode.ButtonB] = "MeleeButton",
		[Enum.KeyCode.ButtonX] = "InteractButton",
		[Enum.KeyCode.ButtonY] = "SwapWeapon",
	},

	--- WASD → Vector2 dirección de movimiento
	MoveKeys = {
		[Enum.KeyCode.W] = Vector2.new(0, 1),
		[Enum.KeyCode.S] = Vector2.new(0, -1),
		[Enum.KeyCode.A] = Vector2.new(-1, 0),
		[Enum.KeyCode.D] = Vector2.new(1, 0),
	},

	--- Botones que usan detección TAP vs HOLD (los demás emiten Pressed/Released)
	HoldThresholds = {
		CoverButton = Constants.HOLD_THRESHOLD,
		MeleeButton = Constants.MELEE_HOLD_THRESHOLD,
	},

	--- Teclas numéricas → slot de arma (data adjunta al evento)
	WeaponSlots = {
		[Enum.KeyCode.One] = 1,
		[Enum.KeyCode.Two] = 2,
		[Enum.KeyCode.Three] = 3,
		[Enum.KeyCode.ButtonY] = 0, -- Gamepad: cycle
	},

	------------------------------------------------------------------------
	-- CAPA 2: RawName → Intents (consumido por IntentMapper)
	------------------------------------------------------------------------

	Intents = {
		-- CoverButton (A / Space) — contexto-sensitivo tap/hold
		WantsCover = { RawInput = "CoverButton", Mode = "Tap" },
		WantsMantle = { RawInput = "CoverButton", Mode = "Tap" },

		WantsEvade = {
			{ RawInput = "CoverButton", Mode = "Tap" },
			{ RawInput = "EvadeButton", Mode = "Pressed" },
		},

		WantsVault = {
			{ RawInput = "CoverButton", Mode = "Tap" },
			{ RawInput = "InteractButton", Mode = "Pressed" },
		},

		WantsRoadieRun = {
			{ RawInput = "CoverButton", Mode = "HoldStart", StopMode = "Release" },
			{ RawInput = "SprintModifier", Mode = "Pressed", StopMode = "Released" },
		},

		-- Combate
		WantsShoot = { RawInput = "FireButton", Mode = "Pressed", StopMode = "Released" },
		WantsAim = { RawInput = "AimButton", Mode = "Pressed", StopMode = "Released" },
		WantsReload = { RawInput = "ReloadButton", Mode = "Pressed" },
		WantsBlindFire = { RawInput = "BlindFireButton", Mode = "Pressed", StopMode = "Released" },

		-- Melee
		WantsMelee = { RawInput = "MeleeButton", Mode = "Tap" },
		WantsChainsaw = { RawInput = "MeleeButton", Mode = "HoldStart", StopMode = "Release" },

		-- Interacción y swap
		WantsInteract = { RawInput = "InteractButton", Mode = "Pressed" },
		WantsSwapWeapon = { RawInput = "SwapWeapon", Mode = "Pressed" },

		-- DBNO (auto-revive)
		WantsSelfRevive = { RawInput = "CoverButton", Mode = "Tap" },
	},

	------------------------------------------------------------------------
	-- MOBILE: Definiciones de botones virtuales para touch HUD
	------------------------------------------------------------------------
	--
	-- Cada entrada define un botón que la UI creará en pantalla.
	-- Cuando el jugador toca/suelta, el UI llama:
	--   inputDetector:FireUIButton(RawInput, "Pressed") / "Released"
	--   o para HoldSensitive: "Tap" / "HoldStart" / "Release"
	--
	-- HoldSensitive = true → el UI debe implementar detección tap vs hold
	--   usando HoldThresholds[RawInput] como umbral. Si lo suelta antes
	--   del threshold → FireUIButton("Tap"). Si lo mantiene → "HoldStart".
	--   Al soltar después de hold → "Release".
	--
	-- HoldSensitive = false → el UI solo emite "Pressed" y "Released".
	--
	-- Para implementar los botones:
	--   1. Crear un módulo MobileTouchHUD.luau en src/client/UI/
	--   2. Leer PlayerBindings.DEFAULT.MobileButtons
	--   3. Para cada entrada, crear un ImageButton/TextButton en ScreenGui
	--   4. Conectar InputBegan/InputEnded del botón:
	--      - Si HoldSensitive: trackear tiempo, emitir Tap/HoldStart/Release
	--      - Si no: emitir Pressed/Released
	--   5. Llamar inputDetector:FireUIButton(entry.RawInput, mode)
	--
	-- El movimiento en móvil viene de un joystick virtual (sistema aparte).
	-- La cámara viene del touch-drag en el lado derecho (sistema aparte).
	------------------------------------------------------------------------

	MobileButtons = {
		{
			Id = "CoverAction",
			Label = "A",
			UIName = "SpaceMoveButton",
			RawInput = "CoverButton",
			HoldSensitive = true,
			-- Visible mientras esté vivo Y en DBNO (tap = WantsSelfRevive para auto-revive)
			VisibilityGroup = "Cover",
		},
		{
			Id = "Fire",
			Label = "RT",
			UIName = "ShootButton",
			RawInput = "FireButton",
			HoldSensitive = false,
			-- Visible solo con arma equipada
			VisibilityGroup = "Combat",
		},
		{
			Id = "Aim",
			Label = "LT",
			UIName = "AimButton",
			RawInput = "AimButton",
			HoldSensitive = false,
			VisibilityGroup = "Combat",
		},
		{
			Id = "Reload",
			Label = "RB",
			UIName = "ReloadButton",
			RawInput = "ReloadButton",
			HoldSensitive = false,
			VisibilityGroup = "Combat",
		},
	},

	------------------------------------------------------------------------
	-- SPECTATOR: Botones de espectador (no pasan por InputDetector)
	------------------------------------------------------------------------
	SpectatorButtons = {
		{
			Id = "NextPlayer",
			UIName = "NextPlayerRightButton",
			Action = "RequestNext",
		},
		{
			Id = "PreviousPlayer",
			UIName = "NextPlayerLeftButton",
			Action = "RequestPrevious",
		},
	},
}

return PlayerBindings
