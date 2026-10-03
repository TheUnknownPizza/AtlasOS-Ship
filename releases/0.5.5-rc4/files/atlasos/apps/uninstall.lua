local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")
local util = require("atlasos.lib.util")

print("AtlasOS uninstall / recovery")
print("")
print("This will disable AtlasOS startup and preserve its files.")
write("Continue? (yes/no): ")
if read():lower() ~= "yes" then print("Cancelled.") return end

local backup = "/atlasos/backup/original_startup.lua"
if fs.exists(backup) then
  if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
  util.copyRecursive(backup, "/startup.lua")
  print("Original startup.lua restored.")
else
  if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
  print("AtlasOS startup.lua removed.")
end

local destination = "/atlasos-disabled-" .. tostring(os.getComputerID())
if fs.exists(destination) then fs.delete(destination) end
fs.move("/atlasos", destination)
print("AtlasOS files preserved at " .. destination)
print("Rebooting...")
sleep(2)
os.reboot()
