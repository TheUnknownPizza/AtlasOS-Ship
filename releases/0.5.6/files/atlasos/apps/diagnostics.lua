local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")
local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local version = require("atlasos.version")
local log = require("atlasos.lib.log")
local ioControl = require("atlasos.lib.io")
local sensors = require("atlasos.lib.sensors")
local assist = require("atlasos.lib.assist")

local cfg = config.load()
local terminalWidth = select(1, term.getSize())
local reportWidth = math.max(12, terminalWidth - 1)
local lines = {}
local function append(text) lines[#lines + 1] = tostring(text or "") end

local function wrapText(text, width)
  text, width = tostring(text or ""), math.max(1, tonumber(width) or reportWidth)
  local output = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    if paragraph == "" then output[#output + 1] = ""
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if #candidate <= width then line = candidate
        else
          if line ~= "" then output[#output + 1] = line end
          while #word > width do output[#output + 1] = word:sub(1, width); word = word:sub(width + 1) end
          line = word
        end
      end
      if line ~= "" then output[#output + 1] = line end
    end
  end
  return output
end

local function addField(label, value)
  local prefix, text = tostring(label) .. ": ", tostring(value)
  if #prefix + #text <= reportWidth then append(prefix .. text); return end
  append(tostring(label) .. ":")
  for _, line in ipairs(wrapText(text, reportWidth - 2)) do append("  " .. line) end
end

local modemName = util.findWirelessModem()
local modemText = modemName or "NOT FOUND"
if pocket and modemName == "back" then modemText = "pocket upgrade (CC API name: back)" end

addField("AtlasOS", version.version .. " / Volume " .. version.volume .. " Day " .. tostring(version.day) .. " / " .. version.codename)
addField("Computer ID", os.getComputerID())
addField("Computer label", os.getComputerLabel() or "(none)")
addField("Role", cfg.role or "not configured")
addField("CraftOS", os.version())
addField("Host", _HOST or "unknown")
addField("Free space", fs.getFreeSpace("/"))
addField("Wireless modem", modemText)
addField("Safe state", tostring(cfg.safe))
addField("Paired pocket ID", cfg.pairedPocketId or "none")
addField("Server ID", cfg.serverId or "none")

if cfg.role == "server" then
  local valid, errors = ioControl.validate(cfg, true)
  addField("I/O configured", tostring(cfg.hardware.configured == true))
  addField("I/O commissioned", tostring(cfg.hardware.commissioned == true))
  addField("I/O valid", tostring(valid))
  addField("Propulsion lock", cfg.safe and "LOCKED" or "OPEN")
  addField("Steering authority", cfg.safe and "MANUAL WHEEL" or "COMPUTER")
  if not valid then addField("I/O errors", table.concat(errors or {}, "; ")) end
  append("")
  append("I/O map:")
  for _, line in ipairs(ioControl.describe(cfg)) do append("  " .. line) end

  local sensorValid, sensorValidationErrors = sensors.validate(cfg, false, false)
  local telemetry = sensors.read(cfg)
  append("")
  addField("Sensors configured", tostring((cfg.sensors or {}).configured == true))
  addField("Sensors commissioned", tostring((cfg.sensors or {}).commissioned == true))
  addField("Sensors valid", tostring(sensorValid and telemetry.healthy))
  if not sensorValid then addField("Sensor map errors", table.concat(sensorValidationErrors or {}, "; ")) end
  if not telemetry.healthy then addField("Sensor read errors", table.concat(telemetry.errors or {}, "; ")) end
  append("")
  append("Sensor map:")
  for _, line in ipairs(sensors.describe(cfg)) do append("  " .. line) end
  append("")
  append("Telemetry sample:")
  addField("  Altitude", string.format("%.2f m", telemetry.altitude or 0))
  addField("  Vertical speed", string.format("%+.2f m/s", telemetry.verticalSpeed or 0))
  addField("  Heading", string.format("%.2f deg", telemetry.heading or 0))
  addField("  Pitch", string.format("%+.2f deg", telemetry.pitch or 0))
  addField("  Roll", string.format("%+.2f deg", telemetry.roll or 0))
  addField("  Yaw rate", string.format("%+.2f deg/s", telemetry.yawRate or 0))
  addField("  Forward speed", string.format("%+.2f m/s", telemetry.forwardSpeed or 0))
  addField("  Right speed", string.format("%+.2f m/s", telemetry.rightSpeed or 0))
  addField("  Wheel held", tostring(telemetry.wheelHeld))
  addField("  Wheel normalized", string.format("%+.3f", telemetry.wheelNormalized or 0))
  addField("  Rudder bearing", telemetry.rudderBearingLabel or "unknown")
  addField("  Bearing angle", string.format("%+.2f deg", telemetry.rudderBearingAngle or 0))
  addField("  Day 1 rudder angle", telemetry.rudderAngle and string.format("%+.2f deg", telemetry.rudderAngle) or "not calibrated")
  addField("  Rudder assembled", tostring(telemetry.rudderAssembled))
  addField("  Steering target", telemetry.steeringTargetRpm and string.format("%+.1f RPM", telemetry.steeringTargetRpm) or "not mapped")
  addField("  Steering live", telemetry.steeringLiveRpm and string.format("%+.1f RPM", telemetry.steeringLiveRpm) or "unavailable")
  addField("  Steering source", telemetry.steeringHasSource and "POWERED" or "NO SOURCE")
  addField("  Steering stress", telemetry.steeringOverstressed and "OVERSTRESSED" or "OK")

  local assistValid, assistErrors = assist.validate(cfg, true)
  local geometry = assist.rudderGeometry(cfg)
  append("")
  addField("Assist configured", tostring((cfg.autoflight or {}).configured == true))
  addField("Assist commissioned", tostring((cfg.autoflight or {}).commissioned == true))
  addField("Assist valid", tostring(assistValid))
  if not assistValid then addField("Assist errors", table.concat(assistErrors or {}, "; ")) end
  if geometry.ok then
    addField("True rudder centre", string.format("%+.2f deg", geometry.trueCentre))
    addField("Safe rudder travel", string.format("left %.2f / right %.2f deg", geometry.leftMagnitude, geometry.rightMagnitude))
    local semantic = assist.bearingToSemantic(cfg, telemetry.rudderBearingAngle)
    addField("Day 2 semantic rudder", semantic and string.format("%+.2f deg", semantic) or "unavailable")
  else
    addField("Rudder geometry", geometry.error)
  end
  append("")
  append("Flight-assist configuration:")
  for _, line in ipairs(assist.describe(cfg)) do append("  " .. line) end
end

append("")
append("Peripherals:")
local names = peripheral.getNames(); table.sort(names)
if #names == 0 then append("  (none)")
else
  for _, name in ipairs(names) do
    local shown = (pocket and name == "back") and "pocket upgrade" or name
    for _, line in ipairs(wrapText(shown .. " - " .. util.peripheralTypeText(name), reportWidth - 2)) do append("  " .. line) end
  end
end

local report = table.concat(lines, "\n")
local reportPath = "/atlasos/logs/diagnostics-" .. tostring(util.nowMillis()) .. ".txt"
local saved, saveError = util.atomicWrite(reportPath, report .. "\n")
if saved then log.info("Diagnostics report written to " .. reportPath)
else log.error("Diagnostics report write failed: " .. tostring(saveError)) end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear(); term.setCursorPos(1, 1)
textutils.pagedPrint(report)
print("")
if saved then
  term.setTextColor(colors.lime); print("Saved inside this computer:")
  term.setTextColor(colors.white); print(reportPath); print("")
  print("View with:"); print("edit " .. reportPath)
else
  term.setTextColor(colors.red); print("REPORT NOT SAVED")
  term.setTextColor(colors.white); print(tostring(saveError or "unknown filesystem error"))
end
