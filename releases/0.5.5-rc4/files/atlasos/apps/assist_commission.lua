local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")

local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local ioControl = require("atlasos.lib.io")
local sensors = require("atlasos.lib.sensors")
local assist = require("atlasos.lib.assist")
local log = require("atlasos.lib.log")
local version = require("atlasos.version")

local cfg = config.load()
if cfg.role ~= "server" then error("Flight-assist commissioning runs on the onboard server", 0) end

local acfg = assist.ensureConfig(cfg)
local map = (cfg.sensors or {}).map or {}
local speedController = map.steeringSpeedController
local baselineRpm = math.abs(tonumber((cfg.sensors or {}).steeringActuatorRpm) or 16)
local currentSetRpm = nil

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

local function setSpeed(rpm)
  rpm = math.abs(tonumber(rpm) or baselineRpm)
  if currentSetRpm and math.abs(currentSetRpm - rpm) <= 0.05 then return true end
  local ok, err = pcall(peripheral.call, speedController, "setTargetSpeed", rpm)
  if not ok then return false, tostring(err) end
  currentSetRpm = rpm
  return true
end

local function setRawRudder(command)
  local outputs = cfg.hardware.outputs
  local ok1, err1 = ioControl.setDigital(outputs.rudderLeft, false)
  local ok2, err2 = ioControl.setDigital(outputs.rudderRight, false)
  if not ok1 then return false, "rudder left stop: " .. tostring(err1) end
  if not ok2 then return false, "rudder right stop: " .. tostring(err2) end
  command = tonumber(command) or 0
  if command == -1 then return ioControl.setDigital(outputs.rudderLeft, true) end
  if command == 1 then return ioControl.setDigital(outputs.rudderRight, true) end
  return true
end

local function cleanup()
  pcall(setRawRudder, 0)
  if speedController and peripheral.isPresent(speedController) then pcall(setSpeed, baselineRpm) end
  pcall(ioControl.setComputerSteering, cfg, false)
  pcall(ioControl.setPropulsionPermit, cfg, false)
  pcall(ioControl.applyBestEffortSafe, cfg)
end

local function readTelemetry()
  local data = sensors.read(cfg)
  if not data.valid.rudder then error("Rudder bearing feedback is unavailable", 0) end
  if not data.valid.steeringController then error("Steering speed controller feedback is unavailable", 0) end
  return data
end

local function semantic(data)
  local value, err = assist.bearingToSemantic(cfg, data.rudderBearingAngle)
  if value == nil then error(err, 0) end
  return value
end

local function waitManualCentre(timeoutSeconds)
  local deadline = util.nowMillis() + timeoutSeconds * 1000
  local stable = 0
  while util.nowMillis() < deadline do
    local data = readTelemetry()
    local position = semantic(data)
    if not data.wheelHeld and math.abs(data.wheelNormalized or 0) <= 0.08 and math.abs(position) <= 2 then
      stable = stable + 1
      if stable >= 10 then return data end
    else
      stable = 0
    end
    sleep(0.05)
  end
  return nil
end

local function captureWheelLeftSign(timeoutSeconds)
  local deadline = util.nowMillis() + timeoutSeconds * 1000
  local stable = 0
  local capturedSign = nil
  while util.nowMillis() < deadline do
    local data = readTelemetry()
    local normalized = tonumber(data.wheelNormalized) or 0
    local position = semantic(data)
    if data.wheelHeld and math.abs(normalized) >= 0.15 and position <= -2 then
      local sign = normalized < 0 and -1 or 1
      if capturedSign == sign then stable = stable + 1 else capturedSign, stable = sign, 1 end
      if stable >= 8 then return sign end
    else
      stable = 0
    end
    sleep(0.05)
  end
  return nil
end

local function driveTo(targetSemantic, timeoutSeconds)
  local deadline = util.nowMillis() + timeoutSeconds * 1000
  local lastPosition = nil
  local lastMovementAt = util.nowMillis()
  local activeCommand = 0
  local activeRpm = nil

  while util.nowMillis() < deadline do
    local data = readTelemetry()
    if not data.rudderAssembled then error("Rudder bearing disassembled during test", 0) end
    if not data.steeringHasSource then error("Computer-steering engine/source is not powered", 0) end
    if math.abs(tonumber(data.steeringLiveRpm) or 0) < 0.1 then error("Computer-steering source is connected but not rotating", 0) end
    if data.steeringOverstressed then error("Computer-steering kinetic network is overstressed", 0) end

    local result, err = assist.computeRudderActuation(cfg, data, targetSemantic)
    if not result then error(err, 0) end
    local now = util.nowMillis()

    if lastPosition == nil or math.abs(result.currentSemantic - lastPosition) >= acfg.rudder.movementThresholdDeg then
      lastPosition = result.currentSemantic
      lastMovementAt = now
    end

    if result.command ~= activeCommand or (result.command ~= 0 and result.rpm ~= activeRpm) then
      local stopped, stopErr = setRawRudder(0)
      if not stopped then error(stopErr, 0) end
      activeCommand = 0
      if result.command ~= 0 then
        local speedOk, speedErr = setSpeed(result.rpm)
        if not speedOk then error("Could not set steering speed: " .. tostring(speedErr), 0) end
        local commandOk, commandErr = setRawRudder(result.command)
        if not commandOk then error("Could not command rudder: " .. tostring(commandErr), 0) end
        activeCommand = result.command
        activeRpm = result.rpm
      end
    end

    if result.reached then
      setRawRudder(0)
      setSpeed(baselineRpm)
      return result.currentSemantic
    end

    if result.command ~= 0 and now - lastMovementAt > acfg.rudder.stallTimeoutMs then
      error("Rudder actuator stalled or the steering engine lost power", 0)
    end
    sleep(0.05)
  end
  setRawRudder(0)
  error(string.format("Timed out moving rudder to %+.1f degrees", targetSemantic), 0)
end

local function main()
  local ioValid, ioErrors = ioControl.validate(cfg, true)
  if not ioValid then error(table.concat(ioErrors, "; "), 0) end
  local sensorValid, sensorErrors = sensors.validate(cfg, true, true)
  if not sensorValid then error(table.concat(sensorErrors, "; "), 0) end
  local assistValid, assistErrors = assist.validate(cfg, false)
  if not assistValid then error(table.concat(assistErrors, "; "), 0) end
  if not speedController or not peripheral.isPresent(speedController) then
    error("Steering Rotation Speed Controller is required for Day 2", 0)
  end

  heading("GROUND COMMISSIONING")
  print("This test learns wheel and actuator direction, then")
  print("commands -10, 0, +10 and 0 degrees closed-loop.")
  print("")
  term.setTextColor(colors.yellow)
  print("SECURE ATLAS. Keep propellers and lift disabled.")
  print("Power ONLY the engine/source that drives computer steering.")
  term.setTextColor(colors.white)
  print("Propulsion permit remains mechanically locked throughout.")
  print("The rudder bearing itself must be assembled.")
  print("")
  write("Type GROUND TEST to continue: ")
  if read() ~= "GROUND TEST" then print("Cancelled."); return end

  local safeOk, safeErrors = ioControl.applySafe(cfg)
  if not safeOk then error("Could not assert SAFE: " .. table.concat(safeErrors or {}, "; "), 0) end
  ioControl.setPropulsionPermit(cfg, false)

  local initial = readTelemetry()
  if not initial.rudderAssembled then error("Assemble the rudder bearing before commissioning", 0) end
  if not initial.steeringHasSource then error("The computer-steering engine/source is not powered", 0) end
  if math.abs(tonumber(initial.steeringLiveRpm) or 0) < 0.1 then error("The computer-steering source is connected but not rotating", 0) end
  if initial.steeringOverstressed then error("The computer-steering kinetic network is overstressed", 0) end

  heading("PILOT WHEEL DIRECTION")
  print("Manually place the wheel and rudder near true 0 degrees.")
  print("Release the wheel there, then press Enter.")
  read()
  if not waitManualCentre(45) then
    error("Could not detect a centred free wheel and rudder within 45 seconds", 0)
  end

  print("")
  print("Press Enter, close this screen, turn the physical")
  print("wheel LEFT by at least 15%, and HOLD it.")
  print("Reopen this computer after a couple of seconds.")
  read()
  local wheelLeftSign = captureWheelLeftSign(45)
  if not wheelLeftSign then error("Could not capture a stable physical LEFT wheel input", 0) end
  acfg.rudder.wheelLeftSign = wheelLeftSign
  print("Physical wheel LEFT sign captured: " .. tostring(wheelLeftSign))
  print("")
  print("Manually return the wheel and rudder near true 0, release it,")
  print("then wait.")
  if not waitManualCentre(45) then error("Wheel/rudder did not return near true centre", 0) end

  heading("AUTOMATIC DIRECTION TEST")
  print("Switching to the computer steering branch with propulsion locked.")
  print("AtlasOS will pulse one rudder output at 2 RPM.")
  print("")
  local steerOk, steerErr = ioControl.setComputerSteering(cfg, true)
  if not steerOk then error("Could not select computer steering: " .. tostring(steerErr), 0) end
  local speedOk, speedErr = setSpeed(2)
  if not speedOk then error("Could not set test speed: " .. tostring(speedErr), 0) end
  sleep(0.25)

  local before = semantic(readTelemetry())
  local commandOk, commandErr = setRawRudder(-1)
  if not commandOk then error(commandErr, 0) end
  sleep(0.55)
  setRawRudder(0)
  sleep(0.2)
  local after = semantic(readTelemetry())
  local movement = after - before
  if math.abs(movement) < 1.5 then
    error("Rudder did not move during the automatic pulse; check engine power and links", 0)
  end
  acfg.rudder.leftOutputCommand = movement < 0 and -1 or 1
  print(string.format("Raw -1 moved the rudder %+.2f degrees.", movement))
  print("Learned LEFT output command: " .. tostring(acfg.rudder.leftOutputCommand))

  heading("CLOSED-LOOP POSITION TEST")
  print("The rudder will now visit four safe targets:")
  print("  -10 deg LEFT, true 0, +10 deg RIGHT, true 0")
  print("")
  print("Watch the rudder. Ctrl+T aborts and returns SAFE.")
  sleep(1)

  driveTo(0, 12)
  driveTo(-10, 12)
  sleep(0.6)
  driveTo(0, 12)
  driveTo(10, 12)
  sleep(0.6)
  local finalPosition = driveTo(0, 12)

  setRawRudder(0)
  setSpeed(baselineRpm)
  ioControl.setComputerSteering(cfg, false)
  ioControl.setPropulsionPermit(cfg, false)

  heading("CONFIRM OBSERVED MOTION")
  print(string.format("Final rudder position: %+.2f degrees", finalPosition))
  print("")
  print("Confirm the sequence visibly moved LEFT, centred,")
  print("moved RIGHT, then centred again.")
  write("Type COMMISSION: ")
  if read() ~= "COMMISSION" then
    acfg.commissioned = false
    config.save(cfg)
    print("Not commissioned. Hardware remains SAFE.")
    return
  end

  acfg.configured = true
  acfg.commissioned = true
  cfg.sensors.samplePeriodMs = acfg.samplePeriodMs
  cfg.safe = true
  cfg.armed = false
  cfg.lastSafeReason = "Volume III Day 2 ground commissioning complete"
  local saved, saveError = config.save(cfg)
  if not saved then error("Could not save commissioning: " .. tostring(saveError), 0) end
  log.info(string.format("Flight assist commissioned: wheelLeftSign %d, leftOutput %d",
    acfg.rudder.wheelLeftSign, acfg.rudder.leftOutputCommand))

  heading("FLIGHT ASSIST COMMISSIONED")
  term.setTextColor(colors.lime)
  print("Closed-loop rudder control passed the ground test.")
  term.setTextColor(colors.white)
  print("")
  print("Heading, Navigation and altitude gains are conservative.")
  print("Perform the first flight test at low thrust and clear altitude.")
  print("")
  print("Reboot both computers.")
end

local ok, err = xpcall(main, function(value) return tostring(value) end)
cleanup()
if not ok then
  term.setTextColor(colors.red)
  print("")
  print("COMMISSIONING ABORTED")
  term.setTextColor(colors.white)
  print(err)
  print("Propulsion locked; computer steering disconnected.")
  log.error("Flight-assist commissioning failed: " .. tostring(err))
end
