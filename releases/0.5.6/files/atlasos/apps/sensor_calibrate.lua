local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")

local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local sensors = require("atlasos.lib.sensors")
local ioControl = require("atlasos.lib.io")
local log = require("atlasos.lib.log")
local version = require("atlasos.version")

local cfg = config.load()
if cfg.role ~= "server" then error("Rudder calibration runs on the onboard server", 0) end

local valid, errors = sensors.validate(cfg, false, false)
if not valid then error(table.concat(errors, "; "), 0) end

local map = cfg.sensors.map
local wheel = map.steeringWheel
local bearing = map.rudderBearing

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

local function call(name, method)
  local ok, value = pcall(peripheral.call, name, method)
  if not ok then error(tostring(method) .. " failed: " .. tostring(value), 0) end
  return value
end

local function bearingAngle()
  local ok, value = sensors.readRudderBearingAngle(bearing)
  if not ok then error("Rudder angle read failed: " .. tostring(value), 0) end
  return tonumber(value) or 0
end

local function waitStableCentre(timeoutSeconds)
  local deadline = util.nowMillis() + timeoutSeconds * 1000
  local stable = 0
  local lastAngle = nil
  while util.nowMillis() < deadline do
    local held = call(wheel, "isHeld")
    local normalized = tonumber(call(wheel, "getNormalizedAngle")) or 0
    local angle = bearingAngle()
    local movement = lastAngle and math.abs(sensors.angleDelta(angle, lastAngle)) or 999
    lastAngle = angle
    if not held and math.abs(normalized) <= 0.08 and movement <= 0.15 then
      stable = stable + 1
      if stable >= 12 then return angle end
    else
      stable = 0
    end
    sleep(0.05)
  end
  return nil
end

local function waitExtreme(label, zeroAngle, timeoutSeconds)
  print("")
  print("Press Enter, close this computer screen, then")
  print("turn the PHYSICAL wheel to your normal SAFE maximum")
  print(label .. " position and hold it. Do not use an unsafe")
  print("360-degree mechanical limit just because it exists.")
  print("AtlasOS captures it automatically; reopen this")
  print("computer after a couple of seconds.")
  read()

  local deadline = util.nowMillis() + timeoutSeconds * 1000
  local stable = 0
  local lastAngle = nil
  local captured = nil
  while util.nowMillis() < deadline do
    local held = call(wheel, "isHeld")
    local normalized = tonumber(call(wheel, "getNormalizedAngle")) or 0
    local angle = bearingAngle()
    local movement = lastAngle and math.abs(sensors.angleDelta(angle, lastAngle)) or 999
    lastAngle = angle

    local deflection = math.abs(sensors.angleDelta(angle, zeroAngle))
    if held and math.abs(normalized) >= 0.05 and deflection >= 2 and movement <= 0.25 then
      stable = stable + 1
      if stable >= 8 then captured = angle; break end
    else
      stable = 0
    end
    sleep(0.05)
  end
  if not captured then error("Timed out waiting for full " .. label .. " steering input", 0) end
  print("")
  term.setTextColor(colors.lime)
  print(label .. " position captured.")
  term.setTextColor(colors.white)
  print("Manually return the wheel to its normal centred")
  print("position, then release it there.")
  sleep(1)
  return captured
end

heading("RUDDER CALIBRATION")
print("This measures the real rudder movement produced by")
print("your physical wheel and mechanical linkage.")
print("")
term.setTextColor(colors.yellow)
print("The vessel must be secured. Keep thrust mechanically locked.")
term.setTextColor(colors.white)
print("The automatic steering motor is NOT used by this wizard.")
print("SAFE selects the physical wheel branch.")
local bearingInfo = sensors.rudderBearingInfo(bearing)
print("Rudder sensor: " .. (bearingInfo and bearingInfo.label or "unknown bearing"))
print("")
write("Type CALIBRATE to continue: ")
if read() ~= "CALIBRATE" then print("Cancelled."); return end

local safeOk, safeErrors = ioControl.applySafe(cfg)
if not safeOk then error("Could not assert SAFE: " .. table.concat(safeErrors or {}, "; "), 0) end
cfg.safe = true
cfg.armed = false
cfg.lastSafeReason = "rudder sensor calibration"
config.save(cfg)

heading("CAPTURE CENTRE")
print("Manually place the physical wheel at its normal")
print("centred position, then release it there.")
print("")
print("Press Enter, then AtlasOS will wait for a stable centre.")
read()
local zeroAngle = waitStableCentre(45)
if not zeroAngle then error("Could not detect a stable centred rudder within 45 seconds", 0) end
print(string.format("Centre captured: %.2f degrees", zeroAngle))

local leftAngle = waitExtreme("LEFT", zeroAngle, 45)
print("")
print("Waiting for you to return the wheel to centre...")
if not waitStableCentre(45) then error("Wheel/rudder was not manually returned to centre after LEFT capture", 0) end

local rightAngle = waitExtreme("RIGHT", zeroAngle, 45)
print("")
print("Waiting for you to return the wheel to centre again...")
local finalCentre = waitStableCentre(45)
if not finalCentre then error("Wheel/rudder was not manually returned to centre after RIGHT capture", 0) end

local leftDelta = sensors.angleDelta(leftAngle, zeroAngle)
local rightDelta = sensors.angleDelta(rightAngle, zeroAngle)
local centreError = math.abs(sensors.angleDelta(finalCentre, zeroAngle))

if math.abs(leftDelta) < 2 or math.abs(rightDelta) < 2 then
  error("Rudder movement was too small to calibrate", 0)
end
if leftDelta * rightDelta >= 0 then
  error("LEFT and RIGHT captures moved the bearing in the same direction", 0)
end
if centreError > 8 then
  error(string.format("Final centre differs by %.2f degrees; inspect the linkage", centreError), 0)
end

cfg.sensors.rudder = cfg.sensors.rudder or {}
cfg.sensors.rudder.calibrated = true
cfg.sensors.rudder.zeroAngle = zeroAngle
cfg.sensors.rudder.leftDelta = leftDelta
cfg.sensors.rudder.rightDelta = rightDelta
cfg.sensors.rudder.centreTolerance = math.max(2, math.min(8, centreError + 2))
cfg.sensors.commissioned = false

local saved, saveError = config.save(cfg)
if not saved then error("Could not save calibration: " .. tostring(saveError), 0) end
log.info(string.format("Rudder calibrated: zero %.2f, left %.2f, right %.2f", zeroAngle, leftDelta, rightDelta))

heading("RUDDER CALIBRATED")
term.setTextColor(colors.lime)
print("Rudder position feedback is calibrated.")
term.setTextColor(colors.white)
print("")
print(string.format("Centre:     %.2f deg", zeroAngle))
print(string.format("Full left:  %+.2f deg", leftDelta))
print(string.format("Full right: %+.2f deg", rightDelta))
print("")
print("Next run:")
print("  atlasctl sensors monitor")
print("  atlasctl sensors commission")
