local component = require("component")
local filesystem = require("filesystem")
local serialization = require("serialization")
local sides = require("sides")

-- config

local R_INPUT_CRATE = sides.east
local R_OUTPUT_CRATE = sides.up
local D_MEINTERFACE_SIDE = sides.north
local D_CRATE_SIDE = sides.south

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

local cacheItemToDeliveryTransposer = {}
function findDeliveryTransposerForItem(itemName)
    local cached = cacheItemToDeliveryTransposer[itemName]
    if cached ~= nil then
        return cached
    end

    for addr,proxy in pairs(deliveryTransposers) do
        -- the delivery transposer has an ME interface against it
        -- on side D_MEINTERFACE_SIDE
        -- which has known slots
        for slot=1,9 do
            local stack = proxy.getStackInSlot(D_MEINTERFACE_SIDE, slot)
            if stack["name"] == itemName then
                local ret = {}
                ret["addr"] = addr
                ret["proxy"] = proxy
                ret["slot"] = slot
                cacheItemToDeliveryTransposer[itemName] = ret
                return ret
            end
        end
    end

    -- not found
    return nil
end

function firstEmptySlot(transposer, side)
    local stacks = transposer.getAllStacks(side)
    local slot = 0
    while true do
        local stack = inputStacks()
        slot = slot + 1
        if stack == nil then
            return nil
        end
        if next(stack) == nil then
            return slot
        end
    end
end

-- get a stack from the recipe transposer input crate
local inputStacks = recipeTransposer.getAllStacks(R_INPUT_CRATE)
local slot = 0
while true do
    local stack = inputStacks()
    slot = slot + 1
    if stack == nil then
        break
    end
    if next(stack) ~= nil then
        local itemName = stack["name"]
        local delivery = findDeliveryTransposerForItem(itemName)
        assert(delivery ~= nil, "Could not find delivery transposer for " .. itemName)

        -- move the one item to the output crate
        local outputSlot = firstEmptySlot(recipeTransposer, R_OUTPUT_CRATE)
        assert(outputSlot ~= nil, "No empty slots in output crate")
        recipeTransposer.transferItem(R_INPUT_CRATE, R_OUTPUT_CRATE, 1, slot, outputSlot)

        -- make the delivery transposer move 9999 of the item
        print("need to move 9999 more " .. itemName)
        break
    end
end


local tmpfile = filesystem.open("/tmp/output.txt", "w")
tmpfile:write(serialization.serialize(recipeTransposer, true))
tmpfile:close()

