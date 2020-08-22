local component = require("component")
local filesystem = require("filesystem")
local serialization = require("serialization")

-- load the address of the recipe transposer
local file = filesystem.open("/etc/compressors.cfg", "r")
local recipeTransposerAddress = file:read(100)
file:close()

-- open the transposer proxies
local recipeTransposer
local deliveryTransposers = {}
local deliveryTransposersCount = 0
for address, name in component.list("transposer", false) do
    local proxy = component.proxy(address)
    if address == recipeTransposerAddress then
        recipeTransposer = proxy
    else
        deliveryTransposers[address] = proxy
        deliveryTransposersCount = deliveryTransposersCount + 1
    end
end

assert(recipeTransposer ~= nil, "Could not find the recipe transposer " .. recipeTransposerAddress)
assert(deliveryTransposersCount > 0, "Found no delivery transposers")

-- 

local tmpfile = filesystem.open("/tmp/output.txt", "w")
tmpfile:write(serialization.serialize(recipeTransposer, true))
tmpfile:close()

