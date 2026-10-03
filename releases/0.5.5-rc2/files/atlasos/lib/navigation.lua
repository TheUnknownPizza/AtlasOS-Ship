local util = require("atlasos.lib.util")
local provider = require("atlasos.lib.navigation_provider")

local navigation = {}

local WORLD_LIMIT = 29999984
local MAX_WAYPOINTS = 32
local MAX_LABEL = 40

local function finite(value)
  value = tonumber(value)
  return value ~= nil and value == value and value ~= math.huge and value ~= -math.huge
end

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function label(value, fallback)
  local text = trim(value)
  if text == "" then text = tostring(fallback or "Destination") end
  return text:sub(1, MAX_LABEL)
end

local function validXZ(x, z)
  if not finite(x) or not finite(z) then return false, "X and Z must be numbers" end
  x, z = tonumber(x), tonumber(z)
  if math.abs(x) > WORLD_LIMIT or math.abs(z) > WORLD_LIMIT then
    return false, "Coordinates exceed Minecraft world limits"
  end
  return true
end

local function copyWaypoint(value)
  if type(value) ~= "table" then return nil end
  local ok = validXZ(value.x, value.z)
  if not ok then return nil end
  local result = {
    label = label(value.label, string.format("%.0f, %.0f", tonumber(value.x), tonumber(value.z))),
    x = tonumber(value.x),
    z = tonumber(value.z),
  }
  if finite(value.y) then result.y = tonumber(value.y) end
  return result
end

local function copyTarget(value)
  local target = copyWaypoint(value)
  if not target then return nil end
  target.active = value.active ~= false
  return target
end

function navigation.ensureConfig(cfg)
  cfg.navigation = type(cfg.navigation) == "table" and cfg.navigation or {}
  if cfg.navigation.source ~= "nav_table" and cfg.navigation.source ~= "gps" then
    cfg.navigation.source = "auto"
  end
  cfg.navigation.waypoints = type(cfg.navigation.waypoints) == "table" and cfg.navigation.waypoints or {}

  local cleaned = {}
  for _, entry in ipairs(cfg.navigation.waypoints) do
    local waypoint = copyWaypoint(entry)
    if waypoint and #cleaned < MAX_WAYPOINTS then cleaned[#cleaned + 1] = waypoint end
  end
  cfg.navigation.waypoints = cleaned
  cfg.navigation.target = copyTarget(cfg.navigation.target)
  return cfg.navigation
end

function navigation.compatibility(cfg)
  return provider.navTableCompatibility(cfg)
end

function navigation.updateSource(cfg, armed, force)
  navigation.ensureConfig(cfg)
  return provider.updateSource(cfg, armed == true, force == true)
end

function navigation.gpsWorker(cfg)
  navigation.ensureConfig(cfg)
  return provider.gpsWorker(cfg)
end

function navigation.getTarget(cfg)
  local navcfg = navigation.ensureConfig(cfg)
  local active = provider.activeSource()
  if active == "nav_table" then
    local target = provider.readNavTableTarget(cfg)
    if target then
      if target.active then
        navcfg.target = copyTarget(target)
        return util.deepCopy(navcfg.target)
      end
      navcfg.target = nil
      return { active = false }
    end
  end
  return navcfg.target and util.deepCopy(navcfg.target) or { active = false }
end

local function makeTarget(x, z, name, y)
  local valid, err = validXZ(x, z)
  if not valid then return nil, err end
  x, z = tonumber(x), tonumber(z)
  local target = {
    active = true,
    label = label(name, string.format("X %.0f Z %.0f", x, z)),
    x = x,
    z = z,
  }
  if finite(y) then target.y = tonumber(y) end
  return target
end

function navigation.setDirect(cfg, x, z, name, y)
  local navcfg = navigation.ensureConfig(cfg)
  local target, err = makeTarget(x, z, name, y)
  if not target then return false, err end

  local source, sourceError = provider.programmingSource(cfg)
  if not source then return false, sourceError end
  if source == "nav_table" then
    local ok, why = provider.writeNavTableTarget(cfg, target)
    if not ok then return false, why end
  end

  navcfg.target = util.deepCopy(target)
  if source == "gps" and not provider.gpsAvailable() then
    return true, "DESTINATION SET - WAITING FOR GPS FIX"
  end
  return true, source == "gps" and "GPS DESTINATION SET" or "DESTINATION SET"
end

function navigation.clearTarget(cfg)
  local navcfg = navigation.ensureConfig(cfg)
  local source, sourceError = provider.programmingSource(cfg)
  if not source then return false, sourceError end
  if source == "nav_table" then
    local ok, why = provider.clearNavTableTarget(cfg)
    if not ok then return false, why end
  end
  navcfg.target = nil
  return true, source == "gps" and "GPS TARGET CLEARED" or "ATLAS TARGET CLEARED"
end

function navigation.saveWaypoint(cfg, name, x, z, y)
  local navcfg = navigation.ensureConfig(cfg)
  local valid, err = validXZ(x, z)
  if not valid then return false, err end
  local waypoint = {
    label = label(name, string.format("X %.0f Z %.0f", tonumber(x), tonumber(z))),
    x = tonumber(x),
    z = tonumber(z),
  }
  if finite(y) then waypoint.y = tonumber(y) end

  local lowered = waypoint.label:lower()
  for index, existing in ipairs(navcfg.waypoints) do
    if tostring(existing.label or ""):lower() == lowered then
      navcfg.waypoints[index] = waypoint
      return true, "WAYPOINT UPDATED"
    end
  end
  if #navcfg.waypoints >= MAX_WAYPOINTS then return false, "Waypoint list is full" end
  navcfg.waypoints[#navcfg.waypoints + 1] = waypoint
  table.sort(navcfg.waypoints, function(a, b) return a.label:lower() < b.label:lower() end)
  return true, "WAYPOINT SAVED"
end

function navigation.isActiveWaypoint(cfg, name)
  local target = navigation.getTarget(cfg)
  if type(target) ~= "table" or target.active ~= true then return false end
  return trim(target.label):lower() == trim(name):lower()
end

function navigation.deleteWaypoint(cfg, name)
  local navcfg = navigation.ensureConfig(cfg)
  local wanted = trim(name):lower()
  local found = nil
  for index, existing in ipairs(navcfg.waypoints) do
    if tostring(existing.label or ""):lower() == wanted then
      found = index
      break
    end
  end
  if not found then return false, "WAYPOINT NOT FOUND" end

  local active = navigation.isActiveWaypoint(cfg, name)
  if active then
    local cleared, clearReason = navigation.clearTarget(cfg)
    if not cleared then return false, "DELETE BLOCKED: " .. tostring(clearReason) end
  end

  table.remove(navcfg.waypoints, found)
  if active then return true, "WAYPOINT + TARGET CLEARED" end
  return true, "WAYPOINT DELETED"
end

function navigation.findWaypoint(cfg, name)
  local navcfg = navigation.ensureConfig(cfg)
  local wanted = trim(name):lower()
  for _, waypoint in ipairs(navcfg.waypoints) do
    if tostring(waypoint.label or ""):lower() == wanted then return util.deepCopy(waypoint) end
  end
  return nil
end

function navigation.activateWaypoint(cfg, name)
  local waypoint = navigation.findWaypoint(cfg, name)
  if not waypoint then return false, "WAYPOINT NOT FOUND" end
  return navigation.setDirect(cfg, waypoint.x, waypoint.z, waypoint.label, waypoint.y)
end

function navigation.listWaypoints(cfg)
  local navcfg = navigation.ensureConfig(cfg)
  return util.deepCopy(navcfg.waypoints)
end

function navigation.status(cfg)
  local navcfg = navigation.ensureConfig(cfg)
  local status = provider.status(cfg)
  status.target = navigation.getTarget(cfg)
  status.waypoints = navigation.listWaypoints(cfg)
  return status
end

function navigation.command(cfg, action, payload)
  payload = type(payload) == "table" and payload or {}
  action = tostring(action or "")

  if action == "set_direct" then
    local ok, reason = navigation.setDirect(cfg, payload.x, payload.z, payload.label, payload.y)
    if not ok then return false, reason end
    if payload.save == true and trim(payload.label) ~= "" then
      local saved, saveReason = navigation.saveWaypoint(cfg, payload.label, payload.x, payload.z, payload.y)
      if not saved then return false, "Target set, but waypoint was not saved: " .. tostring(saveReason) end
      return true, reason .. " + WAYPOINT SAVED"
    end
    return true, reason
  elseif action == "activate_waypoint" then
    return navigation.activateWaypoint(cfg, payload.label)
  elseif action == "clear" then
    return navigation.clearTarget(cfg)
  elseif action == "save_waypoint" then
    return navigation.saveWaypoint(cfg, payload.label, payload.x, payload.z, payload.y)
  elseif action == "delete_waypoint" then
    return navigation.deleteWaypoint(cfg, payload.label)
  end

  return false, "Unsupported navigation command"
end

return navigation
