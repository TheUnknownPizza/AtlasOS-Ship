local util = require("atlasos.lib.util")
local sensors = require("atlasos.lib.sensors")

local assist = {}

local DEFAULTS = {
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
}

local function sign(value)
  value = tonumber(value) or 0
  if value < 0 then return -1 end
  if value > 0 then return 1 end
  return 0
end

local function append(list, value)
  list[#list + 1] = tostring(value)
end

function assist.defaults()
  return util.deepCopy(DEFAULTS)
end

function assist.ensureConfig(cfg)
  -- Preserve the existing table identity. Setup and commissioning keep a
  -- reference to this table while helper functions may call ensureConfig again.
  local existing = type(cfg.autoflight) == "table" and cfg.autoflight or nil
  local merged = util.deepMerge(DEFAULTS, existing or {})
  if not existing then
    cfg.autoflight = merged
    return cfg.autoflight
  end
  for key in pairs(existing) do existing[key] = nil end
  for key, value in pairs(merged) do existing[key] = value end
  cfg.autoflight = existing
  return existing
end

function assist.validate(cfg, requireCommissioned)
  local errors = {}
  local acfg = assist.ensureConfig(cfg)
  local scfg = cfg.sensors or {}
  local rcal = scfg.rudder or {}
  local map = scfg.map or {}

  if acfg.configured ~= true then append(errors, "flight assist is not configured") end
  if requireCommissioned and acfg.commissioned ~= true then append(errors, "flight assist is not commissioned") end
  if scfg.commissioned ~= true then append(errors, "Volume III Day 1 instruments are not commissioned") end
  if rcal.calibrated ~= true then append(errors, "rudder position is not calibrated") end
  if not map.steeringSpeedController then append(errors, "steering Rotation Speed Controller is not mapped") end
  if not acfg.rudder.wheelLeftSign or math.abs(tonumber(acfg.rudder.wheelLeftSign) or 0) ~= 1 then
    if requireCommissioned then append(errors, "physical wheel left-sign is not commissioned") end
  end
  if not acfg.rudder.leftOutputCommand or math.abs(tonumber(acfg.rudder.leftOutputCommand) or 0) ~= 1 then
    if requireCommissioned then append(errors, "automatic steering direction is not commissioned") end
  end

  local numeric = {
    { "rudder tolerance", acfg.rudder.toleranceDeg, 0.2, 5 },
    { "rudder crawl RPM", acfg.rudder.crawlRpm, 0.5, 16 },
    { "rudder slow RPM", acfg.rudder.slowRpm, 1, 16 },
    { "rudder fast RPM", acfg.rudder.fastRpm, 1, 64 },
    { "rudder maximum assist", acfg.rudder.maxAssistDeg, 2, 80 },
    { "rudder crawl zone", acfg.rudder.crawlZoneDeg, 0.5, 10 },
    { "rudder slow zone", acfg.rudder.slowZoneDeg, 1, 30 },
    { "wheel override threshold", acfg.wheelOverrideThreshold, 0.02, 0.5 },
    { "heading Kp", acfg.heading.kp, 0, 5 },
    { "heading Kd", acfg.heading.kd, 0, 10 },
    { "heading maximum rudder", acfg.heading.maxRudderDeg, 2, 80 },
    { "navigation Kp", acfg.navigation.kp, 0, 5 },
    { "navigation Kd", acfg.navigation.kd, 0, 10 },
    { "navigation maximum rudder", acfg.navigation.maxRudderDeg, 2, 80 },
    { "navigation arrival radius", acfg.navigation.arrivalRadius, 2, 100 },
    { "altitude Kp", acfg.altitude.kp, 0, 3 },
    { "altitude Ki", acfg.altitude.ki, 0, 1 },
    { "altitude Kd", acfg.altitude.kd, 0, 10 },
    { "altitude maximum correction", acfg.altitude.maxCorrection, 1, 8 },
  }
  for _, item in ipairs(numeric) do
    local value = tonumber(item[2])
    if not value or value < item[3] or value > item[4] then
      append(errors, item[1] .. " is outside its safe configuration range")
    end
  end

  local geometry = assist.rudderGeometry(cfg)
  if not geometry.ok then append(errors, geometry.error) end
  if geometry.ok and tonumber(acfg.rudder.maxAssistDeg) > math.min(geometry.leftMagnitude, geometry.rightMagnitude) then
    append(errors, "maximum assist deflection exceeds a calibrated rudder endpoint")
  end
  if tonumber(acfg.heading.maxRudderDeg) > tonumber(acfg.rudder.maxAssistDeg) then
    append(errors, "heading maximum rudder exceeds the automatic rudder limit")
  end
  if tonumber(acfg.navigation.maxRudderDeg) > tonumber(acfg.rudder.maxAssistDeg) then
    append(errors, "navigation maximum rudder exceeds the automatic rudder limit")
  end
  if tonumber(acfg.rudder.crawlRpm) > tonumber(acfg.rudder.slowRpm) or
      tonumber(acfg.rudder.slowRpm) > tonumber(acfg.rudder.fastRpm) then
    append(errors, "rudder RPM stages must satisfy crawl <= slow <= fast")
  end
  if tonumber(acfg.rudder.crawlZoneDeg) > tonumber(acfg.rudder.slowZoneDeg) then
    append(errors, "rudder crawl zone must not exceed the slow zone")
  end

  return #errors == 0, errors
end

function assist.rudderGeometry(cfg)
  local acfg = assist.ensureConfig(cfg)
  local rcal = ((cfg.sensors or {}).rudder or {})
  if rcal.calibrated ~= true or rcal.zeroAngle == nil or rcal.leftDelta == nil or rcal.rightDelta == nil then
    return { ok = false, error = "rudder calibration is incomplete" }
  end

  local trueCentre = tonumber(acfg.rudder.trueCentreAngle) or 0
  local capturedCentre = tonumber(rcal.zeroAngle) or 0
  local leftAbsolute = capturedCentre + (tonumber(rcal.leftDelta) or 0)
  local rightAbsolute = capturedCentre + (tonumber(rcal.rightDelta) or 0)
  local leftSpan = sensors.angleDelta(leftAbsolute, trueCentre)
  local rightSpan = sensors.angleDelta(rightAbsolute, trueCentre)

  if math.abs(leftSpan) < 2 or math.abs(rightSpan) < 2 then
    return { ok = false, error = "calibrated rudder travel is too small" }
  end
  if leftSpan * rightSpan >= 0 then
    return { ok = false, error = "calibrated left and right endpoints do not straddle true centre" }
  end

  return {
    ok = true,
    trueCentre = trueCentre,
    capturedCentre = capturedCentre,
    leftAbsolute = leftAbsolute,
    rightAbsolute = rightAbsolute,
    leftSpan = leftSpan,
    rightSpan = rightSpan,
    leftSign = sign(leftSpan),
    rightSign = sign(rightSpan),
    leftMagnitude = math.abs(leftSpan),
    rightMagnitude = math.abs(rightSpan),
  }
end

function assist.bearingToSemantic(cfg, bearingAngle)
  local geometry = assist.rudderGeometry(cfg)
  if not geometry.ok then return nil, geometry.error end
  local raw = sensors.angleDelta(tonumber(bearingAngle) or 0, geometry.trueCentre)
  if math.abs(raw) < 0.0001 then return 0 end
  if sign(raw) == geometry.leftSign then return -math.abs(raw) end
  if sign(raw) == geometry.rightSign then return math.abs(raw) end
  return 0
end

function assist.clampSemantic(cfg, semanticDeg, useAssistLimit)
  local geometry = assist.rudderGeometry(cfg)
  if not geometry.ok then return 0, geometry.error end
  local acfg = assist.ensureConfig(cfg)
  local leftLimit = geometry.leftMagnitude
  local rightLimit = geometry.rightMagnitude
  if useAssistLimit then
    local maximum = tonumber(acfg.rudder.maxAssistDeg) or math.min(leftLimit, rightLimit)
    leftLimit = math.min(leftLimit, maximum)
    rightLimit = math.min(rightLimit, maximum)
  end
  return util.clamp(tonumber(semanticDeg) or 0, -leftLimit, rightLimit)
end

function assist.semanticToBearing(cfg, semanticDeg, useAssistLimit)
  local geometry = assist.rudderGeometry(cfg)
  if not geometry.ok then return nil, geometry.error end
  local semantic = assist.clampSemantic(cfg, semanticDeg, useAssistLimit)
  if semantic < 0 then
    return geometry.trueCentre + geometry.leftSign * math.abs(semantic)
  elseif semantic > 0 then
    return geometry.trueCentre + geometry.rightSign * math.abs(semantic)
  end
  return geometry.trueCentre
end

function assist.wheelToSemantic(cfg, normalized)
  local acfg = assist.ensureConfig(cfg)
  local geometry = assist.rudderGeometry(cfg)
  if not geometry.ok then return nil, geometry.error end
  local leftSign = tonumber(acfg.rudder.wheelLeftSign)
  if leftSign ~= -1 and leftSign ~= 1 then return nil, "wheel left-sign is not commissioned" end
  normalized = util.clamp(tonumber(normalized) or 0, -1, 1)
  local magnitude = normalized * leftSign
  if magnitude > 0 then
    return -geometry.leftMagnitude * math.abs(normalized)
  elseif magnitude < 0 then
    return geometry.rightMagnitude * math.abs(normalized)
  end
  return 0
end

function assist.headingErrorRight(currentHeading, targetHeading)
  -- Navigation Table heading is atan2(x, z): increasing heading is a LEFT yaw.
  -- AtlasOS semantic steering is right-positive, so reverse the heading delta.
  return sensors.wrap180((tonumber(currentHeading) or 0) - (tonumber(targetHeading) or 0))
end

function assist.computeHeadingRudder(cfg, telemetry, targetHeading)
  local acfg = assist.ensureConfig(cfg)
  local errorRight = assist.headingErrorRight(telemetry.heading, targetHeading)
  local yawRate = tonumber(telemetry.yawRate) or 0
  local command = acfg.heading.kp * errorRight + acfg.heading.kd * yawRate
  if math.abs(errorRight) <= acfg.heading.deadbandDeg and math.abs(yawRate) <= 0.35 then command = 0 end
  return util.clamp(command, -acfg.heading.maxRudderDeg, acfg.heading.maxRudderDeg), errorRight
end

function assist.computeNavigationRudder(cfg, telemetry)
  local acfg = assist.ensureConfig(cfg)

  -- v0.5.2-r2:
  -- Navigation Table bearing follows the same left-positive angular convention
  -- as its heading. AtlasOS semantic rudder demand is right-positive.
  --
  -- Convert the raw bearing to a wrapped right-positive error before applying
  -- the controller. Without this inversion a target to starboard produces a
  -- port rudder command and Atlas attempts the scenic 360-degree route.
  local rawBearing = sensors.wrap180(tonumber(telemetry.bearing) or 0)
  local errorRight = -rawBearing
  local yawRate = tonumber(telemetry.yawRate) or 0
  local command = acfg.navigation.kp * errorRight + acfg.navigation.kd * yawRate

  if math.abs(errorRight) <= acfg.navigation.deadbandDeg and math.abs(yawRate) <= 0.35 then
    command = 0
  end

  return util.clamp(command, -acfg.navigation.maxRudderDeg, acfg.navigation.maxRudderDeg), errorRight
end

function assist.newAltitudeState(currentAltitude, currentLift)
  return {
    target = tonumber(currentAltitude) or 0,
    trim = util.clamp(util.round(currentLift), 0, 15),
    integral = 0,
    lastOutputAt = 0,
  }
end

function assist.computeAltitudeLift(cfg, telemetry, altitudeState, dtSeconds)
  local acfg = assist.ensureConfig(cfg)
  local alt = acfg.altitude
  altitudeState = altitudeState or assist.newAltitudeState(telemetry.altitude, 0)
  dtSeconds = util.clamp(tonumber(dtSeconds) or 0.05, 0.01, 1)

  local error = (tonumber(altitudeState.target) or 0) - (tonumber(telemetry.altitude) or 0)
  local verticalSpeed = tonumber(telemetry.verticalSpeed) or 0
  if math.abs(error) < alt.deadbandM then error = 0 end

  altitudeState.integral = util.clamp((tonumber(altitudeState.integral) or 0) + error * dtSeconds,
    -alt.integralLimit, alt.integralLimit)

  local correction = alt.kp * error + alt.ki * altitudeState.integral - alt.kd * verticalSpeed
  correction = util.clamp(correction, -alt.maxCorrection, alt.maxCorrection)
  local requested = util.clamp(util.round((tonumber(altitudeState.trim) or 0) + correction), 0, 15)
  return requested, error, correction, altitudeState
end

function assist.rudderSpeedForError(cfg, errorMagnitude)
  local acfg = assist.ensureConfig(cfg)
  local rudder = acfg.rudder
  errorMagnitude = math.abs(tonumber(errorMagnitude) or 0)
  if errorMagnitude <= rudder.toleranceDeg then return 0 end
  if errorMagnitude <= rudder.crawlZoneDeg then return rudder.crawlRpm end
  if errorMagnitude <= rudder.slowZoneDeg then return rudder.slowRpm end
  return rudder.fastRpm
end

function assist.computeRudderActuation(cfg, telemetry, targetSemanticDeg)
  local acfg = assist.ensureConfig(cfg)
  local current, err = assist.bearingToSemantic(cfg, telemetry.rudderBearingAngle)
  if current == nil then return nil, err end
  local target = assist.clampSemantic(cfg, targetSemanticDeg, false)
  local error = target - current
  local command = 0
  if math.abs(error) > acfg.rudder.toleranceDeg then
    local leftOutput = tonumber(acfg.rudder.leftOutputCommand)
    if leftOutput ~= -1 and leftOutput ~= 1 then return nil, "automatic steering direction is not commissioned" end
    command = error < 0 and leftOutput or -leftOutput
  end
  return {
    currentSemantic = current,
    targetSemantic = target,
    errorSemantic = error,
    command = command,
    rpm = assist.rudderSpeedForError(cfg, error),
    reached = command == 0,
  }
end

function assist.describe(cfg)
  local acfg = assist.ensureConfig(cfg)
  local geometry = assist.rudderGeometry(cfg)
  local lines = {}
  append(lines, "Configured: " .. tostring(acfg.configured == true))
  append(lines, "Commissioned: " .. tostring(acfg.commissioned == true))
  append(lines, "Sensor period: " .. tostring(acfg.samplePeriodMs) .. " ms")
  append(lines, "True rudder centre: " .. string.format("%.2f deg", tonumber(acfg.rudder.trueCentreAngle) or 0))
  append(lines, "Wheel override threshold: " .. string.format("%.2f", tonumber(acfg.wheelOverrideThreshold) or 0))
  append(lines, "Automatic rudder limit: +/-" .. string.format("%.1f deg", tonumber(acfg.rudder.maxAssistDeg) or 0))
  append(lines, "Rudder speeds: " .. tostring(acfg.rudder.crawlRpm) .. "/" .. tostring(acfg.rudder.slowRpm)
    .. "/" .. tostring(acfg.rudder.fastRpm) .. " RPM")
  append(lines, "Wheel left sign: " .. tostring(acfg.rudder.wheelLeftSign or "not commissioned"))
  append(lines, "Left output command: " .. tostring(acfg.rudder.leftOutputCommand or "not commissioned"))
  if geometry.ok then
    append(lines, string.format("Safe physical travel: left %.2f / right %.2f deg",
      geometry.leftMagnitude, geometry.rightMagnitude))
  else
    append(lines, "Rudder geometry: " .. tostring(geometry.error))
  end
  append(lines, "")
  append(lines, string.format("Heading gains: Kp %.3f / Kd %.3f / max %.1f deg",
    acfg.heading.kp, acfg.heading.kd, acfg.heading.maxRudderDeg))
  append(lines, string.format("Navigation gains: Kp %.3f / Kd %.3f / max %.1f deg",
    acfg.navigation.kp, acfg.navigation.kd, acfg.navigation.maxRudderDeg))
  append(lines, string.format("Altitude gains: Kp %.3f / Ki %.3f / Kd %.3f / max correction %.1f",
    acfg.altitude.kp, acfg.altitude.ki, acfg.altitude.kd, acfg.altitude.maxCorrection))
  return lines
end

return assist
