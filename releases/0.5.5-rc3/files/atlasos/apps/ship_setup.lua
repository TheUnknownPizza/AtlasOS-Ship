local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")

local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local ioControl = require("atlasos.lib.io")
local sensors = require("atlasos.lib.sensors")
local assist = require("atlasos.lib.assist")
local navigationProvider = require("atlasos.lib.navigation_provider")
local version = require("atlasos.version")

local cfg = config.load()
if cfg.role ~= "server" then error("Ship hardware setup runs on the onboard server", 0) end

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

local function pause()
  print("")
  term.setTextColor(colors.gray)
  print("Press Enter to continue.")
  term.setTextColor(colors.white)
  read()
end

local function yesNo(prompt, default)
  local suffix = default and " [Y/n]: " or " [y/N]: "
  while true do
    write(prompt .. suffix)
    local value = util.trim(read()):lower()
    if value == "" then return default end
    if value == "y" or value == "yes" then return true end
    if value == "n" or value == "no" then return false end
  end
end

local function refreshConfig()
  cfg = config.load()
  return cfg
end

local function mark(label, ready)
  term.setTextColor(ready and colors.lime or colors.yellow)
  write(ready and "[READY] " or "[TODO ] ")
  term.setTextColor(colors.white)
  print(label)
end

local function showStatus()
  local acfg = assist.ensureConfig(cfg)
  mark("Flight I/O mapped", ((cfg.hardware or {}).configured == true))
  mark("Flight I/O commissioned", ((cfg.hardware or {}).commissioned == true))
  mark("Sensors mapped", ((cfg.sensors or {}).configured == true))
  mark("Sensors commissioned", ((cfg.sensors or {}).commissioned == true))
  mark("Flight assist configured", (acfg.configured == true))
  mark("Flight assist commissioned", (acfg.commissioned == true))
end

local function gpsCheck()
  local ok, err = navigationProvider.pollGpsOnce()
  local state = navigationProvider.gpsStatus()
  return ok == true and state.available == true, err or state.lastError, state
end

heading("SHIP HARDWARE SETUP")
print("This guide explains the physical flight-control hardware")
print("and hands off to AtlasOS's existing mapping wizards.")
print("")
term.setTextColor(colors.yellow)
print("Keep the vessel SAFE, stationary, and mechanically secured.")
print("Some child wizards pulse relay/rudder outputs during testing.")
term.setTextColor(colors.white)
print("")
showStatus()
pause()

heading("1/6 - COMPUTER + RELAYS")
print("Recommended onboard layout:")
print("")
print("             Wireless Modem")
print("                  [M]")
print("                   |")
print("  POWER Relay [P]-[SERVER]-[S] STEERING Relay")
print("")
print("Install two CC:Tweaked Redstone Relays where the server")
print("can see them as peripherals. Direct attachment is simplest;")
print("a wired modem network also works.")
print("")
print("Do NOT connect transmitting Redstone Links while mapping.")
print("The mapper pulses exposed relay faces so you can identify")
print("each channel without assuming relay orientation.")
print("")
if yesNo("Launch Flight I/O mapper now?", (cfg.hardware or {}).configured ~= true) then
  shell.run("/atlasos/apps/flight_setup.lua")
  refreshConfig()
end
pause()

heading("2/6 - REDSTONE LINKS + FAIL-SAFE")
if (cfg.hardware or {}).configured == true then
  print("Your current output map:")
  print("")
  for _, line in ipairs(ioControl.describe(cfg)) do print(line) end
else
  term.setTextColor(colors.yellow)
  print("Flight I/O is not mapped yet. Run: atlasctl io setup")
  term.setTextColor(colors.white)
end
print("")
print("Place a transmitting Redstone Link against every mapped")
print("relay face, then give it the same frequency pair as the")
print("matching receiver on the vessel mechanism.")
print("")
print("The PROPULSION PERMIT must be fail-safe:")
print("  no permit -> clutch powered/locked -> propulsion CUT")
print("  permit    -> clutch released      -> propulsion READY")
print("")
print("A dead computer, relay, or control link must therefore")
print("remove propulsion rather than leaving stale thrust active.")
print("")
print("Before commissioning, test outputs individually:")
print("  atlasctl io test propulsionPermit")
print("  atlasctl io test lift 7")
print("  atlasctl io test thrust 7")
print("  atlasctl io test reverse")
print("  atlasctl io test gyro")
print("  atlasctl io test steeringEnable")
print("  atlasctl io test rudderLeft")
print("  atlasctl io test rudderRight")
print("")
print("Then: atlasctl io check")
print("      atlasctl io commission")
pause()

heading("3/6 - SENSORS + RUDDER")
print("Connect these to the server's wired peripheral network:")
print("  - Navigation Table")
print("  - Gimbal Sensor")
print("  - Altitude Sensor")
print("  - Velocity Sensors X / Y / Z")
print("  - Physical Steering Wheel")
print("  - Rudder Mechanical or Swivel Bearing")
print("  - Steering Rotation Speed Controller")
print("  - Physics Assembler (optional)")
print("")
print("The tested steering-actuator baseline is 16 RPM.")
print("The sensor wizard also records the vessel's body/nose axis.")
print("")
if yesNo("Launch sensor mapper now?", (cfg.sensors or {}).configured ~= true) then
  shell.run("/atlasos/apps/sensor_setup.lua")
  refreshConfig()
end
print("")
print("After mapping:")
print("  atlasctl sensors check")
print("  atlasctl sensors calibrate")
print("  atlasctl sensors commission")
pause()

heading("4/6 - NAVIGATION + GPS")
print("The Navigation Table remains the vessel heading instrument.")
print("Atlas Navigation Compatibility adds direct target/position")
print("integration and is preferred by NAV SOURCE = AUTO.")
print("")
local compatible, compatWhy = navigationProvider.navTableCompatibility(cfg)
if compatible then
  term.setTextColor(colors.lime)
  print("Navigation Table integration: AVAILABLE")
  term.setTextColor(colors.white)
else
  term.setTextColor(colors.yellow)
  print("Navigation Table integration: " .. tostring(compatWhy or "UNAVAILABLE"))
  term.setTextColor(colors.white)
end
print("")
print("If compatibility integration is unavailable, AtlasOS can")
print("use standard CC:Tweaked GPS as the navigation-position")
print("backend. You therefore need a GPS constellation before")
print("using GPS navigation or FULL AUTO.")
print("")
print("Recommended GPS constellation:")
print("  - 4 stationary wireless-modem computers")
print("  - place them at separated known world coordinates")
print("  - on each host run: gps host <x> <y> <z>")
print("  - on the vessel test with: gps locate")
print("")
print("Checking for a GPS fix now...")
local gpsOkay, gpsWhy, gpsState = gpsCheck()
if gpsOkay then
  term.setTextColor(colors.lime)
  print(string.format("GPS FIX: %.1f, %.1f, %.1f", gpsState.x, gpsState.y, gpsState.z))
  term.setTextColor(colors.white)
else
  term.setTextColor(colors.yellow)
  print("GPS FIX: unavailable (" .. tostring(gpsWhy or "no reply") .. ")")
  term.setTextColor(colors.white)
end
print("")
if not compatible and not gpsOkay then
  term.setTextColor(colors.red)
  print("NO NAVIGATION POSITION PROVIDER IS READY.")
  term.setTextColor(colors.white)
  print("Manual flight remains available, but navigation/FULL AUTO")
  print("must not be commissioned until GPS or compatibility works.")
elseif compatible then
  print("AUTO can use the Navigation Table integration.")
elseif gpsOkay then
  print("AUTO can fall back to GPS.")
end
pause()

heading("5/6 - FLIGHT ASSIST")
print("Flight assist closes the loop around the rudder, heading,")
print("navigation, altitude, and physical wheel override.")
print("")
print("Only continue after I/O and sensors have been mapped and")
print("the rudder has been calibrated.")
print("")
if yesNo("Launch flight-assist setup now?", (cfg.autoflight or {}).configured ~= true) then
  shell.run("/atlasos/apps/assist_setup.lua")
  refreshConfig()
end
print("")
print("Then run:")
print("  atlasctl assist check")
print("  atlasctl assist commission")
print("")
print("Commissioning is a ground test; propulsion stays locked.")
pause()

heading("6/6 - FINAL CHECK")
showStatus()
print("")
local ioOkay = ioControl.validate(cfg, true)
local sensorOkay = sensors.validate(cfg, true, true)
local assistOkay = assist.validate(cfg, true)
if ioOkay and sensorOkay and assistOkay then
  term.setTextColor(colors.lime)
  print("CORE FLIGHT HARDWARE: COMMISSIONED")
  term.setTextColor(colors.white)
else
  term.setTextColor(colors.yellow)
  print("SETUP IS NOT COMPLETE YET.")
  term.setTextColor(colors.white)
  print("Re-run this guide at any time: atlasctl ship setup")
end
print("")
print("Before the first real flight:")
print("  1. verify SAFE physically removes propulsion")
print("  2. verify manual wheel authority in SAFE")
print("  3. verify Pocket pairing and heartbeat SAFE behavior")
print("  4. test assisted steering before FULL AUTO")
print("  5. verify the chosen navigation source reports READY")
