local fs = require("fs")
local args = ...   -- shell passes the full args table as the first vararg

local path = args and args[2]

if not path or path == "" then
    print("Usage: cat <file>")
    return
end

-- Resolve relative paths against the current directory
if path:sub(1, 1) ~= "/" then
    path = (os.currentDirectory or "/") .. "/" .. path
end

local file, reason = fs.open(path, "r")
if not file then
    print("cat: " .. tostring(path) .. ": " .. tostring(reason or "file not found"))
    return
end

-- OC fs.read expects a byte count, not "*a"
while true do
    local data, err = file:read(2048)
    if not data then
        if err then
            print("cat: read error: " .. tostring(err))
        end
        break
    end
    io.write(data)
end

file:close()
