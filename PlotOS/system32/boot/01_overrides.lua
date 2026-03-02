local process = require("process")
local _pullSignal = computer.pullSignal
printk("Overriding function so process can work")

computer._signal = {}
computer.realPullSignal = _pullSignal
computer.pullSignal = function(tout)
    local proc = process.getCurrentProcess()


    if proc then
        --coroutine.yield()
        -- Insert a new signal with timeout and start time into the process's signal pull
        table.insert(proc.io.signal.pull, { timeout = tout and math.max(tout, 0.05) or math.huge, start_at = computer.uptime() })
        local signalIndex = #proc.io.signal.pull
        while true do
            -- If the signal has a return value, unpack it and remove the signal from the pull
            if proc.io.signal.pull[signalIndex].ret then
                local t = proc.io.signal.pull[signalIndex].ret
                table.remove(proc.io.signal.pull, signalIndex)
                return table.unpack(t)
            end
            coroutine.yield()
        end
    else
        -- If there's no signal, create a new one
       --[[ if not computer._signal then
            computer._signal = table.pack(_pullSignal(tout))
        end
        return table.unpack(computer._signal) -- what im saying is, a coroutine.yield() will instantly return an event? i hav eno idea llmao]]

        return _pullSignal(tout)
    end
end
