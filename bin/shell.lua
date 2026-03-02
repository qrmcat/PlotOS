local std     = require("stdlib")
local fs      = require("fs")
local process = require("process")
local event   = require("event")
local Pipe    = require("pipe")

-- ANSI color shortcuts
local A = require("terminal").ansi

-- Initialize environment
local function initEnvironment()
    print("PlotOS")
    print("Testing beta")
    os.setEnv("computerName", "PlotOS")
    os.setEnv("user", "guest")
    os.currentDirectory = "/"
end

-- Path handling
local function canonicalizePath(p)
    local path = std.str.split(p, "/")
    local r = {}
    
    if p:sub(1,1) ~= "/" then
        r = std.str.split(os.currentDirectory, "/")
    end
    
    for _, v in ipairs(path) do
        if v == ".." then
            table.remove(r, #r)
        elseif v ~= "." then
            table.insert(r, v)
        end
    end

    return "/" .. table.concat(r, "/")
end

-- Command execution
local function findExecutable(cmd)
    if string.find(cmd, "/") then
        local fullPath = canonicalizePath(cmd)
        return fs.exists(fullPath) and fullPath or nil
    end

    local PATH = std.str.split(os.getEnv("PATH"), ";")
    for _, dir in ipairs(PATH) do
        local paths = {
            dir .. "/" .. cmd,
            dir .. "/" .. cmd .. ".lua"
        }
        for _, path in ipairs(paths) do
            if fs.exists(path) then
                return path
            end
        end
    end
    return nil
end


local function handleError(message)
    print(A.red .. tostring(message) .. A.reset)
    printk(message)
end

-- Forward declaration: executePipeline references commands before its definition.
local commands

-- ── Pipeline helpers ───────────────────────────────────────────────────────────

--- Split a command line on unquoted '|' characters.
--- Returns a list of trimmed segment strings.
local function parsePipeline(input)
    local segments = {}
    for seg in (input .. "|"):gmatch("([^|]*)|") do
        seg = seg:match("^%s*(.-)%s*$")
        if #seg > 0 then
            segments[#segments + 1] = seg
        end
    end
    return segments
end

--- Load a program file and create a process, optionally overriding its stdin/stdout
--- file descriptors (used for pipe plumbing).
--- @param binPath   string   Absolute path to the .lua program
--- @param args      table    Argument list (args[1] = command name)
--- @param stdinFd   table?   Replace fd[0] with this fd endpoint (pipe reader)
--- @param stdoutFd  table?   Replace fd[1] with this fd endpoint (pipe writer)
--- @return table|nil, string?
local function spawnCommand(binPath, args, stdinFd, stdoutFd)
    local fileHandle = fs.open(binPath, "r")
    if not fileHandle then
        return nil, "failed to open " .. binPath
    end

    local program = ""
    while true do
        local data, reason = fileHandle:read(1024)
        if not data then
            fileHandle:close()
            if reason then return nil, "read error: " .. tostring(reason) end
            break
        end
        program = program .. data
    end

    local proc = process.new(fs.name(binPath), program, _G, nil, nil, args)

    if stdinFd and proc.io and proc.io.fd then
        proc.io.fd[0]  = stdinFd
        proc.io.use_ld = false   -- pipe input bypasses line discipline
    end
    if stdoutFd and proc.io and proc.io.fd then
        proc.io.fd[1] = stdoutFd
    end

    return proc
end

--- Run a single command, forwarding ^C/^Z to it via the shell's line discipline.
local function executeCommand(binPath, args, stdinFd, stdoutFd)
    local proc, err = spawnCommand(binPath, args, stdinFd, stdoutFd)
    if not proc then
        return false, err
    end

    -- Route ^C / ^Z to the child through the shell's line discipline fg_proc.
    -- The line discipline's processKey() sees ^C and calls proc:signal("SIGINT").
    local shellProc = process.currentProcess
    if shellProc and shellProc.io and shellProc.io.ld then
        shellProc.io.ld.fg_proc = proc
    end

    while proc.status ~= "dead" do
        event.pull(nil, 0)
    end

    if shellProc and shellProc.io and shellProc.io.ld then
        shellProc.io.ld.fg_proc = nil
    end

    return true
end

--- Execute a parsed pipeline.  If there is only one segment this degrades to a
--- plain executeCommand.  Multiple segments are connected by Pipe objects so
--- each command's stdout feeds the next command's stdin.
local function executePipeline(segments)
    if #segments == 0 then return true end

    if #segments == 1 then
        -- Fast path: no pipes.
        local args = std.str.split(segments[1], " ")
        local cmd  = args[1]
        if not cmd or #cmd == 0 then return true end

        if commands[cmd] then
            commands[cmd](args)
            return true
        end

        local binPath = findExecutable(cmd)
        if not binPath then
            print("shell: " .. cmd .. ": command not found")
            return true
        end

        local ok, err = executeCommand(binPath, args)
        if not ok then handleError("shell: " .. cmd .. ": " .. tostring(err)) end
        return true
    end

    -- ── Multi-command pipeline ─────────────────────────────────────────────────
    -- Build: proc[1].fd[1]→writer[1]  pipe[1]  reader[1]→proc[2].fd[0]
    --        proc[2].fd[1]→writer[2]  pipe[2]  reader[2]→proc[3].fd[0]  etc.
    local procs   = {}
    local writers = {}   -- one writer per inter-process pipe (index = left segment)
    local prevReader = nil

    for i, seg in ipairs(segments) do
        local args = std.str.split(seg, " ")
        local cmd  = args[1]
        if not cmd or #cmd == 0 then
            print("shell: syntax error near '|'")
            return true
        end

        local binPath = findExecutable(cmd)
        if not binPath then
            print("shell: " .. cmd .. ": command not found")
            return true
        end

        -- Create a pipe between this command and the next (not after the last).
        local reader, writer
        if i < #segments then
            reader, writer = Pipe.new()
            writers[i] = writer
        end

        local proc, err = spawnCommand(binPath, args, prevReader, writer)
        if not proc then
            handleError("shell: " .. cmd .. ": " .. tostring(err))
            return true
        end

        procs[#procs + 1] = proc
        prevReader = reader   -- pipe read end becomes stdin of next command
    end

    -- Route ^C to the last process in the pipeline (Unix convention).
    local shellProc = process.currentProcess
    if shellProc and shellProc.io and shellProc.io.ld then
        shellProc.io.ld.fg_proc = procs[#procs]
    end

    -- Wait for all processes; close a pipe's write end as soon as its producer
    -- finishes so downstream consumers receive EOF.
    while true do
        event.pull(nil, 0)

        local anyAlive = false
        for i, p in ipairs(procs) do
            if p.status ~= "dead" then
                anyAlive = true
            elseif writers[i] and not writers[i]._closed then
                writers[i].close()
                writers[i]._closed = true
            end
        end

        if not anyAlive then break end
    end

    if shellProc and shellProc.io and shellProc.io.ld then
        shellProc.io.ld.fg_proc = nil
    end

    return true
end

-- Command handlers
commands = {
    cd = function(args)
        local path = args[2] and canonicalizePath(tostring(args[2])) or "/"
        if not fs.exists(path) then
            print("shell: cannot access '" .. tostring(args[2]) .. "': No such file or directory")
            return
        end
        os.currentDirectory = path
    end
}

-- Main loop
local function main()
    initEnvironment()

    local history = {}

    while true do
        -- Display prompt
        io.write(A.green .. os.getEnv("user") .. "@" .. os.getEnv("computerName") .. ":" .. A.reset)
        io.write(A.cyan  .. os.currentDirectory .. "$ " .. A.reset)

        -- Read input (routes through line discipline when use_ld=true)
        local input = io.read({history = history})

        -- Maintain history (skip blank / whitespace-only lines)
        if input and #input > 0 and not input:match("^%s*$") then
            table.insert(history, input)
            if #history > 64 then table.remove(history, 1) end
        end

        -- Parse pipeline and execute
        local segments = parsePipeline(input or "")
        executePipeline(segments)
    end
end


main()
