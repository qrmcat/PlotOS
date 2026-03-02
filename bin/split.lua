--- split.lua
--- Two shell panes side by side.  Click on either side (or press Tab) to
--- switch focus.  Ctrl+Q exits.  The divider is drawn in the middle column.

local process  = require("process")
local keyboard = require("keyboard")
local gpu      = require("driver").load("gpu")
local fs       = require("fs")
local TTY      = require("tty")

local sw, sh = gpu.getResolution()

-- ── Layout ───────────────────────────────────────────────────────────────────
-- |  left pane  |div|  right pane  |
-- divider lives at column divX (1 char wide)
local divX   = math.floor(sw / 2)
local leftW  = divX - 1          -- cols 1 .. divX-1
local rightX = divX + 1          -- cols divX+1 .. sw
local rightW = sw - divX          -- cols divX+1 .. sw

-- ── Draw divider ─────────────────────────────────────────────────────────────
local function drawDivider(focusRight)
    local savedFg = gpu.getForeground()
    local savedBg = gpu.getBackground()
    gpu.setBackground(0x000000)
    gpu.setForeground(focusRight and 0x00BFFF or 0xFFFFFF)
    for y = 1, sh do
        gpu.set(divX, y, "\x7C")  -- │
    end
    gpu.setForeground(savedFg)
    gpu.setBackground(savedBg)
end

-- ── Helper: load shell source ─────────────────────────────────────────────────
local function readFile(path)
    local h, err = fs.open(path, "r")
    if not h then error("split: cannot open " .. path .. ": " .. tostring(err)) end
    local buf = {}
    while true do
        local data = h:read(2048)
        if not data then break end
        buf[#buf + 1] = data
    end
    h:close()
    return table.concat(buf)
end

local shellCode = readFile("/bin/shell.lua")

-- ── Spawn panes ───────────────────────────────────────────────────────────────
local leftProc  = process.new("shell-left",  shellCode)
local rightProc = process.new("shell-right", shellCode)

-- Assign regions.  process.new already created a full-screen TTY; overwrite it.
leftProc.tty  = TTY.new(gpu, 1,      1, leftW,  sh)
rightProc.tty = TTY.new(gpu, rightX, 1, rightW, sh)

-- Also fix the line disciplines to use the correct TTYs.
local LineDiscipline = require("linedisc")
leftProc.io.ld  = LineDiscipline.new(leftProc.tty,  { history = {} })
rightProc.io.ld = LineDiscipline.new(rightProc.tty, { history = {} })

-- split.lua itself does NOT want a line discipline — it manages two shells
-- that have their own lds.  Disable ld on self so raw keyboard events land
-- in our signal queue (use_ld=false → tickProcess puts all events in the queue).
local selfProc = process.currentProcess
if selfProc then selfProc.io.use_ld = false end

-- Start with left pane focused.
local focused = leftProc  -- the one that receives keyboard events
rightProc.io.keyboard_muted = true

-- ── Initial draw ─────────────────────────────────────────────────────────────
gpu.fill(1, 1, sw, sh, " ")  -- clear screen
drawDivider(false)

-- ── Focus switch ─────────────────────────────────────────────────────────────
local function switchFocus()
    if focused == leftProc then
        focused = rightProc
        leftProc.io.keyboard_muted  = true
        rightProc.io.keyboard_muted = false
    else
        focused = leftProc
        rightProc.io.keyboard_muted = true
        leftProc.io.keyboard_muted  = false
    end
    drawDivider(focused == rightProc)
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
-- We yield via coroutine.yield() each iteration so the scheduler runs and
-- ticks the child shell processes.  Keyboard/touch events arrive in our
-- signal queue because use_ld=false.
while leftProc.status ~= "dead" or rightProc.status ~= "dead" do
    -- Yield one scheduler tick so child processes (shells) get CPU time.
    coroutine.yield()

    -- Drain every event the scheduler put in our signal queue this tick.
    while selfProc and #selfProc.io.signal.queue > 0 do
        local ev = table.remove(selfProc.io.signal.queue, 1)

        if ev[1] == "key_down" then
            local char, code = ev[3], ev[4]
            if code == 0x0F then          -- Tab → switch focus
                switchFocus()
            elseif keyboard.isControlDown() and (char == 17 or char == 113) then
                -- Ctrl+Q: kill both panes and exit
                leftProc:kill()
                rightProc:kill()
                goto done
            end

        -- Touch/click: focus the pane that was clicked
        elseif ev[1] == "touch" then
            local x = ev[3]
            if x < divX and focused ~= leftProc then
                switchFocus()
            elseif x > divX and focused ~= rightProc then
                switchFocus()
            end
        end
    end

    -- If either pane died, show a notice in its region and mute it
    if leftProc.status == "dead" and not leftProc._deadNotice then
        leftProc._deadNotice = true
        gpu.setForeground(0xFF4444)
        gpu.set(1, sh, string.rep(" ", leftW))
        gpu.set(1, sh, "[ pane exited ]")
        gpu.setForeground(0xFFFFFF)
        if focused == leftProc then switchFocus() end
    end
    if rightProc.status == "dead" and not rightProc._deadNotice then
        rightProc._deadNotice = true
        gpu.setForeground(0xFF4444)
        gpu.set(rightX, sh, string.rep(" ", rightW))
        gpu.set(rightX, sh, "[ pane exited ]")
        gpu.setForeground(0xFFFFFF)
        if focused == rightProc then switchFocus() end
    end
end

::done::
