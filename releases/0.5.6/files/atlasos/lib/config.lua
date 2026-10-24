local util = require("atlasos.lib.util")
local settings = require("atlasos.lib.settings")

local config = {}
local path = "/atlasos/config.db"

local defaults = {
  installed = true,
  role = nil,
  name = "Vessel",
  safe = true,
  armed = false,
  lastSafeReason = "initial installation",
  pairingOpen = false,
  pairingPinHash = nil,
  pairedPocketId = nil,
  serverId = nil,
  serverName = "Vessel",
  token = nil,
  operatorPinHash = nil,
  heartbeatTimeoutMs = 2000,
  liftRampMs = 150,
  thrustRampMs = 100,
  hardware = {
    configured = false,
    commissioned = false,
    powerRelay = nil,
    steeringRelay = nil,
    gyroSafe = false,
    liftSignalZero = 0,
    liftSignalFull = 15,
    thrustSignalZero = 0,
    thrustSignalFull = 15,
    outputs = {},
  },
  control = {
    lift = 0,
    thrust = 0,
    reverse = false,
    gyro = false,
    rudder = 0,
  },
  sensors = {
    configured = false,
    commissioned = false,
    noseAxis = "+z",
    samplePeriodMs = 200,
    steeringActuatorRpm = 16,
    map = {
      altitude = nil,
      gimbal = nil,
      navigation = nil,
      steeringWheel = nil,
      rudderBearing = nil,
      steeringSpeedController = nil,
      physicsAssembler = nil,
      velocity = {
        x = nil,
        y = nil,
        z = nil,
      },
    },
    rudder = {
      calibrated = false,
      zeroAngle = nil,
      leftDelta = nil,
      rightDelta = nil,
      centreTolerance = 4,
    },
  },
  autoflight = {
    configured = false,
    commissioned = false,
    samplePeriodMs = 50,
    wheelOverrideThreshold = 0.08,
    rudder = {
      trueCentreAngle = 0,
      toleranceDeg = 0.65,
      crawlZoneDeg = 2.5,
      slowZoneDeg = 9,
      crawlRpm = 1,
      slowRpm = 5,
      fastRpm = 16,
      jogRateDegPerSec = 55,
      maxAssistDeg = 35,
      stallTimeoutMs = 1600,
      movementThresholdDeg = 0.12,
      wheelLeftSign = nil,
      leftOutputCommand = nil,
    },
    heading = {
      kp = 0.72,
      kd = 1.15,
      deadbandDeg = 0.8,
      maxRudderDeg = 30,
    },
    navigation = {
      kp = 0.62,
      kd = 1.15,
      deadbandDeg = 1.2,
      maxRudderDeg = 35,
      arrivalRadius = 8,
      targetLossMs = 1200,
    },
    altitude = {
      kp = 0.16,
      ki = 0.012,
      kd = 0.45,
      deadbandM = 0.35,
      maxCorrection = 4,
      integralLimit = 100,
      outputIntervalMs = 350,
    },
  },
}

defaults = util.deepMerge(defaults, settings.defaults())

function config.defaults()
  return util.deepCopy(defaults)
end

function config.load()
  local saved = {}
  if fs.exists(path) and not fs.isDir(path) then
    local raw = util.readAll(path)
    local decoded = raw and textutils.unserialize(raw) or nil
    if type(decoded) == "table" then saved = decoded end
  end
  local result = util.deepMerge(defaults, saved)
  settings.ensure(result)
  -- No flight-control process may survive a restart in ARMED state.
  result.armed = false
  return result
end

function config.save(value)
  local encoded = textutils.serialize(value, { compact = true })
  return util.atomicWrite(path, encoded)
end

function config.path()
  return path
end

return config
