--[[
	WeaponClient.luau
	═══════════════════════════════════════════════════════════════
	Módulo OOP del arma en el cliente.
	═══════════════════════════════════════════════════════════════

	Uso (desde un LocalScript dentro del Tool):
	  local WeaponClient = require(path.to.WeaponClient)
	  local weapon = WeaponClient.new(player, tool)
	  -- El objeto se auto-gestiona: escucha Equipped/Unequipped del Tool
	  -- y StateChanged de la StateMachine para decidir su estado interno.

	Responsabilidades:
	  - Detectar equip/unequip del Tool y sincronizar con WeaponState
	  - Identificar el arma por Tool.Name → buscar stats en WeaponConstants
	  - Ejecutar timers de Equipping/Unequipping (cooldown de transición)
	  - Bloquear disparo y recarga durante transiciones (Equipping/Unequipping)
	  - Escuchar PlayerState para auto-unequip en estados bloqueados
	    (RoadieRun, Evading, DBNO, Death, CoverSlide, etc.)
	  - Limpiar conexiones y cancelar timers pendientes al desequipar
	  - Exponer señales para que otros sistemas (animación, cámara, HUD)
	    reaccionen a cambios de estado del arma
	  - Gestionar RemoteEvents hacia WeaponServer

	NO hace (aún):
	  - Lógica de disparo (Fase siguiente)
	  - Raycast visual (predicción cliente)
	  - Recarga / Active Reload

	Ciclo de vida:
	  Tool.Equipped   → _onToolEquipped()  → Equipping → (timer) → Equipped
	  Tool.Unequipped → _onToolUnequipped()→ Unequipping → (timer) → Unequipped
	  StateChanged    → _onPlayerStateChanged() → puede forzar Unequipped (instantáneo)
	  Destroy()       → limpia conexiones, cancela timers, mata señales
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponConstants = require(Shared:WaitForChild("WeaponConstants"))
local Signal = require(Shared:WaitForChild("Signal"))

------------------------------------------------------------------------
-- STATES (internos — alineados con WeaponState enum)
------------------------------------------------------------------------

local WS_UNEQUIPPED = "Unequipped"
local WS_EQUIPPING = "Equipping"
local WS_EQUIPPED = "Equipped"
local WS_UNEQUIPPING = "Unequipping"

--- Set de estados de transición donde el arma NO puede actuar.
--- Bloquea disparo, recarga, swap durante equip/unequip.
local TRANSITION_STATES: { [string]: true } = {
	[WS_EQUIPPING] = true,
	[WS_UNEQUIPPING] = true,
}

------------------------------------------------------------------------
-- Sets de estados donde el arma DEBE estar Unequipped.
-- Lookup O(1) para _onPlayerStateChanged.
------------------------------------------------------------------------

local FORCE_UNEQUIP_STATES: { [string]: true } = {
	RoadieRun = true,
	Evading = true,
	Mantling = true,
	Vaulting = true,
	CoverSlide = true,
	CoverEntering = true,
	CoverExiting = true,
	CoverSwap = true,
	ExitCorner = true,
	DBNO = true,
	Death = true,
	Spectator = true,
	Lobby = true,
}

------------------------------------------------------------------------
-- CLASS
------------------------------------------------------------------------

local WeaponClient = {}
WeaponClient.__index = WeaponClient

--- Crea una nueva instancia de WeaponClient.
--- @param player Player — el jugador local
--- @param tool Tool — la herramienta (arma) en StarterPack / Backpack
function WeaponClient.new(player: Player, tool: Tool)
	local self = setmetatable({}, WeaponClient)

	self._player = player
	self._tool = tool
	self._connections = {} :: { RBXScriptConnection | { Disconnect: () -> () } }

	-- ──────────────────────────────────────────────────────────
	-- Identificación del arma: obtener nombre del Tool y buscar
	-- stats/effects en WeaponConstants. Si no existe, warn y nil.
	-- ──────────────────────────────────────────────────────────
	self._weaponName = tool:GetAttribute("WeaponName") or tool.Name

	local stats = WeaponConstants.STATS[self._weaponName]

	if not stats then
		warn("[WeaponClient] Arma no encontrada en WeaponConstants.STATS: " .. tostring(self._weaponName))
	end
	self._stats = stats

	local effects = WeaponConstants.EFFECTS[self._weaponName]
	if not effects then
		warn("[WeaponClient] Arma no encontrada en WeaponConstants.EFFECTS: " .. tostring(self._weaponName))
	end
	self._effects = effects

	-- Estado interno del arma
	self._weaponState = WS_UNEQUIPPED
	self._isToolEquipped = false -- flag físico: ¿el Tool está en el Character?

	-- ──────────────────────────────────────────────────────────
	-- Timer de transición: thread activo de equip/unequip.
	-- Se cancela al iniciar una nueva transición o al forzar estado.
	-- ──────────────────────────────────────────────────────────
	self._transitionThread = nil :: thread?

	-- Munición (se inicializa con el cargador lleno)
	self._currentAmmo = if self._stats then self._stats.MagazineSize else 0
	self._reserveAmmo = if self._stats then self._stats.MagazineSize * 3 else 0

	-- Señales públicas (otros sistemas se conectan)
	self.WeaponStateChanged = Signal.new() -- (newState: string, oldState: string)
	self.WeaponEquipped = Signal.new() -- (weaponName: string, stats: table?)
	self.WeaponUnequipped = Signal.new() -- (weaponName: string)
	self.AmmoChanged = Signal.new() -- (current: number, reserve: number)

	-- Referencia a la StateMachine (se inyecta en Init)
	self._stateMachine = nil

	-- RemoteEvent para comunicación con WeaponServer
	self._weaponRemote = nil :: RemoteEvent?

	return self
end

------------------------------------------------------------------------
-- LIFECYCLE (Init / Start / Destroy)
------------------------------------------------------------------------

--- Fase Init: resolver dependencias, sin side-effects.
function WeaponClient:Init(stateMachine)
	self._stateMachine = stateMachine

	-- Buscar RemoteEvent (creado por WeaponServer)
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if remotes then
		self._weaponRemote = remotes:FindFirstChild("WeaponRemote") :: RemoteEvent?
	end
end

--- Fase Start: conectar señales y eventos.
function WeaponClient:Start()
	-- Escuchar equip/unequip del Tool
	table.insert(
		self._connections,
		self._tool.Equipped:Connect(function()
			self:_onToolEquipped()
		end)
	)

	table.insert(
		self._connections,
		self._tool.Unequipped:Connect(function()
			self:_onToolUnequipped()
		end)
	)

	-- Escuchar cambios de PlayerState
	if self._stateMachine then
		table.insert(
			self._connections,
			self._stateMachine.StateChanged:Connect(function(newState, _oldState)
				self:_onPlayerStateChanged(newState)
			end)
		)
	end

	-- Si el Tool ya está equipado al hacer Start (caso: require tardío)
	if self._tool.Parent and self._tool.Parent == self._player.Character then
		self:_onToolEquipped()
	end
end

--- Limpieza total: desconecta todo, cancela timers, destruye señales.
function WeaponClient:Destroy()
	-- Cancelar transición pendiente
	self:_cancelTransition()

	for _, conn in self._connections do
		if typeof(conn) == "RBXScriptConnection" then
			conn:Disconnect()
		elseif conn.Disconnect then
			conn.Disconnect()
		end
	end
	table.clear(self._connections)

	self.WeaponStateChanged:Destroy()
	self.WeaponEquipped:Destroy()
	self.WeaponUnequipped:Destroy()
	self.AmmoChanged:Destroy()

	self._stateMachine = nil
	self._tool = nil :: any
end

------------------------------------------------------------------------
-- PUBLIC API — Getters
------------------------------------------------------------------------

function WeaponClient:GetWeaponState(): string
	return self._weaponState
end

function WeaponClient:GetWeaponName(): string
	return self._weaponName
end

function WeaponClient:GetCurrentAmmo(): number
	return self._currentAmmo
end

function WeaponClient:GetReserveAmmo(): number
	return self._reserveAmmo
end

function WeaponClient:GetStats()
	return self._stats
end

function WeaponClient:IsEquipped(): boolean
	return self._weaponState == WS_EQUIPPED
end

--- Devuelve true si el arma está en transición (Equipping o Unequipping).
--- Durante transiciones NO se puede disparar, recargar ni cambiar de arma.
function WeaponClient:IsTransitioning(): boolean
	return TRANSITION_STATES[self._weaponState] == true
end

--- Devuelve true si el arma puede ejecutar acciones (disparar, recargar).
--- Solo true cuando el arma está completamente Equipped.
function WeaponClient:CanAct(): boolean
	return self._weaponState == WS_EQUIPPED
end

------------------------------------------------------------------------
-- PRIVATE — Tool events
------------------------------------------------------------------------

function WeaponClient:_onToolEquipped()
	self._isToolEquipped = true

	-- Solo equipar si el PlayerState lo permite
	local currentState = self._stateMachine and self._stateMachine:GetCurrentState()
	if currentState and FORCE_UNEQUIP_STATES[currentState] then
		return
	end

	-- Cancelar cualquier transición previa (ej: estaba unequipping)
	self:_cancelTransition()

	-- Identificar arma: re-leer atributo por si cambió (pickup de suelo)
	local newName = self._tool:GetAttribute("WeaponName") or self._tool.Name
	if newName ~= self._weaponName then
		self._weaponName = newName
		self._stats = WeaponConstants.STATS[self._weaponName]
		self._effects = WeaponConstants.EFFECTS[self._weaponName]

		if not self._stats then
			warn("[WeaponClient] Arma no encontrada en STATS al equipar: " .. tostring(self._weaponName))
		end

		-- Reiniciar munición al obtener arma nueva
		self._currentAmmo = if self._stats then self._stats.MagazineSize else 0
		self._reserveAmmo = if self._stats then self._stats.MagazineSize * 3 else 0
		self.AmmoChanged:Fire(self._currentAmmo, self._reserveAmmo)
	end

	-- Iniciar transición Equipping → (timer) → Equipped
	self:_setWeaponState(WS_EQUIPPING)

	self._transitionThread = task.delay(WeaponConstants.EQUIP_TIME, function()
		self._transitionThread = nil

		-- Verificar que seguimos en Equipping (no fue cancelado)
		if self._weaponState ~= WS_EQUIPPING then
			return
		end

		self:_setWeaponState(WS_EQUIPPED)
		self.WeaponEquipped:Fire(self._weaponName, self._stats)

		-- Notificar al servidor
		if self._weaponRemote then
			self._weaponRemote:FireServer("Equip", self._weaponName)
		end
	end)
end

function WeaponClient:_onToolUnequipped()
	self._isToolEquipped = false

	-- Cancelar cualquier transición previa (ej: estaba equipping)
	self:_cancelTransition()

	-- Si ya está Unequipped, no hacer nada
	if self._weaponState == WS_UNEQUIPPED then
		return
	end

	-- Iniciar transición Unequipping → (timer) → Unequipped
	self:_setWeaponState(WS_UNEQUIPPING)

	self._transitionThread = task.delay(WeaponConstants.UNEQUIP_TIME, function()
		self._transitionThread = nil

		-- Verificar que seguimos en Unequipping
		if self._weaponState ~= WS_UNEQUIPPING then
			return
		end

		self:_setWeaponState(WS_UNEQUIPPED)
		self.WeaponUnequipped:Fire(self._weaponName)

		-- Notificar al servidor
		if self._weaponRemote then
			self._weaponRemote:FireServer("Unequip", self._weaponName)
		end
	end)
end

------------------------------------------------------------------------
-- PRIVATE — PlayerState observer
------------------------------------------------------------------------

function WeaponClient:_onPlayerStateChanged(newState: string)
	if FORCE_UNEQUIP_STATES[newState] then
		-- Forzar unequip INSTANTÁNEO (sin timer) — estados críticos
		-- como Death, DBNO, RoadieRun no pueden esperar el timer.
		self:_cancelTransition()

		if self._weaponState ~= WS_UNEQUIPPED then
			self:_setWeaponState(WS_UNEQUIPPED)
		end
	else
		-- Si el Tool está físicamente equipado y el estado lo permite,
		-- re-equipar automáticamente al volver a un estado libre.
		-- Pasa por Equipping con su timer normal.
		if self._isToolEquipped and self._weaponState == WS_UNEQUIPPED then
			self:_onToolEquipped()
		end
	end
end

------------------------------------------------------------------------
-- PRIVATE — Transition timer management
------------------------------------------------------------------------

--- Cancela cualquier thread de transición activo (equip/unequip timer).
--- Llamar SIEMPRE antes de iniciar una nueva transición o al forzar estado.
function WeaponClient:_cancelTransition()
	if self._transitionThread then
		task.cancel(self._transitionThread)
		self._transitionThread = nil
	end
end

------------------------------------------------------------------------
-- PRIVATE — State management
------------------------------------------------------------------------

function WeaponClient:_setWeaponState(newState: string)
	if self._weaponState == newState then
		return
	end
	local oldState = self._weaponState
	self._weaponState = newState
	self.WeaponStateChanged:Fire(newState, oldState)
end

return WeaponClient
