local util = require("atlasos.lib.util")

local settings = {}

local FULL_AUTO_DEFAULTS = {
  cruiseSpeed = 8.0,
  approachDistance = 80.0,
  minimumApproachSpeed = 1.5,
  arrivalSpeed = 1.2,
  speedDeadband = 0.45,
  thrustAdjustIntervalMs = 300,
  maxThrust = 12,
  headingSlowDeg = 20,
  headingGateDeg = 55,
  turnSpeed = 2.5,
  brakeLeadSeconds = 3.0,
  brakeMinLeadDistance = 4.0,
  brakeStopSpeed = 0.20,
  brakeReboundMargin = 0.20,
  brakeMaxThrust = 6,
  overshootCaptureExtra = 6.0,
  overshootBehindDeg = 95.0,
  overshootTrendMargin = 2.0,
  overshootEscapeMargin = 8.0,
  overshootConfirmMs = 350,
}

local TELEMETRY_DEFAULTS = {
  enabled = true,
  preferred = nil,
  scale = "auto",
}

local FIELDS = {
  ["fullAutopilot.cruiseSpeed"] = {
    group = "auto", label = "Cruise m/s", default = 8.0, min = 1.0, max = 20.0, step = 0.5, format = "%.1f", safeOnly = true,
  },
  ["fullAutopilot.approachDistance"] = {
    group = "auto", label = "Approach m", default = 80.0, min = 20.0, max = 500.0, step = 5.0, format = "%.0f", safeOnly = true,
  },
  ["fullAutopilot.minimumApproachSpeed"] = {
    group = "auto", label = "Min app m/s", default = 1.5, min = 0.5, max = 12.0, step = 0.5, format = "%.1f", safeOnly = true,
  },
  ["fullAutopilot.arrivalSpeed"] = {
    group = "auto", label = "Arrival m/s", default = 1.2, min = 0.2, max = 8.0, step = 0.2, format = "%.1f", safeOnly = true,
  },
  ["fullAutopilot.maxThrust"] = {
    group = "auto", label = "Max thrust", default = 12, min = 1, max = 15, step = 1, format = "%.0f", integer = true, safeOnly = true,
  },
  ["fullAutopilot.brakeLeadSeconds"] = {
    group = "auto", label = "Brake lead s", default = 3.0, min = 0.5, max = 8.0, step = 0.5, format = "%.1f", safeOnly = true,
  },
  ["fullAutopilot.brakeMaxThrust"] = {
    group = "auto", label = "Brake thrust", default = 6, min = 1, max = 15, step = 1, format = "%.0f", integer = true, safeOnly = true,
  },

  ["autoflight.heading.kp"] = {
    group = "assist", label = "HDG Kp", default = 0.72, min = 0.0, max = 5.0, step = 0.05, format = "%.2f", safeOnly = true,
  },
  ["autoflight.heading.kd"] = {
    group = "assist", label = "HDG Kd", default = 1.15, min = 0.0, max = 10.0, step = 0.05, format = "%.2f", safeOnly = true,
  },
  ["autoflight.navigation.kp"] = {
    group = "assist", label = "NAV Kp", default = 0.62, min = 0.0, max = 5.0, step = 0.05, format = "%.2f", safeOnly = true,
  },
  ["autoflight.navigation.kd"] = {
    group = "assist", label = "NAV Kd", default = 1.15, min = 0.0, max = 10.0, step = 0.05, format = "%.2f", safeOnly = true,
  },
  ["autoflight.altitude.kp"] = {
    group = "assist", label = "ALT Kp", default = 0.16, min = 0.0, max = 3.0, step = 0.02, format = "%.2f", safeOnly = true,
  },
  ["autoflight.altitude.ki"] = {
    group = "assist", label = "ALT Ki", default = 0.012, min = 0.0, max = 1.0, step = 0.002, format = "%.3f", safeOnly = true,
  },
  ["autoflight.altitude.kd"] = {
    group = "assist", label = "ALT Kd", default = 0.45, min = 0.0, max = 10.0, step = 0.05, format = "%.2f", safeOnly = true,
  },

  ["telemetryDisplay.enabled"] = {
    group = "display", label = "Telemetry", default = true, kind = "boolean", safeOnly = false,
  },
  ["telemetryDisplay.scale"] = {
    group = "display", label = "Text scale", default = "auto", kind = "scale", safeOnly = false,
  },
  ["telemetryDisplay.preferred"] = {
    group = "display", label = "Monitor", default = nil, kind = "peripheral", safeOnly = false,
  },

  ["navigation.source"] = {
    group = "display", label = "Nav source", default = "auto", kind = "enum",
    options = { "auto", "nav_table", "gps" }, safeOnly = true,
  },
}

local GROUP_ORDER = {
  auto = {
    "fullAutopilot.cruiseSpeed",
    "fullAutopilot.approachDistance",
    "fullAutopilot.minimumApproachSpeed",
    "fullAutopilot.arrivalSpeed",
    "fullAutopilot.maxThrust",
    "fullAutopilot.brakeLeadSeconds",
    "fullAutopilot.brakeMaxThrust",
  },
  assist = {
    "autoflight.heading.kp",
    "autoflight.heading.kd",
    "autoflight.navigation.kp",
    "autoflight.navigation.kd",
    "autoflight.altitude.kp",
    "autoflight.altitude.ki",
    "autoflight.altitude.kd",
  },
  display = {
    "telemetryDisplay.enabled",
    "telemetryDisplay.scale",
    "telemetryDisplay.preferred",
    "navigation.source",
  },
}

local function splitPath(path)
  local parts = {}
  for part in tostring(path or ""):gmatch("[^%.]+") do parts[#parts + 1] = part end
  return parts
end

local function getPath(root, path)
  local value = root
  for _, part in ipairs(splitPath(path)) do
    if type(value) ~= "table" then return nil end
    value = value[part]
  end
  return value
end

local function setPath(root, path, value)
  local parts = splitPath(path)
  local target = root
  for index = 1, #parts - 1 do
    local part = parts[index]
    if type(target[part]) ~= "table" then target[part] = {} end
    target = target[part]
  end
  target[parts[#parts]] = value
end

local function nearestHalf(value)
  return math.floor((tonumber(value) or 0.5) * 2 + 0.5) / 2
end

local function normaliseScale(value)
  if value == nil or tostring(value):lower() == "auto" then return "auto" end
  value = nearestHalf(value)
  return util.clamp(value, 0.5, 5.0)
end

local function normaliseEnum(meta, value)
  value = tostring(value or meta.default)
  for _, option in ipairs(meta.options or {}) do
    if value == option then return value end
  end
  return meta.default
end

local function normaliseField(meta, value)
  if meta.kind == "boolean" then return value == true end
  if meta.kind == "scale" then return normaliseScale(value) end
  if meta.kind == "peripheral" then
    local text = tostring(value or "")
    if text == "" or text:lower() == "auto" then return nil end
    return text
  end
  if meta.kind == "enum" then return normaliseEnum(meta, value) end

  value = tonumber(value)
  if value == nil then value = tonumber(meta.default) or 0 end
  value = util.clamp(value, meta.min, meta.max)
  if meta.integer then value = util.round(value) end
  return value
end

function settings.defaults()
  return {
    fullAutopilot = util.deepCopy(FULL_AUTO_DEFAULTS),
    telemetryDisplay = util.deepCopy(TELEMETRY_DEFAULTS),
    navigation = { source = "auto" },
  }
end

local function mergePreservingIdentity(current, defaults)
  if type(current) ~= "table" then return util.deepMerge(defaults, {}) end
  local merged = util.deepMerge(defaults, current)
  for key in pairs(current) do current[key] = nil end
  for key, value in pairs(merged) do current[key] = value end
  return current
end

function settings.ensure(cfg)
  cfg.fullAutopilot = mergePreservingIdentity(cfg.fullAutopilot, FULL_AUTO_DEFAULTS)
  cfg.telemetryDisplay = mergePreservingIdentity(cfg.telemetryDisplay, TELEMETRY_DEFAULTS)
  cfg.navigation = type(cfg.navigation) == "table" and cfg.navigation or {}
  if cfg.navigation.source == nil then cfg.navigation.source = "auto" end

  for key, meta in pairs(FIELDS) do
    local current = getPath(cfg, key)
    if current == nil and meta.default ~= nil then current = meta.default end
    setPath(cfg, key, normaliseField(meta, current))
  end

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

  return cfg
end

function settings.field(key)
  local meta = FIELDS[tostring(key or "")]
  return meta and util.deepCopy(meta) or nil
end

function settings.group(name)
  local result = {}
  for _, key in ipairs(GROUP_ORDER[tostring(name or "")] or {}) do
    local meta = settings.field(key)
    if meta then
      meta.key = key
      result[#result + 1] = meta
    end
  end
  return result
end

function settings.get(cfg, key)
  settings.ensure(cfg)
  return getPath(cfg, key)
end

function settings.requiresSafe(key)
  local meta = FIELDS[tostring(key or "")]
  return meta and meta.safeOnly == true or false
end

local function adjust(meta, current, direction)
  if meta.kind then return nil, "Setting is not numeric" end
  direction = tonumber(direction) or 0
  if direction == 0 then return current end
  local step = tonumber(meta.step) or 1
  return normaliseField(meta, (tonumber(current) or tonumber(meta.default) or 0) + step * direction)
end

function settings.apply(cfg, action, key, value, context)
  settings.ensure(cfg)
  action = tostring(action or "")
  key = tostring(key or "")
  local meta = FIELDS[key]
  if not meta then return false, "Unknown setting" end

  context = type(context) == "table" and context or {}
  if meta.safeOnly and context.armed then
    return false, "Set ship SAFE before changing " .. tostring(meta.label or key)
  end

  local current = getPath(cfg, key)
  local nextValue

  if action == "reset" then
    nextValue = meta.default
  elseif action == "adjust" then
    local adjusted, err = adjust(meta, current, value)
    if adjusted == nil then return false, err end
    nextValue = adjusted
  elseif action == "toggle" then
    if meta.kind ~= "boolean" then return false, "Setting is not a toggle" end
    nextValue = not (current == true)
  elseif action == "set" then
    nextValue = value
  else
    return false, "Unsupported settings action"
  end

  setPath(cfg, key, normaliseField(meta, nextValue))
  settings.ensure(cfg)
  return true, tostring(meta.label or key) .. " = " .. settings.format(key, getPath(cfg, key))
end

function settings.format(key, value)
  local meta = FIELDS[tostring(key or "")]
  if not meta then return tostring(value) end
  if meta.kind == "boolean" then return value == true and "ON" or "OFF" end
  if meta.kind == "scale" then
    if value == "auto" then return "AUTO" end
    return string.format("%.1f", tonumber(value) or 0.5)
  end
  if meta.kind == "peripheral" then return value and tostring(value) or "AUTO" end
  if meta.kind == "enum" then return tostring(value or meta.default):upper() end
  return string.format(meta.format or "%s", tonumber(value) or tonumber(meta.default) or 0)
end

function settings.public(cfg)
  settings.ensure(cfg)
  local values = {}
  for key in pairs(FIELDS) do values[key] = util.deepCopy(getPath(cfg, key)) end
  return {
    values = values,
    groups = {
      auto = util.deepCopy(GROUP_ORDER.auto),
      assist = util.deepCopy(GROUP_ORDER.assist),
      display = util.deepCopy(GROUP_ORDER.display),
    },
  }
end

return settings
