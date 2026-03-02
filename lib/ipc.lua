local process = package.require("process")

local ipc = {}
ipc.handlers = {}
ipc.DEFAULT_TIMEOUT = 5 -- seconds

function ipc.call(name, ...)
    if not ipc.handlers[name] then
        return false, "IPC handler not found: " .. tostring(name)
    end
    -- Yield to the scheduler; it will dispatch the call and resume us with
    -- the handler's return values set directly in sysret.
    return coroutine.yield("ipc_call", name, table.pack(...))
end

function ipc.register(name, handler)
    if ipc.handlers[name] then
        return false, "Handler already exists"
    end
    
    local proc = process.getCurrentProcess()
    --if not proc then
    --    return false, "No active process"
    --end
    
    -- Add cleanup hook.
    -- NOTE: on/off/emit are plain functions (not methods), use . not : syntax.
    if proc then
        proc.on("exit", function()
            ipc.handlers[name] = nil
        end)
    end
    
    ipc.handlers[name] = {
        handler = handler,
        process = proc,
        registered = computer.uptime()
    }
    return true
end

function ipc.unregister(name)
    if not ipc.handlers[name] then
        return false, "Handler doesn't exist"
    end
    
    local proc = process.getCurrentProcess()
    if proc ~= ipc.handlers[name].process then
        return false, "Not handler owner"
    end
    
    ipc.handlers[name] = nil
    return true
end

-- New helper functions
function ipc.list()
    local handlers = {}
    for name, data in pairs(ipc.handlers) do
        handlers[name] = {
            process = data.process.pid,
            registered = data.registered
        }
    end
    return handlers
end

function ipc.cleanup()
    for name, data in pairs(ipc.handlers) do
        if data.process.status == "dead" then
            ipc.handlers[name] = nil
        end
    end
end

function ipc.tick_me(event)
    if event[1] == "ipc_request" then
        local name     = event[2]
        local caller   = event[3]  -- the process that made the ipc_call
        local args     = event[4] or {}  -- handler_args table (NOT unpacked)
        local handler  = ipc.handlers[name]

        if not handler then
            printk("ipc.tick_me: received request for unknown handler '" .. tostring(name) .. "'", "warn")
            return false
        end

        local cur = process.currentProcess
        if cur ~= handler.process then
            local cur_pid = cur and tostring(cur.pid) or "(kernel)"
            printk("ipc.tick_me: process " .. cur_pid ..
                " received ipc_request for '" .. name ..
                "' but owner is pid " .. tostring(handler.process and handler.process.pid) ..
                " — dropping", "warn")
            return false
        end

        printk("ipc.tick_me: dispatching '" .. name ..
            "' for caller pid " .. tostring(caller and caller.pid), "debug")

        local ok, res = xpcall(function()
            return table.pack(handler.handler(table.unpack(args, 1, args.n)))
        end, function(e)
            return e .. "\n" .. debug.traceback("", 2)
        end)

        if not ok then
            printk("ipc.tick_me: handler '" .. name .. "' crashed: " .. tostring(res), "error")
            res = table.pack(false, "IPC handler error: " .. tostring(res))
        end

        if coroutine.isyieldable() then
            coroutine.yield("ipc_response", caller.pid, table.unpack(res, 1, res.n))
        else
            return { "ipc_response", caller.pid, table.unpack(res, 1, res.n) }
        end
        return true
    end
end

return ipc