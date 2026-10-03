local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")
local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local ioControl = require("atlasos.lib.io")
local log = require("atlasos.lib.log")
local version = require("atlasos.version")

local cfg = config.load()
if cfg.role ~= "server" then error("Flight I/O is configured on the onboard server", 0) end

local function heading(text)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.orange)
  term.clear()
  term.setCursorPos(1, 1)
  print("AtlasOS " .. version.version .. " - " .. text)
  term.setTextColor(colors.lightGray)
  print("FICSIT Heavy Aeronautics Division")
  print(string.rep("-", math.min(44, select(1, term.getSize()))))
  term.setTextColor(colors.white)
end

local function askNumber(prompt, default, minimum, maximum)
  while true do
    write(prompt .. " [" .. tostring(default) .. "]: ")
    local raw = util.trim(read())
    local value = raw == "" and default or tonumber(raw)
    if value and value >= minimum and value <= maximum and value == math.floor(value) then return value end
    printError("Enter a whole number from " .. minimum .. " to " .. maximum)
  end
end

local function askYesNo(prompt, default)
  local suffix = default and " [Y/n]: " or " [y/N]: "
  while true do
    write(prompt .. suffix)
    local value = util.trim(read()):lower()
    if value == "" then return default end
    if value == "y" or value == "yes" then return true end
    if value == "n" or value == "no" then return false end
  end
end

local function chooseRelay(prompt, relays, defaultIndex)
  print(prompt)
  for index, name in ipairs(relays) do print("  " .. index .. ") " .. name) end
  return relays[askNumber("Choose relay", defaultIndex, 1, #relays)]
end

local function endpointKey(device, side)
  return tostring(device) .. ":" .. tostring(side)
end

local function chooseSide(channelLabel, device, used, defaultEndpoint, mode)
  local allSides = ioControl.sides()
  while true do
    heading("MAP " .. channelLabel:upper())
    print("Relay: " .. tostring(device))
    print("Side names are local to the relay's facing.")
    print("Select a side; AtlasOS will pulse it briefly.")
    print("")
    local available = {}
    for _, side in ipairs(allSides) do
      if not used[endpointKey(device, side)] then available[#available + 1] = side end
    end
    if #available == 0 then error("No unused sides remain on " .. tostring(device), 0) end
    local defaultIndex = 1
    if type(defaultEndpoint) == "table" and defaultEndpoint.device == device then
      for index, side in ipairs(available) do if side == defaultEndpoint.side then defaultIndex = index end end
    end
    for index, side in ipairs(available) do print("  " .. index .. ") " .. side) end
    local side = available[askNumber("Side for " .. channelLabel, defaultIndex, 1, #available)]
    local endpoint = { device = device, side = side, mode = mode }
    print("")
    print("Pulsing " .. device .. " / " .. side .. " for 0.8 seconds...")
    local ok, err
    if mode == "analog" then ok, err = ioControl.setAnalog(endpoint, 15)
    else ok, err = ioControl.setDigital(endpoint, true) end
    if not ok then error("Could not pulse side: " .. tostring(err), 0) end
    sleep(0.8)
    if mode == "analog" then ioControl.setAnalog(endpoint, 0) else ioControl.setDigital(endpoint, false) end
    if askYesNo("Did the intended EXPOSED face light?", true) then
      used[endpointKey(device, side)] = channelLabel
      return endpoint
    end
  end
end

heading("MANUAL FLIGHT I/O")
print("This wizard manually maps two attached Redstone Relays.")
print("It makes no assumption about relay orientation.")
print("")
term.setTextColor(colors.yellow)
print("REMOVE OR DISCONNECT TRANSMITTING LINKS FIRST.")
term.setTextColor(colors.white)
print("The wizard pulses relay faces while mapping them.")
print("Type MAP only when the vessel cannot move.")
write("> ")
if read() ~= "MAP" then print("Cancelled."); return end

local relays = util.listPeripheralsByType("redstone_relay")
if #relays < 2 then
  printError("Two Redstone Relays were not detected.")
  print("Place one against each of two free server faces.")
  return
end

local powerRelay = chooseRelay("Select the POWER relay:", relays, 1)
local steeringCandidates = {}
for _, name in ipairs(relays) do if name ~= powerRelay then steeringCandidates[#steeringCandidates + 1] = name end end
local steeringRelay = chooseRelay("Select the STEERING relay:", steeringCandidates, 1)

ioControl.clearRelay(powerRelay)
ioControl.clearRelay(steeringRelay)

local oldOutputs = cfg.hardware.outputs or {}
if not oldOutputs.propulsionPermit and oldOutputs.master then oldOutputs.propulsionPermit = oldOutputs.master end
local used = {}
local outputs = {}
outputs.propulsionPermit = chooseSide("propulsion permit", powerRelay, used, oldOutputs.propulsionPermit, "digital")
outputs.lift = chooseSide("lift", powerRelay, used, oldOutputs.lift, "analog")
outputs.thrust = chooseSide("thrust", powerRelay, used, oldOutputs.thrust, "analog")
outputs.reverse = chooseSide("reverse", powerRelay, used, oldOutputs.reverse, "digital")
outputs.gyro = chooseSide("gyro", powerRelay, used, oldOutputs.gyro, "digital")
outputs.steeringEnable = chooseSide("computer steering", steeringRelay, used, oldOutputs.steeringEnable, "digital")
outputs.rudderLeft = chooseSide("rudder left", steeringRelay, used, oldOutputs.rudderLeft, "digital")
outputs.rudderRight = chooseSide("rudder right", steeringRelay, used, oldOutputs.rudderRight, "digital")

heading("SIGNAL CALIBRATION")
print("Analogue controls use the same 0-15 scale as the tablet.")
local liftZero = askNumber("Lift signal at level 0", cfg.hardware.liftSignalZero or 0, 0, 15)
local liftFull = askNumber("Lift signal at level 15", cfg.hardware.liftSignalFull or 15, 0, 15)
local thrustZero = askNumber("Thrust signal at level 0", cfg.hardware.thrustSignalZero or 0, 0, 15)
local thrustFull = askNumber("Thrust signal at level 15", cfg.hardware.thrustSignalFull or 15, 0, 15)
local gyroSafe = askYesNo("Keep the gyro output ON while SAFE?", cfg.hardware.gyroSafe == true)

cfg.hardware.configured = true
cfg.hardware.commissioned = false
cfg.hardware.powerRelay = powerRelay
cfg.hardware.steeringRelay = steeringRelay
cfg.hardware.outputs = outputs
cfg.hardware.liftSignalZero = liftZero
cfg.hardware.liftSignalFull = liftFull
cfg.hardware.thrustSignalZero = thrustZero
cfg.hardware.thrustSignalFull = thrustFull
cfg.hardware.gyroSafe = gyroSafe
cfg.safe = true
cfg.armed = false
cfg.lastSafeReason = "Volume II I/O manually mapped; commissioning required"
cfg.control = ioControl.safeControl(cfg)
local saved, saveError = config.save(cfg)
if not saved then error("Could not save I/O configuration: " .. tostring(saveError), 0) end
local safeOk, safeErrors = ioControl.applySafe(cfg)
if not safeOk then error("Could not assert SAFE outputs: " .. table.concat(safeErrors, "; "), 0) end
log.info("Volume II I/O manually mapped; commissioning remains locked")

heading("I/O MAP CREATED")
for _, line in ipairs(ioControl.describe(cfg)) do print(line) end
print("")
term.setTextColor(colors.yellow)
print("NOT COMMISSIONED - ARMING REMAINS LOCKED")
term.setTextColor(colors.white)
print("")
if gyroSafe then print("The mapped gyro face is now ON because gyro SAFE = true.") end
print("Reconnect transmitters according to this map.")
print("Then test every channel and commission I/O.")
