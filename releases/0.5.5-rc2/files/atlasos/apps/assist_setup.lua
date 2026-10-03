local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")

local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local assist = require("atlasos.lib.assist")
local log = require("atlasos.lib.log")
local version = require("atlasos.version")

local cfg = config.load()
if cfg.role ~= "server" then error("Flight-assist setup runs on the onboard server", 0) end

local function heading(text)
  local width = select(1, term.getSize())
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.orange)
  term.clear()
  term.setCursorPos(1, 1)
  print("AtlasOS " .. version.version .. " - " .. text)
  term.setTextColor(colors.lightGray)
  print("FICSIT Heavy Aeronautics Division")
  print(string.rep("-", math.min(width, 48)))
  term.setTextColor(colors.white)
end

local function askNumber(prompt, default, minimum, maximum)
  while true do
    write(prompt .. " [" .. tostring(default) .. "]: ")
    local raw = util.trim(read())
    local value = raw == "" and default or tonumber(raw)
    if value and value >= minimum and value <= maximum then return value end
    printError("Enter a number from " .. tostring(minimum) .. " to " .. tostring(maximum))
  end
end

heading("FLIGHT-ASSIST SETUP")
print("Day 2 adds closed-loop rudder control, heading hold,")
print("Navigation Table steering, altitude hold and pilot")
print("wheel override through the computer steering actuator.")
print("")
term.setTextColor(colors.yellow)
print("This wizard changes configuration only. It moves nothing.")
term.setTextColor(colors.white)
write("Type ASSIST to continue: ")
if read() ~= "ASSIST" then print("Cancelled."); return end

local acfg = assist.ensureConfig(cfg)
local geometry = assist.rudderGeometry(cfg)
if not geometry.ok then error(geometry.error, 0) end

heading("RUDDER CONTROL")
print("True mechanical centre is the bearing angle where the")
print("rudder is physically straight. Atlas uses 0.00 degrees.")
print("The captured manual centre remains stored for reference.")
print("")
acfg.rudder.trueCentreAngle = askNumber("True centre angle", acfg.rudder.trueCentreAngle or 0, -180, 180)

geometry = assist.rudderGeometry(cfg)
if not geometry.ok then error(geometry.error, 0) end
local safeMaximum = math.floor(math.min(geometry.leftMagnitude, geometry.rightMagnitude) * 10) / 10
local defaultMaximum = math.min(tonumber(acfg.rudder.maxAssistDeg) or 35, safeMaximum)
print("")
print(string.format("Calibrated physical travel: %.2f deg left / %.2f deg right",
  geometry.leftMagnitude, geometry.rightMagnitude))
print("Automatic modes deliberately use less than full rudder.")
acfg.rudder.maxAssistDeg = askNumber("Maximum automatic rudder", defaultMaximum, 5, safeMaximum)

local baseline = math.abs(tonumber((cfg.sensors or {}).steeringActuatorRpm) or 16)
acfg.rudder.fastRpm = askNumber("Fast steering RPM", math.min(acfg.rudder.fastRpm or baseline, baseline), 1, baseline)
acfg.rudder.slowRpm = askNumber("Slow steering RPM", math.min(acfg.rudder.slowRpm or 5, acfg.rudder.fastRpm), 1, acfg.rudder.fastRpm)
acfg.rudder.crawlRpm = askNumber("Final-approach RPM", math.min(acfg.rudder.crawlRpm or 1, acfg.rudder.slowRpm), 0.5, acfg.rudder.slowRpm)

heading("ASSIST LIMITS")
print("Heading hold and Navigation steering begin with")
print("conservative gains. Flight tuning can change them later.")
print("")
acfg.heading.maxRudderDeg = math.min(acfg.heading.maxRudderDeg or 30, acfg.rudder.maxAssistDeg)
acfg.navigation.maxRudderDeg = math.min(acfg.navigation.maxRudderDeg or 35, acfg.rudder.maxAssistDeg)
acfg.samplePeriodMs = 50
acfg.configured = true
acfg.commissioned = false
acfg.rudder.wheelLeftSign = nil
acfg.rudder.leftOutputCommand = nil
cfg.sensors.samplePeriodMs = 50

local ok, err = config.save(cfg)
if not ok then error("Could not save flight-assist setup: " .. tostring(err), 0) end
log.info("Volume III Day 2 flight-assist configuration saved")

heading("FLIGHT ASSIST CONFIGURED")
term.setTextColor(colors.lime)
print("Configuration saved. No outputs were moved.")
term.setTextColor(colors.white)
print("")
print("Next run:")
print("  atlasctl assist check")
print("  atlasctl assist commission")
print("")
print("Commissioning keeps propulsion mechanically locked.")
