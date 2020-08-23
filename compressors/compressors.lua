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

-- find any me interface
local interfaces = component.list("me_interface", true)
local meInterfaceAddr = next(interfaces)
assert(meInterfaceAddr ~= nil, "Need an adapter hooked to an ME interface")
local meInterface = component.proxy(meInterfaceAddr)
assert(meInterface ~= nil, "Failed to proxy ME interface")

function makeAe2Filter(stack)
    local filter = {}
    filter.name = stack.name
    filter.label = stack.label
    filter.hasTag = stack.hasTag
    filter.damage = stack.damage
    return filter
end

function getAe2Amount(stack)
    local filter = makeAe2Filter(stack)

    local itemsInNetwork = meInterface.getItemsInNetwork(filter)
    if itemsInNetwork == nil then
        return 0
    end
    assert(#itemsInNetwork < 2, "getAe2Amount: filter not specific enough: " .. serialization.serialize(filter) .. " from " .. serialization.serialize(stack))
    if #itemsInNetwork > 0 then
        local stackInNetwork = next(itemsInNetwork)
        return stackInNetwork.size
    end
    return 0
end

function getCraftable(stack)
    local filter = makeAe2Filter(stack)

    local craftables = meInterface.getCraftables(filter)
    if craftables == nil then
        return nil
    end
    assert(#craftables < 2, "getCraftable: filter not specific enough: " .. serialization.serialize(filter) .. " from " .. serialization.serialize(stack))
    if #craftables > 0 then
        local craftable = next(craftables)
        return craftable
    end
    return nil
end

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
            if stack ~= nil and getItemName(stack) == itemName then
                local delivery = {}
                delivery.addr = addr
                delivery.proxy = proxy
                delivery.slot = slot
                cacheItemToDeliveryTransposer[itemName] = delivery
                return delivery
            end
        end
    end

    -- not found
    return nil
end

function getItemName(stack)
    if stack == nil then
        return nil
    end
    return stack.name .. "-" .. stack.label
end

function firstEmptySlot(transposer, side)
    return firstAvailableSlot(transposer, side, nil, nil)
end

function firstAvailableSlot(transposer, side, itemName, maxSize)
    local stacks = transposer.getAllStacks(side)
    local slot = 0
    while true do
        local stack = stacks()
        slot = slot + 1
        if stack == nil then
            return nil
        end
        if next(stack) == nil then
            return slot
        end
        if itemName ~= nil and maxSize ~= nil and getItemName(stack) == itemName and stack.size < maxSize then
            return slot
        end
    end
end

local jobQueue = {}

function pollInputCrate()
    local outputSlot = firstEmptySlot(recipeTransposer, R_OUTPUT_CRATE)
    if outputSlot == nil then
        print("No empty slots in output crate")
        return
    end

    -- get a stack from the recipe transposer input crate
    local inputStacks = recipeTransposer.getAllStacks(R_INPUT_CRATE)
    local slot = 0
    while true do
        local stack = inputStacks()
        slot = slot + 1
        if stack == nil then
            -- no input
            break
        end
        if next(stack) ~= nil then
            local itemName = getItemName(stack)
            -- (if there is already an ongoing job for this item, leave it in the input chest)
            if jobQueue[itemName] == nil then
                local delivery = findDeliveryTransposerForItem(itemName)
                if delivery == nil then
                    print("No delivery transposer for " .. itemName)
                else
                    -- check if we already have 9999 of the item, and if not, start a craft
                    local ae2Amount = getAe2Amount(stack)
                    if ae2Amount < 9999 then
                        local amountToRequest = 9999 - ae2Amount
                        local craftable = getCraftable(stack)
                        if craftable ~= nil then
                            craftable.request(amountToRequest)
                            print("Craft requested: " .. amountToRequest .. " " .. itemName)
                        else
                            print("Could not find craft for " .. itemName .. ", relying on ME interface on-demand crafting")
                        end
                    end

                    -- move the one item to the output crate
                    recipeTransposer.transferItem(R_INPUT_CRATE, R_OUTPUT_CRATE, 1, slot, outputSlot)

                    -- queue up 9999 more items
                    print("Queueing " .. itemName)

                    local queueItem = {}
                    queueItem.remaining = 9999
                    queueItem.delivery = delivery
                    jobQueue[itemName] = queueItem
    
                    -- If we wanted to pull more items in this go then we would need to find
                    -- a new output slot for each of them. Let's just break.
                    break
                end
            end
        end
    end
end

function processJobQueue()
    for itemName, queueItem in pairs(jobQueue) do
        local remaining = queueItem.remaining
        local delivery = queueItem.delivery

        local stack = delivery.proxy.getStackInSlot(D_MEINTERFACE_SIDE, delivery.slot)
        local stackItemName = getItemName(stack)
        if stack ~= nil and stackItemName ~= itemName then
            print("ME interface " .. delivery.addr .. " expected " .. itemName .. " slot " .. delivery.slot .. " but was " .. getItemName(stack))
        elseif stack ~= nil and stack.size > 0 then
            local outputSlot = firstAvailableSlot(delivery.proxy, D_CRATE_SIDE, stackItemName, stack.maxSize)
            if outputSlot == nil then
                print("Output full: " .. delivery.addr)
            else
                local amount = stack.size
                if amount > remaining then
                    amount = remaining
                end
                amount = delivery.proxy.transferItem(D_MEINTERFACE_SIDE, D_CRATE_SIDE, amount, delivery.slot, outputSlot)
                queueItem.remaining = queueItem.remaining - amount
                print("Moved " .. amount .. " " .. itemName .. ", " .. queueItem.remaining .. " remaining")
                if queueItem.remaining <= 0 then
                    jobQueue[itemName] = nil
                end
            end
        else
            print("Waiting for " .. itemName .. " to restock")
        end
    end
end

while true do
    pollInputCrate()
    processJobQueue()
    if next(jobQueue) == nil then
        -- print("No jobs")
        os.sleep(10)
    else
        os.sleep(1)
    end
end



-- local tmpfile = filesystem.open("/tmp/output.txt", "w")
-- tmpfile:write(serialization.serialize(recipeTransposer, true))
-- tmpfile:close()

