-- terminal.lua
-- all text goes through here. all of it. do not bypass this. i will know

local terminal = {}

local function grabProc()
    return package.require("process")
end

terminal.TTY_BACKEND = {
    --- @param tty table
    --- @param str string
    write = function(tty, str) tty:write(str) end,

    --- @param tty  table
    --- @param opts {history:table?, completionCallback:function?}?
    --- @return string
    read  = function(tty, opts) return tty:read(opts) end,

    --- @param tty table
    clear = function(tty) tty:clear() end,
}

--- @param tty table
function terminal.init(tty)
    terminal.tty      = tty
    terminal._backend = terminal.TTY_BACKEND -- sane default, unlike everything else here
end

--- @param newBackend table must have at least a write function or we explode on purpose
function terminal.setBackend(newBackend)
    assert(
        type(newBackend) == "table" and type(newBackend.write) == "function",
        "terminal.setBackend: that is not a backend. a backend has write(). yours does not"
    )
    terminal._backend = newBackend
end

--- @return table the master screen tty
function terminal.getTTY()
    return terminal.tty
end

local function whoseTTY()
    local someone = grabProc().currentProcess
    if someone and someone.tty then return someone.tty end
    return terminal.tty -- nobody home, use master
end

--- write to whatever is in front of us right now
--- @param str string
function terminal.write(str)
    str = tostring(str)
    local someone = grabProc().currentProcess
    if someone and someone.io and someone.io.fd and someone.io.fd[1] then
        someone.io.fd[1].write(str) -- their problem now
        return
    end
    if terminal._backend then
        terminal._backend.write(whoseTTY(), str)
    end
end


--- @param opts {history:table?, completionCallback:function?}?
--- @return string
function terminal.read(opts)
    local line = terminal._backend.read(whoseTTY(), opts)
    local someone = grabProc().currentProcess
    if someone and someone.io and someone.io.stdin and line then
        someone.io.stdin:write(line .. "\n") -- feed the stdin beast
    end
    return line
end

--- wipe the screen. very destructive. very satisfying
function terminal.clear()
    if terminal._backend then
        terminal._backend.clear(whoseTTY())
    end
end

terminal.ansi = {
    reset    = "\27[0m",
    bold     = "\27[1m",
    black    = "\27[30m",
    red      = "\27[31m",
    green    = "\27[32m",
    yellow   = "\27[33m",
    blue     = "\27[34m",
    magenta  = "\27[35m",
    cyan     = "\27[36m",
    white    = "\27[37m",
    bblack   = "\27[90m",
    bred     = "\27[91m",
    bgreen   = "\27[92m",
    byellow  = "\27[93m",
    bblue    = "\27[94m",
    bmagenta = "\27[95m",
    bcyan    = "\27[96m",
    bwhite   = "\27[97m",
    bg_black   = "\27[40m",
    bg_red     = "\27[41m",
    bg_green   = "\27[42m",
    bg_yellow  = "\27[43m",
    bg_blue    = "\27[44m",
    bg_magenta = "\27[45m",
    bg_cyan    = "\27[46m",
    bg_white   = "\27[47m",
    bg_bblack   = "\27[100m",
    bg_bred     = "\27[101m",
    bg_bgreen   = "\27[102m",
    bg_byellow  = "\27[103m",
    bg_bblue    = "\27[104m",
    bg_bmagenta = "\27[105m",
    bg_bcyan    = "\27[106m",
    bg_bwhite   = "\27[107m",
}

--- @param colorCode string  e.g. "\27[31m"
--- @param str       string
--- @return string
function terminal.ansi.wrap(colorCode, str)
    return colorCode .. tostring(str) .. "\27[0m"
end

return terminal
