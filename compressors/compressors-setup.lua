local component = require("component")
local filesystem = require("filesystem")
local term = require("term")

local transposers = {}
local i = 0
for address, name in component.list("transposer", false) do
    print((i + 1) .. ": " .. address)
    transposers[i] = address
    i = i + 1
end

print("Which is the recipe transposer? (enter a number)")
local choice = tonumber(term.read()) - 1

local transposer = transposers[choice]

local file = filesystem.open("/etc/compressors.cfg", "w")
file:write(transposer)
file:close()

print()
print("Written to /etc/compressors.cfg")
