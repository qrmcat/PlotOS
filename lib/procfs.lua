--- procfs.lua
--- Dynamic virtual filesystem mounted at /proc.
---
--- Layout:
---   /proc/{pid}/stdin    – backed by proc.io.stdin  (r/w stream)
---   /proc/{pid}/stdout   – backed by proc.io.stdout (r/w stream)
---   /proc/{pid}/stderr   – backed by proc.io.stderr (r/w stream)
---   /proc/{pid}/status   – read-only text: current status string
---   /proc/{pid}/name     – read-only text: process name
---   /proc/{pid}/cmdline  – read-only text: NUL-separated argv
---
--- Pipe idiom
--- ----------
--- To pipe process A's stdout into process B's stdin, just do:
---   procB.io.stdin = procA.io.stdout
--- /proc then transparently exposes the shared stream through both entries.
---
--- The filesystem is implemented as a plain table compatible with fs.mount(),
--- so the standard fs library handles all path resolution on top of it.

local procfs = {}

-- ── Lazy process-module accessor (avoids circular require at load time) ───────
local function proc_api()
    return package.require("process")
end

-- ── Path parser ───────────────────────────────────────────────────────────────
-- fs.mount strips the mount-point prefix, so procfs receives paths like:
--   ""         → root
--   "1"        → directory for pid 1
--   "1/stdout" → file stdout inside pid 1
local function parsePath(path)
    local rest = path:match("^/?(.*)$") or path
    if rest == "" then return nil, nil end                  -- root
    local pid_s, fname = rest:match("^(%d+)/(.+)$")
    if pid_s then return tonumber(pid_s), fname end
    local dir_s = rest:match("^(%d+)/?$")
    if dir_s then return tonumber(dir_s), nil end
    return nil, nil
end

-- ── Process search (recursive through child-process tables) ──────────────────
local function findProc(pid, list)
    list = list or proc_api().processes
    for _, p in ipairs(list) do
        if p.pid == pid then return p end
        if #(p.processes or {}) > 0 then
            local found = findProc(pid, p.processes)
            if found then return found end
        end
    end
end

local function collectPids(list, out)
    list = list or proc_api().processes
    out  = out  or {}
    for _, p in ipairs(list) do
        table.insert(out, p.pid)
        collectPids(p.processes or {}, out)
    end
    return out
end

-- ── Open handle pool ──────────────────────────────────────────────────────────
local handles    = {}   -- [id] = { cursor = <StreamCursor|staticCursor>, mode = string }
local nextHandle = 1

local function allocHandle(cursor, mode)
    local id  = nextHandle
    nextHandle = id + 1
    handles[id] = { cursor = cursor, mode = mode }
    return id
end

-- ── Tiny read-only cursor for static text files ───────────────────────────────
-- Implements the same method signatures as StreamCursor so the procfs
-- read/write/seek/close functions can treat both identically.
local function staticCursor(text)
    local pos = 1
    local c = {}
    function c:read(n)
        if pos > #text then return nil end
        local chunk = text:sub(pos, pos + (n or #text) - 1)
        pos = pos + #chunk
        return chunk ~= "" and chunk or nil
    end
    function c:write()    return nil, "read-only" end
    function c:seek(whence, offset)
        whence = whence or "cur"; offset = offset or 0
        if     whence == "set" then pos = offset + 1
        elseif whence == "cur" then pos = pos + offset
        elseif whence == "end" then pos = #text + offset + 1
        end
        if pos < 1 then pos = 1 end
        return pos - 1  -- 0-based, matching StreamCursor
    end
    function c:close() end
    return c
end

-- ── Entry name tables ─────────────────────────────────────────────────────────
local STATIC_ENTRIES = { status = true, name = true, cmdline = true }
local STREAM_ENTRIES = { stdin  = true, stdout = true, stderr = true }
local ALL_ENTRIES    = { "stdin", "stdout", "stderr", "status", "name", "cmdline" }

-- ── FS interface (called by lib/fs.lua after path resolution) ─────────────────

function procfs.spaceUsed()      return 0      end
function procfs.spaceTotal()     return 0      end
function procfs.isReadOnly()     return false  end
function procfs.getLabel()       return "procfs" end

function procfs.exists(path)
    local rest = path:match("^/?(.-)/?$") or ""
    if rest == "" then return true end                      -- root always exists
    local pid, fname = parsePath(path)
    if not pid then return false end
    local p = findProc(pid)
    if not p then return false end
    if not fname then return true end                       -- directory /proc/{pid}
    return STATIC_ENTRIES[fname] or STREAM_ENTRIES[fname] or false
end

function procfs.isDirectory(path)
    local rest = path:match("^/?(.-)/?$") or ""
    if rest == "" then return true end
    local pid, fname = parsePath(path)
    if not pid or fname then return false end               -- file paths are not dirs
    return findProc(pid) ~= nil
end

function procfs.size()
    return 0    -- streams have no meaningful static size
end

function procfs.list(path)
    local rest = path:match("^/?(.-)/?$") or ""
    if rest == "" then
        -- root: one entry per living process
        local out = {}
        for _, pid in ipairs(collectPids()) do
            table.insert(out, tostring(pid))
        end
        return out
    end
    local pid = tonumber(rest)
    if pid and findProc(pid) then
        return ALL_ENTRIES
    end
    return nil, "no such directory: " .. tostring(path)
end

function procfs.open(path, mode)
    mode = mode or "r"
    if not procfs.exists(path) then
        return nil, "no such file: " .. tostring(path)
    end
    local pid, fname = parsePath(path)
    if not pid or not fname then
        return nil, "cannot open a directory"
    end
    local p = findProc(pid)
    if not p then
        return nil, "process " .. tostring(pid) .. " not found"
    end

    -- ── Static text entries ────────────────────────────────────────────────
    if fname == "status" then
        if mode ~= "r" then return nil, "status is read-only" end
        return allocHandle(staticCursor(tostring(p.status) .. "\n"), "r")
    end

    if fname == "name" then
        if mode ~= "r" then return nil, "name is read-only" end
        return allocHandle(staticCursor(tostring(p.name) .. "\n"), "r")
    end

    if fname == "cmdline" then
        if mode ~= "r" then return nil, "cmdline is read-only" end
        local args  = p.args or {}
        local parts = {}
        for i = 1, (args.n or #args) do
            parts[i] = tostring(args[i] or "")
        end
        return allocHandle(staticCursor(table.concat(parts, "\0") .. "\n"), "r")
    end

    -- ── Stream entries: stdin / stdout / stderr ───────────────────────────
    -- Lazily create stderr if this process was spawned before procfs existed.
    if fname == "stderr" and not p.io.stderr then
        local Stream = package.require("stream")
        p.io.stderr = Stream.new()
    end

    local streamObj =
        (fname == "stdin"  and p.io.stdin)  or
        (fname == "stdout" and p.io.stdout) or
        (fname == "stderr" and p.io.stderr)

    if not streamObj then
        return nil, "stream not available for " .. fname
    end

    local canRead  = (mode == "r")
    local canWrite = (mode == "w" or mode == "a")
    local cursor   = streamObj:createCursor(canRead, canWrite)
    if mode == "a" then
        cursor:seek("end", 0)
    end

    return allocHandle(cursor, mode)
end

function procfs.read(handle, n)
    local h = handles[handle]
    if not h then return nil, "invalid handle" end
    return h.cursor:read(n)
end

function procfs.write(handle, data)
    local h = handles[handle]
    if not h then return nil, "invalid handle" end
    return h.cursor:write(data)
end

function procfs.seek(handle, whence, offset)
    local h = handles[handle]
    if not h then return nil, "invalid handle" end
    if h.cursor.seek then
        return h.cursor:seek(whence, offset)
    end
    return nil, "not seekable"
end

function procfs.close(handle)
    local h = handles[handle]
    if not h then return nil, "invalid handle" end
    h.cursor:close()
    handles[handle] = nil
    return true
end

-- ── Unsupported mutations ──────────────────────────────────────────────────────
function procfs.rename()        return nil, "procfs is a virtual filesystem" end
function procfs.remove()        return nil, "procfs is a virtual filesystem" end
function procfs.makeDirectory() return nil, "procfs is a virtual filesystem" end

return procfs
