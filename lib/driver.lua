local ret = {}
local fs = package.require("fs")
local reg = package.require("registry")
local ipc = package.require("ipc")
local process = package.require("process")
local cp = component
ret.loaded = {}
local drivers = {}
local driver_cache = {}  -- stores raw driver instances (kernel-side only)

function generate_unique_id()
    -- generate a unique id, 16 chars a-z0-9
    local id = ""
    for i = 1, 16 do
        local r = math.random(1, 36)
        if r <= 26 then
            id = id .. string.char(r + 96)
        else
            id = id .. string.char(r + 21)
        end
    end
    return id
end

function ret.getDriver(path)
    if not ret.loaded[path] then
        printk("Loading driver " .. path)
        local driverPath = "/driver/" .. path
        if fs.exists(driverPath) then
            ret.loaded[path] = raw_dofile(driverPath)
            local type = path:match("(.*)/(.*)")
            printk("Driver type: " .. type)
            ret.loaded[path].type = type
        else
            error('Driver doesn\'t exist')
        end
    end
    local d = ret.loaded[path]

    return d
end

function ret.getBest(type, addr)
    --[[if not type then
        -- check all types
        for k,v in fs.list("/driver") do
            for kk,vv in fs.list("/driver/"..k) do
                print(k..", "..kk)
                local d = ret.getDriver(k..""..kk)
                if d.compatible(addr) then
                    return d
                end
            end
        end
        return nil
    end
    for k,v in fs.list("/driver/"..type) do
        local d = ret.getDriver(type.."/"..k)
        if d.compatible(addr) then
            return d
        end
    end]]
    -- first check loaded drivers
    for k, v in pairs(ret.loaded) do
        if v and v.compatible(addr) and (not type or v.type == type) then
            return v
        end
    end
    -- then check all drivers
    if not type then
        -- check all types
        for k, v in fs.list("/driver") do
            for kk, vv in fs.list("/driver/" .. k) do
                print(k .. ", " .. kk)
                local d = ret.getDriver(k .. "" .. kk)
                if d.compatible(addr) then
                    return d
                end
            end
        end
        return nil
    end
    for k, v in fs.list("/driver/" .. type) do
        local d = ret.getDriver(type .. "/" .. k)
        if d.compatible(addr) then
            return d
        end
    end
    return nil
end

--- get the default driver for a type
--- @param type string
--- This function returns a table and a string. If the table is nil, the string will also be nil.
--- @return table|nil, string|nil
function ret.getDefault(type)
    local defa = nil
    if type == "drive" then
        return ret.getBest(type, computer.getBootAddress())
    end
    for k, v in pairs(cp.list()) do
        local d = ret.getBest(type, k)
        if d then
            return d, k
        end
    end

    return defa
end

-- we return the info (version, name, etc)
function ret.getinfo(type, addr)
    if not addr then addr = "default" end

    if addr == "default" then
        local d, addra = ret.getDefault(type)
        if d then
            return d.getName(), d.getVersion(), addra
        else
            return nil, "No driver found"
        end
    else
        local d = ret.getBest(type, addr)
        if d then
            return d.getName(), d.getVersion(), addr
        else
            return nil, "No driver found"
        end
    end
end

local segg = function(e)
    return e, debug.traceback("", 1)
end

--- Instantiate a raw driver object for an address. This is KERNEL-ONLY;
--- processes must never receive the raw instance — they get a syscall proxy.
local function newdriver(d, addr)
    printk("[driver] instantiating driver '" .. d.getName() .. "' for addr " .. tostring(addr), "debug")
    local ok, dd, tb = xpcall(d.new,
        function(e) return e, debug.traceback("", 1) end, addr)
    if not ok then
        bsod("Failed to load driver: " .. dd, false, tb)
    end
    dd.getDriverName    = d.getName
    dd.getDriverVersion = d.getVersion
    return dd
end

function ret.load(typed, addr)
    if not addr then addr = "default" end

    -- Step 1: resolve "default" to an actual address and driver module.
    local resolved_addr = addr
    local d_module = nil
    if addr == "default" then
        d_module, resolved_addr = ret.getDefault(typed)
        if not (d_module and resolved_addr) then
            return nil, "No drivers found for type: " .. tostring(typed)
        end
    else
        d_module = ret.getBest(typed, addr)
        if not d_module then
            return nil, "No driver found for addr: " .. tostring(addr) ..
                " type: " .. tostring(typed)
        end
    end

    -- Step 2: get or create the raw driver instance in the kernel cache.
    -- driver_cache is kernel-internal; processes must never receive it directly.
    local dd = driver_cache[resolved_addr]
    if not dd then
        dd = newdriver(d_module, resolved_addr)
        dd.getDriverName    = d_module.getName
        dd.getDriverVersion = d_module.getVersion
        dd.address = resolved_addr
        driver_cache[resolved_addr] = dd
        printk("[driver] cached '" .. d_module.getName() ..
            "' at " .. tostring(resolved_addr), "debug")
    end

    -- Step 3: return a syscall proxy to processes, raw driver to kernel.
    -- The proxy routes every function call through coroutine.yield("driver", ...)
    -- so only the scheduler (tickProcess) ever calls the real driver methods —
    -- the process itself never has direct access.
    if process.currentProcess ~= nil then
        printk("[driver] proxy for '" .. d_module.getName() ..
            "' issued to pid " .. process.currentProcess.pid, "debug")
        local dd_proxy = {}
        setmetatable(dd_proxy, {
            __index = function(t, k)
                local raw = dd[k]
                if type(raw) == "function" then
                    return function(...)
                        return coroutine.yield("driver", resolved_addr, k, ...)
                    end
                else
                    return raw
                end
            end
        })
        return dd_proxy
    else
        printk("[driver] kernel-side load of '" .. d_module.getName() ..
            "' at " .. tostring(resolved_addr), "warn")
        return dd
    end
end

--- Returns the raw (kernel-side) driver instance from the cache.
--- Must only be called from the kernel / scheduler (tickProcess).
--- Processes must never call this — they receive proxies from ret.load().
--- @param addr string Component address.
--- @return table|nil Raw driver instance or nil if not cached.
function ret.fromCache(addr)
    return driver_cache[addr]
end

return ret
