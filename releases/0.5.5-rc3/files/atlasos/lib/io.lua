local util = require("atlasos.lib.util")

local ioControl = {}
local sides = { "top", "bottom", "front", "back", "left", "right" }

local function sideIsValid(side)
  for _, candidate in ipairs(sides) do if side == candidate then return true end end
  return false
end

local function endpointKey(endpoint)
  return tostring(endpoint and endpoint.device) .. ":" .. tostring(endpoint and endpoint.side)
end

local function endpointObject(endpoint)
  if type(endpoint) ~= "table" then return nil, "missing endpoint" end
  if not sideIsValid(endpoint.side) then return nil, "invalid side " .. tostring(endpoint.side) end
  if endpoint.device == "computer" then return redstone end
  if not peripheral.isPresent(endpoint.device) then return nil, "peripheral " .. tostring(endpoint.device) .. " is missing" end
  if not util.hasPeripheralType(endpoint.device, "redstone_relay") then
    return nil, tostring(endpoint.device) .. " is not a redstone relay"
  end
  local wrapped = peripheral.wrap(endpoint.device)
  if not wrapped then return nil, "could not wrap " .. tostring(endpoint.device) end
  return wrapped
end

local function call(endpoint, method, value)
  local object, err = endpointObject(endpoint)
  if not object then return false, err end
  local fn = object[method]
  if type(fn) ~= "function" then return false, method .. " is unavailable on " .. endpointKey(endpoint) end
  local ok, callError = pcall(fn, endpoint.side, value)
  if not ok then return false, tostring(callError) end
  return true
end

local function normaliseOutputs(hw)
  if type(hw) ~= "table" then return end
  hw.outputs = type(hw.outputs) == "table" and hw.outputs or {}
  if not hw.outputs.propulsionPermit and hw.outputs.master then
    hw.outputs.propulsionPermit = hw.outputs.master
  end
  hw.outputs.master = nil
end

function ioControl.sides()
  local result = {}
  for index, side in ipairs(sides) do result[index] = side end
  return result
end

function ioControl.setDigital(endpoint, value)
  return call(endpoint, "setOutput", value == true)
end

function ioControl.setAnalog(endpoint, value)
  return call(endpoint, "setAnalogOutput", util.clamp(util.round(value), 0, 15))
end

function ioControl.clearRelay(name)
  if not name or not peripheral.isPresent(name) then return false, "relay missing" end
  if not util.hasPeripheralType(name, "redstone_relay") then return false, tostring(name) .. " is not a redstone relay" end
  local relay = peripheral.wrap(name)
  if not relay then return false, "could not wrap " .. tostring(name) end
  local failures = {}
  for _, side in ipairs(sides) do
    local ok, err = pcall(relay.setAnalogOutput, side, 0)
    if not ok then failures[#failures + 1] = side .. ": " .. tostring(err) end
  end
  return #failures == 0, failures
end

function ioControl.levelToSignal(level, atZero, atFull)
  level = util.clamp(util.round(level), 0, 15)
  atZero = util.clamp(util.round(atZero), 0, 15)
  atFull = util.clamp(util.round(atFull), 0, 15)
  return util.clamp(util.round(atZero + (atFull - atZero) * (level / 15)), 0, 15)
end

function ioControl.safeControl(cfg)
  return {
    lift = 0,
    thrust = 0,
    reverse = false,
    gyro = cfg.hardware and cfg.hardware.gyroSafe == true or false,
    rudder = 0,
  }
end

function ioControl.validate(cfg, requireCommissioned)
  local errors = {}
  local hw = cfg.hardware or {}
  normaliseOutputs(hw)
  if not hw.configured then errors[#errors + 1] = "I/O is not configured" end
  if requireCommissioned and not hw.commissioned then errors[#errors + 1] = "I/O is not commissioned" end
  if not hw.powerRelay or not peripheral.isPresent(hw.powerRelay) then errors[#errors + 1] = "power relay missing" end
  if not hw.steeringRelay or not peripheral.isPresent(hw.steeringRelay) then errors[#errors + 1] = "steering relay missing" end

  local expected = {
    "propulsionPermit", "lift", "thrust", "reverse", "gyro",
    "steeringEnable", "rudderLeft", "rudderRight",
  }
  local used = {}
  for _, name in ipairs(expected) do
    local endpoint = hw.outputs and hw.outputs[name] or nil
    if not endpoint then
      errors[#errors + 1] = name .. " output missing"
    else
      local key = endpointKey(endpoint)
      if used[key] then errors[#errors + 1] = name .. " duplicates " .. used[key] end
      used[key] = name
      local object, err = endpointObject(endpoint)
      if not object then errors[#errors + 1] = name .. ": " .. tostring(err) end
    end
  end
  return #errors == 0, errors
end

local function writeAll(cfg, control)
  local hw = cfg.hardware
  normaliseOutputs(hw)
  local outputs = hw.outputs
  local failures = {}
  local function attempt(name, ok, err)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
  end

  attempt("lift", ioControl.setAnalog(outputs.lift,
    ioControl.levelToSignal(control.lift, hw.liftSignalZero, hw.liftSignalFull)))
  attempt("thrust", ioControl.setAnalog(outputs.thrust,
    ioControl.levelToSignal(control.thrust, hw.thrustSignalZero, hw.thrustSignalFull)))
  attempt("reverse", ioControl.setDigital(outputs.reverse, control.reverse == true))
  attempt("gyro", ioControl.setDigital(outputs.gyro, control.gyro == true))
  attempt("rudder left", ioControl.setDigital(outputs.rudderLeft, tonumber(control.rudder) == -1))
  attempt("rudder right", ioControl.setDigital(outputs.rudderRight, tonumber(control.rudder) == 1))
  return #failures == 0, failures
end

function ioControl.setPropulsionPermit(cfg, enabled)
  local hw = cfg.hardware or {}
  normaliseOutputs(hw)
  local endpoint = hw.outputs and hw.outputs.propulsionPermit
  if not endpoint then return false, "propulsion permit output is not configured" end
  return ioControl.setDigital(endpoint, enabled == true)
end

function ioControl.setComputerSteering(cfg, enabled)
  local hw = cfg.hardware or {}
  normaliseOutputs(hw)
  local endpoint = hw.outputs and hw.outputs.steeringEnable
  if not endpoint then return false, "computer steering output is not configured" end
  return ioControl.setDigital(endpoint, enabled == true)
end

function ioControl.applyBestEffortSafe(cfg)
  local hw = cfg.hardware or {}
  normaliseOutputs(hw)
  local outputs = hw.outputs or {}
  local failures = {}
  local function attempt(name, fn, endpoint, value)
    if endpoint then
      local ok, err = fn(endpoint, value)
      if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
    end
  end
  attempt("propulsion permit", ioControl.setDigital, outputs.propulsionPermit, false)
  attempt("computer steering", ioControl.setDigital, outputs.steeringEnable, false)
  attempt("lift", ioControl.setAnalog, outputs.lift,
    ioControl.levelToSignal(0, hw.liftSignalZero or 0, hw.liftSignalFull or 15))
  attempt("thrust", ioControl.setAnalog, outputs.thrust,
    ioControl.levelToSignal(0, hw.thrustSignalZero or 0, hw.thrustSignalFull or 15))
  attempt("reverse", ioControl.setDigital, outputs.reverse, false)
  attempt("gyro", ioControl.setDigital, outputs.gyro, hw.gyroSafe == true)
  attempt("rudder left", ioControl.setDigital, outputs.rudderLeft, false)
  attempt("rudder right", ioControl.setDigital, outputs.rudderRight, false)
  return #failures == 0, failures
end

function ioControl.applySafe(cfg)
  local valid, errors = ioControl.validate(cfg, false)
  if not valid then return false, errors end
  local failures = {}
  local ok, err = ioControl.setPropulsionPermit(cfg, false)
  if not ok then failures[#failures + 1] = "propulsion permit: " .. tostring(err) end
  ok, err = ioControl.setComputerSteering(cfg, false)
  if not ok then failures[#failures + 1] = "computer steering: " .. tostring(err) end
  local controlsOk, controlErrors = writeAll(cfg, ioControl.safeControl(cfg))
  if not controlsOk then for _, value in ipairs(controlErrors) do failures[#failures + 1] = value end end
  return #failures == 0, failures
end

function ioControl.applyControl(cfg, control)
  local valid, errors = ioControl.validate(cfg, true)
  if not valid then return false, errors end
  return writeAll(cfg, control)
end

function ioControl.arm(cfg)
  local safeOk, safeErrors = ioControl.applySafe(cfg)
  if not safeOk then return false, safeErrors end
  local ok, err = ioControl.setComputerSteering(cfg, true)
  if not ok then ioControl.applyBestEffortSafe(cfg); return false, { "computer steering: " .. tostring(err) } end
  ok, err = ioControl.setPropulsionPermit(cfg, true)
  if not ok then ioControl.applyBestEffortSafe(cfg); return false, { "propulsion permit: " .. tostring(err) } end
  return true, {}
end

function ioControl.describe(cfg)
  local hw = cfg.hardware or {}
  normaliseOutputs(hw)
  local output = {}
  output[#output + 1] = "Power relay: " .. tostring(hw.powerRelay or "not set")
  output[#output + 1] = "Steering relay: " .. tostring(hw.steeringRelay or "not set")
  output[#output + 1] = ""
  local order = {
    { "propulsionPermit", "prop permit" },
    { "lift", "lift" },
    { "thrust", "thrust" },
    { "reverse", "reverse" },
    { "gyro", "gyro" },
    { "steeringEnable", "computer steer" },
    { "rudderLeft", "rudder left" },
    { "rudderRight", "rudder right" },
  }
  for _, item in ipairs(order) do
    local endpoint = hw.outputs and hw.outputs[item[1]] or nil
    if endpoint then
      output[#output + 1] = string.format("%-14s %s / %s", item[2], endpoint.device, endpoint.side)
    else
      output[#output + 1] = string.format("%-14s not mapped", item[2])
    end
  end
  output[#output + 1] = ""
  output[#output + 1] = "Lift signal: " .. tostring(hw.liftSignalZero) .. " at 0, " .. tostring(hw.liftSignalFull) .. " at 15"
  output[#output + 1] = "Thrust signal: " .. tostring(hw.thrustSignalZero) .. " at 0, " .. tostring(hw.thrustSignalFull) .. " at 15"
  output[#output + 1] = "Gyro in SAFE: " .. tostring(hw.gyroSafe == true)
  output[#output + 1] = "SAFE steering: MANUAL wheel"
  output[#output + 1] = "Commissioned: " .. tostring(hw.commissioned == true)
  return output
end

function ioControl.testChannel(cfg, channel, level, seconds)
  local hw = cfg.hardware or {}
  normaliseOutputs(hw)
  local endpoint = hw.outputs and hw.outputs[channel]
  if not endpoint then return false, "unknown or unmapped channel" end
  ioControl.applySafe(cfg)
  seconds = util.clamp(tonumber(seconds) or 1, 0.1, 3)
  local ok, err
  if endpoint.mode == "analog" then ok, err = ioControl.setAnalog(endpoint, util.clamp(tonumber(level) or 7, 0, 15))
  else ok, err = ioControl.setDigital(endpoint, true) end
  if not ok then return false, err end
  sleep(seconds)
  ioControl.applySafe(cfg)
  return true
end

return ioControl
