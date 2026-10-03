local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")
local args = { ... }
local command = (args[1] or "help"):lower()
local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local log = require("atlasos.lib.log")
local ioControl = require("atlasos.lib.io")
local sensors = require("atlasos.lib.sensors")
local assist = require("atlasos.lib.assist")
local version = require("atlasos.version")
local cfg = config.load()

local function help()
  print("AtlasOS control utility " .. version.version)
  print("")
  print("atlasctl status")
  print("atlasctl diagnostics")
  print("atlasctl logs")
  print("atlasctl setup")
  print("atlasctl pair on [six-digit-pin]")
  print("atlasctl pair off")
  print("atlasctl safe")
  print("atlasctl io setup | map | check | test")
  print("atlasctl io commission | uncommission")
  print("atlasctl sensors setup | map | check | monitor")
  print("atlasctl sensors calibrate | commission | uncommission")
  print("atlasctl assist setup | map | check")
  print("atlasctl assist commission | uncommission")
  print("atlasctl assist tune show")
  print("atlasctl assist tune set <key> <value>")
  print("atlasctl reboot")
  print("")
  print("Stop AtlasOS with Ctrl+T before server maintenance.")
end

local function requireServer()
  if cfg.role ~= "server" then error("This command runs on the onboard server", 0) end
end

local function printErrors(errors)
  for _, err in ipairs(errors or {}) do print("- " .. tostring(err)) end
end

local function ioCommand()
  requireServer()
  local sub = (args[2] or "help"):lower()
  if sub == "setup" then shell.run("/atlasos/apps/flight_setup.lua")
  elseif sub == "map" then for _, line in ipairs(ioControl.describe(cfg)) do print(line) end
  elseif sub == "check" then
    local valid, errors = ioControl.validate(cfg, true)
    if valid then term.setTextColor(colors.lime); print("Flight I/O READY")
    else term.setTextColor(colors.red); print("Flight I/O LOCKED"); term.setTextColor(colors.white); printErrors(errors) end
    term.setTextColor(colors.white)
  elseif sub == "test" then shell.run("/atlasos/apps/io_test.lua", args[3] or "", args[4] or "")
  elseif sub == "commission" then
    local valid, errors = ioControl.validate(cfg, false)
    if not valid then error(table.concat(errors, "; "), 0) end
    ioControl.applySafe(cfg)
    print("Commissioning unlocks arming, but does not arm Atlas now.")
    print("SAFE locks thrust and returns steering authority to the wheel.")
    print("Confirm every mapped output has been tested and returns SAFE.")
    write("Type COMMISSION: ")
    if read() ~= "COMMISSION" then print("Cancelled."); return end
    cfg.hardware.commissioned = true
    cfg.safe = true
    cfg.armed = false
    cfg.lastSafeReason = "I/O commissioned; propulsion locked; manual wheel selected"
    config.save(cfg)
    ioControl.applySafe(cfg)
    log.info("Manual flight I/O commissioned")
    term.setTextColor(colors.lime); print("I/O COMMISSIONED. Reboot the server."); term.setTextColor(colors.white)
  elseif sub == "uncommission" then
    cfg.hardware.commissioned = false
    cfg.safe = true
    cfg.armed = false
    cfg.lastSafeReason = "I/O manually uncommissioned"
    config.save(cfg)
    ioControl.applySafe(cfg)
    print("I/O uncommissioned; propulsion locked and manual wheel selected.")
  else
    print("atlasctl io setup | map | check | test | commission | uncommission")
  end
end

local function sensorCommand()
  requireServer()
  local sub = (args[2] or "help"):lower()
  if sub == "setup" then
    shell.run("/atlasos/apps/sensor_setup.lua")
  elseif sub == "map" then
    for _, line in ipairs(sensors.describe(cfg)) do print(line) end
  elseif sub == "check" then
    local valid, validationErrors = sensors.validate(cfg, false, false)
    local data = sensors.read(cfg)
    if valid and data.healthy then
      term.setTextColor(colors.lime); print("SENSOR SUITE HEALTHY")
    else
      term.setTextColor(colors.red); print("SENSOR SUITE DEGRADED")
      term.setTextColor(colors.white); printErrors(validationErrors); printErrors(data.errors)
    end
    term.setTextColor(colors.white)
    print(string.format("Altitude: %.2f m", data.altitude or 0))
    print(string.format("Heading: %.2f deg", data.heading or 0))
    print(string.format("Pitch/Roll: %+.2f / %+.2f deg", data.pitch or 0, data.roll or 0))
    print(string.format("Velocity F/R/U: %+.2f / %+.2f / %+.2f m/s",
      data.forwardSpeed or 0, data.rightSpeed or 0, data.verticalBodySpeed or 0))
    print("Rudder calibrated: " .. tostring(data.rudderAngle ~= nil))
    if data.steeringTargetRpm then
      print(string.format("Steering controller target: %.1f RPM", data.steeringTargetRpm))
      print("Steering source powered: " .. tostring(data.steeringHasSource))
      print("Steering network overstressed: " .. tostring(data.steeringOverstressed))
    end
  elseif sub == "monitor" then
    shell.run("/atlasos/apps/sensor_monitor.lua")
  elseif sub == "calibrate" then
    shell.run("/atlasos/apps/sensor_calibrate.lua")
  elseif sub == "commission" then
    local valid, validationErrors = sensors.validate(cfg, false, true)
    if not valid then error(table.concat(validationErrors, "; "), 0) end
    local data = sensors.read(cfg)
    if not data.healthy then error(table.concat(data.errors or {}, "; "), 0) end
    local expected = tonumber((cfg.sensors or {}).steeringActuatorRpm) or 16
    if data.steeringTargetRpm and math.abs(math.abs(data.steeringTargetRpm) - math.abs(expected)) > 0.1 then
      error(string.format("Steering speed controller is %.1f RPM; expected tested baseline magnitude %.1f RPM",
        data.steeringTargetRpm, expected), 0)
    end
    print("This commissions the Volume III Day 1 instrumentation.")
    print("Closed-loop control still requires Day 2 commissioning.")
    write("Type INSTRUMENTS: ")
    if read() ~= "INSTRUMENTS" then print("Cancelled."); return end
    cfg.sensors.commissioned = true
    local ok, err = config.save(cfg)
    if not ok then error("Could not save sensor commissioning: " .. tostring(err), 0) end
    log.info("Volume III Day 1 instrumentation commissioned")
    term.setTextColor(colors.lime); print("INSTRUMENTATION COMMISSIONED"); term.setTextColor(colors.white)
    print("Reboot both computers after all maintenance is complete.")
  elseif sub == "uncommission" then
    cfg.sensors.commissioned = false
    cfg.autoflight = cfg.autoflight or {}
    cfg.autoflight.commissioned = false
    config.save(cfg)
    print("Instrumentation and flight assist uncommissioned. Manual flight is unaffected.")
  else
    print("atlasctl sensors setup | map | check | monitor")
    print("atlasctl sensors calibrate | commission | uncommission")
  end
end

local tuneKeys = {
  headingKp = { path = { "heading", "kp" }, min = 0, max = 5 },
  headingKd = { path = { "heading", "kd" }, min = 0, max = 10 },
  headingMax = { path = { "heading", "maxRudderDeg" }, min = 2, max = 80 },
  navigationKp = { path = { "navigation", "kp" }, min = 0, max = 5 },
  navigationKd = { path = { "navigation", "kd" }, min = 0, max = 10 },
  navigationMax = { path = { "navigation", "maxRudderDeg" }, min = 2, max = 80 },
  arrivalRadius = { path = { "navigation", "arrivalRadius" }, min = 2, max = 100 },
  altitudeKp = { path = { "altitude", "kp" }, min = 0, max = 3 },
  altitudeKi = { path = { "altitude", "ki" }, min = 0, max = 1 },
  altitudeKd = { path = { "altitude", "kd" }, min = 0, max = 10 },
  altitudeMax = { path = { "altitude", "maxCorrection" }, min = 1, max = 8 },
  rudderTolerance = { path = { "rudder", "toleranceDeg" }, min = 0.2, max = 5 },
  rudderMax = { path = { "rudder", "maxAssistDeg" }, min = 2, max = 80 },
  rudderCrawlRpm = { path = { "rudder", "crawlRpm" }, min = 0.5, max = 16 },
  rudderSlowRpm = { path = { "rudder", "slowRpm" }, min = 1, max = 32 },
  rudderFastRpm = { path = { "rudder", "fastRpm" }, min = 1, max = 64 },
  wheelThreshold = { path = { "wheelOverrideThreshold" }, min = 0.02, max = 0.5 },
}

local function setNested(root, path, value)
  local cursor = root
  for index = 1, #path - 1 do
    cursor[path[index]] = cursor[path[index]] or {}
    cursor = cursor[path[index]]
  end
  cursor[path[#path]] = value
end

local function assistCheck()
  local valid, errors = assist.validate(cfg, false)
  local data = sensors.read(cfg)
  local runtimeErrors = {}
  if not data.valid.rudder or not data.rudderAssembled then runtimeErrors[#runtimeErrors + 1] = "rudder bearing is unavailable or disassembled" end
  if not data.valid.wheel then runtimeErrors[#runtimeErrors + 1] = "steering wheel feedback is unavailable" end
  if not data.valid.steeringController then runtimeErrors[#runtimeErrors + 1] = "steering speed controller feedback is unavailable" end
  if data.valid.steeringController and not data.steeringHasSource then runtimeErrors[#runtimeErrors + 1] = "computer-steering engine/source is not powered" end
  if data.valid.steeringController and math.abs(tonumber(data.steeringLiveRpm) or 0) < 0.1 then runtimeErrors[#runtimeErrors + 1] = "computer-steering source is connected but not rotating" end
  if data.steeringOverstressed then runtimeErrors[#runtimeErrors + 1] = "computer-steering kinetic network is overstressed" end
  if valid and #runtimeErrors == 0 then
    term.setTextColor(colors.lime); print("FLIGHT ASSIST READY FOR GROUND COMMISSIONING")
  else
    term.setTextColor(colors.red); print("FLIGHT ASSIST LOCKED")
    term.setTextColor(colors.white); printErrors(errors); printErrors(runtimeErrors)
  end
  term.setTextColor(colors.white)
  print("")
  for _, line in ipairs(assist.describe(cfg)) do print(line) end
end

local function assistCommand()
  requireServer()
  local sub = (args[2] or "help"):lower()
  if sub == "setup" then
    shell.run("/atlasos/apps/assist_setup.lua")
  elseif sub == "map" or sub == "status" then
    for _, line in ipairs(assist.describe(cfg)) do print(line) end
  elseif sub == "check" then
    assistCheck()
  elseif sub == "commission" then
    shell.run("/atlasos/apps/assist_commission.lua")
  elseif sub == "uncommission" then
    ioControl.applyBestEffortSafe(cfg)
    cfg.autoflight = cfg.autoflight or {}
    cfg.autoflight.commissioned = false
    cfg.safe = true; cfg.armed = false
    cfg.lastSafeReason = "flight assist manually uncommissioned"
    config.save(cfg)
    print("Flight assist uncommissioned. Propulsion locked; physical wheel selected.")
  elseif sub == "tune" then
    local tuneSub = (args[3] or "show"):lower()
    local acfg = assist.ensureConfig(cfg)
    if tuneSub == "show" then
      print("Tunable keys:")
      local names = {}
      for name in pairs(tuneKeys) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do print("  " .. name) end
      print("")
      for _, line in ipairs(assist.describe(cfg)) do print(line) end
    elseif tuneSub == "set" then
      if cfg.safe ~= true then error("Enter SAFE before changing flight-assist tuning", 0) end
      local key = args[4]
      local spec = key and tuneKeys[key] or nil
      local value = tonumber(args[5])
      if not spec then error("Unknown tune key. Run: atlasctl assist tune show", 0) end
      if not value or value < spec.min or value > spec.max then
        error(string.format("%s must be from %s to %s", key, spec.min, spec.max), 0)
      end
      local before = util.deepCopy(acfg)
      setNested(acfg, spec.path, value)
      local okay, tuneErrors = assist.validate(cfg, false)
      if not okay then
        cfg.autoflight = before
        error(table.concat(tuneErrors, "; "), 0)
      end
      local saved, saveError = config.save(cfg)
      if not saved then error("Could not save tuning: " .. tostring(saveError), 0) end
      log.info("Flight-assist tune set: " .. tostring(key) .. " = " .. tostring(value))
      print(key .. " = " .. tostring(value))
      print("Saved. Restart AtlasOS before the next flight test.")
    else
      print("atlasctl assist tune show")
      print("atlasctl assist tune set <key> <value>")
    end
  else
    print("atlasctl assist setup | map | check | commission | uncommission")
    print("atlasctl assist tune show | tune set <key> <value>")
  end
end

if command == "help" then help()
elseif command == "status" then
  print("AtlasOS: " .. version.version .. " / Volume " .. version.volume .. " Day " .. tostring(version.day or 1))
  print("Role: " .. tostring(cfg.role))
  print("Name: " .. tostring(cfg.name))
  print("Computer ID: " .. os.getComputerID())
  print("Safe: " .. tostring(cfg.safe))
  print("Paired pocket: " .. tostring(cfg.pairedPocketId))
  print("Server ID: " .. tostring(cfg.serverId))
  if cfg.role == "server" then
    print("I/O configured: " .. tostring(cfg.hardware.configured))
    print("I/O commissioned: " .. tostring(cfg.hardware.commissioned))
    print("Propulsion lock: " .. (cfg.safe and "LOCKED" or "OPEN"))
    print("Steering: " .. (cfg.safe and "MANUAL" or "COMPUTER"))
    print("Sensors configured: " .. tostring((cfg.sensors or {}).configured == true))
    print("Sensors commissioned: " .. tostring((cfg.sensors or {}).commissioned == true))
    local acfg = assist.ensureConfig(cfg)
    print("Assist configured: " .. tostring(acfg.configured == true))
    print("Assist commissioned: " .. tostring(acfg.commissioned == true))
  end
  print("Free space: " .. tostring(fs.getFreeSpace("/")))
elseif command == "diagnostics" or command == "diag" then shell.run("/atlasos/apps/diagnostics.lua")
elseif command == "logs" then for _, line in ipairs(log.tail(25)) do print(line) end
elseif command == "setup" then shell.run("/atlasos/apps/setup.lua", cfg.role or "")
elseif command == "io" then ioCommand()
elseif command == "sensors" or command == "sensor" then sensorCommand()
elseif command == "assist" or command == "autoflight" then assistCommand()
elseif command == "pair" then
  requireServer()
  local mode = (args[2] or ""):lower()
  if mode == "off" then
    cfg.pairingOpen = false; cfg.pairingPinHash = nil; config.save(cfg); print("Pairing mode closed. Reboot server.")
  elseif mode == "on" then
    local pin = args[3] or util.randomDigits(6)
    if not tostring(pin):match("^%d%d%d%d%d%d$") then error("PIN must contain exactly six digits", 0) end
    cfg.pairingOpen = true; cfg.pairingPinHash = util.hash(pin); cfg.pairedPocketId = nil; cfg.token = nil
    config.save(cfg); print("Pairing mode enabled. PIN: " .. pin); print("Reboot server, then pair pocket.")
  else print("Usage: atlasctl pair on [six-digit-pin] | off") end
elseif command == "safe" then
  requireServer()
  local ok, errors = ioControl.applySafe(cfg)
  cfg.safe = true; cfg.armed = false; cfg.lastSafeReason = "asserted from atlasctl"; config.save(cfg)
  if ok then print("Physical outputs commanded SAFE.") else printError(table.concat(errors or {}, "; ")) end
elseif command == "reboot" then os.reboot()
else help() end
