-- linedisc.lua

local LineDiscipline = {}
LineDiscipline.__index = LineDiscipline

LineDiscipline.MODE_COOKED = "cooked"
LineDiscipline.MODE_RAW    = "raw"

--- @param tty   table   TTY object
--- @param opts  table?  { mode, echo, signals, history }
--- @return LineDiscipline
function LineDiscipline.new(tty, opts)
    opts = opts or {}
    local self = setmetatable({}, LineDiscipline)

    self.tty     = tty
    self.mode    = opts.mode or LineDiscipline.MODE_COOKED
    self.echo    = opts.echo    ~= false
    self.signals = opts.signals ~= false


    self._lineBuf  = ""
    self._cur      = 1
    self._scroll   = 1
    self._beginX   = nil

    self.history   = opts.history or {}
    self._histPos  = nil
    self._histDraft = ""

    self._readyLines = {}

    self._rawBytes = ""

    self.fg_proc = nil

    return self
end

-- don't fucking touch this
function LineDiscipline:_draw()
    if not self.echo or not self._beginX then return end
    local cols    = self.tty.w - self._beginX + 1
    local visible = self._lineBuf:sub(self._scroll, self._scroll + cols - 1)
    visible = visible .. string.rep(" ", cols - #visible)
    local ax, ay = self.tty:_abs(self._beginX, self.tty.cy)
    self.tty.gpu.set(ax, ay, visible)
end

function LineDiscipline:_redrawCursor()
    if not self.echo or not self._beginX then return end
    self.tty:setBlink(false)
    self.tty.cx = self._beginX + self._cur - self._scroll
    self.tty:setBlink(true)
end

function LineDiscipline:_visibleCols()
    return self.tty.w - (self._beginX or 1) + 1
end

function LineDiscipline:_nukeLineState()
    self._lineBuf  = ""
    self._cur      = 1
    self._scroll   = 1
    self._beginX   = nil
    self._histPos  = nil
end

--- @param mode string  LineDiscipline.MODE_COOKED or MODE_RAW
function LineDiscipline:setMode(mode)
    self.mode = mode
end

function LineDiscipline:canRead()
    if self.mode == LineDiscipline.MODE_COOKED then
        return #self._readyLines > 0
    else
        return #self._rawBytes > 0
    end
end

--- @param maxBytes number|nil  how many bytes max. nil = full line
--- @return string|nil, string|nil
function LineDiscipline:tryRead(maxBytes)
    if self.mode == LineDiscipline.MODE_COOKED then
        if #self._readyLines == 0 then return nil end
        local line = self._readyLines[1]
        if line == "\4" then  -- ^D sentinel: the process gets nothing and likes it
            table.remove(self._readyLines, 1)
            return nil, "eof"
        end
        if maxBytes and maxBytes < #line then
            self._readyLines[1] = line:sub(maxBytes + 1)
            return line:sub(1, maxBytes)
        end
        table.remove(self._readyLines, 1)
        return line
    else
        if #self._rawBytes == 0 then return nil end
        maxBytes = maxBytes or #self._rawBytes
        local chunk = self._rawBytes:sub(1, maxBytes)
        self._rawBytes = self._rawBytes:sub(maxBytes + 1)
        return chunk
    end
end

--- @param char  number  unicode codepoint. 0 if there isn't one
--- @param code  number  hardware scancode
--- @return string|nil  signal name ("SIGINT", "SIGTSTP") or nil if nothing exciting happened
--- @return table|nil   who to send it to. nil means the owning process
function LineDiscipline:processKey(char, code)

    if self.mode == LineDiscipline.MODE_RAW then
        -- just eat the byte and shut up
        if char and char > 0 then
            self._rawBytes = self._rawBytes .. string.char(char)
        end
        return nil
    end

    if not self._beginX then
        self._beginX = self.tty.cx
        if self.echo then self.tty:setBlink(true) end
    end

    if char == 13 then
        local doneLine = self._lineBuf
        if self.echo then
            self.tty:setBlink(false)
            self:_draw()
            self.tty.cx = 1
            self.tty.cy = self.tty.cy + 1
            self.tty:_clampCursor()
        end
        table.insert(self._readyLines, doneLine .. "\n")
        if #doneLine > 0 and self.history[#self.history] ~= doneLine then
            table.insert(self.history, doneLine)
            if #self.history > 64 then table.remove(self.history, 1) end
        end
        self:_nukeLineState()
        return nil

    elseif char == 4 and #self._lineBuf == 0 then
        table.insert(self._readyLines, "\4")
        return nil

    elseif char == 3 and self.signals then
        if self.echo then
            self.tty:setBlink(false)
            self.tty:write("^C\n")
        end
        self:_nukeLineState()
        return "SIGINT", self.fg_proc

    elseif char == 26 and self.signals then
        if self.echo then self.tty:write("^Z\n") end
        self:_nukeLineState()
        return "SIGTSTP", self.fg_proc

    elseif char == 12 then
        self.tty:clear()
        self._beginX = self.tty.cx
        self:_draw(); self:_redrawCursor()

    elseif char == 8 or ((char == 0 or char == 127) and code == 0x0E) then
        if #self._lineBuf > 0 and self._cur > 1 then
            self._lineBuf = self._lineBuf:sub(1, self._cur - 2) .. self._lineBuf:sub(self._cur)
            self._cur = self._cur - 1
            if self._cur - self._scroll < 0 then self._scroll = math.max(1, self._scroll - 1) end
        end
        self:_draw(); self:_redrawCursor()

    elseif char == 127 or (char == 0 and code == 0xD3) then
        if #self._lineBuf > 0 and self._cur <= #self._lineBuf then
            self._lineBuf = self._lineBuf:sub(1, self._cur - 1) .. self._lineBuf:sub(self._cur + 1)
        end
        self:_draw(); self:_redrawCursor()

    elseif code == 203 then 
        if self._cur > 1 then
            self._cur = self._cur - 1
            if self._cur - self._scroll < 0 then self._scroll = math.max(1, self._scroll - 1) end
            self:_redrawCursor()
        end

    elseif code == 205 then
        if self._cur <= #self._lineBuf then
            self._cur = self._cur + 1
            if self._cur - self._scroll > self:_visibleCols() then self._scroll = self._scroll + 1 end
            self:_redrawCursor()
        end

    elseif code == 200 then
        if self._histPos and self._histPos > 1 then
            self.history[self._histPos] = self._lineBuf
            self._histPos = self._histPos - 1
            self._lineBuf = self.history[self._histPos]
        elseif not self._histPos and #self.history > 0 then
            self._histPos   = #self.history
            self._histDraft = self._lineBuf  -- save the draft so we can get it back
            self._lineBuf   = self.history[self._histPos]
        else
            return nil
        end
        self._scroll = math.max(1, #self._lineBuf - self:_visibleCols() + 1)
        self._cur    = #self._lineBuf + 1
        self:_draw(); self:_redrawCursor()

    elseif code == 208 then
        if self._histPos then
            if self._histPos == #self.history then
                self.history[self._histPos] = self._lineBuf
                self._lineBuf = self._histDraft
                self._histPos = nil
            else
                self.history[self._histPos] = self._lineBuf
                self._histPos = self._histPos + 1
                self._lineBuf = self.history[self._histPos]
            end
            self._scroll = math.max(1, #self._lineBuf - self:_visibleCols() + 1)
            self._cur    = #self._lineBuf + 1
            self:_draw(); self:_redrawCursor()
        end

    elseif code == 199 then
        self._scroll = 1; self._cur = 1
        self:_draw(); self:_redrawCursor()

    elseif code == 207 then
        self._scroll = math.max(1, #self._lineBuf - self:_visibleCols() + 1)
        self._cur    = #self._lineBuf + 1
        self:_draw(); self:_redrawCursor()

    elseif char and char > 31 then
        self._lineBuf = self._lineBuf:sub(1, self._cur - 1) .. string.char(char) .. self._lineBuf:sub(self._cur)
        self._cur = self._cur + 1
        if self._cur - self._scroll > self:_visibleCols() then self._scroll = self._scroll + 1 end
        self:_draw(); self:_redrawCursor()
    end

    return nil
end

--- @param text string
function LineDiscipline:pasteText(text)
    if self.mode == LineDiscipline.MODE_RAW then
        self._rawBytes = self._rawBytes .. text  -- raw mode eats everything
        return
    end
    if not self._beginX then self._beginX = self.tty.cx end
    self._lineBuf = self._lineBuf:sub(1, self._cur - 1) .. text .. self._lineBuf:sub(self._cur)
    self._cur     = self._cur + #text
    self._scroll  = math.max(1, self._cur - self:_visibleCols())
    self:_draw(); self:_redrawCursor()
end

return LineDiscipline
