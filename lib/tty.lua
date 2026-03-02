--- tty.lua
--- A TTY (terminal) object that owns a rectangular screen region, a cursor,
--- colors, and all read/write/scroll logic.  io.lua is a thin wrapper on top.
---
--- All public x/y values are REGION-RELATIVE (1-based).
--- GPU calls are translated to absolute screen coordinates internally.
---
--- Construction:
---   local TTY = require("tty")
---   local t   = TTY.new(gpu, ox, oy, w, h)
---     gpu  – driver proxy or raw driver
---     ox   – left edge of the region on the screen (1-based, inclusive)
---     oy   – top  edge of the region on the screen (1-based, inclusive)
---     w/h  – region width / height in characters

local TTY = {}
TTY.__index = TTY

-- ── ANSI colour tables ──────────────────────────────────────────────────────
-- Maps the 16 standard ANSI colour indices (0-15) to 24-bit RGB values.
-- Indices 0-7  → normal colours  (SGR 30-37 fg / 40-47 bg)
-- Indices 8-15 → bright variants (SGR 90-97 fg / 100-107 bg)
local ANSI_COLORS = {
    [0]  = 0x000000, -- black
    [1]  = 0xAA0000, -- red
    [2]  = 0x00AA00, -- green
    [3]  = 0xAA5500, -- dark yellow
    [4]  = 0x0000AA, -- blue
    [5]  = 0xAA00AA, -- magenta
    [6]  = 0x00AAAA, -- cyan
    [7]  = 0xAAAAAA, -- light grey
    [8]  = 0x555555, -- bright black (dark grey)
    [9]  = 0xFF5555, -- bright red
    [10] = 0x55FF55, -- bright green
    [11] = 0xFFFF55, -- bright yellow
    [12] = 0x5555FF, -- bright blue
    [13] = 0xFF55FF, -- bright magenta
    [14] = 0x55FFFF, -- bright cyan
    [15] = 0xFFFFFF, -- bright white
}
local ANSI_DEFAULT_FG = 0xFFFFFF
local ANSI_DEFAULT_BG = 0x000000

--- @param gpu    table   GPU driver (proxy or raw)
--- @param ox     number  Screen X of top-left corner (default 1)
--- @param oy     number  Screen Y of top-left corner (default 1)
--- @param w      number  Width  in chars (default: full screen width)
--- @param h      number  Height in chars (default: full screen height)
function TTY.new(gpu, ox, oy, w, h)
    local sw, sh = gpu.getResolution()
    local self  = setmetatable({}, TTY)
    self.gpu    = gpu
    self.ox     = ox or 1
    self.oy     = oy or 1
    self.w      = w  or sw
    self.h      = h  or sh
    -- Cursor is region-relative, 1-based
    self.cx     = 1
    self.cy     = 1
    self.fg     = 0xFFFFFF
    self.bg     = 0x000000
    self._blink = false
    return self
end

-- ── Internal helpers ────────────────────────────────────────────────────────

--- Convert region-relative coords to absolute screen coords.
function TTY:_abs(rx, ry)
    return self.ox + rx - 1, self.oy + ry - 1
end

--- Draw one character at region-relative position without moving the cursor.
function TTY:_drawChar(rx, ry, ch)
    local ax, ay = self:_abs(rx, ry)
    self.gpu.set(ax, ay, ch)
end

--- Scroll the region up by one line and blank the bottom row.
function TTY:_scrollUp()
    local ax, ay = self:_abs(1, 1)
    -- copy rows 2..h up by one
    if self.h > 1 then
        self.gpu.copy(ax, ay + 1, self.w, self.h - 1, 0, -1)
    end
    -- blank the last row
    self.gpu.fill(ax, ay + self.h - 1, self.w, 1, " ")
end

--- Ensure the cursor row is within [1, h], scrolling if needed.
function TTY:_clampCursor()
    while self.cy > self.h do
        self:_scrollUp()
        self.cy = self.cy - 1
    end
    if self.cy < 1 then self.cy = 1 end
    if self.cx < 1 then self.cx = 1 end
    if self.cx > self.w + 1 then self.cx = self.w + 1 end
end

-- ── Blink ───────────────────────────────────────────────────────────────────

function TTY:setBlink(on)
    local ax, ay = self:_abs(self.cx, self.cy)
    local ch, fg, bg = self.gpu.get(ax, ay)
    ch = (ch or " "):sub(1, 1)
    if on then
        self.gpu.setBackground(fg or self.fg)
        self.gpu.setForeground(bg or self.bg)
        self.gpu.set(ax, ay, ch)
    else
        self.gpu.setBackground(self.bg)
        self.gpu.setForeground(self.fg)
        self.gpu.set(ax, ay, ch)
    end
    self.gpu.setForeground(self.fg)
    self.gpu.setBackground(self.bg)
    self._blink = on
end

function TTY:getBlink()
    return self._blink
end

-- ── Color ───────────────────────────────────────────────────────────────────

function TTY:setForeground(col)
    self.fg = col
    self.gpu.setForeground(col)
end

function TTY:setBackground(col)
    self.bg = col
    self.gpu.setBackground(col)
end

-- ── Cursor ──────────────────────────────────────────────────────────────────

--- Move cursor to region-relative position.
function TTY:setCursor(rx, ry)
    if self._blink then self:setBlink(false) end
    self.cx = rx
    self.cy = ry
    self:_clampCursor()
    if self._blink then self:setBlink(true) end
end

function TTY:getCursor()
    return self.cx, self.cy
end

-- ── Clear ───────────────────────────────────────────────────────────────────

function TTY:clear()
    local ax, ay = self:_abs(1, 1)
    self.gpu.fill(ax, ay, self.w, self.h, " ")
    self.cx = 1
    self.cy = 1
end

-- ── Resize / move ───────────────────────────────────────────────────────────

function TTY:resize(w, h)
    self.w = w
    self.h = h
end

function TTY:move(ox, oy)
    self.ox = ox
    self.oy = oy
end

-- ── ANSI escape handler ─────────────────────────────────────────────────────

--- Handle a parsed ANSI/VT100 escape sequence.
--- @param params string  Everything between ESC[ and the command letter.
--- @param cmd    string  The single terminating command letter.
function TTY:_handleAnsi(params, cmd)
    if cmd == "m" then
        -- SGR: Select Graphic Rendition
        -- Parse semicolon-separated numbers; empty string means reset (0).
        local codes = {}
        for s in (params .. ";"):gmatch("(%d*);?") do
            if s ~= "" then table.insert(codes, tonumber(s)) end
        end
        if #codes == 0 then codes = { 0 } end

        local ci = 1
        while ci <= #codes do
            local c = codes[ci]
            if c == 0 then
                -- reset
                self:setForeground(ANSI_DEFAULT_FG)
                self:setBackground(ANSI_DEFAULT_BG)
            elseif c >= 30 and c <= 37 then
                self:setForeground(ANSI_COLORS[c - 30])
            elseif c == 39 then
                self:setForeground(ANSI_DEFAULT_FG)
            elseif c >= 40 and c <= 47 then
                self:setBackground(ANSI_COLORS[c - 40])
            elseif c == 49 then
                self:setBackground(ANSI_DEFAULT_BG)
            elseif c >= 90 and c <= 97 then
                self:setForeground(ANSI_COLORS[c - 90 + 8])
            elseif c >= 100 and c <= 107 then
                self:setBackground(ANSI_COLORS[c - 100 + 8])
            elseif c == 38 then
                -- 38;2;r;g;b  true-colour foreground
                if codes[ci+1] == 2 and codes[ci+2] and codes[ci+3] and codes[ci+4] then
                    self:setForeground(codes[ci+2]*0x10000 + codes[ci+3]*0x100 + codes[ci+4])
                    ci = ci + 4
                end
            elseif c == 48 then
                -- 48;2;r;g;b  true-colour background
                if codes[ci+1] == 2 and codes[ci+2] and codes[ci+3] and codes[ci+4] then
                    self:setBackground(codes[ci+2]*0x10000 + codes[ci+3]*0x100 + codes[ci+4])
                    ci = ci + 4
                end
            end
            ci = ci + 1
        end

    elseif cmd == "J" then
        -- Erase in display
        local n = tonumber(params) or 0
        if n == 2 or n == 3 then
            self:clear()
        elseif n == 0 then
            -- cursor to end
            local ax, ay = self:_abs(self.cx, self.cy)
            self.gpu.fill(ax, ay, self.w - self.cx + 1, 1, " ")
            if self.cy < self.h then
                local bx, by = self:_abs(1, self.cy + 1)
                self.gpu.fill(bx, by, self.w, self.h - self.cy, " ")
            end
        elseif n == 1 then
            -- start to cursor
            if self.cy > 1 then
                local ax, ay = self:_abs(1, 1)
                self.gpu.fill(ax, ay, self.w, self.cy - 1, " ")
            end
            local ax, ay = self:_abs(1, self.cy)
            self.gpu.fill(ax, ay, self.cx, 1, " ")
        end

    elseif cmd == "K" then
        -- Erase in line
        local n = tonumber(params) or 0
        local ax, ay = self:_abs(1, self.cy)
        if n == 0 then
            local cx_abs, cy_abs = self:_abs(self.cx, self.cy)
            self.gpu.fill(cx_abs, cy_abs, self.w - self.cx + 1, 1, " ")
        elseif n == 1 then
            self.gpu.fill(ax, ay, self.cx, 1, " ")
        elseif n == 2 then
            self.gpu.fill(ax, ay, self.w, 1, " ")
        end

    elseif cmd == "H" or cmd == "f" then
        -- Cursor position: ESC[row;colH  (1-based, 0 treated as 1)
        local row, col = params:match("^(%d*);?(%d*)$")
        row = math.max(1, tonumber(row) or 1)
        col = math.max(1, tonumber(col) or 1)
        self:setCursor(col, row)

    elseif cmd == "A" then
        local n = math.max(1, tonumber(params) or 1)
        self:setCursor(self.cx, math.max(1, self.cy - n))
    elseif cmd == "B" then
        local n = math.max(1, tonumber(params) or 1)
        self:setCursor(self.cx, math.min(self.h, self.cy + n))
    elseif cmd == "C" then
        local n = math.max(1, tonumber(params) or 1)
        self:setCursor(math.min(self.w, self.cx + n), self.cy)
    elseif cmd == "D" then
        local n = math.max(1, tonumber(params) or 1)
        self:setCursor(math.max(1, self.cx - n), self.cy)

    elseif cmd == "s" then
        self._saved_cx = self.cx
        self._saved_cy = self.cy
    elseif cmd == "u" then
        if self._saved_cx then
            self:setCursor(self._saved_cx, self._saved_cy)
        end
    end
end

-- ── Write ───────────────────────────────────────────────────────────────────

--- Write a string into the TTY region.
--- Handles newlines, carriage returns, auto-scroll, and ANSI/VT100 escape
--- sequences (\27[...X).  Color is managed by the escape codes themselves;
--- callers should NOT call gpu.setForeground separately anymore.
--- @param str string
function TTY:write(str)
    local i = 1
    while i <= #str do
        local ch = str:sub(i, i)

        if ch == "\27" and str:sub(i+1, i+1) == "[" then
            -- ANSI/VT100 escape sequence: find the terminating letter
            local seq_end = str:find("[A-Za-z]", i + 2)
            if seq_end then
                self:_handleAnsi(str:sub(i + 2, seq_end - 1), str:sub(seq_end, seq_end))
                i = seq_end + 1
            else
                i = i + 1  -- malformed / incomplete — skip ESC
            end

        elseif ch == "\n" then
            self.cx = 1
            self.cy = self.cy + 1
            self:_clampCursor()
            i = i + 1

        elseif ch == "\r" then
            self.cx = 1
            i = i + 1

        else
            -- Grab a run of printable chars — stop at newline, CR, or ESC.
            local lineLen = self.w - self.cx + 1
            local chunk   = str:match("([^\n\r\27]+)", i) or ch
            if #chunk > lineLen then chunk = chunk:sub(1, lineLen) end

            local ax, ay = self:_abs(self.cx, self.cy)
            self.gpu.set(ax, ay, chunk)
            self.cx = self.cx + #chunk
            i = i + #chunk

            if self.cx > self.w then
                self.cx = 1
                self.cy = self.cy + 1
                self:_clampCursor()
            end
        end
    end
end

-- ── Read ────────────────────────────────────────────────────────────────────

--- Interactive line editor — reads one line from the keyboard, rendered inside
--- this TTY's region.  Mirrors the previous io.read() behaviour.
---
--- @param options {history: table?, completionCallback: function?}?
--- @return string
--- KERNEL-ONLY minimal blocking read.
--- Process code must use io.read() which routes through syscall.stdinRead()
--- and the line discipline.  Calling TTY:read() from inside a running process
--- will call computer.pullSignal() which cannot be yielded across coroutines
--- and will freeze the entire scheduler.
---
--- This stub is intentionally simple: it is only safe to call from early boot
--- code that runs before the scheduler starts (e.g. a boot-time login prompt).
--- No history, no cursor editing, no completion.
function TTY:read(options)
    options = options or {}
    local buf    = ""
    local beginX = self.cx
    self:setBlink(true)

    local function draw()
        local ax, ay = self:_abs(beginX, self.cy)
        self.gpu.fill(ax, ay, self.w - beginX + 1, 1, " ")
        local vis = buf:sub(1, self.w - beginX + 1)
        if #vis > 0 then self.gpu.set(ax, ay, vis) end
        self.cx = beginX + #buf
    end

    while true do
        local ev = { computer.pullSignal(0.5) }
        if ev[1] == "key_down" then
            local char, code = ev[3], ev[4]
            if char == 13 then                          -- Enter
                self:setBlink(false)
                self.cx = 1
                self.cy = self.cy + 1
                self:_clampCursor()
                return buf
            elseif (char == 8 or (char == 0 and code == 0x0E)) and #buf > 0 then
                buf = buf:sub(1, -2)                    -- Backspace
                draw()
                self:setBlink(true)
            elseif char > 31 then                       -- Printable
                buf = buf .. string.char(char)
                draw()
                self:setBlink(true)
            end
        elseif ev[1] == nil then
            self:setBlink(not self._blink)             -- Cursor blink tick
        end
    end
end

return TTY
