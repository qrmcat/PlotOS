-- 80_io.lua

local io       = {}
local TTY      = require("tty")
local terminal = require("terminal")
local proc     = require("process")
local gpu      = require("driver").load("gpu")

-- ONE tty. kernel owns it. dont touch it. i mean it
local kernel_tty = TTY.new(gpu)
terminal.init(kernel_tty)
_G.terminal = terminal

local function active_tty()
    local p = proc.currentProcess
    if p and p.tty then return p.tty end
    return kernel_tty -- fallback to the one true tty
end

io.cursor = {}
setmetatable(io.cursor, {
    __index = function(_, k)
        local t = active_tty()
        if k == "x"     then return t.cx    end
        if k == "y"     then return t.cy    end
        if k == "blink" then return t._blink end
    end,
    __newindex = function(_, k, v)
        local t = active_tty()
        if k == "x"     then t:setCursor(v, t.cy) end
        if k == "y"     then t:setCursor(t.cx, v) end
        if k == "blink" then t:setBlink(v)         end
    end,
})

function io.cursor.setPosition(x, y) active_tty():setCursor(x, y)  end
function io.cursor.getPosition()     return active_tty():getCursor() end
function io.cursor.setBlink(b)       active_tty():setBlink(b)        end

-- write a thing
function io.write(str)
    terminal.write(tostring(str))
end

function io.writeline(str)
    terminal.write(tostring(str) .. "\n")
end

function io.read(options)
    local p = proc.currentProcess
    if p and p.io and p.io.use_ld then
        if p.io.ld and p.tty then
            p.io.ld._beginX = p.tty.cx
        end
        if options and options.history and p.io.ld then
            p.io.ld.history = options.history
        end
        local syscall = package.require("syscall")
        local data, err = syscall.stdinRead()
        if err == "eof" then return "" end -- EOF. nothing. empty. gone. bye
        return data and data:gsub("\n$", "") or ""
    end
    -- no line discipline. just block and pray
    return terminal.read(options)
end

-- yes you can resize the screen. no i dont know why youd want to but you can
function io.setScreenSize(w, h)
    active_tty():resize(w, h)
end

function io.getScreenSize()
    local t = active_tty()
    return t.w, t.h
end

_G.io = io
