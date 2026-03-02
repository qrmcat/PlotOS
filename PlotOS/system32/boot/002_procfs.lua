--- 002_procfs.lua
--- Mount the process filesystem at /proc.
---
--- After this script runs, every live process is accessible at:
---   /proc/{pid}/stdin    read/write  → proc.io.stdin  stream
---   /proc/{pid}/stdout   read/write  → proc.io.stdout stream
---   /proc/{pid}/stderr   read/write  → proc.io.stderr stream
---   /proc/{pid}/status   read-only   → process status string
---   /proc/{pid}/name     read-only   → process name
---   /proc/{pid}/cmdline  read-only   → NUL-separated argv
---
--- Piping example (from a shell or launcher):
---   local procA = process.load("cmd_a", "/bin/cmd_a.lua")
---   local procB = process.load("cmd_b", "/bin/cmd_b.lua")
---   procB.io.stdin = procA.io.stdout   -- wire stdout → stdin
---   -- now /proc/{pidB}/stdin and /proc/{pidA}/stdout point at the same stream

local procfs = package.require("procfs")
local fs     = package.require("fs")

local ok, err = fs.mount(procfs, "/proc")
if ok then
    printk("procfs mounted at /proc", "info")
else
    printk("procfs: failed to mount at /proc: " .. tostring(err), "warn")
end
