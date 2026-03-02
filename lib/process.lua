local api = {}
api.processes = {}
api.signal = {}
api.currentProcess = nil

function api.getCurrentProcess()
    return api.currentProcess
end

local unusedTime = 0
local security = package.require("security")
local reg    = package.require("registry")
local stream = package.require("stream")
local nextPid = 1
local usedTime = 0
local _signal = nil

-- syscall dispatch table. kernel registers handlers here, processes yield into them
local SYSCALL_TABLE = {}

--- @param name    string
--- @param handler function  handler(proc, args)
function api.registerSyscall(name, handler)
    if api.currentProcess ~= nil then
        error("registerSyscall: not permitted from a userspace process ('" ..
            tostring(name) .. "' blocked for pid " .. api.currentProcess.pid .. ")", 2)
    end
    if SYSCALL_TABLE[name] then
        printk("[syscall] overwriting handler for '" .. name .. "'", "warn")
    end
    SYSCALL_TABLE[name] = handler
end

api.registerSyscall("ipc_call", function(proc, args)
    local handler_name = args[1]
    local handler_args = args[2]  -- table.pack'd by ipc.call / syscall.ipc
    local handler = require("ipc").handlers[handler_name]

    if not handler then
        printk("[syscall] ipc_call '" .. tostring(handler_name) .. "' — no handler registered", "warn")
        proc.sysret = table.pack(false, "IPC handler not found: " .. tostring(handler_name))
        return
    end

    if handler.process then
        local hpStatus = handler.process.status
        if hpStatus == "dying" or hpStatus == "dead" then
            printk("[syscall] ipc_call '" .. tostring(handler_name) ..
                "': handler process (pid " .. tostring(handler.process.pid) ..
                ") is " .. hpStatus .. ", cleaning up and returning error", "warn")
            require("ipc").handlers[handler_name] = nil
            proc.sysret = table.pack(false, "IPC handler process is dead")
            return
        end
        table.insert(handler.process.io.signal.queue, {
            "ipc_request",
            handler_name,
            proc,
            handler_args  -- kept as table; tick_me unpacks
        })
        proc.status = "suspended"
        proc.ipc_waiting = true
    else
        local ok, res = xpcall(function()
            return table.pack(handler.handler(
                table.unpack(handler_args, 1, handler_args.n)))
        end, function(e)
            return e .. "\n" .. debug.traceback("", 2)
        end)
        if not ok then
            printk("[syscall] ipc_call '" .. handler_name .. "' kernel handler crashed: " .. tostring(res), "error")
            proc.sysret = table.pack(false, "IPC handler error: " .. tostring(res))
        else
            proc.sysret = res
        end
        proc.status = "running"
        proc.ipc_waiting = false
    end
end)

api.registerSyscall("ipc_response", function(proc, args)
    local target_pid = args[1]
    for _, waiting_proc in ipairs(api.processes) do
        if waiting_proc.pid == target_pid then
            waiting_proc.status = "running"
            waiting_proc.ipc_waiting = false
            waiting_proc.sysret = table.pack(table.unpack(args, 2))
            break
        end
    end
end)

api.registerSyscall("driver", function(proc, args)
    local driverAddr     = table.remove(args, 1)
    local driverFuncName = table.remove(args, 1)
    local driverArgs     = args

    local drv = package.require("driver").fromCache(driverAddr)
    if not drv then
        printk("[syscall] driver " .. tostring(driverAddr) ..
            " not in cache (pid " .. proc.pid .. ")", "warn")
        proc.sysret = table.pack(false,
            "Driver not loaded or not in cache: " .. tostring(driverAddr))
        return
    end

    local driverMethod = drv[driverFuncName]
    if not driverMethod then
        printk("[syscall] driver function '" .. tostring(driverFuncName) ..
            "' not found on " .. tostring(driverAddr), "warn")
        proc.sysret = table.pack(false,
            "Driver function not found: " .. tostring(driverFuncName))
        return
    end

    local ok, res = xpcall(function()
        return table.pack(driverMethod(table.unpack(driverArgs)))
    end, function(e)
        return e .. "\n" .. debug.traceback("", 2)
    end)
    if not ok then
        printk("[syscall] driver " .. tostring(driverAddr) ..
            "." .. tostring(driverFuncName) .. "() crashed: " .. tostring(res), "error")
        proc.sysret = table.pack(false, "Driver error: " .. tostring(res))
    else
        proc.sysret = res
    end
end)

api.registerSyscall("stdin_read", function(proc, args)
    local n   = args[1]
    local fd0 = proc.io.fd and proc.io.fd[0]
    if not fd0 then
        proc.sysret = table.pack(nil, "no stdin fd")
        return
    end
    if proc.io.ld then
        if not proc.io.ld._beginX then
            proc.io.ld._beginX = proc.tty and proc.tty.cx or 1
        end
        if proc.tty then proc.tty:setBlink(true) end
    end
    if fd0.canRead() then
        local data, err = fd0.tryRead(n)
        proc.sysret = table.pack(data, err)
    else
        proc.status          = "blocked_stdin"
        proc._pending_read_n = n
    end
end)

--- @param thread thread
--- @param process? table
--- @return table?
api.findByThread = function(thread, process)
    -- process is optional
    process = process or api.processes

    for _, subProcess in ipairs(process) do
        if subProcess.thread == thread then
            return subProcess
        elseif #subProcess.processes > 0 then
            local t = api.findByThread(thread, subProcess.processes)
            if t then
                return t
            end
        end
    end
end

--- @return boolean?
api.isProcess = function()
    if api.currentProcess then
        return true
    end
end

--- @param proc  table
--- @param extra table|nil
--- @return table
local function makeProcessEnv(proc, extra)
    local env = {}
    local PASSTHROUGH = {
        "math", "string", "table", "io", "os", "utf8",
        "ipairs", "pairs", "next", "select",
        "tostring", "tonumber", "type",
        "pcall", "xpcall", "error", "assert",
        "rawget", "rawset", "rawequal", "rawlen",
        "setmetatable", "getmetatable",
        "require", "package",
        "load", "loadstring", "loadfile", "dofile",
        "checkArg", "printk", "print", "printf",
        "debug", "coroutine", "unpack",
        "terminal",  -- display/color manager; always available
    }
    for _, k in ipairs(PASSTHROUGH) do
        if _G[k] ~= nil then env[k] = _G[k] end
    end

    env.syscall = package.require("syscall")

    local BLOCKED = { component = true, computer = true }  -- no raw hw access. ever

    env._G = env

    setmetatable(env, {
        __index = function(_, k)
            if BLOCKED[k] then
                error(
                    "process '" .. tostring(proc.name or "?") ..
                    "' (pid " .. tostring(proc.pid or "?") ..
                    ") attempted direct access to blocked global '" .. k ..
                    "' — use syscall.driver() instead", 2)
            end
            return _G[k]
        end,
        __newindex = function(t, k, v)
            if BLOCKED[k] then
                error(
                    "process '" .. tostring(proc.name or "?") ..
                    "' attempted to overwrite blocked global '" .. k .. "'", 2)
            end
            rawset(t, k, v)
        end,
    })

    if type(extra) == "table" then
        for k, v in pairs(extra) do rawset(env, k, v) end
    end

    return env
end

--- @param name string
--- @param code string
--- @param env? table
--- @param perms? table
--- @param inService? boolean
--- @return table
api.new = function(name, code, env, perms, inService, ...)
    local ret = {}
    ret.listeners = {}
    ret.on = function(event, callback)
        table.insert(ret.listeners, {
            event = event,
            callback = callback
        })
    end
    ret.off = function(event, callback)
        for k, v in pairs(ret.listeners) do
            if v.event == event and v.callback == callback then
                table.remove(ret.listeners, k)
            end
        end
    end
    ret.emit = function(event, ...)
        for k, v in pairs(ret.listeners) do
            if v.event == event then
                v.callback(...)
            end
        end
    end



    local _code = ""
    local i = 1
    local in_string = false
    local string_char = nil
    local in_comment = false
    local in_multiline_string = false

    while i <= #code do
        local c = code:sub(i,i)

        -- Handle multiline string detection
        if not in_string and not in_multiline_string and c == "[" and code:sub(i+1,i+1) == "[" then
            in_multiline_string = true
            _code = _code .. "[["
            i = i + 2
            goto continue
        elseif in_multiline_string and c == "]" and code:sub(i+1,i+1) == "]" then
            in_multiline_string = false
            _code = _code .. "]]"  -- put ]] back obviously
            i = i + 2
            goto continue
        end

        -- Handle regular string detection
        if not in_multiline_string and not in_string and (c == '"' or c == "'") then
            in_string = true
            string_char = c
        elseif in_string and c == string_char and code:sub(i-1,i-1) ~= "\\" then
            in_string = false
        end

        -- Handle comment detection
        if not in_string and not in_multiline_string and c == "-" and code:sub(i+1,i+1) == "-" then
            in_comment = true
        elseif in_comment and c == "\n" then
            in_comment = false
        end

        -- Replace 'do' with 'do coroutine.yield()' only in actual code
        if not in_string and not in_multiline_string and not in_comment and 
            code:sub(i,i+1) == "do" and 
            (i == 1 or not code:sub(i-1,i-1):match("[%w_]")) and
            (i+2 > #code or not code:sub(i+2,i+2):match("[%w_]")) then
            _code = _code .. "do coroutine.yield();"
            i = i + 2
        else
            _code = _code .. c
            i = i + 1
        end

        ::continue::
    end

    local penv = makeProcessEnv(ret, env)
    ret.env = penv  -- store reference for debuggers / runtime inspection

    local code, err = load(_code, "=" .. name, nil, penv)
    if not code then
        printk("Failed to load process code: " .. err, "error")
        return
    end

    ret.thread = coroutine.create(code)
    ret.name = name or "not defined"
    ret.status = "running"
    ret.err = ""
    ret.args = table.pack(...)

    ret.io = {}
    ret.io.signal = {}
    ret.io.signal.pull = {}
    ret.io.signal.queue = {}
    ret.io.handles = {}
    ret.pid = nextPid
    ret.lastCpuTime = 0
    ret.cputime_avg = {}
    ret.processes = {}
    ret.io.screen = {}

    printk("load gpu drv")
    local gpu = package.require("driver").load("gpu")
    printk("loaded gpu drv")
    local sw, sh = gpu.getResolution()
    printk("got resolution")

    local TTY = package.require("tty")
    local parentTTY = api.currentProcess and api.currentProcess.tty
    if parentTTY then
        ret.tty = TTY.new(gpu, parentTTY.ox, parentTTY.oy, parentTTY.w, parentTTY.h)
        ret.tty.cx = parentTTY.cx
        ret.tty.cy = parentTTY.cy
    else
        ret.tty = TTY.new(gpu, 1, 1, sw, sh)
        if _G.io and _G.io.cursor then
            ret.tty.cx = _G.io.cursor.x or 1
            ret.tty.cy = _G.io.cursor.y or 1
        end
    end

    setmetatable(ret.io.screen, {  -- compat shim so old code reading io.screen.width doesnt explode
        __index = function(_, k)
            if k == "width"  then return ret.tty.w end
            if k == "height" then return ret.tty.h end
            if k == "offset" then
                return { x = ret.tty.ox - 1, y = ret.tty.oy - 1 }
            end
        end,
        __newindex = function(_, k, v)
            if k == "width"  then ret.tty:resize(v, ret.tty.h) end
            if k == "height" then ret.tty:resize(ret.tty.w, v) end
            if k == "offset" then ret.tty:move(v.x + 1, v.y + 1) end
        end,
    })
    ret.io.stdin  = stream.new()
    ret.io.stdout = stream.new()
    ret.io.stderr = stream.new()

    ret.signals = {}  -- POSIX-style. deliver via proc:signal("SIGINT") etc

    local LineDiscipline = package.require("linedisc")
    ret.io.ld     = LineDiscipline.new(ret.tty, { history = {} })
    ret.io.use_ld = true  -- set to false for GUI processes that want raw key events

    ret.io.fd = {}  -- fd[0]=stdin fd[1]=stdout fd[2]=stderr. shell may replace fd[0]/fd[1] with pipes
    ret.io.fd[0] = {
        canRead = function() return ret.io.ld:canRead() end,
        tryRead = function(n) return ret.io.ld:tryRead(n) end,
        write   = function() return nil, "stdin is not writable" end,
        name    = "stdin",
    }
    ret.io.fd[1] = {
        canRead = function() return false end,
        tryRead = function() return nil, "stdout is not readable" end,
        write   = function(data)
            local s = tostring(data)
            ret.tty:write(s)
            ret.io.stdout:write(s)
            return #s
        end,
        name    = "stdout",
    }
    ret.io.fd[2] = {
        canRead = function() return false end,
        tryRead = function() return nil, "stderr is not readable" end,
        write   = function(data)
            local s = tostring(data)
            ret.tty:write(s)
            ret.io.stderr:write(s)
            return #s
        end,
        name    = "stderr",
    }

    ret.ipc_waiting = false
    nextPid = nextPid + 1

    function ret:getCpuTime()
        return ret.lastCpuTime
    end

    function ret:getCpuPercentage()
        local allcputime = 0
        for k, v in ipairs(api.list()) do allcputime = allcputime + v:getCpuTime() end
        return ret.lastCpuTime > 0 and (math.min(((ret.lastCpuTime*1000)/50), 1)) or 0
    end

    function ret:getAvgCpuTime()
        local total = 0
        for k, v in ipairs(ret.cputime_avg) do total = total + v end
        return total / #ret.cputime_avg
    end

    function ret:getAvgCpuPercentage()
        local allcputime = 0
        for k, v in ipairs(api.list()) do allcputime = allcputime + v:getAvgCpuTime() end
        allcputime = allcputime + api.getAvgIdleTime()
        return allcputime > 0 and (math.min((ret:getAvgCpuTime()*1000)/50, 1)) or 0
    end

    function ret:kill()      self.status = "dying" end
    function ret:terminate() self.status = "dead"  end

    --- @param sig string  "SIGINT"|"SIGTERM"|"SIGKILL"|"SIGTSTP"|"SIGCONT"
    function ret:signal(sig)
        if self.status == "blocked_stdin" then
            if sig == "SIGINT" or sig == "SIGKILL" then
                if self.tty then self.tty:setBlink(false) end
                self.err    = "Killed (" .. sig .. ")"
                self.status = "dying"
                return
            elseif sig == "SIGTERM" then
                self.status = "dying"
                return
            end
        end
        table.insert(self.signals, sig)
    end

    function ret:getStatus() return self.status end

    if reg.get("system/processes/attach_security") == 1 then
        security.attach(ret)
    end

    if api.isProcess() then
        local p = api.currentProcess
        table.insert(p.processes, ret)
        ret.parent = p
    else
        table.insert(api.processes, ret)
    end

    printk("New process named " .. ret.name .. " with pid" .. ret.pid .. " created")

    return ret
end

--- @param name string
--- @param path string
--- @param perms table
--- @param forceRoot boolean
--- @return table?, string|boolean?
api.load = function(name, path, perms, forceRoot, ...)
    local fs = require("fs")
    if path:sub(1, 1) ~= "/" then
        path = (os.currentDirectory or "/") .. "/" .. path
    end
    local handle, open_reason = fs.open(path)
    if not handle then
        return nil, open_reason
    end
    local buffer = {}
    while true do
        local data, reason = handle:read(1024)
        if not data then
            handle:close()
            if reason then
                return nil, reason
            end
            break
        end
        buffer[#buffer + 1] = data
    end
    return api.new(name, table.concat(buffer), nil, perms, forceRoot, ...)
end

local toRemoveFromProc = {}
local driverCache = {}

api.tickProcess = function(process, event)

    if process.status == "blocked_stdin" then
        if not process.io.keyboard_muted then
            if event[1] == "key_down" and process.io.use_ld and process.io.ld then
                local sig, target = process.io.ld:processKey(event[3], event[4])
                if sig then (target or process):signal(sig) end
            elseif event[1] == "clipboard" and process.io.use_ld and process.io.ld then
                process.io.ld:pasteText(tostring(event[3] or ""))
            end
        end
        local fd0 = process.io.fd and process.io.fd[0]
        if fd0 and fd0.canRead() then
            local data, err = fd0.tryRead(process._pending_read_n)
            if process.tty then process.tty:setBlink(false) end
            process.sysret          = table.pack(data, err)
            process._pending_read_n = nil
            process.status          = "running"
        else
            if process.signals and #process.signals > 0 then
                local sig = process.signals[1]
                if sig == "SIGINT" or sig == "SIGKILL" then
                    table.remove(process.signals, 1)
                    if process.tty then process.tty:setBlink(false) end
                    process.err    = "Killed (" .. sig .. ")"
                    process.status = "dying"
                    return false
                elseif sig == "SIGTERM" then
                    table.remove(process.signals, 1)
                    process.status = "dying"
                    return false
                end
            end
            return false
        end
    end

    if process.status == "suspended" then
        if process.signals and #process.signals > 0 and process.signals[1] == "SIGCONT" then
            table.remove(process.signals, 1)
            process.status = "running"
        else
            return false
        end
    end

    if (process.status == "running" or process.status == "idle")
            and process.signals and #process.signals > 0 then
        local sig = process.signals[1]
        if sig == "SIGINT" or sig == "SIGKILL" then
            table.remove(process.signals, 1)
            process.err    = "Killed (" .. sig .. ")"
            process.status = "dying"
            return false
        elseif sig == "SIGTERM" then
            table.remove(process.signals, 1)
            process.err    = "Terminated"
            process.status = "dying"
            return false
        elseif sig == "SIGTSTP" then
            table.remove(process.signals, 1)
            process.status = "suspended"
            return false
        elseif sig == "SIGCONT" then
            table.remove(process.signals, 1)
            process.status = "running"
        else
            table.remove(process.signals, 1)  -- unknown signal: consume silently
        end
    end

    if process.status == "running" or process.status == "idle" then
        if coroutine.status(process.thread) == "suspended" then
            if event[1] then
                local isKeyboard  = (event[1] == "key_down" or event[1] == "key_up")
                local isClipboard = (event[1] == "clipboard")

                if isKeyboard and process.io.use_ld and process.io.ld then
                    -- in ld-mode we only deliver ^C and ^Z while running. echo happens in blocked_stdin
                    if event[1] == "key_down" and process.io.ld.signals then
                        local char   = event[3]
                        local target = process.io.ld.fg_proc or process
                        if char == 3  then target:signal("SIGINT")  end
                        if char == 26 then target:signal("SIGTSTP") end
                    end
                elseif isClipboard and process.io.use_ld and process.io.ld then
                    process.io.ld:pasteText(tostring(event[3] or ""))
                elseif not process.io.use_ld or not process.io.ld then
                    if not (isKeyboard and process.io.keyboard_muted) then
                        table.insert(process.io.signal.queue, event)
                    end
                elseif not isKeyboard and not isClipboard then
                    table.insert(process.io.signal.queue, event)
                end
            end

            local shouldResume = false
            if #process.io.signal.pull > 0 then
                local pullSignal = process.io.signal.pull[#process.io.signal.pull]
                if type(process.io.signal.queue[1]) == "table" and process.io.signal.queue[1][1] or ((computer.uptime() >= (pullSignal.timeout) + pullSignal.start_at)) then
                    shouldResume = true
                    process.io.signal.pull[#process.io.signal.pull].ret = process.io.signal.queue[1] or {}
                    if process.io.signal.queue[1] then
                        table.remove(process.io.signal.queue, 1)
                    end
                end
            else
                shouldResume = true
            end

            if shouldResume then
                local startTime = computer.uptime() * 1000
                api.currentProcess = process
                local resumeResult = { coroutine.resume(process.thread, table.unpack(process.sysret or process.args)) }
                process.sysret     = nil
                api.currentProcess = nil

                if not resumeResult[1] then
                    process.err = resumeResult[2] or "Died"
                else
                    if resumeResult[2] then
                        table.remove(resumeResult, 1)
                        local syscall_name    = table.remove(resumeResult, 1)
                        local syscall_handler = SYSCALL_TABLE[syscall_name]
                        if syscall_handler then
                            syscall_handler(process, resumeResult)
                        else
                            printk("[syscall] unknown syscall '" .. tostring(syscall_name) ..
                                "' from pid " .. process.pid, "warn")
                            process.sysret = table.pack(false, "Unknown syscall: " .. tostring(syscall_name))
                        end
                    end
                end

                local endTime = computer.uptime() * 1000
                process.lastCpuTime = endTime / 1000 - startTime / 1000
                for _, child in ipairs(process.processes) do
                    process.lastCpuTime = process.lastCpuTime + child.lastCpuTime
                end
                usedTime = usedTime + process.lastCpuTime
                table.insert(process.cputime_avg, process.lastCpuTime)
                if #process.cputime_avg > 32 then table.remove(process.cputime_avg, 1) end
                return true
            else
                process.status = "idle"
                process.lastCpuTime = 0
                for _, child in ipairs(process.processes) do
                    process.lastCpuTime = process.lastCpuTime + child.lastCpuTime
                end
                usedTime = usedTime + process.lastCpuTime
                table.insert(process.cputime_avg, process.lastCpuTime)
                if #process.cputime_avg > 24 then table.remove(process.cputime_avg, 1) end
                return false
            end
        elseif coroutine.status(process.thread) == "dead" then
            process.status = "dying"
            return false
        end
    elseif process.status == "dead" then
        table.insert(toRemoveFromProc, process)
        return false
    elseif process.status == "dying" then
        process.emit("exit")
        local nClosed = 0
        for _, h in ipairs(process.io.handles) do
            h:close()
            nClosed = nClosed + 1
        end
        if nClosed > 0 then
            printk("Process manager terminated " .. nClosed .. " handles for process " .. process.pid, "warn")
        end
        printk("Process with name " .. process.name .. " with pid " .. process.pid .. " has died: " .. process.err)
        -- hand cursor back to parent so it doesn't start drawing from the wrong spot
        if process.parent and process.parent.tty and process.tty then
            process.parent.tty.cx = process.tty.cx
            process.parent.tty.cy = process.tty.cy
        elseif not process.parent and process.tty and _G.io and _G.io.cursor then
            _G.io.cursor.x = process.tty.cx
            _G.io.cursor.y = process.tty.cy
        end
        process.io.signal.pull  = {}
        process.io.signal.queue = {}
        process.err         = ""
        process.lastCpuTime = 0
        process.status      = "dead"
        return false
    end
    api.currentProcess = nil
end
local idleTimeAvg = {}

api.tick = function()
    local startTickTime = computer.uptime()
    usedTime = 0

    local function ticker(processes, event)
        local nTicked = 0
        for _, proc in ipairs(processes) do
            if #proc.processes > 0 then
                nTicked = nTicked + ticker(proc.processes, event)
            end
            if event[1] == "ipc_response" and proc.ipc_waiting and event[2] == proc.pid then
                printk("[ipc] response arrived for waiting pid " .. proc.pid, "debug")
                proc.status      = "running"
                proc.ipc_waiting = false
                proc.sysret      = table.pack(table.unpack(event, 3))
            end
            if api.tickProcess(proc, event) then nTicked = nTicked + 1 end
        end
        return nTicked
    end

    local event   = {computer.pullSignal(0)}
    local nTicks  = 0
    local st      = computer.uptime()
    while ticker(api.processes, nTicks == 0 and event or {}) > 0 and computer.uptime() - st < 0.05 do
        nTicks = nTicks + 1
    end

    for _, dead in ipairs(toRemoveFromProc) do
        local list = dead.parent and dead.parent.processes or api.processes
        for i = 1, #list do
            if list[i].pid == dead.pid then
                table.remove(list, i)
                break
            end
        end
    end

    local endTickTime = computer.uptime()
    usedTime = 0
    for _, proc in ipairs(api.processes) do usedTime = usedTime + proc.lastCpuTime end
    unusedTime = endTickTime - startTickTime - usedTime
    table.insert(idleTimeAvg, unusedTime)
    if #idleTimeAvg > 32 then table.remove(idleTimeAvg, 1) end
end

api.getIdleTime = function()
    return unusedTime
end

api.getIdlePercentage = function()
    local allUsed = 0
    for _, v in ipairs(api.processes) do allUsed = allUsed + v.getCpuTime() end
    allUsed = allUsed + api.getIdleTime()
    return allUsed > 0 and (api.getIdleTime() / allUsed * 100) or 100
end

api.getAvgIdleTime = function()
    local total = 0
    for _, v in ipairs(idleTimeAvg) do total = total + v end
    return total / #idleTimeAvg
end

api.getAvgIdlePercentage = function()
    local allUsed = 0
    for _, v in ipairs(api.processes) do allUsed = allUsed + v.getAvgCpuTime() end
    allUsed = allUsed + api.getAvgIdleTime()
    return allUsed > 0 and (api.getAvgIdleTime() / allUsed * 100) or 100
end

api.autoTick = function()
    local i = 0
    while true do
        i = i + 1
        api.tick()
        if i > 100 then os.sleep(0); i = 0 end
    end
end

api.list = function(filter)
    local ret = {}
    for k, v in ipairs(api.processes) do
        if string.match(v.name, filter or "") then
            table.insert(ret, v)
        end
    end
    return ret
end

api.setStatus = function(pid, status)
    for k, v in ipairs(api.processes) do
        if v.pid == pid then
            v.status = status
        end
    end
    return false
end

api.suspend = function(pid)
    api.setStatus(pid, "suspended")
end

api.resume = function(pid)
    api.setStatus(pid, "running")
end

return api
