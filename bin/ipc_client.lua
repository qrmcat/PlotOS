local ipc = require("ipc")
local ser = require("serialization")

print(ipc.call("shell"))