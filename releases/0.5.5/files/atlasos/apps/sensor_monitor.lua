local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")

local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local sensors = require("atlasos.lib.sensors")

local cfg = config.load()
if cfg.role ~= "server" then error("Sensor monitor runs on the onboard server", 0) end

local page = 1

local function signed(value, decimals, suffix)
  if value == nil then return "-" end
  return string.format("%+." .. tostring(decimals or 1) .. "f%s", tonumber(value) or 0, suffix or "")
end

local function writeLine(row, label, value, valueColor)
  local width, height = term.getSize()
  if row < 1 or row > height then return end
  local left = tostring(label or "")
  local right = tostring(value or "")
  term.setCursorPos(1, row)
  term.setTextColor(colors.lightGray)
  term.write(util.truncate(left, math.max(1, width - #right - 1)))
  term.setCursorPos(math.max(1, width - #right + 1), row)
  term.setTextColor(valueColor or colors.white)
  term.write(util.truncate(right, width))
end

local function drawHeader(data, title)
  local width = select(1, term.getSize())
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.orange)
  print("AtlasOS Instrument Monitor")
  term.setTextColor(colors.lightGray)
  print(title .. " | advisory only")
  print(string.rep("-", math.min(width, 48)))
  term.setTextColor(data.healthy and colors.lime or colors.red)
  print(data.healthy and "SENSOR SUITE: HEALTHY" or "SENSOR SUITE: DEGRADED")
end

local function drawFlight(data)
  drawHeader(data, "FLIGHT")
  writeLine(5, "Altitude", string.format("%.2f m", data.altitude or 0))
  writeLine(6, "Vertical speed", signed(data.verticalSpeed, 2, " m/s"))
  writeLine(7, "Air pressure", string.format("%.1f%%", (data.airPressure or 0) * 100))
  writeLine(8, "Heading", string.format("%06.2f deg", data.heading or 0))
  writeLine(9, "Pitch", signed(data.pitch, 2, " deg"))
  writeLine(10, "Roll", signed(data.roll, 2, " deg"))
  writeLine(11, "Yaw rate", signed(data.yawRate, 2, " deg/s"))
  writeLine(12, "Forward speed", signed(data.forwardSpeed, 2, " m/s"))
  writeLine(13, "Right speed", signed(data.rightSpeed, 2, " m/s"))
  writeLine(14, "Body-up speed", signed(data.verticalBodySpeed, 2, " m/s"))
  if data.hasTarget then
    writeLine(15, "Target bearing", signed(data.bearing, 1, " deg"))
    writeLine(16, "Target range", string.format("%.1f m", data.distance or 0))
    writeLine(17, "Closure / height", signed(data.closureRate, 1, " / ") .. signed(data.verticalOffset, 1, " m"))
  else
    writeLine(15, "Navigation target", "NONE", colors.gray)
  end
end

local function drawSteering(data)
  drawHeader(data, "STEERING")
  writeLine(5, "Wheel state", data.wheelHeld and "HELD" or "FREE",
    data.wheelHeld and colors.yellow or colors.lime)
  writeLine(6, "Wheel angle", signed(data.wheelAngle, 2, " deg"))
  writeLine(7, "Wheel command", signed(data.wheelTargetAngle, 2, " deg"))
  writeLine(8, "Wheel normalized", signed((data.wheelNormalized or 0) * 100, 0, "%"))
  writeLine(9, "Rudder type", data.rudderBearingLabel or "UNKNOWN")
  writeLine(10, "Bearing angle", signed(data.rudderBearingAngle, 2, " deg"))
  writeLine(11, "Rudder angle", data.rudderAngle and signed(data.rudderAngle, 2, " deg") or "UNCAL")
  writeLine(12, "Rudder position", data.rudderNormalized and signed(data.rudderNormalized * 100, 0, "%") or "UNCAL")
  writeLine(13, "Rudder assembled", tostring(data.rudderAssembled))
  local lockState = data.rudderLocked == nil and "N/A" or tostring(data.rudderLocked)
  writeLine(14, "Bearing lock", lockState)
  writeLine(15, "Steer target RPM", data.steeringTargetRpm and signed(data.steeringTargetRpm, 0, "") or "NOT MAPPED")
  writeLine(16, "Steer live RPM", data.steeringLiveRpm and signed(data.steeringLiveRpm, 0, "") or "-")
  writeLine(17, "Steer source", data.steeringHasSource and "POWERED" or "NO SOURCE",
    data.steeringHasSource and colors.lime or colors.red)
  writeLine(18, "Steer stress", data.steeringOverstressed and "OVERSTRESSED" or "OK",
    data.steeringOverstressed and colors.red or colors.lime)
  writeLine(19, "Calibration", data.rudderAngle and "READY" or "REQUIRED",
    data.rudderAngle and colors.lime or colors.yellow)
  if not data.healthy then
    writeLine(20, "First error", (data.errors or {})[1] or "unknown", colors.red)
  end
end

local function draw()
  local data = sensors.read(cfg)
  if page == 1 then drawFlight(data) else drawSteering(data) end
  local _, height = term.getSize()
  if height >= 2 then
    term.setCursorPos(1, height - 1)
    term.setTextColor(colors.gray)
    term.write("1 Flight | 2 Steering")
    term.setCursorPos(1, height)
    term.write("Ctrl+T exits; outputs unchanged")
  end
end

local timer = os.startTimer(0)
while true do
  local event = { os.pullEventRaw() }
  if event[1] == "terminate" then
    term.setTextColor(colors.white)
    term.setCursorPos(1, select(2, term.getSize()))
    return
  elseif event[1] == "key" then
    if event[2] == keys.one then page = 1
    elseif event[2] == keys.two then page = 2 end
    draw()
  elseif event[1] == "timer" and event[2] == timer then
    draw()
    timer = os.startTimer(0.2)
  end
end
