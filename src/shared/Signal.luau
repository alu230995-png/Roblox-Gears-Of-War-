--[[
	Signal.luau
	Implementación mínima de señales para comunicación entre módulos.
	Patrón Observer sin dependencias externas.
]]

local Signal = {}
Signal.__index = Signal

function Signal.new()
	local self = setmetatable({}, Signal)
	self._listeners = {}
	return self
end

function Signal:Connect(fn: (...any) -> ())
	table.insert(self._listeners, fn)
	return {
		Disconnect = function()
			local idx = table.find(self._listeners, fn)
			if idx then
				table.remove(self._listeners, idx)
			end
		end,
	}
end

function Signal:Fire(...)
	for _, listener in self._listeners do
		listener(...)
	end
end

function Signal:Destroy()
	table.clear(self._listeners)
end

return Signal
