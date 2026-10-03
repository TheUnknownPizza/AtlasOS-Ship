local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")
local requestedChannel, requestedLevel = ...
local config = require("atlasos.lib.config")
local ioControl = require("atlasos.lib.io")
local util = require("atlasos.lib.util")

local cfg = config.load()
if cfg.role ~= "server" then error("I/O tests run on the onboard server", 0) end
local valid, errors = ioControl.validate(cfg, false)
if not valid then error(table.concat(errors, "; "), 0) end

local allowed = {
  propulsionPermit = true, lift = true, thrust = true, reverse = true, gyro = true,
  steeringEnable = true, rudderLeft = true, rudderRight = true,
}

term.setBackgroundColor(colors.black)
term.setTextColor(colors.orange)
term.clear()
term.setCursorPos(1, 1)
print("AtlasOS I/O TEST")
term.setTextColor(colors.white)
print("")
print("Every pulse returns to SAFE afterward.")
print("Secure the vessel and disconnect motion where needed.")
print("")
print("Channels:")
print("  propulsionPermit, lift, thrust")
print("  reverse, gyro, steeringEnable")
print("  rudderLeft, rudderRight")
print("")

local channel = util.trim(requestedChannel or "")
if channel == "" then write("Channel: "); channel = util.trim(read()) end
if not allowed[channel] then error("Unknown test channel", 0) end
local level = tonumber(requestedLevel)
if (channel == "lift" or channel == "thrust") and not level then
  write("Test signal 0-15 [7]: ")
  local raw = util.trim(read())
  level = raw == "" and 7 or tonumber(raw)
end
level = util.clamp(level or 15, 0, 15)

if channel == "propulsionPermit" then
  term.setTextColor(colors.yellow)
  print("WARNING: this briefly opens the physical thrust lock.")
  term.setTextColor(colors.white)
elseif channel == "steeringEnable" then
  term.setTextColor(colors.yellow)
  print("WARNING: this briefly selects computer steering.")
  term.setTextColor(colors.white)
end
write("Type TEST to pulse " .. channel .. ": ")
if read() ~= "TEST" then print("Cancelled.") return end
local ok, err = ioControl.testChannel(cfg, channel, level, 1)
if not ok then error(tostring(err), 0) end
term.setTextColor(colors.lime)
print("Pulse complete; all outputs returned to SAFE.")
term.setTextColor(colors.white)
