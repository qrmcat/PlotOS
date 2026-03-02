--- syscall.lua
--- Userspace syscall helper. All process→kernel communication should go through
--- these wrappers instead of raw coroutine.yield() calls, so the syscall
--- "protocol" is defined in exactly one place.

local syscall = {}

-- Internal: yield a named syscall to the scheduler and return its result.
local function do_syscall(syscall_type, ...)
    if not coroutine.isyieldable() then
        error("syscall." .. tostring(syscall_type) .. " called outside of a process context", 2)
    end
    return coroutine.yield(syscall_type, ...)
end

--- Call a method on a hardware driver that is already loaded/cached.
--- @param addr    string   Component address the driver wraps.
--- @param method  string   Method name on the driver instance.
--- @param ...     any      Arguments forwarded to the method.
--- @return ...             Whatever the driver method returns.
function syscall.driver(addr, method, ...)
    return do_syscall("driver", addr, method, ...)
end

--- Invoke a registered IPC handler by name.
--- @param name  string  Handler name (as registered with ipc.register).
--- @param ...   any     Arguments forwarded to the handler.
--- @return ...          Return values from the handler.
function syscall.ipc(name, ...)
    return do_syscall("ipc_call", name, table.pack(...))
end

--- Suspend this process until a signal arrives or the timeout expires.
--- Mirrors computer.pullSignal but goes through the scheduler properly.
--- @param timeout number  Max seconds to wait (math.huge = wait forever).
--- @return ...            Signal fields, same as computer.pullSignal.
function syscall.pullSignal(timeout)
    return do_syscall("signal", timeout ~= nil and timeout or math.huge)
end

--- Voluntarily yield execution back to the scheduler (cooperative tick).
function syscall.yield()
    coroutine.yield()
end

--- Block until a line (or n bytes) is available from the process's stdin fd.
--- Goes through the line discipline in COOKED mode (echo, ^C, history etc.).
--- In RAW mode returns as soon as any byte is buffered.
--- @param n number|nil  Max bytes to read.  nil = one full line.
--- @return string|nil data
--- @return string|nil err   "eof" when ^D / write-end closed, or "interrupted".
function syscall.stdinRead(n)
    return do_syscall("stdin_read", n)
end

return syscall