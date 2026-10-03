local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")
local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local net = require("atlasos.lib.net")
local ioControl = require("atlasos.lib.io")
local sensors = require("atlasos.lib.sensors")
local assist = require("atlasos.lib.assist")
local navigation = require("atlasos.lib.navigation")
local radio = require("atlasos.lib.radio")
local telemetryDisplay = require("atlasos.lib.telemetry_display")
local settings = require("atlasos.lib.settings")
local log = require("atlasos.lib.log")
local version = require("atlasos.version")

local cfg = config.load()
settings.ensure(cfg)
if cfg.role ~= "server" then error("This computer is not configured as the AtlasOS server", 0) end
local modemName, modemError = net.openWireless()
if not modemName then error(modemError, 0) end
local acfg = assist.ensureConfig(cfg)
local ncfg = navigation.ensureConfig(cfg)
local rcfg = radio.ensureConfig(cfg)
local radioRuntime = radio.newRuntime(cfg)
local telemetryDisplayRuntime = telemetryDisplay.new(cfg.telemetryDisplay)

-- Full Auto defaults now live in atlasos.lib.settings so the Pocket editor,
-- config loader, and flight server all share one authoritative configuration.
local facfg = cfg.fullAutopilot
facfg.cruiseSpeed = util.clamp(tonumber(facfg.cruiseSpeed) or 8.0, 1.0, 20.0)
facfg.approachDistance = util.clamp(tonumber(facfg.approachDistance) or 80.0, 20.0, 500.0)
facfg.minimumApproachSpeed = util.clamp(tonumber(facfg.minimumApproachSpeed) or 1.5, 0.5, facfg.cruiseSpeed)
facfg.arrivalSpeed = util.clamp(tonumber(facfg.arrivalSpeed) or 1.2, 0.2, facfg.minimumApproachSpeed)
facfg.speedDeadband = util.clamp(tonumber(facfg.speedDeadband) or 0.45, 0.1, 2.0)
facfg.thrustAdjustIntervalMs = util.clamp(util.round(tonumber(facfg.thrustAdjustIntervalMs) or 300), 100, 1500)
facfg.maxThrust = util.clamp(util.round(tonumber(facfg.maxThrust) or 12), 1, 15)
facfg.headingSlowDeg = util.clamp(tonumber(facfg.headingSlowDeg) or 20, 5, 45)
facfg.headingGateDeg = util.clamp(tonumber(facfg.headingGateDeg) or 55, facfg.headingSlowDeg + 5, 100)
facfg.turnSpeed = util.clamp(tonumber(facfg.turnSpeed) or 2.5, 0.5, facfg.cruiseSpeed)
facfg.brakeLeadSeconds = util.clamp(tonumber(facfg.brakeLeadSeconds) or 3.0, 0.5, 8.0)
facfg.brakeMinLeadDistance = util.clamp(tonumber(facfg.brakeMinLeadDistance) or 4.0, 1.0, 30.0)
facfg.brakeStopSpeed = util.clamp(tonumber(facfg.brakeStopSpeed) or 0.20, 0.05, facfg.arrivalSpeed)
facfg.brakeReboundMargin = util.clamp(tonumber(facfg.brakeReboundMargin) or 0.20, 0.05, 1.0)
facfg.brakeMaxThrust = util.clamp(util.round(tonumber(facfg.brakeMaxThrust) or 6), 1, 15)
facfg.overshootCaptureExtra = util.clamp(tonumber(facfg.overshootCaptureExtra) or 6.0, 1.0, 30.0)
facfg.overshootBehindDeg = util.clamp(tonumber(facfg.overshootBehindDeg) or 95.0, 70.0, 150.0)
facfg.overshootTrendMargin = util.clamp(tonumber(facfg.overshootTrendMargin) or 2.0, 0.5, 10.0)
facfg.overshootEscapeMargin = util.clamp(tonumber(facfg.overshootEscapeMargin) or 8.0, facfg.overshootTrendMargin + 1.0, 30.0)
facfg.overshootConfirmMs = util.clamp(util.round(tonumber(facfg.overshootConfirmMs) or 350), 100, 1500)

local state = {
  bootAt = util.nowMillis(),
  lastContactAt = 0,
  lastCommandAt = 0,
  lastDrawAt = 0,
  lastHardwareCheckAt = 0,
  lastLiftStepAt = 0,
  lastThrustStepAt = 0,
  commandCount = 0,
  safe = true,
  armed = false,
  lastReason = cfg.lastSafeReason or "startup",
  lastSender = nil,
  lastSequence = 0,
  controllerSession = nil,
  serverBootId = util.token(12),
  statusSerial = 0,
  lastOutputReassertAt = 0,
  safeCenter = { active = false, deadlineAt = 0, reason = nil },
  linkHold = { active = false, startedAt = 0, reason = nil },
  desired = ioControl.safeControl(cfg),
  actual = ioControl.safeControl(cfg),
  armNonce = nil,
  armExpiresAt = 0,
  hardwareValid = false,
  hardwareErrors = {},
  lastSensorReadAt = 0,
  telemetry = nil,
  sensorsValid = false,
  sensorErrors = {},
  assistReady = false,
  assistErrors = {},
  flight = {
    steeringMode = "pilot",
    rudderTargetDeg = 0,
    rudderCurrentDeg = 0,
    rudderErrorDeg = 0,
    rudderCommand = 0,
    rudderRpm = 0,
    headingTarget = nil,
    headingError = nil,
    altitudeMode = "manual",
    altitudeState = nil,
    altitudeError = nil,
    altitudeCorrection = nil,
    lastAltitudeUpdateAt = 0,
    navLastTargetAt = 0,
    fault = nil,
    lastTransition = "startup",
    lastTransitionAt = util.nowMillis(),
    lastRudderMovementAt = util.nowMillis(),
    lastRudderPosition = nil,
    lastRudderCommand = 0,
    speedTargetRpm = nil,
    wheelOverrideCandidateAt = nil,
    wheelReleaseCandidateAt = nil,
    wheelIgnoreUntil = 0,
    missionMode = "assisted",
    missionReason = "startup",
    missionPhase = "idle",
    missionCruiseThrust = 0, -- retained for status compatibility; FULL AUTO owns thrust now
    missionCruiseSpeed = facfg.cruiseSpeed,
    missionTargetSpeed = 0,
    missionCurrentSpeed = 0,
    lastAutoThrustAt = 0,
    missionEngagedAt = 0,
    arrivalAt = 0,
    autoBrakeStage = "idle",
    autoBrakeStartedAt = 0,
    autoBrakeMinSpeed = nil,
    autoBrakeTriggerDistance = nil,
    autoBrakeFinishMode = "arrival",
    autoClosestDistance = nil,
    autoCaptureArmed = false,
    autoOvershootSince = 0,
  },
}

local function persistState()
  cfg.safe = state.safe
  cfg.armed = false
  cfg.lastSafeReason = state.lastReason
  cfg.control = util.deepCopy(state.actual)
  config.save(cfg)
end

local function transition(text)
  state.flight.lastTransition = tostring(text or "")
  state.flight.lastTransitionAt = util.nowMillis()
  log.info("Flight assist: " .. state.flight.lastTransition)
end

local function setSteeringSpeed(rpm)
  local name = (((cfg.sensors or {}).map or {}).steeringSpeedController)
  if not name or not peripheral.isPresent(name) then return false, "steering speed controller missing" end
  rpm = math.abs(tonumber(rpm) or math.abs(tonumber((cfg.sensors or {}).steeringActuatorRpm) or 16))
  local observed = state.telemetry and tonumber(state.telemetry.steeringTargetRpm) or nil
  if state.flight.speedTargetRpm and math.abs(state.flight.speedTargetRpm - rpm) <= 0.05
      and observed and math.abs(observed - rpm) <= 0.05 then return true end
  local ok, err = pcall(peripheral.call, name, "setTargetSpeed", rpm)
  if not ok then return false, tostring(err) end
  state.flight.speedTargetRpm = rpm
  return true
end

local function writeActual()
  local ok, errors = ioControl.applyControl(cfg, state.actual)
  if not ok then return false, table.concat(errors or {}, "; ") end
  return true
end

local function resetAssistRuntime(reason)
  state.flight.steeringMode = "pilot"
  state.flight.rudderTargetDeg = 0
  state.flight.rudderCurrentDeg = 0
  state.flight.rudderErrorDeg = 0
  state.flight.rudderCommand = 0
  state.flight.rudderRpm = 0
  state.flight.headingTarget = nil
  state.flight.headingError = nil
  state.flight.altitudeMode = "manual"
  state.flight.altitudeState = nil
  state.flight.altitudeError = nil
  state.flight.altitudeCorrection = nil
  state.flight.navLastTargetAt = 0
  state.flight.fault = nil
  state.flight.lastRudderMovementAt = util.nowMillis()
  state.flight.lastRudderPosition = nil
  state.flight.lastRudderCommand = 0
  state.flight.wheelOverrideCandidateAt = nil
  state.flight.wheelReleaseCandidateAt = nil
  state.flight.wheelIgnoreUntil = 0
  state.flight.missionMode = "assisted"
  state.flight.missionReason = reason or "reset"
  state.flight.missionPhase = "idle"
  state.flight.missionCruiseThrust = 0
  state.flight.missionCruiseSpeed = facfg.cruiseSpeed
  state.flight.missionTargetSpeed = 0
  state.flight.missionCurrentSpeed = 0
  state.flight.lastAutoThrustAt = 0
  state.flight.missionEngagedAt = 0
  state.flight.arrivalAt = 0
  state.flight.autoBrakeStage = "idle"
  state.flight.autoBrakeStartedAt = 0
  state.flight.autoBrakeMinSpeed = nil
  state.flight.autoBrakeTriggerDistance = nil
  state.flight.autoBrakeFinishMode = "arrival"
  state.flight.autoClosestDistance = nil
  state.flight.autoCaptureArmed = false
  state.flight.autoOvershootSince = 0
  state.desired.rudder = 0
  state.actual.rudder = 0
  if reason then state.flight.lastTransition = reason end
end

-- AtlasOS v0.5.4 retains the Link Integrity / Flight Continuity safety policy.
-- Sable/Simulated can transiently miss peripheral reads or stale projected outputs.
-- Debounce brief feedback loss, keep a generous hard heartbeat timeout, and reassert
-- physical outputs periodically instead of assuming one successful write remained applied.
local transientSafeFaults = {}
local TRANSIENT_FEEDBACK_GRACE_MS = 350
local HARDWARE_VALIDITY_GRACE_MS = 750
local MIN_HEARTBEAT_TIMEOUT_MS = 10000
local OUTPUT_REASSERT_MS = 750
local SAFE_CENTER_TIMEOUT_MS = 8000
local SAFE_CENTER_TOLERANCE_DEG = 0.5

local function clearTransientSafeFaults()
  for key in pairs(transientSafeFaults) do transientSafeFaults[key] = nil end
end

local function reasonAllowsSafeCentering(reason)
  local lower = tostring(reason or ""):lower()
  -- Never drive a subsystem which is itself the reason SAFE was asserted.
  local blocked = {
    "rudder", "steering", "flight i/o", "i/o write", "hardware",
    "peripheral", "overstress", "source lost", "server crashed", "server terminated",
  }
  for _, needle in ipairs(blocked) do
    if lower:find(needle, 1, true) then return false end
  end
  return true
end

local function assertSafe(reason)
  clearTransientSafeFaults()
  local ok, errors = ioControl.applySafe(cfg)
  state.safe = true
  state.armed = false
  state.lastReason = reason or "unspecified"
  state.desired = ioControl.safeControl(cfg)
  state.actual = ioControl.safeControl(cfg)
  state.armNonce = nil
  state.armExpiresAt = 0
  state.safeCenter.active = false
  state.safeCenter.deadlineAt = 0
  state.safeCenter.reason = nil
  state.linkHold.active = false
  state.linkHold.startedAt = 0
  state.linkHold.reason = nil
  resetAssistRuntime("SAFE: " .. state.lastReason)
  pcall(setSteeringSpeed, math.abs(tonumber((cfg.sensors or {}).steeringActuatorRpm) or 16))

  -- For non-steering faults (operator SAFE, heartbeat timeout, etc.), briefly retain
  -- computer steering authority with propulsion locked so the rudder can return to
  -- true zero. A steering/rudder/hardware fault skips this and remains fully passive.
  local data = state.telemetry
  if reasonAllowsSafeCentering(state.lastReason) and state.assistReady and data and
      data.valid and data.valid.rudder and data.rudderAssembled and data.valid.steeringController and
      data.steeringHasSource and not data.steeringOverstressed then
    local current = assist.bearingToSemantic(cfg, data.rudderBearingAngle)
    if current ~= nil and math.abs(current) > SAFE_CENTER_TOLERANCE_DEG then
      local steeringOk = ioControl.setComputerSteering(cfg, true)
      if steeringOk then
        state.safeCenter.active = true
        state.safeCenter.deadlineAt = util.nowMillis() + SAFE_CENTER_TIMEOUT_MS
        state.safeCenter.reason = state.lastReason
        state.flight.rudderTargetDeg = 0
        state.flight.rudderCurrentDeg = current
        state.flight.rudderErrorDeg = -current
        state.flight.lastTransition = "SAFE rudder centering"
        state.flight.lastTransitionAt = util.nowMillis()
      end
    end
  end

  radio.duck(radioRuntime, 4000)
  persistState()
  if ok then log.warn("SAFE state asserted: " .. state.lastReason)
  else log.error("SAFE requested but I/O reported: " .. table.concat(errors or {}, "; ")) end
end

-- Returns active, asserted. While a transient fault is inside its grace window,
-- callers pause that control update rather than trusting the bad sample.
local function debounceSafeFault(key, active, reason, now, graceMs)
  if not active then
    transientSafeFaults[key] = nil
    return false, false
  end

  now = tonumber(now) or util.nowMillis()
  graceMs = math.max(0, tonumber(graceMs) or TRANSIENT_FEEDBACK_GRACE_MS)
  local firstSeen = transientSafeFaults[key]
  if not firstSeen then
    transientSafeFaults[key] = now
    log.warn("Transient safety fault (debouncing): " .. tostring(reason))
    return true, false
  end

  if now - firstSeen >= graceMs then
    transientSafeFaults[key] = nil
    assertSafe(reason)
    return true, true
  end
  return true, false
end

local function refreshHardware()
  state.hardwareValid, state.hardwareErrors = ioControl.validate(cfg, true)
  return state.hardwareValid
end

-- v0.5.4-r1:
-- Create: Avionics reports getDistanceToTarget() as full 3D Euclidean distance.
-- Full Auto is a horizontal navigation controller; altitude is handled separately
-- by Altitude Hold. Remove the vertical component so arrival/braking use X/Z range.
local function horizontalNavigationDistance(data)
  if type(data) ~= "table" or not data.hasTarget then return nil end
  local distance = tonumber(data.distance)
  if not distance then return nil end
  distance = math.max(0, distance)

  local vertical = math.abs(tonumber(data.verticalOffset) or 0)
  local squared = distance * distance - vertical * vertical
  if squared < 0 then squared = 0 end
  return math.sqrt(squared)
end

local function refreshSensors()
  navigation.updateSource(cfg, state.armed, false)
  local valid, validationErrors = sensors.validate(cfg, false, false)
  local telemetry = sensors.read(cfg)
  telemetry.horizontalDistance = horizontalNavigationDistance(telemetry)
  state.telemetry = telemetry
  state.sensorsValid = valid and telemetry.healthy
  state.sensorErrors = {}
  for _, value in ipairs(validationErrors or {}) do state.sensorErrors[#state.sensorErrors + 1] = value end
  for _, value in ipairs(telemetry.errors or {}) do state.sensorErrors[#state.sensorErrors + 1] = value end
  local assistValid, assistErrors = assist.validate(cfg, true)
  state.assistReady = assistValid
  state.assistErrors = assistErrors or {}
  return state.sensorsValid
end

local function currentRudderSemantic()
  if not state.telemetry then return nil end
  local value = assist.bearingToSemantic(cfg, state.telemetry.rudderBearingAngle)
  return value
end

-- Calibrated endpoints are hard mechanical limits, not normal operating targets.
-- Stay slightly inside them so bearing jitter or a tiny calibration mismatch cannot
-- leave the actuator pushing against the stop until the stall watchdog fires.
local function clampOperationalRudderTarget(value)
  local geometry = assist.rudderGeometry(cfg)
  if not geometry.ok then return tonumber(value) or 0 end
  local tolerance = tonumber(acfg.rudder.toleranceDeg) or 0.65
  local margin = math.max(1.0, tolerance + 0.35)
  local leftLimit = math.max(0, geometry.leftMagnitude - margin)
  local rightLimit = math.max(0, geometry.rightMagnitude - margin)
  return util.clamp(tonumber(value) or 0, -leftLimit, rightLimit)
end

local function statusPayload()
  local contactAge = state.lastContactAt > 0 and (util.nowMillis() - state.lastContactAt) or nil
  local flight = state.flight
  return {
    serverName = cfg.name,
    serverId = os.getComputerID(),
    version = version.version,
    volume = version.volume,
    day = version.day,
    safe = state.safe,
    armed = state.armed,
    safeReason = state.lastReason,
    paired = cfg.pairedPocketId ~= nil,
    pairedPocketId = cfg.pairedPocketId,
    uptimeMs = util.nowMillis() - state.bootAt,
    lastContactAgeMs = contactAge,
    peripheralCount = #peripheral.getNames(),
    freeSpace = fs.getFreeSpace("/"),
    hardwareConfigured = cfg.hardware.configured == true,
    hardwareCommissioned = cfg.hardware.commissioned == true,
    hardwareValid = state.hardwareValid,
    hardwareErrors = state.hardwareErrors,
    heartbeatTimeoutMs = math.max(tonumber(cfg.heartbeatTimeoutMs) or 2000, MIN_HEARTBEAT_TIMEOUT_MS),
    controllerSession = state.controllerSession,
    serverBootId = state.serverBootId,
    safeCentering = state.safeCenter.active == true,
    linkHold = state.linkHold.active == true,
    linkHoldReason = state.linkHold.reason,
    linkHoldAgeMs = state.linkHold.active and (util.nowMillis() - state.linkHold.startedAt) or 0,
    desired = util.deepCopy(state.desired),
    control = util.deepCopy(state.actual),
    propulsionLocked = (not state.armed) or state.linkHold.active,
    steeringMode = state.linkHold.active and "link_hold" or
      (state.safeCenter.active and "centering" or (state.armed and "computer" or "manual")),
    sensorsConfigured = (cfg.sensors or {}).configured == true,
    sensorsCommissioned = (cfg.sensors or {}).commissioned == true,
    sensorsValid = state.sensorsValid,
    sensorErrors = util.deepCopy(state.sensorErrors),
    telemetry = util.deepCopy(state.telemetry),
    autoflightConfigured = acfg.configured == true,
    autoflightCommissioned = acfg.commissioned == true,
    autoflightReady = state.assistReady,
    autoflightErrors = util.deepCopy(state.assistErrors),
    mission = {
      mode = flight.missionMode,
      reason = flight.missionReason,
      cruiseThrust = flight.missionCruiseThrust,
      cruiseSpeed = flight.missionCruiseSpeed,
      targetSpeed = flight.missionTargetSpeed,
      currentSpeed = flight.missionCurrentSpeed,
      phase = flight.missionPhase,
      engagedAt = flight.missionEngagedAt,
      arrivalAt = flight.arrivalAt,
      brakeStage = flight.autoBrakeStage,
      brakeTriggerDistance = flight.autoBrakeTriggerDistance,
      autopilot = flight.missionMode == "autopilot",
      arrival = flight.missionMode == "arrival",
    },
    navigation = navigation.status(cfg),
    radio = radio.status(cfg, radioRuntime),
    settings = settings.public(cfg),
    telemetryDisplay = telemetryDisplay.status(telemetryDisplayRuntime, cfg.telemetryDisplay),
    assist = {
      steeringMode = flight.steeringMode,
      rudderTargetDeg = flight.rudderTargetDeg,
      rudderCurrentDeg = flight.rudderCurrentDeg,
      rudderErrorDeg = flight.rudderErrorDeg,
      rudderCommand = flight.rudderCommand,
      rudderRpm = flight.rudderRpm,
      headingTarget = flight.headingTarget,
      headingError = flight.headingError,
      altitudeMode = flight.altitudeMode,
      altitudeTarget = flight.altitudeState and flight.altitudeState.target or nil,
      altitudeTrim = flight.altitudeState and flight.altitudeState.trim or nil,
      altitudeError = flight.altitudeError,
      altitudeCorrection = flight.altitudeCorrection,
      fault = flight.fault,
      lastTransition = flight.lastTransition,
      lastTransitionAt = flight.lastTransitionAt,
    },
  }
end

local function validControl(sender, message)
  if not net.valid(message) then return false, "invalid envelope or protocol" end
  if cfg.pairedPocketId == nil then return false, "no pocket paired" end
  if sender ~= cfg.pairedPocketId then return false, "wrong computer ID" end
  if message.token ~= cfg.token then return false, "bad token" end
  return true
end

local function sendStatus(sender, kind, extra)
  local payload = extra or {}
  state.statusSerial = state.statusSerial + 1
  payload.token = cfg.token
  payload.session = payload.session or state.controllerSession
  payload.serverBootId = state.serverBootId
  payload.statusSerial = state.statusSerial
  payload.status = statusPayload()
  net.send(sender, kind or "STATUS", payload, net.CONTROL_PROTOCOL)
end

local function handlePair(sender, message)
  if not net.valid(message) or message.kind ~= "PAIR_REQUEST" then return end
  if not cfg.pairingOpen then
    net.send(sender, "PAIR_REJECT", { reason = "Server pairing mode is closed" }, net.PAIR_PROTOCOL)
    return
  end
  if util.hash(message.pin or "") ~= cfg.pairingPinHash then
    log.warn("Rejected pairing request from computer " .. sender)
    net.send(sender, "PAIR_REJECT", { reason = "Incorrect pairing PIN" }, net.PAIR_PROTOCOL)
    return
  end
  cfg.pairedPocketId = sender
  cfg.token = util.token(40)
  cfg.pairingOpen = false
  cfg.pairingPinHash = nil
  config.save(cfg)
  log.info("Paired pocket computer ID " .. sender)
  net.send(sender, "PAIR_ACCEPT", {
    token = cfg.token, serverName = cfg.name, serverId = os.getComputerID(),
  }, net.PAIR_PROTOCOL)
  pcall(rednet.unhost, net.PAIR_PROTOCOL)
end

local function sanitiseControl(raw)
  raw = type(raw) == "table" and raw or {}
  return {
    lift = util.clamp(util.round(raw.lift), 0, 15),
    thrust = util.clamp(util.round(raw.thrust), 0, 15),
    reverse = raw.reverse == true,
    gyro = raw.gyro == true,
    rudder = util.clamp(util.round(raw.rudder), -1, 1),
  }
end

local function neutralForArm(control)
  return util.isNeutralControl(control) and control.gyro == ioControl.safeControl(cfg).gyro
end

local function armDenied(sender, reason)
  sendStatus(sender, "ARM_DENIED", { reason = reason })
end

local function assistArmCheck()
  if not state.assistReady then return false, table.concat(state.assistErrors or {}, "; ") end
  local data = state.telemetry
  if not data then return false, "telemetry unavailable" end
  if not data.valid.rudder or not data.rudderAssembled then return false, "rudder bearing feedback is unavailable or disassembled" end
  if not data.valid.wheel then return false, "physical steering wheel feedback is unavailable" end
  if not data.valid.steeringController then return false, "steering speed controller feedback is unavailable" end
  if not data.steeringHasSource then return false, "computer-steering engine/source is not powered" end
  if math.abs(tonumber(data.steeringLiveRpm) or 0) < 0.1 then return false, "computer-steering source is connected but not rotating" end
  if data.steeringOverstressed then return false, "computer-steering kinetic network is overstressed" end
  local rudder = currentRudderSemantic()
  if rudder == nil then return false, "rudder position unavailable; centre it near true 0 degrees before arming" end
  if math.abs(rudder) > 3 then
    return false, string.format("rudder is %+.1f deg; use SAFE manual steering to centre it before arming", rudder)
  end
  if math.abs(data.wheelNormalized or 0) > acfg.wheelOverrideThreshold then
    return false, "centre the physical steering wheel before arming"
  end
  return true
end

local function beginArm(sender, message)
  refreshHardware()
  refreshSensors()
  if not state.hardwareValid then armDenied(sender, table.concat(state.hardwareErrors, "; ")); return end
  if state.armed then sendStatus(sender, "ARMED"); return end
  local requested = sanitiseControl(message.control)
  if not neutralForArm(requested) or not neutralForArm(state.actual) then
    armDenied(sender, "Set lift and thrust to 0, reverse off, and rudder command neutral")
    return
  end
  if acfg.commissioned == true then
    local okay, reason = assistArmCheck()
    if not okay then armDenied(sender, reason); return end
  end
  state.armNonce = util.token(12)
  state.armExpiresAt = util.nowMillis() + 5000
  -- v0.5.3 cumulative: ARM_CHALLENGE must use the session-bound status envelope.
  sendStatus(sender, "ARM_CHALLENGE", {
    nonce = state.armNonce,
    expiresAt = state.armExpiresAt,
  })
end

local function confirmArm(sender, message)
  if not state.armNonce or util.nowMillis() > state.armExpiresAt or message.nonce ~= state.armNonce then
    armDenied(sender, "Arming confirmation expired")
    return
  end
  refreshHardware()
  refreshSensors()
  if not state.hardwareValid then armDenied(sender, table.concat(state.hardwareErrors, "; ")); return end
  if not neutralForArm(state.actual) then armDenied(sender, "Controls are not neutral"); return end
  if acfg.commissioned == true then
    local okay, reason = assistArmCheck()
    if not okay then armDenied(sender, reason); return end
  end
  local ok, errors = ioControl.arm(cfg)
  if not ok then armDenied(sender, table.concat(errors or {}, "; ")); assertSafe("arming I/O failure"); return end
  state.safe = false
  state.armed = true
  state.lastReason = "armed by pocket controller"
  state.armNonce = nil
  state.armExpiresAt = 0
  resetAssistRuntime("computer steering armed")
  state.flight.rudderTargetDeg = 0
  -- Ignore wheel telemetry briefly while the manual and automatic clutches swap.
  -- This prevents a one-tick mechanical transient from latching wheel override.
  state.flight.wheelIgnoreUntil = util.nowMillis() + 750
  cfg.safe = false
  cfg.lastSafeReason = state.lastReason
  config.save(cfg)
  pcall(setSteeringSpeed, math.abs(tonumber((cfg.sensors or {}).steeringActuatorRpm) or 16))
  log.info("Flight controls ARMED")
  sendStatus(sender, "ARMED")
end

local function setMissionMode(mode, reason)
  state.flight.missionMode = tostring(mode or "assisted")
  state.flight.missionReason = tostring(reason or state.flight.missionMode)
  if state.flight.missionMode == "autopilot" then
    state.flight.missionEngagedAt = util.nowMillis()
    state.flight.arrivalAt = 0
    state.flight.missionPhase = "ALIGN"
    state.flight.autoBrakeStage = "idle"
    state.flight.autoBrakeStartedAt = 0
    state.flight.autoBrakeMinSpeed = nil
    state.flight.autoBrakeTriggerDistance = nil
    state.flight.autoBrakeFinishMode = "arrival"
    state.flight.autoClosestDistance = nil
    state.flight.autoCaptureArmed = false
    state.flight.autoOvershootSince = 0
    elseif state.flight.missionMode == "arrival" then
    state.flight.arrivalAt = util.nowMillis()
    state.flight.missionPhase = "ARRIVED"
    state.flight.autoBrakeStage = "idle"
    state.flight.autoBrakeStartedAt = 0
    state.flight.autoBrakeMinSpeed = nil
    state.flight.autoBrakeTriggerDistance = nil
    state.flight.autoBrakeFinishMode = "arrival"
    state.flight.autoClosestDistance = nil
    state.flight.autoCaptureArmed = false
    state.flight.autoOvershootSince = 0
    else
    state.flight.missionEngagedAt = 0
    state.flight.arrivalAt = 0
    state.flight.missionPhase = "idle"
    state.flight.missionTargetSpeed = 0
    state.flight.autoBrakeStage = "idle"
    state.flight.autoBrakeStartedAt = 0
    state.flight.autoBrakeMinSpeed = nil
    state.flight.autoBrakeTriggerDistance = nil
    state.flight.autoBrakeFinishMode = "arrival"
    state.flight.autoClosestDistance = nil
    state.flight.autoCaptureArmed = false
    state.flight.autoOvershootSince = 0
    end
end

local function disengageAutopilot(reason, stopThrust)
  if state.flight.missionMode == "autopilot" or state.flight.missionMode == "arrival" then
    setMissionMode("assisted", reason or "autopilot disengaged")
    if stopThrust then state.desired.thrust = 0 end
  end
end

-- Manual thrust/lift/reverse takeover drops FULL AUTO but deliberately leaves the
-- navigation steering layer available when a live target remains. This is the
-- old "NAV assist" behaviour and gives the pilot immediate propulsion authority.
local function downgradeFullAutoToNav(reason, stopThrust)
  if state.flight.missionMode ~= "autopilot" and state.flight.missionMode ~= "arrival" then return end
  setMissionMode("assisted", reason or "FULL AUTO downgraded to NAV assist")
  if stopThrust then state.desired.thrust = 0 end
  local data = state.telemetry
  if data and data.valid and data.valid.navigation and data.valid.attitude and data.hasTarget then
    state.flight.steeringMode = "navigation"
    state.flight.navLastTargetAt = util.nowMillis()
    state.flight.headingTarget = nil
    state.desired.rudder = 0
  else
    state.flight.steeringMode = "pilot"
    state.flight.rudderTargetDeg = currentRudderSemantic() or 0
    state.flight.headingTarget = nil
    state.desired.rudder = 0
  end
  transition(reason or "FULL AUTO downgraded to NAV assist")
end

local function completeMissionArrival()
  state.flight.steeringMode = "pilot"
  state.flight.rudderTargetDeg = 0
  state.flight.headingTarget = nil
  state.flight.headingError = nil
  state.desired.rudder = 0
  state.desired.thrust = 0
  state.desired.reverse = false
  state.flight.missionTargetSpeed = 0
  state.flight.missionCurrentSpeed = tonumber(state.telemetry and state.telemetry.horizontalSpeed) or 0
  setMissionMode("arrival", "target reached; stopped, reverse off, altitude hold retained")
  transition("FULL AUTO ARRIVAL: stopped, reverse off, rudder centred")
end

-- v0.5.4-r2: if Atlas has already passed a captured waypoint, do not let
-- navigation turn around and orbit/reacquire it. Stop the ship, retain vertical
-- stabilization, then hand control back to the pilot.
local function completeOvershootHold()
  local data = state.telemetry
  local distance = data and (tonumber(data.horizontalDistance) or horizontalNavigationDistance(data)) or nil
  local arrivalRadius = tonumber(acfg.navigation.arrivalRadius) or 8

  state.flight.steeringMode = "pilot"
  state.flight.rudderTargetDeg = 0
  state.flight.headingTarget = nil
  state.flight.headingError = nil
  state.desired.rudder = 0
  state.desired.thrust = 0
  state.desired.reverse = false
  state.flight.missionTargetSpeed = 0
  state.flight.missionCurrentSpeed = tonumber(data and data.horizontalSpeed) or 0

  if distance and distance <= arrivalRadius then
    setMissionMode("arrival", "target captured after overshoot braking")
    transition(string.format("FULL AUTO ARRIVAL: overshoot recovered at %.1fm", distance))
  else
    setMissionMode("assisted", "FULL AUTO overshoot guard stopped the ship")
    transition(string.format("FULL AUTO OVERSHOOT HOLD: stopped %.1fm from target; pilot/re-engage required",
      tonumber(distance) or -1))
  end
end

local function setPilotHoldCurrent(reason)
  disengageAutopilot(reason or "pilot steering hold", false)
  local current = currentRudderSemantic()
  state.flight.steeringMode = "pilot"
  state.flight.rudderTargetDeg = current or state.flight.rudderTargetDeg or 0
  state.flight.headingTarget = nil
  state.flight.headingError = nil
  state.desired.rudder = 0
  transition(reason or "pilot rudder hold")
end

local function cancelAltitude(reason)
  if state.flight.altitudeMode == "hold" then
    state.flight.altitudeMode = "manual"
    state.flight.altitudeState = nil
    state.flight.altitudeError = nil
    state.flight.altitudeCorrection = nil
    transition(reason or "altitude hold cancelled")
  end
end

local function acceptControl(sender, message)
  if not state.armed then sendStatus(sender, "CONTROL_REJECT", { reason = "Server is SAFE" }); return end
  local sequence = tonumber(message.sequence) or 0
  if sequence <= state.lastSequence then return end
  local requested = sanitiseControl(message.control)
  if state.flight.missionMode == "autopilot" and state.flight.autoBrakeStage ~= "idle" then
    local brakingControlOverride = requested.thrust ~= state.desired.thrust or
      requested.reverse ~= state.desired.reverse or requested.rudder ~= 0
    if brakingControlOverride then
      sendStatus(sender, "CONTROL_REJECT", { reason = "Automatic braking owns thrust/reverse/steering; use SAFE to abort" })
      return
    end
  end
  if state.flight.missionMode == "arrival" then
    local pilotChanged = requested.lift ~= state.desired.lift or
      requested.thrust ~= state.desired.thrust or
      requested.reverse ~= state.desired.reverse or
      requested.rudder ~= 0
    if pilotChanged then setMissionMode("assisted", "arrival hold exited by pilot control") end
  end
  if requested.reverse ~= state.desired.reverse then
    if state.flight.missionMode == "autopilot" then downgradeFullAutoToNav("FULL AUTO disengaged by reverse selection", true) end
    if requested.thrust > 0 or state.desired.thrust > 0 or state.actual.thrust > 0 then
      sendStatus(sender, "CONTROL_REJECT", { reason = "Thrust must be 0 before changing reverse" })
      return
    end
  end

  if state.flight.altitudeMode == "hold" and requested.lift ~= state.desired.lift then
    if state.flight.missionMode == "autopilot" then downgradeFullAutoToNav("FULL AUTO disengaged by pilot lift input", false) end
    cancelAltitude("pilot lift input")
  end
  if state.flight.missionMode == "autopilot" and requested.thrust ~= state.desired.thrust then
    downgradeFullAutoToNav("manual thrust takeover; NAV assist remains", false)
  end
  if state.assistReady and requested.rudder ~= 0 then
    if state.flight.steeringMode ~= "pilot" then setPilotHoldCurrent("pocket rudder override") end
  end

  state.lastSequence = sequence
  state.desired.lift = requested.lift
  state.desired.thrust = requested.thrust
  state.desired.reverse = requested.reverse
  state.desired.gyro = requested.gyro
  state.desired.rudder = requested.rudder
  sendStatus(sender, "CONTROL_ACK")
end

local function assistDenied(sender, reason)
  sendStatus(sender, "ASSIST_REJECT", { reason = reason })
end

local function handleAssistCommand(sender, message)
  if not state.armed then assistDenied(sender, "Arm controls first"); return end
  if not state.assistReady then assistDenied(sender, table.concat(state.assistErrors or {}, "; ")); return end
  local action = tostring(message.action or "")
  local value = tonumber(message.value) or 0
  local data = state.telemetry

  if action == "autopilot_toggle" then
    if state.flight.missionMode == "autopilot" and state.flight.autoBrakeStage ~= "idle" then
      assistDenied(sender, "Automatic braking is active; wait for ARRIVED or use SAFE to abort")
      return
    elseif state.flight.missionMode == "autopilot" or state.flight.missionMode == "arrival" then
      setPilotHoldCurrent("autopilot disengaged by operator")
      cancelAltitude("autopilot altitude hold disengaged")
    else
      if not data or not data.valid.navigation or not data.valid.attitude or not data.valid.altitude or
          not data.valid.velocity or not data.hasTarget then
        assistDenied(sender, "Full Auto requires live navigation, attitude, altitude, and velocity data")
        return
      end
      if state.desired.reverse or state.actual.reverse then
        assistDenied(sender, "Disable reverse before engaging autopilot")
        return
      end
      state.flight.steeringMode = "navigation"
      state.flight.headingTarget = nil
      state.flight.navLastTargetAt = util.nowMillis()
      state.desired.rudder = 0
      if state.flight.altitudeMode ~= "hold" or not state.flight.altitudeState then
        state.flight.altitudeMode = "hold"
        state.flight.altitudeState = assist.newAltitudeState(data.altitude, state.actual.lift)
        state.flight.altitudeError = 0
        state.flight.altitudeCorrection = 0
        state.flight.lastAltitudeUpdateAt = 0
      end
      -- FULL AUTO owns forward thrust. Start from zero and let the speed controller
      -- ramp up only after the nose is reasonably aligned with the destination.
      state.desired.thrust = 0
      state.flight.missionCruiseThrust = 0
      state.flight.missionCruiseSpeed = facfg.cruiseSpeed
      state.flight.missionTargetSpeed = 0
      state.flight.missionCurrentSpeed = tonumber(data.horizontalSpeed) or 0
      state.flight.lastAutoThrustAt = 0
      setMissionMode("autopilot", "Full Auto Navigation Table mission engaged")
      transition(string.format("FULL AUTO engaged: alt %.1f m, cruise %.1f m/s",
        state.flight.altitudeState.target, state.flight.missionCruiseSpeed))
    end
  elseif action == "rudder_center" then
    disengageAutopilot("autopilot disengaged by rudder centre command", false)
    state.flight.steeringMode = "pilot"
    state.flight.rudderTargetDeg = 0
    state.flight.headingTarget = nil
    state.desired.rudder = 0
    transition("true-zero rudder centre requested")
  elseif action == "assist_off" then
    setPilotHoldCurrent("all steering assists cancelled")
    cancelAltitude("altitude hold cancelled")
    setMissionMode("assisted", "all automatic modes cancelled")
  elseif action == "heading_toggle" then
    if state.flight.steeringMode == "heading" then
      setPilotHoldCurrent("heading hold disengaged")
    else
      if not data or not data.valid.heading or not data.valid.attitude then assistDenied(sender, "Heading or yaw-rate sensor unavailable"); return end
      setMissionMode("assisted", "heading hold selected")
      state.flight.steeringMode = "heading"
      state.flight.headingTarget = data.heading
      state.desired.rudder = 0
      transition(string.format("heading hold engaged at %.1f deg", data.heading))
    end
  elseif action == "heading_adjust" then
    if state.flight.steeringMode ~= "heading" or state.flight.headingTarget == nil then assistDenied(sender, "Heading hold is not engaged"); return end
    state.flight.headingTarget = sensors.wrap360(state.flight.headingTarget + value)
    transition(string.format("heading target %.1f deg", state.flight.headingTarget))
  elseif action == "navigation_toggle" then
    if state.flight.steeringMode == "navigation" then
      setPilotHoldCurrent("Navigation steering disengaged")
    else
      if not data or not data.valid.navigation or not data.valid.attitude or not data.hasTarget then
        assistDenied(sender, "Navigation Table has no live target or sensor data is unavailable")
        return
      end
      setMissionMode("assisted", "Navigation steering selected")
      state.flight.steeringMode = "navigation"
      state.flight.headingTarget = nil
      state.flight.navLastTargetAt = util.nowMillis()
      state.desired.rudder = 0
      transition("Navigation Table steering engaged")
    end
  elseif action == "altitude_toggle" then
    if state.flight.altitudeMode == "hold" then
      if state.flight.missionMode == "autopilot" then
        setPilotHoldCurrent("autopilot disengaged by altitude-hold command")
      end
      cancelAltitude("altitude hold disengaged")
    else
      if not data or not data.valid.altitude then assistDenied(sender, "Altitude sensor unavailable"); return end
      state.flight.altitudeMode = "hold"
      state.flight.altitudeState = assist.newAltitudeState(data.altitude, state.actual.lift)
      state.flight.altitudeError = 0
      state.flight.altitudeCorrection = 0
      state.flight.lastAltitudeUpdateAt = 0
      transition(string.format("altitude hold engaged at %.1f m", data.altitude))
    end
  elseif action == "altitude_adjust" then
    if state.flight.altitudeMode ~= "hold" or not state.flight.altitudeState then assistDenied(sender, "Altitude hold is not engaged"); return end
    state.flight.altitudeState.target = state.flight.altitudeState.target + value
    transition(string.format("altitude target %.1f m", state.flight.altitudeState.target))
  else
    assistDenied(sender, "Unsupported flight-assist command")
    return
  end
  sendStatus(sender, "ASSIST_ACK")
end

local function prepareForDestinationChange(reason)
  if state.flight.missionMode == "autopilot" or state.flight.missionMode == "arrival" then
    -- A route change must never silently bend an already-engaged mission onto a new course.
    -- Stop thrust, centre steering authority, retain altitude hold, and require explicit re-engagement.
    disengageAutopilot(reason or "destination changed; re-engage autopilot", true)
    state.flight.steeringMode = "pilot"
    state.flight.rudderTargetDeg = 0
    state.flight.headingTarget = nil
    state.flight.headingError = nil
    state.desired.rudder = 0
    transition(reason or "destination changed; autopilot disengaged")
  elseif state.flight.steeringMode == "navigation" then
    state.flight.steeringMode = "pilot"
    state.flight.rudderTargetDeg = 0
    state.flight.headingTarget = nil
    state.flight.headingError = nil
    state.desired.rudder = 0
    transition(reason or "destination changed; navigation steering disengaged")
  end
end

local function handleNavigationCommand(sender, message)
  local action = tostring(message.action or "")
  local payload = type(message.value) == "table" and message.value or {}
  local deletesActive = action == "delete_waypoint" and navigation.isActiveWaypoint(cfg, payload.label)
  local mutatesTarget = action == "set_direct" or action == "activate_waypoint" or action == "clear" or deletesActive
  if mutatesTarget and state.flight.missionMode == "autopilot" and state.flight.autoBrakeStage ~= "idle" then
    sendStatus(sender, "NAV_REJECT", { reason = "Automatic braking is active; wait for ARRIVED or use SAFE" })
    return
  end
  if mutatesTarget then prepareForDestinationChange("destination changed; re-engage navigation") end

  local okay, reply = navigation.command(cfg, action, message.value)
  if okay then
    local saved, saveErr = config.save(cfg)
    if not saved then
      sendStatus(sender, "NAV_REJECT", { reason = "Navigation changed but config save failed: " .. tostring(saveErr) })
      return
    end
    refreshSensors()
  end
  sendStatus(sender, okay and "NAV_ACK" or "NAV_REJECT", {
    reason = reply,
    navigation = navigation.status(cfg),
  })
end

local function handleRadioCommand(sender, message)
  local okay, reply = radio.command(cfg, radioRuntime, message.action, message.value)
  config.save(cfg)
  sendStatus(sender, okay and "RADIO_ACK" or "RADIO_REJECT", {
    reason = reply,
    radio = radio.status(cfg, radioRuntime),
  })
end


local function handleSettingsCommand(sender, message)
  local oldValue = util.deepCopy(settings.get(cfg, message.key))
  local okay, reply = settings.apply(cfg, message.action, message.key, message.value, {
    armed = state.armed == true,
  })

  if okay then
    settings.ensure(cfg)
    telemetryDisplay.configure(telemetryDisplayRuntime, cfg.telemetryDisplay)
    local saved, saveErr = config.save(cfg)
    if not saved then
      settings.apply(cfg, "set", message.key, oldValue, { armed = false })
      telemetryDisplay.configure(telemetryDisplayRuntime, cfg.telemetryDisplay)
      sendStatus(sender, "SETTINGS_REJECT", { reason = "Config save failed; setting restored: " .. tostring(saveErr) })
      return
    end
    refreshSensors()
  end

  sendStatus(sender, okay and "SETTINGS_ACK" or "SETTINGS_REJECT", {
    reason = reply,
    settings = settings.public(cfg),
    telemetryDisplay = telemetryDisplay.status(telemetryDisplayRuntime, cfg.telemetryDisplay),
  })
end

-- v0.5.3 Remote Hold:
-- A controller/session outage is not itself an aircraft hardware failure. Instead of
-- hard-SAFEing lift to zero, the onboard computer removes propulsion, freezes remote
-- authority, and keeps the healthy stabilization loops alive until the Pocket resyncs.
local function enterLinkHold(reason)
  if state.linkHold.active or not state.armed then return end
  local now = util.nowMillis()
  local data = state.telemetry

  state.linkHold.active = true
  state.linkHold.startedAt = now
  state.linkHold.reason = tostring(reason or "controller link lost")
  state.lastReason = "REMOTE HOLD: " .. state.linkHold.reason

  -- Never continue an autonomous propulsion mission with no controller link.
  setMissionMode("assisted", "REMOTE HOLD: propulsion paused")
  state.desired.thrust = 0
  state.desired.reverse = false
  state.actual.thrust = 0
  state.actual.reverse = false
  state.flight.missionTargetSpeed = 0
  state.flight.missionCruiseThrust = 0

  -- Preserve lift and gyro exactly as they were. If Altitude Hold was active, the
  -- normal onboard altitude controller keeps updating lift while the link is absent.
  -- Capture the current heading and hold it autonomously when instrumentation permits.
  if state.assistReady and data and data.valid and data.valid.heading and data.valid.attitude then
    state.flight.steeringMode = "heading"
    state.flight.headingTarget = tonumber(data.heading)
    state.flight.headingError = 0
    state.desired.rudder = 0
    transition(string.format("REMOTE HOLD: heading %.1f deg, lift preserved", tonumber(data.heading) or 0))
  else
    state.flight.steeringMode = "pilot"
    state.flight.headingTarget = nil
    state.flight.rudderTargetDeg = 0
    state.desired.rudder = 0
    transition("REMOTE HOLD: rudder centering, lift preserved")
  end

  state.armNonce = nil
  state.armExpiresAt = 0
  state.controllerSession = nil
  state.lastSequence = 0

  -- Make propulsion loss immediate rather than waiting for the normal output ramp.
  local writeOk, writeErr = writeActual()
  local propOk, propErr = ioControl.setPropulsionPermit(cfg, false)
  local steerOk, steerErr
  if state.assistReady then
    steerOk, steerErr = ioControl.setComputerSteering(cfg, true)
  else
    steerOk, steerErr = ioControl.setComputerSteering(cfg, false)
  end
  if not writeOk or not propOk or not steerOk then
    assertSafe("REMOTE HOLD I/O failure: " .. tostring(writeErr or propErr or steerErr or "unknown"))
    return
  end

  persistState()
  log.warn("REMOTE HOLD entered: " .. state.linkHold.reason)
end

local function exitLinkHold(reason)
  if not state.linkHold.active then return true end
  state.linkHold.active = false
  state.linkHold.startedAt = 0
  state.linkHold.reason = nil
  state.lastReason = tostring(reason or "controller link resynchronized; thrust remains zero")

  -- Remote authority may return, but propulsion never resumes by itself. The Pocket
  -- receives the authoritative zero-thrust state and the pilot/full-auto must command
  -- propulsion again intentionally.
  state.desired.thrust = 0
  state.desired.reverse = false
  state.actual.thrust = 0
  state.actual.reverse = false

  local propOk, propErr = ioControl.setPropulsionPermit(cfg, true)
  local steerOk, steerErr = ioControl.setComputerSteering(cfg, true)
  local writeOk, writeErr = writeActual()
  if not propOk or not steerOk or not writeOk then
    assertSafe("REMOTE HOLD recovery I/O failure: " .. tostring(propErr or steerErr or writeErr or "unknown"))
    return false
  end

  transition("REMOTE HOLD cleared; controller resynchronized, thrust held at zero")
  persistState()
  log.info("REMOTE HOLD cleared after controller resync")
  return true
end

local function handleControl(sender, message)
  local ok, reason = validControl(sender, message)
  if not ok then
    log.warn("Rejected control packet from " .. tostring(sender) .. ": " .. reason)
    -- Best-effort negative acknowledgement. This makes ARM failures visible on the
    -- Pocket instead of leaving it stuck on REQUESTING ARM forever.
    if type(message) == "table" and message.atlasos == true then
      pcall(sendStatus, sender, "CONTROL_REJECT", {
        reason = "Control packet rejected: " .. tostring(reason),
        session = message.session,
      })
    end
    return
  end

  local incomingSession = tostring(message.session or "")

  if message.kind == "SAFE_REQUEST" or message.kind == "DISARM" then
    local requestedReason = tostring(message.reason or "operator request")
    state.lastContactAt = util.nowMillis()
    state.lastCommandAt = state.lastContactAt
    state.lastSender = sender
    state.commandCount = state.commandCount + 1
    assertSafe("requested by pocket controller: " .. requestedReason)
    sendStatus(sender, "SAFE_ACK", {
      session = incomingSession ~= "" and incomingSession or state.controllerSession,
      reason = "authoritative SAFE state confirmed",
    })
    return
  end

  if incomingSession == "" then
    sendStatus(sender, "ERROR", { reason = "Controller session missing; update/restart the Pocket" })
    return
  end

  -- A SYNC packet is the only packet allowed to establish/change a controller session.
  -- This prevents delayed pre-timeout packets from resurrecting a stale session.
  if message.kind == "SYNC" then
    if state.controllerSession ~= incomingSession then
      -- A fresh authenticated session from the paired Pocket is a recoverable link
      -- transition, not a reason to dump lift. If we were actively controlled, enter
      -- REMOTE HOLD first, then bind the new session and restore remote authority.
      if state.armed and not state.linkHold.active then
        enterLinkHold("controller session changed; resynchronizing")
      end
      state.controllerSession = incomingSession
      state.lastSequence = 0
    end
    state.lastContactAt = util.nowMillis()
    state.lastCommandAt = state.lastContactAt
    state.lastSender = sender
    state.commandCount = state.commandCount + 1
    if state.linkHold.active then
      exitLinkHold("controller link resynchronized; thrust remains zero")
    end
    sendStatus(sender, "SYNC_ACK", { session = incomingSession, reason = "authoritative server state synchronized" })
    return
  end

  if state.controllerSession == nil or state.controllerSession ~= incomingSession then
    sendStatus(sender, "RESYNC_REQUIRED", { session = incomingSession, reason = "controller session is stale; resynchronize before sending commands" })
    return
  end

  state.lastContactAt = util.nowMillis()
  state.lastCommandAt = state.lastContactAt
  state.lastSender = sender
  state.commandCount = state.commandCount + 1

  if message.kind == "PING" then sendStatus(sender, "STATUS")
  elseif message.kind == "ARM_REQUEST" then beginArm(sender, message)
  elseif message.kind == "ARM_CONFIRM" then confirmArm(sender, message)
  elseif message.kind == "CONTROL" then acceptControl(sender, message)
  elseif message.kind == "ASSIST_COMMAND" then handleAssistCommand(sender, message)
  elseif message.kind == "NAV_COMMAND" then handleNavigationCommand(sender, message)
  elseif message.kind == "RADIO_COMMAND" then handleRadioCommand(sender, message)
  elseif message.kind == "SETTINGS_COMMAND" then handleSettingsCommand(sender, message)
  elseif message.kind == "DIAG_REQUEST" then
    sendStatus(sender, "DIAG_REPLY", { peripherals = peripheral.getNames() })
  else sendStatus(sender, "ERROR", { reason = "Unsupported command" }) end
end

local function updateOrdinaryOutputs(now)
  if not state.armed then return end
  local changed = false
  if now - state.lastLiftStepAt >= (cfg.liftRampMs or 150) then
    local nextValue = util.moveToward(state.actual.lift, state.desired.lift, 1)
    if nextValue ~= state.actual.lift then state.actual.lift = nextValue; changed = true end
    state.lastLiftStepAt = now
  end
  if now - state.lastThrustStepAt >= (cfg.thrustRampMs or 100) then
    local nextValue = util.moveToward(state.actual.thrust, state.desired.thrust, 1)
    if nextValue ~= state.actual.thrust then state.actual.thrust = nextValue; changed = true end
    state.lastThrustStepAt = now
  end
  if state.actual.reverse ~= state.desired.reverse then state.actual.reverse = state.desired.reverse; changed = true end
  if state.actual.gyro ~= state.desired.gyro then state.actual.gyro = state.desired.gyro; changed = true end

  if not state.assistReady and state.actual.rudder ~= state.desired.rudder then
    state.actual.rudder = state.desired.rudder
    changed = true
  end

  if changed then
    local ok, err = writeActual()
    if not ok then assertSafe("I/O write failed: " .. tostring(err)) end
  end
end

local function setRudderOutput(command, rpm)
  command = tonumber(command) or 0
  rpm = tonumber(rpm) or 0
  local currentCommand = state.actual.rudder
  local currentRpm = state.flight.rudderRpm

  if command == currentCommand and (command == 0 or math.abs(currentRpm - rpm) <= 0.05) then return true end

  if currentCommand ~= 0 then
    state.actual.rudder = 0
    local stopped, stopErr = writeActual()
    if not stopped then return false, stopErr end
  end

  if command ~= 0 then
    local speedOk, speedErr = setSteeringSpeed(rpm)
    if not speedOk then return false, speedErr end
    state.actual.rudder = command
    local commandOk, commandErr = writeActual()
    if not commandOk then return false, commandErr end
  else
    state.actual.rudder = 0
    pcall(setSteeringSpeed, math.abs(tonumber((cfg.sensors or {}).steeringActuatorRpm) or 16))
  end

  state.flight.rudderCommand = command
  state.flight.rudderRpm = command == 0 and 0 or rpm
  return true
end

local function cancelSteeringToCentre(reason)
  state.flight.steeringMode = "pilot"
  state.flight.rudderTargetDeg = 0
  state.flight.headingTarget = nil
  state.desired.rudder = 0
  transition(reason)
end

local function finishSafeCentering(reason)
  if not state.safeCenter.active then return end
  state.safeCenter.active = false
  state.safeCenter.deadlineAt = 0
  state.safeCenter.reason = nil
  state.actual.rudder = 0
  state.flight.rudderCommand = 0
  state.flight.rudderRpm = 0
  pcall(ioControl.setComputerSteering, cfg, false)
  ioControl.applySafe(cfg)
  transition(reason or "SAFE rudder centering complete")
end

local function updateSafeCentering(now)
  if not state.safeCenter.active then return end
  if now >= state.safeCenter.deadlineAt then
    finishSafeCentering("SAFE rudder centering timed out; manual steering selected")
    return
  end

  local data = state.telemetry
  if not data or not data.valid or not data.valid.rudder or not data.rudderAssembled or
      not data.valid.steeringController or not data.steeringHasSource or data.steeringOverstressed then
    finishSafeCentering("SAFE rudder centering aborted: steering feedback unavailable")
    return
  end

  local current = assist.bearingToSemantic(cfg, data.rudderBearingAngle)
  if current == nil then
    finishSafeCentering("SAFE rudder centering aborted: rudder position unavailable")
    return
  end
  state.flight.rudderCurrentDeg = current
  state.flight.rudderTargetDeg = 0
  state.flight.rudderErrorDeg = -current

  if math.abs(current) <= SAFE_CENTER_TOLERANCE_DEG then
    setRudderOutput(0, 0)
    finishSafeCentering("SAFE rudder centred; physical wheel selected")
    return
  end

  -- v0.5.3 cumulative: SAFE centering has its own strict true-zero controller.
  -- It must not inherit the normal flight rudder deadband, which may be several degrees.
  local error = -current
  local leftOutput = tonumber(acfg.rudder.leftOutputCommand)
  if leftOutput ~= -1 and leftOutput ~= 1 then
    finishSafeCentering("SAFE rudder centering aborted: automatic steering direction is not commissioned")
    return
  end

  local command = error < 0 and leftOutput or -leftOutput
  local magnitude = math.abs(error)
  local rpm
  if magnitude <= (tonumber(acfg.rudder.crawlZoneDeg) or 2.5) then
    rpm = tonumber(acfg.rudder.crawlRpm) or 2
  elseif magnitude <= (tonumber(acfg.rudder.slowZoneDeg) or 9) then
    rpm = tonumber(acfg.rudder.slowRpm) or 6
  else
    rpm = tonumber(acfg.rudder.fastRpm) or math.abs(tonumber((cfg.sensors or {}).steeringActuatorRpm) or 16)
  end

  state.flight.rudderCurrentDeg = current
  state.flight.rudderErrorDeg = error
  local outputOk, outputErr = setRudderOutput(command, rpm)
  if not outputOk then
    finishSafeCentering("SAFE rudder centering output failed: " .. tostring(outputErr))
  end
end

local function reassertPhysicalOutputs(now)
  if now - state.lastOutputReassertAt < OUTPUT_REASSERT_MS then return end
  state.lastOutputReassertAt = now

  if state.linkHold.active then
    -- REMOTE HOLD continuously reasserts "no propulsion" while preserving lift,
    -- gyro, and onboard heading/altitude stabilization.
    state.actual.thrust = 0
    state.actual.reverse = false
    local propOk, propErr = ioControl.setPropulsionPermit(cfg, false)
    local steerOk, steerErr
    if state.assistReady then
      steerOk, steerErr = ioControl.setComputerSteering(cfg, true)
    else
      steerOk, steerErr = ioControl.setComputerSteering(cfg, false)
    end
    local controlOk, controlErr = writeActual()
    if not propOk or not steerOk or not controlOk then
      assertSafe("REMOTE HOLD periodic output reassert failed: " ..
        tostring(propErr or steerErr or controlErr or "unknown I/O error"))
    end
  elseif state.armed then
    local steerOk, steerErr = ioControl.setComputerSteering(cfg, true)
    local propOk, propErr = ioControl.setPropulsionPermit(cfg, true)
    local controlOk, controlErr = writeActual()
    if not steerOk or not propOk or not controlOk then
      assertSafe("periodic output reassert failed: " .. tostring(steerErr or propErr or controlErr or "unknown I/O error"))
    end
  elseif state.safeCenter.active then
    -- Propulsion remains positively locked while computer steering is retained only
    -- long enough to return the rudder to zero.
    ioControl.setPropulsionPermit(cfg, false)
    ioControl.setComputerSteering(cfg, true)
    writeActual()
  else
    -- Projected Redstone Links can visually/physically retain stale values after a
    -- successful API write. Re-issue the complete SAFE state until it sticks.
    ioControl.applySafe(cfg)
  end
end

local function fullAutoTargetSpeed(data)
  local distance = math.max(0, tonumber(data.horizontalDistance) or horizontalNavigationDistance(data) or 0)
  local arrivalRadius = tonumber(acfg.navigation.arrivalRadius) or 8
  local cruise = tonumber(state.flight.missionCruiseSpeed) or facfg.cruiseSpeed
  local target = cruise

  if distance <= arrivalRadius then
    target = 0
  elseif distance < facfg.approachDistance then
    local span = math.max(1, facfg.approachDistance - arrivalRadius)
    local ratio = util.clamp((distance - arrivalRadius) / span, 0, 1)
    target = facfg.minimumApproachSpeed + (cruise - facfg.minimumApproachSpeed) * ratio
  end

  -- v0.5.3 cumulative: a rudder cannot align a stationary Atlas.
  -- Large heading errors use low turning speed instead of zero target speed.
  local bearing = math.abs(tonumber(data.bearing) or 0)
  if bearing >= facfg.headingSlowDeg then
    target = math.min(target, facfg.turnSpeed)
  end
  return math.max(0, target)
end

local function fullAutoBrakeTriggerDistance(speed)
  local arrivalRadius = tonumber(acfg.navigation.arrivalRadius) or 8
  local lead = math.max(facfg.brakeMinLeadDistance, math.max(0, speed) * facfg.brakeLeadSeconds)
  return math.min(facfg.approachDistance, arrivalRadius + lead)
end

local function beginFullAutoBrake(now, data, speed, distance, finishMode)
  state.flight.autoBrakeStage = "coast"
  state.flight.autoBrakeFinishMode = finishMode or "arrival"
  state.flight.autoBrakeStartedAt = now
  state.flight.autoBrakeMinSpeed = speed
  state.flight.autoBrakeTriggerDistance = distance

  -- v0.5.4-r1:
  -- Remember which sign of body-forward velocity corresponds to our approach.
  -- horizontalSpeed is an unsigned magnitude and cannot tell forward from reverse.
  local initialForward = tonumber(data.forwardSpeed) or 0
  state.flight.autoBrakeApproachSign = initialForward < 0 and -1 or 1
  state.flight.missionPhase = "BRAKE"
  state.flight.missionTargetSpeed = 0

  -- Stop navigating toward a point which may shortly move behind us. During reverse
  -- braking we command true-zero rudder so passing the destination cannot make the
  -- navigation controller attempt a 180-degree turn.
  state.flight.steeringMode = "pilot"
  state.flight.rudderTargetDeg = 0
  state.flight.headingTarget = nil
  state.flight.headingError = nil
  state.desired.rudder = 0

  -- Reverse may only change after forward thrust has physically ramped to zero.
  state.desired.thrust = 0
  state.desired.reverse = false
  transition(string.format("FULL AUTO BRAKE: %.1f m out at %.1f m/s", distance, speed))
end

local function updateFullAutoBrake(now, data, speed)
  local stage = tostring(state.flight.autoBrakeStage or "idle")
  if stage == "idle" then return false end

  state.flight.missionPhase = "BRAKE"
  state.flight.missionTargetSpeed = 0
  state.flight.missionCurrentSpeed = speed
  state.flight.autoBrakeMinSpeed = math.min(tonumber(state.flight.autoBrakeMinSpeed) or speed, speed)

  if stage == "coast" then
    state.desired.thrust = 0
    state.desired.reverse = false
    if (tonumber(state.actual.thrust) or 0) <= 0 then
      state.desired.reverse = true
      state.flight.autoBrakeStage = "reverse"
      state.flight.lastAutoThrustAt = 0
      transition("FULL AUTO BRAKE: reverse selected")
    end
    return true
  end

  if stage == "reverse" then
    state.desired.reverse = true

    -- v0.5.4-r1:
    -- Use SIGNED body-forward velocity to detect the actual zero crossing.
    -- The old rebound heuristic used horizontalSpeed, which is sqrt(vf^2 + vr^2)
    -- and therefore remains positive while travelling backwards. If the telemetry
    -- loop skipped over the minimum, reverse braking could accelerate Atlas away.
    local approachSign = tonumber(state.flight.autoBrakeApproachSign) or 1
    local forwardSpeed = tonumber(data and data.forwardSpeed)
    local signedApproachSpeed = forwardSpeed and (forwardSpeed * approachSign) or nil

    if signedApproachSpeed ~= nil and signedApproachSpeed <= facfg.brakeStopSpeed then
      state.desired.thrust = 0
      state.flight.autoBrakeStage = "release"
      transition(signedApproachSpeed < 0 and
        string.format("FULL AUTO BRAKE: reverse motion detected (%+.2f m/s); releasing", signedApproachSpeed) or
        string.format("FULL AUTO BRAKE: forward speed %.2f m/s; releasing", signedApproachSpeed))
      return true
    elseif signedApproachSpeed == nil and speed <= facfg.brakeStopSpeed then
      -- Fallback only if signed velocity is unexpectedly unavailable.
      state.desired.thrust = 0
      state.flight.autoBrakeStage = "release"
      transition(string.format("FULL AUTO BRAKE: %.2f m/s fallback stop; releasing reverse", speed))
      return true
    end

    if now - (state.flight.lastAutoThrustAt or 0) >= facfg.thrustAdjustIntervalMs then
      state.flight.lastAutoThrustAt = now
      local brakingSpeed = math.max(0, signedApproachSpeed or speed)
      local requestedBrake = util.clamp(math.ceil(brakingSpeed), 1, facfg.brakeMaxThrust)
      state.desired.thrust = util.moveToward(tonumber(state.desired.thrust) or 0, requestedBrake, 1)
      state.flight.missionCruiseThrust = state.desired.thrust
    end
    return true
  end

  if stage == "release" then
    -- Never flip the reverse channel while thrust is nonzero.
    state.desired.thrust = 0
    state.desired.reverse = true
    if (tonumber(state.actual.thrust) or 0) <= 0 then
      state.desired.reverse = false
      state.flight.autoBrakeStage = "unwind"
      transition("FULL AUTO BRAKE: thrust zero; reverse disengaging")
    end
    return true
  end

  if stage == "unwind" then
    state.desired.thrust = 0
    state.desired.reverse = false
    if state.actual.reverse ~= true then
      if state.flight.autoBrakeFinishMode == "overshoot" then
        completeOvershootHold()
      else
        completeMissionArrival()
      end
    end
    return true
  end

  -- Unknown stage: fail propulsion closed without hard-SAFEing lift.
  state.desired.thrust = 0
  state.desired.reverse = false
  downgradeFullAutoToNav("FULL AUTO brake state invalid; propulsion stopped", true)
  return true
end

-- v0.5.4-r2 TARGET CAPTURE / OVERSHOOT GUARD
--
-- A fixed "if distance > X then disengage" guard cannot work because Atlas starts
-- every route far from its waypoint. Instead, the guard latches only after Atlas
-- has entered the destination capture zone. From then on it remembers closest
-- approach. If the waypoint moves behind Atlas and range increases, or if range
-- escapes far enough from closest approach, Full Auto stops trying to reacquire.
local function checkFullAutoOvershoot(now, data, distance, speed, bearingAbs)
  if state.flight.autoBrakeStage ~= "idle" then return false end

  local arrivalRadius = tonumber(acfg.navigation.arrivalRadius) or 8
  local brakeTrigger = fullAutoBrakeTriggerDistance(speed)
  local captureDistance = math.min(
    facfg.approachDistance,
    math.max(arrivalRadius + facfg.overshootCaptureExtra,
      brakeTrigger + facfg.overshootCaptureExtra)
  )

  local closest = tonumber(state.flight.autoClosestDistance)
  if not closest or distance < closest then
    state.flight.autoClosestDistance = distance
    closest = distance
    state.flight.autoOvershootSince = 0
  end

  if not state.flight.autoCaptureArmed and distance <= captureDistance then
    state.flight.autoCaptureArmed = true
    transition(string.format("FULL AUTO TARGET CAPTURE armed at %.1fm", distance))
  end

  if not state.flight.autoCaptureArmed then return false end

  local growth = distance - (tonumber(state.flight.autoClosestDistance) or distance)
  local targetBehind = bearingAbs >= facfg.overshootBehindDeg
  local trendingAway = growth >= facfg.overshootTrendMargin
  local escaped = growth >= facfg.overshootEscapeMargin

  if escaped then
    beginFullAutoBrake(now, data, speed, distance, "overshoot")
    transition(string.format(
      "FULL AUTO OVERSHOOT: escaped %.1fm from closest approach; braking and disengaging",
      growth))
    return true
  end

  if targetBehind and trendingAway then
    if (state.flight.autoOvershootSince or 0) <= 0 then
      state.flight.autoOvershootSince = now
    elseif now - state.flight.autoOvershootSince >= facfg.overshootConfirmMs then
      beginFullAutoBrake(now, data, speed, distance, "overshoot")
      transition(string.format(
        "FULL AUTO OVERSHOOT: target behind, range increasing (closest %.1fm -> %.1fm); braking",
        tonumber(state.flight.autoClosestDistance) or distance, distance))
      return true
    end
  else
    state.flight.autoOvershootSince = 0
  end

  return false
end

local function updateFullAutoThrust(now, data)
  if state.flight.missionMode ~= "autopilot" then return true end
  if not data or not data.valid or not data.valid.navigation or not data.valid.attitude or
      not data.valid.altitude or not data.valid.velocity or not data.hasTarget then
    state.desired.thrust = 0
    downgradeFullAutoToNav("FULL AUTO paused: navigation/velocity telemetry unavailable", true)
    return false
  end

  local speed = math.max(0, tonumber(data.horizontalSpeed) or 0)
  local target = fullAutoTargetSpeed(data)
  local distance = math.max(0, tonumber(data.horizontalDistance) or horizontalNavigationDistance(data) or 0)
  local bearing = math.abs(tonumber(data.bearing) or 0)
  local arrivalRadius = tonumber(acfg.navigation.arrivalRadius) or 8
  state.flight.missionCurrentSpeed = speed
  state.flight.missionTargetSpeed = target

  -- Once automatic braking owns reverse, reverse=true is expected. Outside that
  -- state it still means the pilot selected reverse and FULL AUTO must disengage.
  if state.flight.autoBrakeStage ~= "idle" then
    return updateFullAutoBrake(now, data, speed)
  elseif state.desired.reverse or state.actual.reverse then
    state.desired.thrust = 0
    downgradeFullAutoToNav("FULL AUTO cancelled: reverse selected", true)
    return false
  end

  if distance <= arrivalRadius and speed <= facfg.brakeStopSpeed then
    completeMissionArrival()
    return true
  end

  -- Once target capture has armed, never chase a waypoint behind the ship.
  -- Overshoot handling owns propulsion/steering until Atlas is stopped.
  if checkFullAutoOvershoot(now, data, distance, speed, bearing) then
    return true
  end

  local brakeTriggerDistance = fullAutoBrakeTriggerDistance(speed)
  local brakeGeometryReady = distance <= arrivalRadius or bearing <= facfg.headingSlowDeg
  if speed > facfg.brakeStopSpeed and brakeGeometryReady and distance <= brakeTriggerDistance then
    beginFullAutoBrake(now, data, speed, distance, "arrival")
    return true
  end

  if distance <= arrivalRadius then
    state.flight.missionPhase = "FINAL"
  elseif bearing >= facfg.headingGateDeg then
    state.flight.missionPhase = "ALIGN"
  elseif distance < facfg.approachDistance then
    state.flight.missionPhase = "APPROACH"
  elseif speed < target - facfg.speedDeadband then
    state.flight.missionPhase = "ACCEL"
  else
    state.flight.missionPhase = "CRUISE"
  end

  if now - (state.flight.lastAutoThrustAt or 0) < facfg.thrustAdjustIntervalMs then return true end
  state.flight.lastAutoThrustAt = now

  if target <= 0.05 then
    state.desired.thrust = 0
  elseif speed < target - facfg.speedDeadband then
    state.desired.thrust = util.clamp((tonumber(state.desired.thrust) or 0) + 1, 0, facfg.maxThrust)
  elseif speed > target + facfg.speedDeadband then
    state.desired.thrust = util.clamp((tonumber(state.desired.thrust) or 0) - 1, 0, facfg.maxThrust)
  end
  state.flight.missionCruiseThrust = state.desired.thrust
  return true
end

local function updateFlightAssist(now, dtSeconds)
  if not state.armed or not state.assistReady then return end
  local data = state.telemetry
  if not data then return end

  -- Moving physics contraptions can produce one-frame peripheral/sensor dropouts.
  local transientFaultActive = false
  local function checkTransient(key, active, reason)
    local faultActive, asserted = debounceSafeFault(key, active, reason, now, TRANSIENT_FEEDBACK_GRACE_MS)
    if asserted then return true end
    if faultActive then
      transientFaultActive = true
      state.flight.fault = "transient: " .. reason
    end
    return false
  end

  if checkTransient("rudder_feedback", not data.valid.rudder or not data.rudderAssembled, "rudder bearing feedback lost") then return end
  if checkTransient("steering_controller", not data.valid.steeringController, "steering speed controller feedback lost") then return end
  if checkTransient("steering_source", not data.steeringHasSource, "computer-steering engine/source lost power") then return end
  if checkTransient("steering_rpm", math.abs(tonumber(data.steeringLiveRpm) or 0) < 0.1, "computer-steering source stopped rotating") then return end
  if checkTransient("steering_overstress", data.steeringOverstressed == true, "computer-steering kinetic network overstressed") then return end
  if checkTransient("wheel_feedback", not data.valid.wheel, "physical wheel feedback lost") then return end
  if transientFaultActive then return end
  if type(state.flight.fault) == "string" and state.flight.fault:find("transient: ", 1, true) == 1 then state.flight.fault = nil end

  local wheelNormalized = util.clamp(tonumber(data.wheelNormalized) or 0, -1, 1)
  local wheelEntryThreshold = tonumber(acfg.wheelOverrideThreshold) or 0.08
  local wheelDebounceMs = 150
  local wheelCanEnter = now >= (tonumber(state.flight.wheelIgnoreUntil) or 0)
  local wheelRequest = wheelCanEnter and data.wheelHeld and math.abs(wheelNormalized) >= wheelEntryThreshold

  if state.flight.steeringMode ~= "wheel" then
    state.flight.wheelReleaseCandidateAt = nil
    if wheelRequest then
      if not state.flight.wheelOverrideCandidateAt then
        state.flight.wheelOverrideCandidateAt = now
      elseif now - state.flight.wheelOverrideCandidateAt >= wheelDebounceMs then
        local wheelTarget, wheelErr = assist.wheelToSemantic(cfg, wheelNormalized)
        if wheelTarget == nil then assertSafe(wheelErr); return end
        disengageAutopilot("physical wheel override", false)
        state.flight.steeringMode = "wheel"
        state.flight.rudderTargetDeg = wheelTarget
        state.flight.headingTarget = nil
        state.flight.headingError = nil
        state.desired.rudder = 0
        state.flight.wheelOverrideCandidateAt = nil
        transition("physical wheel fly-by-wire override")
      end
    else
      state.flight.wheelOverrideCandidateAt = nil
    end
  else
    state.flight.wheelOverrideCandidateAt = nil
    if data.wheelHeld then
      state.flight.wheelReleaseCandidateAt = nil
      local wheelTarget, wheelErr = assist.wheelToSemantic(cfg, wheelNormalized)
      if wheelTarget == nil then assertSafe(wheelErr); return end
      state.flight.rudderTargetDeg = wheelTarget
    else
      -- Latch the last player-commanded rudder target. Do not follow wheel
      -- telemetry while the wheel is free: the actuator or clutch transition
      -- must never be able to back-drive its own command source.
      if not state.flight.wheelReleaseCandidateAt then
        state.flight.wheelReleaseCandidateAt = now
      elseif now - state.flight.wheelReleaseCandidateAt >= wheelDebounceMs then
        state.flight.steeringMode = "pilot"
        state.flight.headingTarget = nil
        state.flight.headingError = nil
        state.flight.wheelReleaseCandidateAt = nil
        state.desired.rudder = 0
        transition("physical wheel released; pilot hold engaged")
      end
    end
  end

  if state.flight.steeringMode == "pilot" then
    if state.desired.rudder ~= 0 then
      state.flight.rudderTargetDeg = assist.clampSemantic(cfg,
        state.flight.rudderTargetDeg + state.desired.rudder * acfg.rudder.jogRateDegPerSec * dtSeconds, false)
    end
  elseif state.flight.steeringMode == "heading" then
    if not data.valid.heading or not data.valid.attitude then
      cancelSteeringToCentre("heading hold cancelled: sensor unavailable")
    else
      local target, errorRight = assist.computeHeadingRudder(cfg, data, state.flight.headingTarget)
      state.flight.rudderTargetDeg = target
      state.flight.headingError = errorRight
    end
  elseif state.flight.steeringMode == "navigation" then
    if data.valid.navigation and data.valid.attitude and data.hasTarget then
      state.flight.navLastTargetAt = now
      local navDistance = tonumber(data.horizontalDistance) or horizontalNavigationDistance(data)
      if navDistance and navDistance <= acfg.navigation.arrivalRadius then
        if state.flight.missionMode == "autopilot" then
          local speed = tonumber(data.horizontalSpeed) or math.huge
          if data.valid.velocity and speed <= facfg.brakeStopSpeed then
            completeMissionArrival()
          else
            -- v0.5.4: Full Auto braking is handled by updateFullAutoThrust().
            -- Until it takes ownership, cut forward thrust and keep the approach
            -- controller pointed at the target. The brake phase then centres the
            -- rudder before selecting reverse so overshoot cannot trigger a 180.
            state.desired.thrust = 0
            state.flight.missionTargetSpeed = 0
            state.flight.missionCurrentSpeed = speed == math.huge and 0 or speed
            state.flight.missionPhase = "FINAL"
            local target, bearing = assist.computeNavigationRudder(cfg, data)
            state.flight.rudderTargetDeg = target
            state.flight.headingError = bearing
          end
        else
          cancelSteeringToCentre("Navigation target arrival radius reached")
        end
      else
        local target, bearing = assist.computeNavigationRudder(cfg, data)
        state.flight.rudderTargetDeg = target
        state.flight.headingError = bearing
      end
    elseif now - state.flight.navLastTargetAt > acfg.navigation.targetLossMs then
      if state.flight.missionMode == "autopilot" then
        disengageAutopilot("autopilot cancelled: navigation target lost", true)
      end
      cancelSteeringToCentre("Navigation steering cancelled: target lost")
    end
  end

  if state.flight.altitudeMode == "hold" then
    if not data.valid.altitude then
      if state.flight.missionMode == "autopilot" then
        disengageAutopilot("autopilot cancelled: altitude sensor unavailable", true)
        cancelSteeringToCentre("autopilot steering cancelled after altitude sensor loss")
      end
      cancelAltitude("altitude hold cancelled: sensor unavailable")
    elseif state.flight.altitudeState and now - state.flight.lastAltitudeUpdateAt >= acfg.altitude.outputIntervalMs then
      local requested, error, correction, altitudeState = assist.computeAltitudeLift(cfg, data,
        state.flight.altitudeState, math.max(0.05, (now - state.flight.lastAltitudeUpdateAt) / 1000))
      state.flight.altitudeState = altitudeState
      state.flight.altitudeError = error
      state.flight.altitudeCorrection = correction
      state.flight.lastAltitudeUpdateAt = now
      state.desired.lift = requested
    end
  end

  if state.flight.missionMode == "autopilot" then
    updateFullAutoThrust(now, data)
  end

  state.flight.rudderTargetDeg = clampOperationalRudderTarget(state.flight.rudderTargetDeg)
  local result, resultErr = assist.computeRudderActuation(cfg, data, state.flight.rudderTargetDeg)
  if not result then assertSafe("rudder controller error: " .. tostring(resultErr)); return end

  local geometry = assist.rudderGeometry(cfg)
  if geometry.ok and (result.currentSemantic < -geometry.leftMagnitude - 2 or result.currentSemantic > geometry.rightMagnitude + 2) then
    assertSafe("rudder exceeded calibrated travel envelope")
    return
  end

  state.flight.rudderCurrentDeg = result.currentSemantic
  state.flight.rudderErrorDeg = result.errorSemantic

  if state.flight.lastRudderPosition == nil or
      math.abs(result.currentSemantic - state.flight.lastRudderPosition) >= acfg.rudder.movementThresholdDeg then
    state.flight.lastRudderPosition = result.currentSemantic
    state.flight.lastRudderMovementAt = now
  end
  if result.command ~= state.flight.lastRudderCommand then
    state.flight.lastRudderCommand = result.command
    state.flight.lastRudderMovementAt = now
    state.flight.lastRudderPosition = result.currentSemantic
  end
  if result.command ~= 0 and now - state.flight.lastRudderMovementAt > acfg.rudder.stallTimeoutMs then
    local endpointGuard = math.max(2.0, (tonumber(acfg.rudder.toleranceDeg) or 0.65) + 1.0)
    local pushingLeft = result.errorSemantic < 0
    local pushingRight = result.errorSemantic > 0
    local nearLeft = geometry.ok and result.currentSemantic <= (-geometry.leftMagnitude + endpointGuard)
    local nearRight = geometry.ok and result.currentSemantic >= (geometry.rightMagnitude - endpointGuard)
    if (pushingLeft and nearLeft) or (pushingRight and nearRight) then
      -- The actuator has reached the physical end of travel. Saturate cleanly
      -- instead of treating an expected endpoint as a flight-control failure.
      state.flight.rudderTargetDeg = result.currentSemantic
      state.flight.rudderErrorDeg = 0
      state.flight.lastRudderCommand = 0
      state.flight.lastRudderMovementAt = now
      state.flight.lastRudderPosition = result.currentSemantic
      result.errorSemantic = 0
      result.command = 0
      result.rpm = 0
      result.reached = true
      transition("rudder operational endpoint reached; holding")
    else
      state.flight.fault = "rudder actuator stalled"
      assertSafe(state.flight.fault)
      return
    end
  end

  local outputOk, outputErr = setRudderOutput(result.command, result.rpm)
  if not outputOk then assertSafe("rudder output failed: " .. tostring(outputErr)); return end
end

local function draw()
  local width, height = term.getSize()
  local row = 1
  local function put(text, color)
    if row > height then return end
    term.setCursorPos(1, row)
    term.setTextColor(color or colors.white)
    term.write(util.truncate(text, width))
    row = row + 1
  end
  local function pair(leftLabel, leftValue, rightLabel, rightValue)
    local left = tostring(leftLabel) .. ":" .. tostring(leftValue)
    local right = tostring(rightLabel) .. ":" .. tostring(rightValue)
    local gap = math.max(1, width - #left - #right)
    put(left .. string.rep(" ", gap) .. right)
  end

  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)

  put("AtlasOS Integrated Flight Server", colors.orange)
  put("FICSIT Heavy Aeronautics Division", colors.lightGray)
  put(string.rep("-", math.min(width, 48)), colors.lightGray)
  pair("Ver", version.version, "ID", os.getComputerID())
  pair("Pocket", cfg.pairedPocketId or "-", "Radio", modemName)
  pair("Flight I/O", state.hardwareValid and "READY" or "LOCKED",
    "Assist", state.assistReady and "READY" or (acfg.configured and "LOCKED" or "NONE"))
  pair("Prop", state.armed and "OPEN" or "LOCK", "Steer", state.safeCenter.active and "CENTER" or (state.armed and "PC" or "WHEEL"))
  put("STATE: " .. (state.armed and "ARMED" or "SAFE"), state.armed and colors.yellow or colors.lime)
  put("Reason: " .. state.lastReason, colors.lightGray)
  pair("Lift", state.actual.lift .. ">" .. state.desired.lift,
    "Thrust", state.actual.thrust .. ">" .. state.desired.thrust)
  pair("Reverse", tostring(state.actual.reverse), "Gyro", tostring(state.actual.gyro))
  pair("Mission", state.flight.missionMode == "autopilot" and ("AUTO/" .. tostring(state.flight.missionPhase)) or state.flight.missionMode,
    "Steer", state.flight.steeringMode)
  if state.flight.missionMode == "autopilot" then
    pair("AutoSpd", string.format("%.1f>%.1f", state.flight.missionCurrentSpeed or 0, state.flight.missionTargetSpeed or 0),
      "AutoThr", tostring(state.desired.thrust))
  end
  pair("Altitude", state.flight.altitudeMode, "Radio", radio.status(cfg, radioRuntime).status or "-")
  pair("Rudder", string.format("%+.1f", state.flight.rudderCurrentDeg or 0),
    "Target", string.format("%+.1f", state.flight.rudderTargetDeg or 0))
  pair("Act", tostring(state.flight.rudderCommand), "RPM", string.format("%.1f", state.flight.rudderRpm or 0))

  if state.telemetry then
    pair("Alt", string.format("%.1fm", state.telemetry.altitude or 0),
      "V/S", string.format("%+.1f", state.telemetry.verticalSpeed or 0))
    pair("Hdg", string.format("%03.0f", state.telemetry.heading or 0),
      "Spd", string.format("%.1f", state.telemetry.forwardSpeed or 0))
  else
    put("Telemetry: not available", colors.gray)
  end

  pair("Uptime", util.formatDuration(util.nowMillis() - state.bootAt),
    "Link", state.lastContactAt > 0 and util.formatDuration(util.nowMillis() - state.lastContactAt) or "never")
  put("Ctrl+T -> SAFE, propulsion locked, wheel selected", colors.gray)
end

local function run()
  net.host(net.CONTROL_PROTOCOL, cfg.name .. "-flight-server")
  if cfg.pairingOpen then net.host(net.PAIR_PROTOCOL, cfg.name .. "-pairing") end
  refreshHardware()
  refreshSensors()
  navigation.ensureConfig(cfg)
  config.save(cfg)
  assertSafe("server startup")
  telemetryDisplay.refresh(telemetryDisplayRuntime, cfg.telemetryDisplay)
  log.info("Volume V v0.5.5-rc2 Constellation Navigation started on modem " .. modemName)
  local timer = os.startTimer(0.05)
  local lastTickAt = util.nowMillis()

  while true do
    local event = { os.pullEventRaw() }
    local name = event[1]
    if name == "terminate" then assertSafe("server terminated from keyboard"); return
    elseif name == "rednet_message" then
      local sender, message, protocol = event[2], event[3], event[4]
      if protocol == net.PAIR_PROTOCOL then handlePair(sender, message)
      elseif protocol == net.CONTROL_PROTOCOL then handleControl(sender, message) end
    -- Atlas Audio lifecycle events. Standard CC speaker event remains as fallback.
    elseif name == "atlas_audio_started" then
      radio.onAtlasStarted(radioRuntime, event[2], event[3], event[4])
    elseif name == "atlas_audio_paused" then
      radio.onAtlasPaused(radioRuntime, event[2])
    elseif name == "atlas_audio_resumed" then
      radio.onAtlasResumed(radioRuntime, event[2])
    elseif name == "atlas_audio_stopped" then
      radio.onAtlasStopped(cfg, radioRuntime, event[2])
    elseif name == "atlas_audio_error" then
      radio.onAtlasError(radioRuntime, event[2], event[3], event[4])
    elseif name == "speaker_audio_empty" then
      radio.onSpeakerEmpty(radioRuntime, event[2])
      radio.pump(cfg, radioRuntime)
    elseif name == "disk" or name == "disk_eject" then
      radio.rescan(cfg, radioRuntime)
    elseif name == "peripheral_detach" then
      refreshHardware()
      refreshSensors()
      radio.bindSpeaker(cfg, radioRuntime)
      telemetryDisplay.refresh(telemetryDisplayRuntime, cfg.telemetryDisplay)
      if state.armed then
        debounceSafeFault("hardware_validity", not state.hardwareValid,
          "flight I/O peripheral detached: " .. tostring(event[2]), util.nowMillis(), HARDWARE_VALIDITY_GRACE_MS)
      else
        debounceSafeFault("hardware_validity", false, "", util.nowMillis(), HARDWARE_VALIDITY_GRACE_MS)
      end
    elseif name == "peripheral" then
      refreshHardware()
      refreshSensors()
      radio.bindSpeaker(cfg, radioRuntime)
      telemetryDisplay.refresh(telemetryDisplayRuntime, cfg.telemetryDisplay)
    elseif name == "timer" and event[2] == timer then
      local now = util.nowMillis()
      local dtSeconds = util.clamp((now - lastTickAt) / 1000, 0.01, 0.25)
      lastTickAt = now

      local heartbeatLimitMs = math.max(tonumber(cfg.heartbeatTimeoutMs) or 2000, MIN_HEARTBEAT_TIMEOUT_MS)
      if state.armed and not state.linkHold.active and
          (state.lastContactAt == 0 or now - state.lastContactAt > heartbeatLimitMs) then
        enterLinkHold("controller heartbeat timeout (10s no valid controller traffic)")
      end
      if now - state.lastHardwareCheckAt >= 1000 then
        state.lastHardwareCheckAt = now
        refreshHardware()
        if state.armed then
          debounceSafeFault("hardware_validity", not state.hardwareValid,
            "flight I/O became unavailable", now, HARDWARE_VALIDITY_GRACE_MS)
        else
          debounceSafeFault("hardware_validity", false, "", now, HARDWARE_VALIDITY_GRACE_MS)
        end
      end
      local sensorPeriod = tonumber(acfg.samplePeriodMs) or 50
      if now - state.lastSensorReadAt >= sensorPeriod then
        state.lastSensorReadAt = now
        refreshSensors()
      end

      updateFlightAssist(now, dtSeconds)
      updateSafeCentering(now)
      updateOrdinaryOutputs(now)
      reassertPhysicalOutputs(now)
      radio.pump(cfg, radioRuntime)
      if now - state.lastDrawAt >= 250 then
        draw()
        telemetryDisplay.render(telemetryDisplayRuntime, statusPayload(), cfg.telemetryDisplay)
        state.lastDrawAt = now
      end
      timer = os.startTimer(0.05)
    end
  end
end

local function runGpsWorker()
  navigation.gpsWorker(cfg)
end

local ok, err = xpcall(function()
  parallel.waitForAny(run, runGpsWorker)
end, function(value) return tostring(value) end)
assertSafe(ok and "server stopped" or "server crashed")
term.setBackgroundColor(colors.black)
term.setTextColor(ok and colors.yellow or colors.red)
term.clear()
term.setCursorPos(1, 1)
print("AtlasOS server stopped.")
if not ok then printError(err); log.error("Flight server stopped: " .. tostring(err)) end
print("Propulsion locked and physical wheel selected.")