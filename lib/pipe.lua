--- pipe.lua

local Pipe = {}

--- Create a new pipe.
--- @return table reader  The read (consumer) end of the pipe.
--- @return table writer  The write (producer) end of the pipe.
function Pipe.new()
    local state = {
        buf          = "",       -- buffered data
        write_closed = false,    -- true once the write end is closed
        read_closed  = false,    -- true once the read end is closed
    }

    -- ── Reader end ────────────────────────────────────────────────────────────
    local reader = { _pipe = state, name = "pipe:r" }

    function reader.canRead()
        return #state.buf > 0 or state.write_closed
    end

    --- @param n number|nil  Max bytes; nil = all buffered data.
    function reader.tryRead(n)
        if #state.buf == 0 then
            if state.write_closed then return nil, "eof" end
            return nil  -- would block
        end
        n = n or #state.buf
        local chunk = state.buf:sub(1, n)
        state.buf   = state.buf:sub(n + 1)
        return chunk
    end

    function reader.write()
        return nil, "pipe reader is not writable"
    end

    function reader.close()
        state.read_closed = true
        state.buf = ""
    end

    local writer = { _pipe = state, name = "pipe:w" }

    function writer.canRead()
        return false
    end

    --- @param data string
    --- @return number|nil bytes_written, string|nil err
    function writer.write(data)
        if state.write_closed then return nil, "broken pipe (write end closed)" end
        if state.read_closed  then return nil, "broken pipe (read end closed)"  end
        data = tostring(data)
        state.buf = state.buf .. data
        return #data
    end

    function writer.close()
        state.write_closed = true
    end

    function writer.tryRead()
        return nil, "pipe writer is not readable"
    end

    return reader, writer
end

return Pipe
