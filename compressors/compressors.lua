local component = require("component")
local serialization = require("serialization")

local transposers = {}
for address, name in component.list("transposer", false) do
    print(address)
    table.insert(transposers, component.proxy(address))
end

print(serialization.serialize(transposers, true))
