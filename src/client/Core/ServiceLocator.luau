--[[
	ServiceLocator.luau
	Registry singleton de todos los sistemas del cliente.
	Permite acceder a sistemas por nombre sin dependencias directas.
	
	Uso:
	  locator:Register("InputDetector", InputDetector.new())
	  locator:InitAll()   -- Fase 1: Init() sin side-effects
	  locator:StartAll()  -- Fase 2: Start() con conexiones
	  
	  -- Desde cualquier sistema:
	  local sm = locator:Get("StateMachine")
]]

local ServiceLocator = {}
ServiceLocator.__index = ServiceLocator

local _instance = nil

function ServiceLocator.new()
	if _instance then
		return _instance
	end

	local self = setmetatable({}, ServiceLocator)
	self._services = {}
	self._initOrder = {}
	_instance = self
	return self
end

--- Registra un sistema con un nombre único.
--- @param name string — Nombre del servicio
--- @param service any — Instancia del servicio (debe tener Init/Start/Destroy opcionales)
function ServiceLocator:Register(name: string, service: any)
	if self._services[name] then
		warn(`[ServiceLocator] Servicio ya registrado: {name}`)
		return
	end

	self._services[name] = service
	table.insert(self._initOrder, name)
end

--- Obtiene un servicio por nombre.
--- @param name string — Nombre del servicio
--- @return any — Instancia del servicio, o nil si no existe
function ServiceLocator:Get(name: string): any
	local service = self._services[name]
	if not service then
		warn(`[ServiceLocator] Servicio no encontrado: {name}`)
	end
	return service
end

--- Fase 1: Init() de todos los servicios en orden de registro.
--- Init() no debe crear conexiones ni tener side-effects.
function ServiceLocator:InitAll()
	for _, name in self._initOrder do
		local service = self._services[name]
		if service.Init then
			service:Init()
		end
	end
end

--- Fase 2: Start() de todos los servicios en orden de registro.
--- Start() crea conexiones, signals y arranca lógica.
function ServiceLocator:StartAll()
	for _, name in self._initOrder do
		local service = self._services[name]
		if service.Start then
			service:Start()
		end
	end
end

--- Destruye todos los servicios en orden inverso.
--- Limpia conexiones y libera recursos.
function ServiceLocator:DestroyAll()
	for i = #self._initOrder, 1, -1 do
		local name = self._initOrder[i]
		local service = self._services[name]
		if service.Destroy then
			service:Destroy()
		end
	end
	table.clear(self._services)
	table.clear(self._initOrder)
end

return ServiceLocator
