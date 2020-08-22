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
    return firstAvailableSlot(transposer, side, nil)
end

function firstAvailableSlot(transposer, side, maxSize)
    local stacks = transposer.getAllStacks(side)
    local slot = 0
    while true do
        local stack = stacks()
        slot = slot + 1
        if stack == nil then
            return nil
        end
        if next(stack) == nil or (maxSize ~= nil and stack.size < maxSize) then
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
                    -- move the one item to the output crate
                    recipeTransposer.transferItem(R_INPUT_CRATE, R_OUTPUT_CRATE, 1, slot, outputSlot)
    
                    -- TODO: initiate a craft for 9999 of the item

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
        if stack ~= nil and getItemName(stack) ~= itemName then
            print("ME interface " .. delivery.addr .. " expected " .. itemName .. " slot " .. delivery.slot .. " but was " .. getItemName(stack))
        elseif stack ~= nil and stack.size > 0 then
            local outputSlot = firstAvailableSlot(delivery.proxy, D_CRATE_SIDE, stack.maxSize)
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

