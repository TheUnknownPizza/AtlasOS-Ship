local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")

local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local sensors = require("atlasos.lib.sensors")
local log = require("atlasos.lib.log")
local version = require("atlasos.version")

local cfg = config.load()
if cfg.role ~= "server" then error("Sensor setup runs on the onboard server", 0) end

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
    if value and value >= minimum and value <= maximum and value == math.floor(value) then return value end
    printError("Enter a whole number from " .. minimum .. " to " .. maximum)
  end
end

local function askYesNo(prompt, default)
  local suffix = default and " [Y/n]: " or " [y/N]: "
  while true do
    write(prompt .. suffix)
    local value = util.trim(read()):lower()
    if value == "" then return default end
    if value == "y" or value == "yes" then return true end
    if value == "n" or value == "no" then return false end
  end
end

local function callText(name, method)
  local result = { pcall(peripheral.call, name, method) }
  if not result[1] then return "unreadable" end
  return tostring(result[2])
end

local function choose(label, names, optional, details)
  if #names == 0 then
    if optional then
      print(label .. ": none detected; leaving optional mapping blank.")
      return nil
    end
    error(label .. " was not detected. Check the wired modem network.", 0)
  end

  print("")
  print(label .. ":")
  if optional then print("  0) Do not map this optional peripheral") end
  for index, name in ipairs(names) do
    local suffix = details and details(name) or ""
    if suffix ~= "" then suffix = "  [" .. suffix .. "]" end
    print("  " .. index .. ") " .. name .. suffix)
  end

  local minimum = optional and 0 or 1
  local selected = askNumber("Choose", optional and 0 or 1, minimum, #names)
  if selected == 0 then return nil end
  return names[selected]
end

local function groupVelocity()
  local groups = { x = {}, y = {}, z = {} }
  local all = sensors.findByType("velocity_sensor")
  for _, name in ipairs(all) do
    local ok, axis = pcall(peripheral.call, name, "getAxis")
    if ok and groups[axis] then groups[axis][#groups[axis] + 1] = name end
  end
  return groups
end

heading("INSTRUMENTATION SETUP")
print("This maps the vessel's flight sensors to the onboard server.")
print("")
print("The server must see every sensor through a wired modem network.")
print("Right-click each wired modem so its peripheral is attached.")
print("")
term.setTextColor(colors.yellow)
print("This wizard does not move the vessel or enable autopilot.")
term.setTextColor(colors.white)
write("Type SENSORS to continue: ")
if read() ~= "SENSORS" then print("Cancelled."); return end

local types = sensors.types()
local map = {}

map.altitude = choose("Altitude Sensor", sensors.findByType(types.altitude), false)
map.gimbal = choose("Gimbal Sensor", sensors.findByType(types.gimbal), false)
map.navigation = choose("Navigation Table", sensors.findByType(types.navigation), false)
map.steeringWheel = choose("Physical Steering Wheel", sensors.findByType(types.steeringWheel), false)
map.rudderBearing = choose("Rudder Bearing (Mechanical or Swivel)", sensors.findRudderBearings(), false,
  function(name)
    local info = sensors.rudderBearingInfo(name)
    return info and info.label or util.peripheralTypeText(name)
  end)

local velocity = groupVelocity()
map.velocity = {}
for _, axis in ipairs({ "x", "y", "z" }) do
  map.velocity[axis] = choose("Velocity Sensor " .. axis:upper(), velocity[axis], false,
    function(name) return "axis " .. callText(name, "getAxis") end)
end

local speedControllers = sensors.findByType(types.speedController)
map.steeringSpeedController = choose("Steering Rotation Speed Controller (required for Day 2)", speedControllers, false,
  function(name)
    return "target " .. callText(name, "getTargetSpeed") .. " RPM"
  end)

map.physicsAssembler = choose("Physics Assembler", sensors.findByType(types.assembler), true)

heading("VESSEL BODY AXIS")
print("Choose the direction the vessel's NOSE points right now")
print("while the ship is DISASSEMBLED in its build position.")
print("")
print("  1) +Z  south")
print("  2) -Z  north")
print("  3) +X  east")
print("  4) -X  west")
print("")
print("This corrects heading, speed, pitch and roll labels.")
local noseChoices = { "+z", "-z", "+x", "-x" }
local noseIndex = askNumber("Vessel nose direction", 1, 1, 4)
local noseAxis = noseChoices[noseIndex]

heading("NAVIGATION TABLE")
print("The moving needle follows the selected target.")
print("It is not supposed to remain pointed at the vessel's nose.")
print("")
print("No needle alignment is required during this setup.")
print("A straight-ahead target check will verify bearing later.")
print("")
print("Press Enter to continue.")
read()

cfg.sensors = cfg.sensors or {}
cfg.sensors.map = map
cfg.sensors.noseAxis = noseAxis
cfg.sensors.configured = true
cfg.sensors.commissioned = false
cfg.sensors.samplePeriodMs = cfg.sensors.samplePeriodMs or 200
cfg.sensors.steeringActuatorRpm = cfg.sensors.steeringActuatorRpm or 16
cfg.sensors.rudder = cfg.sensors.rudder or {}
cfg.sensors.rudder.calibrated = false
cfg.sensors.rudder.zeroAngle = nil
cfg.sensors.rudder.leftDelta = nil
cfg.sensors.rudder.rightDelta = nil

local ok, err = config.save(cfg)
if not ok then error("Could not save sensor map: " .. tostring(err), 0) end
log.info("Volume III sensor map configured; rudder calibration required")

heading("SENSOR MAP SAVED")
term.setTextColor(colors.lime)
print("Instrumentation map saved.")
term.setTextColor(colors.white)
print("")
print("Next run:")
print("  atlasctl sensors check")
print("  atlasctl sensors calibrate")
print("")
print("Manual flight remains available. Autopilot remains disabled.")
