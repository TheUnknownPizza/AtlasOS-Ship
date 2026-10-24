local util = require("atlasos.lib.util")

local provider = {}

local GPS_FIX_MAX_AGE_MS = 2500
local SOURCE_RECHECK_MS = 250
local GPS_TIMEOUT_SECONDS = 0.35
local GPS_RETRY_SECONDS = 0.20
local GPS_IDLE_SECONDS = 1.00

local runtime = {
  activeSource = nil,
  sourceLocked = false,
  lastSourceCheckAt = 0,
  sourceReason = "not selected",
  gps = {
    x = nil,
    y = nil,
    z = nil,
    fixedAt = 0,
    lastAttemptAt = 0,
    lastError = "GPS has not been sampled",
  },
}

local function now()
  return util.nowMillis()
end

local function finite(value)
  value = tonumber(value)
  return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
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

local function atan2(y, x)
  y, x = tonumber(y) or 0, tonumber(x) or 0
  if x > 0 then return math.atan(y / x) end
  if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
  if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
  if x == 0 and y > 0 then return math.pi / 2 end
  if x == 0 and y < 0 then return -math.pi / 2 end
  return 0
end

local function navcfg(cfg)
  cfg.navigation = type(cfg.navigation) == "table" and cfg.navigation or {}
  local source = tostring(cfg.navigation.source or "auto")
  if source ~= "auto" and source ~= "nav_table" and source ~= "gps" then source = "auto" end
  cfg.navigation.source = source
  return cfg.navigation
end

local function peripheralName(cfg)
  return ((((cfg or {}).sensors or {}).map or {}).navigation)
end

local function methodSet(name)
  local methods = {}
  if not name or not peripheral.isPresent(name) then return methods end
  local ok, values = pcall(peripheral.getMethods, name)
  if not ok or type(values) ~= "table" then return methods end
  for _, method in ipairs(values) do methods[tostring(method)] = true end
  return methods
end

function provider.navTableCompatibility(cfg)
  local name = peripheralName(cfg)
  if not name then return false, "Navigation Table is not mapped" end
  if not peripheral.isPresent(name) then return false, "Navigation Table peripheral is unavailable" end
  local methods = methodSet(name)
  for _, required in ipairs({ "atlasSetTarget", "atlasClearTarget", "atlasGetTarget", "atlasHasTarget" }) do
    if not methods[required] then
      return false, "Atlas Navigation Compatibility mod is missing or too old"
    end
  end
  return true, name
end

local function normaliseTarget(value)
  if type(value) ~= "table" then return nil end
  if value.active == false then return nil end
  if not finite(value.x) or not finite(value.z) then return nil end
  local target = {
    active = true,
    label = tostring(value.label or "Destination"),
    x = tonumber(value.x),
    z = tonumber(value.z),
  }
  if finite(value.y) then target.y = tonumber(value.y) end
  return target
end

function provider.readNavTableTarget(cfg)
  local compatible, nameOrError = provider.navTableCompatibility(cfg)
  if not compatible then return nil, nameOrError end
  local ok, value = pcall(peripheral.call, nameOrError, "atlasGetTarget")
  if not ok then return nil, tostring(value) end
  if type(value) ~= "table" then return nil, "Navigation Table returned an invalid navigation target" end
  if value.active ~= true then return { active = false }, nil end
  local target = normaliseTarget(value)
  if not target then return nil, "Navigation Table returned malformed target coordinates" end
  return target, nil
end

function provider.writeNavTableTarget(cfg, target)
  local compatible, nameOrError = provider.navTableCompatibility(cfg)
  if not compatible then return false, nameOrError end
  target = normaliseTarget(target)
  if not target then return false, "Invalid target" end
  local methods = methodSet(nameOrError)
  local ok, callError
  if target.y ~= nil then
    if not methods.atlasSetTarget3D then return false, "Atlas Navigation Compatibility does not support 3D targets" end
    ok, callError = pcall(peripheral.call, nameOrError, "atlasSetTarget3D", target.x, target.y, target.z, target.label)
  else
    ok, callError = pcall(peripheral.call, nameOrError, "atlasSetTarget", target.x, target.z, target.label)
  end
  if not ok then return false, tostring(callError) end
  return true
end

function provider.clearNavTableTarget(cfg)
  local compatible, nameOrError = provider.navTableCompatibility(cfg)
  if not compatible then return false, nameOrError end
  local ok, callError = pcall(peripheral.call, nameOrError, "atlasClearTarget")
  if not ok then return false, tostring(callError) end
  return true
end

local function gpsAgeMs()
  if runtime.gps.fixedAt <= 0 then return nil end
  return math.max(0, now() - runtime.gps.fixedAt)
end

function provider.gpsAvailable()
  local age = gpsAgeMs()
  return age ~= nil and age <= GPS_FIX_MAX_AGE_MS
end

function provider.gpsStatus()
  return {
    available = provider.gpsAvailable(),
    x = runtime.gps.x,
    y = runtime.gps.y,
    z = runtime.gps.z,
    ageMs = gpsAgeMs(),
    lastAttemptAt = runtime.gps.lastAttemptAt,
    lastError = runtime.gps.lastError,
  }
end

function provider.pollGpsOnce()
  runtime.gps.lastAttemptAt = now()
  if type(gps) ~= "table" or type(gps.locate) ~= "function" then
    runtime.gps.lastError = "CC GPS API unavailable"
    return false, runtime.gps.lastError
  end

  local ok, x, y, z = pcall(gps.locate, GPS_TIMEOUT_SECONDS, false)
  if not ok then
    runtime.gps.lastError = tostring(x)
    return false, runtime.gps.lastError
  end
  if not finite(x) or not finite(y) or not finite(z) then
    runtime.gps.lastError = "No GPS fix"
    return false, runtime.gps.lastError
  end

  runtime.gps.x = tonumber(x)
  runtime.gps.y = tonumber(y)
  runtime.gps.z = tonumber(z)
  runtime.gps.fixedAt = now()
  runtime.gps.lastError = nil
  return true
end

local function chooseSource(cfg)
  local preference = navcfg(cfg).source
  local tableOkay, tableWhy = provider.navTableCompatibility(cfg)
  local gpsOkay = provider.gpsAvailable()

  if preference == "nav_table" then
    if tableOkay then return "nav_table", "Navigation Table forced" end
    return nil, tableWhy
  elseif preference == "gps" then
    if gpsOkay then return "gps", "GPS forced" end
    return nil, runtime.gps.lastError or "GPS fix unavailable"
  end

  if tableOkay then return "nav_table", "AUTO selected Navigation Table" end
  if gpsOkay then return "gps", "AUTO fallback selected GPS" end
  return nil, tableWhy or runtime.gps.lastError or "No navigation provider available"
end

local function storedTarget(cfg)
  return normaliseTarget(navcfg(cfg).target)
end

local function mirrorStoredTargetToTable(cfg)
  local target = storedTarget(cfg)
  if not target then return true end
  local ok = provider.writeNavTableTarget(cfg, target)
  return ok == true
end

function provider.captureNavTableTarget(cfg)
  local target, err = provider.readNavTableTarget(cfg)
  if target and target.active then
    navcfg(cfg).target = util.deepCopy(target)
    return true
  end
  if target and target.active == false then return true end
  return false, err
end

function provider.updateSource(cfg, armed, force)
  local currentNow = now()
  if armed then
    runtime.sourceLocked = true
    return runtime.activeSource, runtime.sourceReason
  end

  runtime.sourceLocked = false
  if not force and runtime.lastSourceCheckAt > 0 and currentNow - runtime.lastSourceCheckAt < SOURCE_RECHECK_MS then
    return runtime.activeSource, runtime.sourceReason
  end
  runtime.lastSourceCheckAt = currentNow

  local nextSource, reason = chooseSource(cfg)
  if nextSource ~= runtime.activeSource then
    runtime.activeSource = nextSource
    runtime.sourceReason = tostring(reason or "navigation source changed")
    if nextSource == "nav_table" then
      provider.captureNavTableTarget(cfg)
      mirrorStoredTargetToTable(cfg)
    end
  else
    runtime.sourceReason = tostring(reason or runtime.sourceReason)
  end

  return runtime.activeSource, runtime.sourceReason
end

function provider.activeSource()
  return runtime.activeSource
end

function provider.programmingSource(cfg)
  local preference = navcfg(cfg).source
  local tableOkay, tableWhy = provider.navTableCompatibility(cfg)
  if preference == "nav_table" then
    if tableOkay then return "nav_table" end
    return nil, tableWhy
  elseif preference == "gps" then
    return "gps"
  end
  if tableOkay then return "nav_table" end
  return "gps", tableWhy
end

local function sampleNavTable(cfg)
  local compatible, nameOrError = provider.navTableCompatibility(cfg)
  if not compatible then return { valid = false, source = "nav_table", error = nameOrError } end

  local okHas, hasTarget = pcall(peripheral.call, nameOrError, "hasTarget")
  if not okHas then return { valid = false, source = "nav_table", error = tostring(hasTarget) } end
  if hasTarget ~= true then return { valid = true, source = "nav_table", hasTarget = false } end

  local result = { valid = true, source = "nav_table", hasTarget = true }
  local calls = {
    { "bearing", "getBearing" },
    { "distance", "getDistanceToTarget" },
    { "closureRate", "getClosureRate" },
    { "verticalOffset", "getVerticalOffsetToTarget" },
  }
  for _, item in ipairs(calls) do
    local ok, value = pcall(peripheral.call, nameOrError, item[2])
    if not ok or not finite(value) then
      return { valid = false, source = "nav_table", error = item[2] .. ": " .. tostring(value) }
    end
    result[item[1]] = tonumber(value)
  end
  local okType, targetType = pcall(peripheral.call, nameOrError, "getTargetType")
  if okType then result.targetType = targetType end
  return result
end

local function sampleGps(cfg, currentHeading, worldVelocity)
  if not provider.gpsAvailable() then
    return { valid = false, source = "gps", error = runtime.gps.lastError or "GPS fix stale" }
  end

  local result = {
    valid = true,
    source = "gps",
    hasTarget = false,
    position = { x = runtime.gps.x, y = runtime.gps.y, z = runtime.gps.z },
  }
  local target = storedTarget(cfg)
  if not target then return result end

  local dx = target.x - runtime.gps.x
  local dz = target.z - runtime.gps.z
  local dy = target.y ~= nil and (target.y - runtime.gps.y) or 0
  local horizontal = math.sqrt(dx * dx + dz * dz)
  local distance = target.y ~= nil and math.sqrt(horizontal * horizontal + dy * dy) or horizontal
  local targetHeading = wrap360(math.deg(atan2(dx, dz)))
  local bearing = wrap180(targetHeading - (tonumber(currentHeading) or 0))

  local closure = 0
  if horizontal > 0.001 and type(worldVelocity) == "table" then
    local vx = tonumber(worldVelocity.x) or 0
    local vz = tonumber(worldVelocity.z) or 0
    closure = (vx * dx + vz * dz) / horizontal
  end

  result.hasTarget = true
  result.bearing = bearing
  result.distance = distance
  result.horizontalDistance = horizontal
  result.closureRate = closure
  result.verticalOffset = dy
  result.targetType = "atlas_gps"
  result.target = util.deepCopy(target)
  return result
end

function provider.sample(cfg, currentHeading, worldVelocity)
  local source = runtime.activeSource
  if source == "nav_table" then return sampleNavTable(cfg) end
  if source == "gps" then return sampleGps(cfg, currentHeading, worldVelocity) end
  return { valid = false, source = nil, error = runtime.sourceReason or "No navigation source selected" }
end

function provider.status(cfg)
  local compatible, compatibilityError = provider.navTableCompatibility(cfg)
  local gpsState = provider.gpsStatus()
  local programmingSource, programmingError = provider.programmingSource(cfg)
  return {
    source = navcfg(cfg).source,
    activeSource = runtime.activeSource or "none",
    sourceLocked = runtime.sourceLocked,
    sourceReason = runtime.sourceReason,
    programmable = programmingSource ~= nil,
    programmingSource = programmingSource,
    programmingError = programmingError,
    navTableAvailable = compatible,
    compatibilityError = compatible and nil or compatibilityError,
    gpsAvailable = gpsState.available,
    gpsPosition = gpsState.available and { x = gpsState.x, y = gpsState.y, z = gpsState.z } or nil,
    gpsAgeMs = gpsState.ageMs,
    gpsError = gpsState.lastError,
  }
end

function provider.gpsWorker(cfg)
  while true do
    local preference = navcfg(cfg).source
    local tableOkay = provider.navTableCompatibility(cfg)
    local shouldPoll = preference == "gps" or (preference == "auto" and not tableOkay)
    if shouldPoll then
      provider.pollGpsOnce()
      sleep(GPS_RETRY_SECONDS)
    else
      sleep(GPS_IDLE_SECONDS)
    end
  end
end

return provider
