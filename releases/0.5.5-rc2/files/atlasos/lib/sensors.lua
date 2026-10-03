local util = require("atlasos.lib.util")
local navigationProvider = require("atlasos.lib.navigation_provider")

local sensors = {}

local TYPE = {
  altitude = "altitude_sensor",
  gimbal = "gimbal_sensor",
  navigation = "navigation_table",
  steeringWheel = "steering_wheel",
  rudderSwivel = "swivel_bearing",
  rudderMechanical = "Create_MechanicalBearing",
  velocity = "velocity_sensor",
  speedController = "Create_RotationSpeedController",
  assembler = "physics_assembler",
}

local RUDDER_BEARINGS = {
  {
    type = TYPE.rudderSwivel,
    label = "Swivel Bearing",
    angleMethod = "getTargetAngle",
    lockMethod = "isLocked",
  },
  {
    type = TYPE.rudderMechanical,
    label = "Mechanical Bearing",
    angleMethod = "getAngle",
    rotationModeMethod = "getRotationMode",
  },
}

local NOSE = {
  ["+z"] = {
    label = "+Z / south at assembly",
    headingOffset = 0,
    forwardAxis = "z", forwardSign = 1,
    rightAxis = "x", rightSign = 1,
    pitchIndex = 1, pitchSign = 1,
    rollIndex = 2, rollSign = 1,
  },
  ["-z"] = {
    label = "-Z / north at assembly",
    headingOffset = 180,
    forwardAxis = "z", forwardSign = -1,
    rightAxis = "x", rightSign = -1,
    pitchIndex = 1, pitchSign = -1,
    rollIndex = 2, rollSign = -1,
  },
  ["+x"] = {
    label = "+X / east at assembly",
    headingOffset = 90,
    forwardAxis = "x", forwardSign = 1,
    rightAxis = "z", rightSign = -1,
    pitchIndex = 2, pitchSign = -1,
    rollIndex = 1, rollSign = 1,
  },
  ["-x"] = {
    label = "-X / west at assembly",
    headingOffset = -90,
    forwardAxis = "x", forwardSign = -1,
    rightAxis = "z", rightSign = 1,
    pitchIndex = 2, pitchSign = 1,
    rollIndex = 1, rollSign = -1,
  },
}

local function append(list, value)
  list[#list + 1] = tostring(value)
end

local function wrap180(value)
  value = tonumber(value) or 0
  value = (value + 180) % 360
  if value < 0 then value = value + 360 end
  return value - 180
end

local function wrap360(value)
  value = tonumber(value) or 0
  value = value % 360
  if value < 0 then value = value + 360 end
  return value
end

local function angleDelta(value, reference)
  return wrap180((tonumber(value) or 0) - (tonumber(reference) or 0))
end

local function present(name)
  if not name then return false end
  if peripheral.isPresent then return peripheral.isPresent(name) end
  return peripheral.getType(name) ~= nil
end

local function call(name, method, ...)
  if not name then return false, "not mapped" end
  if not present(name) then return false, "peripheral not present: " .. tostring(name) end
  local result = { pcall(peripheral.call, name, method, ...) }
  if not result[1] then return false, result[2] end
  table.remove(result, 1)
  return true, table.unpack(result)
end

local function mappedType(name, wanted)
  return name and present(name) and util.hasPeripheralType(name, wanted)
end

local function rudderProfile(name)
  if not name or not present(name) then return nil end
  for _, profile in ipairs(RUDDER_BEARINGS) do
    if util.hasPeripheralType(name, profile.type) then return profile end
  end
  return nil
end

local function rudderNames()
  local names, seen = {}, {}
  for _, profile in ipairs(RUDDER_BEARINGS) do
    for _, name in ipairs(util.listPeripheralsByType(profile.type)) do
      if not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  return names
end

local function mapOf(cfg)
  cfg.sensors = cfg.sensors or {}
  cfg.sensors.map = cfg.sensors.map or {}
  cfg.sensors.map.velocity = cfg.sensors.map.velocity or {}
  return cfg.sensors.map
end

function sensors.types()
  return util.deepCopy(TYPE)
end

function sensors.noseOptions()
  return util.deepCopy(NOSE)
end

function sensors.wrap180(value)
  return wrap180(value)
end

function sensors.wrap360(value)
  return wrap360(value)
end

function sensors.angleDelta(value, reference)
  return angleDelta(value, reference)
end

function sensors.findByType(wanted)
  return util.listPeripheralsByType(wanted)
end

function sensors.findRudderBearings()
  return rudderNames()
end

function sensors.rudderBearingInfo(name)
  local profile = rudderProfile(name)
  if not profile then return nil end
  return {
    type = profile.type,
    label = profile.label,
    angleMethod = profile.angleMethod,
    hasLock = profile.lockMethod ~= nil,
  }
end

function sensors.readRudderBearingAngle(name)
  local profile = rudderProfile(name)
  if not profile then
    return false, "unsupported rudder bearing: " .. tostring(name)
  end
  return call(name, profile.angleMethod)
end

function sensors.validate(cfg, requireCommissioned, requireRudderCalibration)
  local errors = {}
  local scfg = cfg.sensors or {}
  local map = mapOf(cfg)

  if scfg.configured ~= true then append(errors, "sensor suite is not configured") end
  if requireCommissioned and scfg.commissioned ~= true then append(errors, "sensor suite is not commissioned") end
  if not NOSE[scfg.noseAxis or ""] then append(errors, "invalid Atlas nose-axis setting") end

  local required = {
    { "altitude", map.altitude, TYPE.altitude },
    { "gimbal", map.gimbal, TYPE.gimbal },
    { "navigation", map.navigation, TYPE.navigation },
    { "steering wheel", map.steeringWheel, TYPE.steeringWheel },
    { "velocity X", map.velocity.x, TYPE.velocity },
    { "velocity Y", map.velocity.y, TYPE.velocity },
    { "velocity Z", map.velocity.z, TYPE.velocity },
  }

  for _, item in ipairs(required) do
    if not item[2] then
      append(errors, item[1] .. " is not mapped")
    elseif not mappedType(item[2], item[3]) then
      append(errors, item[1] .. " missing or wrong type: " .. tostring(item[2]))
    end
  end

  if not map.rudderBearing then
    append(errors, "rudder bearing is not mapped")
  elseif not rudderProfile(map.rudderBearing) then
    append(errors, "rudder bearing missing or unsupported type: " .. tostring(map.rudderBearing))
  end

  for _, axis in ipairs({ "x", "y", "z" }) do
    local name = map.velocity[axis]
    if name and mappedType(name, TYPE.velocity) then
      local ok, actualAxis = call(name, "getAxis")
      if not ok then
        append(errors, "velocity " .. axis:upper() .. " unreadable: " .. tostring(actualAxis))
      elseif actualAxis ~= axis then
        append(errors, "velocity " .. axis:upper() .. " map reports axis " .. tostring(actualAxis))
      end
    end
  end

  if map.steeringSpeedController and not mappedType(map.steeringSpeedController, TYPE.speedController) then
    append(errors, "steering speed controller missing or wrong type")
  end
  if map.physicsAssembler and not mappedType(map.physicsAssembler, TYPE.assembler) then
    append(errors, "physics assembler missing or wrong type")
  end

  if requireRudderCalibration and ((scfg.rudder or {}).calibrated ~= true) then
    append(errors, "rudder position is not calibrated")
  end

  return #errors == 0, errors
end

local function readOne(errors, label, name, method, ...)
  local ok, value, second, third, fourth = call(name, method, ...)
  if not ok then
    append(errors, label .. ": " .. tostring(value))
    return nil
  end
  return value, second, third, fourth
end

local function numberAt(value, index)
  if type(value) ~= "table" then return 0 end
  return tonumber(value[index]) or 0
end

function sensors.read(cfg)
  local scfg = cfg.sensors or {}
  local map = mapOf(cfg)
  local transform = NOSE[scfg.noseAxis or "+z"] or NOSE["+z"]
  local errors = {}
  local raw = {}
  local out = {
    sampledAt = util.nowMillis(),
    healthy = false,
    configured = scfg.configured == true,
    commissioned = scfg.commissioned == true,
    noseAxis = scfg.noseAxis or "+z",
    errors = errors,
    valid = {
      altitude = false,
      attitude = false,
      heading = false,
      navigation = false,
      velocity = false,
      wheel = false,
      rudder = false,
      steeringController = false,
    },
  }

  local ok
  ok, raw.altitude = call(map.altitude, "getHeight")
  if not ok then append(errors, "altitude: " .. tostring(raw.altitude)); raw.altitude = nil end
  local okVertical
  okVertical, raw.verticalSpeed = call(map.altitude, "getVerticalSpeed")
  if not okVertical then append(errors, "vertical speed: " .. tostring(raw.verticalSpeed)); raw.verticalSpeed = nil end
  local okPressure
  okPressure, raw.airPressure = call(map.altitude, "getAirPressure")
  if not okPressure then append(errors, "air pressure: " .. tostring(raw.airPressure)); raw.airPressure = nil end
  out.valid.altitude = ok and okVertical and okPressure

  local okAngles, angles = call(map.gimbal, "getAngles")
  if not okAngles then append(errors, "gimbal angles: " .. tostring(angles)); angles = nil end
  local okRates, rates = call(map.gimbal, "getAngularRates")
  if not okRates then append(errors, "gimbal rates: " .. tostring(rates)); rates = nil end
  raw.pitchX = numberAt(angles, 1)
  raw.rollZ = numberAt(angles, 2)
  raw.rateX = numberAt(rates, 1)
  raw.rateY = numberAt(rates, 2)
  raw.rateZ = numberAt(rates, 3)
  out.valid.attitude = okAngles and okRates

  local okHeading
  okHeading, raw.heading = call(map.navigation, "getHeading")
  if not okHeading then append(errors, "heading: " .. tostring(raw.heading)); raw.heading = nil end
  out.valid.heading = okHeading

  local velocity = {}
  local velocityOkay = true
  for _, axis in ipairs({ "x", "y", "z" }) do
    local okVelocity, value = call(map.velocity[axis], "getVelocity")
    if not okVelocity then
      append(errors, "velocity " .. axis:upper() .. ": " .. tostring(value))
      value = nil
      velocityOkay = false
    end
    velocity[axis] = value
  end
  raw.velocity = velocity
  out.valid.velocity = velocityOkay

  out.heading = wrap360((tonumber(raw.heading) or 0) + transform.headingOffset)
  out.rawHeading = tonumber(raw.heading) or 0

  local navSample = navigationProvider.sample(cfg, out.heading, velocity)
  out.navigationSource = navSample.source
  out.hasTarget = navSample.hasTarget == true
  out.valid.navigation = okHeading and navSample.valid == true
  if navSample.position then out.position = util.deepCopy(navSample.position) end
  if not navSample.valid then append(errors, "navigation: " .. tostring(navSample.error or "provider unavailable")) end
  if out.hasTarget then
    raw.bearing = navSample.bearing
    raw.distance = navSample.distance
    raw.closureRate = navSample.closureRate
    raw.verticalOffset = navSample.verticalOffset
    out.horizontalDistance = tonumber(navSample.horizontalDistance)
    out.targetType = navSample.targetType
  end

  local okHeld
  okHeld, raw.wheelHeld = call(map.steeringWheel, "isHeld")
  if not okHeld then append(errors, "steering wheel held: " .. tostring(raw.wheelHeld)); raw.wheelHeld = false end
  local okWheelAngle
  okWheelAngle, raw.wheelAngle = call(map.steeringWheel, "getAngle")
  if not okWheelAngle then append(errors, "steering wheel angle: " .. tostring(raw.wheelAngle)); raw.wheelAngle = nil end
  local okWheelTarget
  okWheelTarget, raw.wheelTargetAngle = call(map.steeringWheel, "getTargetAngle")
  if not okWheelTarget then append(errors, "steering wheel target: " .. tostring(raw.wheelTargetAngle)); raw.wheelTargetAngle = nil end
  local okWheelMax
  okWheelMax, raw.wheelMaxAngle = call(map.steeringWheel, "getMaxAngle")
  if not okWheelMax then append(errors, "steering wheel maximum: " .. tostring(raw.wheelMaxAngle)); raw.wheelMaxAngle = nil end
  local okWheelNorm
  okWheelNorm, raw.wheelNormalized = call(map.steeringWheel, "getNormalizedAngle")
  if not okWheelNorm then append(errors, "steering wheel normalized: " .. tostring(raw.wheelNormalized)); raw.wheelNormalized = nil end
  out.valid.wheel = okHeld and okWheelAngle and okWheelTarget and okWheelMax and okWheelNorm

  local rudderBearing = rudderProfile(map.rudderBearing)
  if rudderBearing then
    local okAngle, bearingAngle = call(map.rudderBearing, rudderBearing.angleMethod)
    if okAngle then
      raw.rudderAngle = bearingAngle
    else
      append(errors, "rudder bearing angle: " .. tostring(bearingAngle))
    end

    local okAssembled
    okAssembled, raw.rudderAssembled = call(map.rudderBearing, "isAssembled")
    if not okAssembled then
      append(errors, "rudder bearing assembly: " .. tostring(raw.rudderAssembled))
      raw.rudderAssembled = false
    end
    out.rudderBearingType = rudderBearing.type
    out.rudderBearingLabel = rudderBearing.label
    out.valid.rudder = okAngle and okAssembled

    if rudderBearing.lockMethod then
      local okLock, lock = call(map.rudderBearing, rudderBearing.lockMethod)
      if okLock then raw.rudderLocked = lock end
    end
    if rudderBearing.rotationModeMethod then
      local okMode, mode = call(map.rudderBearing, rudderBearing.rotationModeMethod)
      if okMode then raw.rudderRotationMode = mode end
    end
  else
    append(errors, "rudder bearing: unsupported or not present")
  end

  if map.steeringSpeedController and mappedType(map.steeringSpeedController, TYPE.speedController) then
    local okTarget, targetRpm = call(map.steeringSpeedController, "getTargetSpeed")
    if okTarget then raw.steeringTargetRpm = targetRpm
    else append(errors, "steering target RPM: " .. tostring(targetRpm)) end
    local okLive, liveRpm = call(map.steeringSpeedController, "getSpeed")
    if okLive then raw.steeringLiveRpm = liveRpm
    else append(errors, "steering live RPM: " .. tostring(liveRpm)) end
    local okSource, source = call(map.steeringSpeedController, "hasSource")
    if okSource then raw.steeringHasSource = source == true
    else append(errors, "steering source state: " .. tostring(source)) end
    local okStress, overstressed = call(map.steeringSpeedController, "isOverstressed")
    if okStress then raw.steeringOverstressed = overstressed == true
    else append(errors, "steering stress state: " .. tostring(overstressed)) end
    out.valid.steeringController = okTarget and okLive and okSource and okStress
  end

  out.altitude = tonumber(raw.altitude) or 0
  out.verticalSpeed = tonumber(raw.verticalSpeed) or 0
  out.airPressure = tonumber(raw.airPressure) or 0
  out.pitch = (transform.pitchIndex == 1 and raw.pitchX or raw.rollZ) * transform.pitchSign
  out.roll = (transform.rollIndex == 1 and raw.pitchX or raw.rollZ) * transform.rollSign
  out.pitchRate = (transform.pitchIndex == 1 and raw.rateX or raw.rateZ) * transform.pitchSign
  out.rollRate = (transform.rollIndex == 1 and raw.rateX or raw.rateZ) * transform.rollSign
  out.yawRate = raw.rateY

  local forwardRaw = tonumber(velocity[transform.forwardAxis]) or 0
  local rightRaw = tonumber(velocity[transform.rightAxis]) or 0
  out.forwardSpeed = forwardRaw * transform.forwardSign
  out.rightSpeed = rightRaw * transform.rightSign
  out.verticalBodySpeed = tonumber(velocity.y) or 0
  out.horizontalSpeed = math.sqrt(out.forwardSpeed * out.forwardSpeed + out.rightSpeed * out.rightSpeed)
  out.totalSpeed = math.sqrt(out.horizontalSpeed * out.horizontalSpeed + out.verticalBodySpeed * out.verticalBodySpeed)

  out.wheelHeld = raw.wheelHeld == true
  out.wheelAngle = tonumber(raw.wheelAngle) or 0
  out.wheelTargetAngle = tonumber(raw.wheelTargetAngle) or 0
  out.wheelMaxAngle = tonumber(raw.wheelMaxAngle) or 0
  out.wheelNormalized = tonumber(raw.wheelNormalized) or 0

  out.rudderBearingAngle = tonumber(raw.rudderAngle) or 0
  out.rudderAssembled = raw.rudderAssembled == true
  if raw.rudderLocked == nil then out.rudderLocked = nil
  else out.rudderLocked = raw.rudderLocked == true end
  out.rudderRotationMode = raw.rudderRotationMode
  out.steeringTargetRpm = tonumber(raw.steeringTargetRpm)
  out.steeringLiveRpm = tonumber(raw.steeringLiveRpm)
  out.steeringHasSource = raw.steeringHasSource == true
  out.steeringOverstressed = raw.steeringOverstressed == true

  local rudderCfg = scfg.rudder or {}
  if rudderCfg.calibrated and rudderCfg.zeroAngle ~= nil then
    local delta = angleDelta(out.rudderBearingAngle, rudderCfg.zeroAngle)
    out.rudderAngle = delta
    local leftDelta = tonumber(rudderCfg.leftDelta)
    local rightDelta = tonumber(rudderCfg.rightDelta)
    if leftDelta and rightDelta and math.abs(leftDelta) > 0.1 and math.abs(rightDelta) > 0.1 then
      if delta * leftDelta > 0 then
        out.rudderNormalized = -util.clamp(math.abs(delta / leftDelta), 0, 1.5)
      elseif delta * rightDelta > 0 then
        out.rudderNormalized = util.clamp(math.abs(delta / rightDelta), 0, 1.5)
      else
        out.rudderNormalized = 0
      end
    else
      out.rudderNormalized = 0
    end
  else
    out.rudderAngle = nil
    out.rudderNormalized = nil
  end

  if out.hasTarget then
    out.bearing = tonumber(raw.bearing) or 0
    out.distance = tonumber(raw.distance) or 0
    out.closureRate = tonumber(raw.closureRate) or 0
    out.verticalOffset = tonumber(raw.verticalOffset) or 0
  end

  out.raw = raw
  out.healthy = #errors == 0
  return out
end

function sensors.describe(cfg)
  local scfg = cfg.sensors or {}
  local map = mapOf(cfg)
  local lines = {}
  local nose = NOSE[scfg.noseAxis or ""]

  append(lines, "Configured: " .. tostring(scfg.configured == true))
  append(lines, "Commissioned: " .. tostring(scfg.commissioned == true))
  append(lines, "Nose axis: " .. tostring(scfg.noseAxis or "not set")
    .. (nose and (" (" .. nose.label .. ")") or ""))
  append(lines, "")
  append(lines, "Altitude: " .. tostring(map.altitude or "not mapped"))
  append(lines, "Gimbal: " .. tostring(map.gimbal or "not mapped"))
  append(lines, "Navigation: " .. tostring(map.navigation or "not mapped"))
  append(lines, "Steering wheel: " .. tostring(map.steeringWheel or "not mapped"))
  local rbInfo = rudderProfile(map.rudderBearing)
  append(lines, "Rudder bearing: " .. tostring(map.rudderBearing or "not mapped")
    .. (rbInfo and (" (" .. rbInfo.label .. ")") or ""))
  append(lines, "Velocity X: " .. tostring(map.velocity.x or "not mapped"))
  append(lines, "Velocity Y: " .. tostring(map.velocity.y or "not mapped"))
  append(lines, "Velocity Z: " .. tostring(map.velocity.z or "not mapped"))
  append(lines, "Steer speed ctrl: " .. tostring(map.steeringSpeedController or "not mapped (REQUIRED for Day 2)"))
  append(lines, "Physics assembler: " .. tostring(map.physicsAssembler or "not mapped (optional)"))
  append(lines, "")
  append(lines, "Steering baseline: " .. tostring(scfg.steeringActuatorRpm or 16) .. " RPM")
  local rcfg = scfg.rudder or {}
  append(lines, "Rudder calibrated: " .. tostring(rcfg.calibrated == true))
  if rcfg.calibrated then
    append(lines, string.format("Rudder zero: %.2f deg", tonumber(rcfg.zeroAngle) or 0))
    append(lines, string.format("Full left delta: %.2f deg", tonumber(rcfg.leftDelta) or 0))
    append(lines, string.format("Full right delta: %.2f deg", tonumber(rcfg.rightDelta) or 0))
  end
  return lines
end

function sensors.formatNumber(value, decimals, suffix)
  if value == nil then return "-" end
  local format = "%." .. tostring(decimals or 1) .. "f"
  return string.format(format, tonumber(value) or 0) .. tostring(suffix or "")
end

return sensors
