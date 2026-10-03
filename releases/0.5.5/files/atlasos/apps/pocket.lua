
local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")
local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local net = require("atlasos.lib.net")
local display = require("atlasos.lib.display")
local settingsModel = require("atlasos.lib.settings")
local log = require("atlasos.lib.log")
local version = require("atlasos.version")

local cfg = config.load()
if cfg.role ~= "pocket" then error("This computer is not configured as the AtlasOS pocket controller", 0) end
if not cfg.serverId or not cfg.token then error("Pocket controller is not paired. Run atlasctl setup.", 0) end
local modemName, modemError = net.openWireless()
if not modemName then error(modemError, 0) end
-- CC:Tweaked exposes both normal and Ender Pocket modems as the back "modem"
-- peripheral and does not expose an advanced/Ender discriminator in the modem API.
-- "WIRELESS" is therefore accurate; the old "UPGRADE" label was misleading.
local modemDisplayName = (pocket and modemName == "back") and "WIRELESS" or modemName

local function unlock()
  if not cfg.operatorPinHash then return true end
  display.reset()
  display.header("ATLASOS LOCKED", "ID " .. os.getComputerID(), colors.yellow)
  display.writeAt(2, 5, "Operator PIN required", colors.white)
  display.writeAt(2, 7, "PIN: ", colors.lightGray)
  term.setCursorPos(7, 7)
  term.setCursorBlink(true)
  local entered = read("*")
  term.setCursorBlink(false)
  if util.hash(entered) == cfg.operatorPinHash then return true end
  display.writeAt(2, 9, "ACCESS DENIED", colors.red)
  sleep(1.5)
  return false
end
while not unlock() do end

local state = {
  page = 1,
  systemPage = 1,
  systemSelection = 1,
  online = false,
  lastReplyAt = 0,
  lastPingAt = 0,
  status = nil,
  control = { lift = 0, thrust = 0, reverse = false, gyro = false, rudder = 0 },
  sequence = 0,
  notice = "v0.5.5-dev2 Configurable Cockpit ready",
  noticeUntil = 0,
  armNonce = nil,
  armExpiresAt = 0,
  mouseRudder = false,
  navMenu = false,
  navSelection = 1,
  navScroll = 1,
  navDeleteConfirm = nil,
  session = util.token(12),
  synced = false,
  serverBootId = nil,
  lastStatusSerial = 0,
  armButtonLockUntil = 0,
  armRequestAt = 0,
  armConfirmAt = 0,
  safePending = false,
  safeReason = nil,
  safeSentAt = 0,
}


local pages = { "FLIGHT", "AUTO", "RADIO", "SYSTEM" }
local systemPages = { "STATUS", "AUTO", "ASSIST", "DISPLAY" }
local hit = {}

local function setNotice(text, duration)
  state.notice = tostring(text or "")
  state.noticeUntil = util.nowMillis() + (duration or 2200)
end

local function send(kind, payload)
  local body = payload or {}
  body.token = cfg.token
  body.session = state.session
  return net.send(cfg.serverId, kind, body, net.CONTROL_PROTOCOL)
end

local function sendChecked(kind, payload, failureText)
  local ok = send(kind, payload)
  if not ok then
    setNotice(failureText or (tostring(kind) .. " FAILED TO SEND"), 3000)
    return false
  end
  return true
end

local function linkReady()
  return state.online and state.synced
end

local function sendControl()
  if not linkReady() or not state.status or not state.status.armed then return end
  state.sequence = state.sequence + 1
  send("CONTROL", { sequence = state.sequence, control = util.deepCopy(state.control) })
end

local function sendAssist(action, value)
  if not linkReady() then setNotice("LINK RESYNCING", 2200); return end
  sendChecked("ASSIST_COMMAND", { action = action, value = value }, "ASSIST COMMAND FAILED TO SEND")
end

local function sendNavigation(action, value)
  if not linkReady() then setNotice("LINK RESYNCING", 2200); return end
  sendChecked("NAV_COMMAND", { action = action, value = value }, "NAV COMMAND FAILED TO SEND")
end

local function sendRadio(action, value)
  if not linkReady() then setNotice("LINK RESYNCING", 2200); return end
  sendChecked("RADIO_COMMAND", { action = action, value = value }, "RADIO COMMAND FAILED TO SEND")
end


local function sendSetting(action, key, value)
  if not linkReady() then setNotice("LINK RESYNCING", 2200); return end
  sendChecked("SETTINGS_COMMAND", {
    action = action,
    key = key,
    value = value,
  }, "SETTING FAILED TO SEND")
end

local function ping()
  state.lastPingAt = util.nowMillis()
  if state.synced then send("PING", {})
  else send("SYNC", { reason = "Pocket link synchronization" }) end
end


local function serverArmed()
  -- REMOTE HOLD keeps the onboard flight computer logically armed so it can
  -- stabilize the ship, but remote controls are intentionally locked.
  return state.status and state.status.armed == true and state.status.linkHold ~= true
end

local function serverLinkHold()
  return state.status and state.status.linkHold == true
end

local function neutraliseLocal()
  state.control.lift = 0
  state.control.thrust = 0
  state.control.reverse = false
  state.control.rudder = 0
  if state.status and state.status.control then state.control.gyro = state.status.control.gyro == true else state.control.gyro = false end
end

local function beginResync(reason)
  local wasLinked = state.online or state.synced
  neutraliseLocal()
  state.online = false
  state.synced = false
  state.status = nil
  state.armNonce = nil
  state.armExpiresAt = 0
  state.armRequestAt = 0
  state.armConfirmAt = 0
  state.sequence = 0
  -- New session token makes all delayed packets from the pre-timeout session stale.
  state.session = util.token(12)
  if wasLinked then setNotice(reason or "LINK LOST - RESYNCING", 2600) end
end

local function transmitSafe()
  if not state.safePending then return false end
  state.safeSentAt = util.nowMillis()
  return send("SAFE_REQUEST", { reason = state.safeReason or "operator request" })
end

local function clearSafePending()
  state.safePending = false
  state.safeReason = nil
  state.safeSentAt = 0
end

local function requestSafe(reason)
  state.safePending = true
  state.safeReason = reason or "operator request"
  neutraliseLocal()
  state.armNonce = nil
  state.armRequestAt = 0
  state.armConfirmAt = 0
  if transmitSafe() then
    setNotice("SAFE REQUEST SENT", 1800)
  else
    setNotice("SAFE REQUEST RETRYING", 2200)
  end
end

local function beginOrConfirmArm()
  if state.safePending then
    transmitSafe()
    setNotice("SAFE CONFIRMATION PENDING", 1800)
    return
  end
  if not linkReady() then setNotice("LINK RESYNCING", 2200); return end
  if serverArmed() then
    if util.nowMillis() < state.armButtonLockUntil then
      setNotice("ARMED - RELEASE BUTTON", 1000)
      return
    end
    requestSafe("operator disarm")
    return
  end
  if not util.isNeutralControl(state.control) then setNotice("ZERO CONTROLS FIRST", 2400); return end
  local now = util.nowMillis()
  if state.armNonce and now < state.armExpiresAt then
    if sendChecked("ARM_CONFIRM", { nonce = state.armNonce }, "ARM CONFIRM FAILED TO SEND") then
      state.armConfirmAt = now
      state.armRequestAt = 0
      setNotice("ARM CONFIRM SENT", 1800)
    end
  else
    if sendChecked("ARM_REQUEST", { control = util.deepCopy(state.control) }, "ARM REQUEST FAILED TO SEND") then
      state.armRequestAt = now
      state.armConfirmAt = 0
      setNotice("REQUESTING ARM...", 2400)
    end
  end
end

local function changeLevel(name, delta)
  if not serverArmed() then setNotice("ARM CONTROLS FIRST", 1800); return end
  state.control[name] = util.clamp((state.control[name] or 0) + delta, 0, 15)
  sendControl()
end

local function setLevelFromBar(name, x, x1, x2)
  if not serverArmed() then setNotice("ARM CONTROLS FIRST", 1800); return end
  local ratio = util.clamp((x - x1) / math.max(1, x2 - x1), 0, 1)
  state.control[name] = util.clamp(util.round(ratio * 15), 0, 15)
  sendControl()
end

local function toggleReverse()
  if not serverArmed() then setNotice("ARM CONTROLS FIRST", 1800); return end
  if state.control.thrust ~= 0 then setNotice("THRUST MUST BE 0", 2200); return end
  state.control.reverse = not state.control.reverse
  sendControl()
end

local function toggleGyro()
  if not serverArmed() then setNotice("ARM CONTROLS FIRST", 1800); return end
  state.control.gyro = not state.control.gyro
  sendControl()
end

local function setRudder(value)
  if not serverArmed() then return end
  state.control.rudder = util.clamp(value, -1, 1)
  sendControl()
end

local function centreRudder()
  if not serverArmed() then setNotice("ARM CONTROLS FIRST", 1800); return end
  state.mouseRudder = false
  state.control.rudder = 0
  sendControl()
  sendAssist("rudder_center")
  setNotice("TRUE 0 CENTER", 1600)
end

local function drawTabs(width, height)
  local count = #pages
  local base = math.floor(width / count)
  for index, page in ipairs(pages) do
    local x = (index - 1) * base + 1
    local buttonWidth = index == count and (width - x + 1) or base
    -- Optical centering for the two inner labels on the pocket's fixed-width display.
    -- FLIGHT and SYSTEM remain exactly where they were; click zones are unchanged.
    local label = page
    if page == "AUTO" then label = "  AUTO"
    elseif page == "RADIO" then label = " RADIO" end
    display.button(x, height, buttonWidth, label, state.page == index, false)
  end
end

local function drawBar(y, label, value)
  local width = select(1, term.getSize())
  display.writeAt(2, y, label, colors.lightGray)
  display.writeAt(width - 2, y, string.format("%02d", value), colors.white)
  display.button(2, y + 1, 4, "-", false, false)
  display.button(width - 4, y + 1, 4, "+", false, false)
  local x1, x2 = 7, width - 6
  local barWidth = x2 - x1 + 1
  display.fill(x1, y + 1, barWidth, 1, colors.gray)
  local filled = util.round((value / 15) * barWidth)
  if filled > 0 then display.fill(x1, y + 1, filled, 1, colors.orange) end
  hit[label:lower() .. "Minus"] = { 2, y + 1, 5, y + 1 }
  hit[label:lower() .. "Plus"] = { width - 4, y + 1, width - 1, y + 1 }
  hit[label:lower() .. "Bar"] = { x1, y + 1, x2, y + 1 }
end

local function drawFlight(width)
  local armed = serverArmed()
  local linkHold = serverLinkHold()
  local stateLabel = linkHold and "REMOTE HOLD" or (armed and "ARMED" or "SAFE")
  local stateColor = linkHold and colors.yellow or (armed and colors.orange or colors.gray)
  display.fill(1, 3, width, 1, stateColor)
  display.writeAt(1, 3, util.center(stateLabel, width), colors.white, stateColor)
  drawBar(4, "LIFT", state.control.lift)
  drawBar(7, "THRUST", state.control.thrust)

  display.button(2, 10, 11, state.control.reverse and "REV ON" or "REV OFF", state.control.reverse, false)
  display.button(14, 10, width - 14, state.control.gyro and "GYRO ON" or "GYRO OFF", state.control.gyro, false)
  hit.reverse = { 2, 10, 12, 10 }
  hit.gyro = { 14, 10, width - 1, 10 }

  local assistState = state.status and state.status.assist or {}
  display.writeAt(2, 12, "RUDDER " .. string.format("%+.0f>%+.0f",
    tonumber(assistState.rudderCurrentDeg) or 0, tonumber(assistState.rudderTargetDeg) or 0), colors.lightGray)
  display.button(2, 13, 6, "LEFT", state.control.rudder == -1, false)
  display.button(9, 13, 9, "CENTER", false, false)
  display.button(19, 13, 6, "RIGHT", state.control.rudder == 1, false)
  hit.rudderLeft = { 2, 13, 7, 13 }
  hit.rudderCenter = { 9, 13, 17, 13 }
  hit.rudderRight = { 19, 13, 24, 13 }

  local armLabel = "ARM CONTROLS"
  if armed then armLabel = "DISARM / SAFE"
  elseif state.armNonce and util.nowMillis() < state.armExpiresAt then armLabel = "CONFIRM ARM" end
  display.button(2, 15, width - 2, armLabel, true, armed)
  hit.arm = { 2, 15, width - 1, 15 }

  display.writeAt(2, 17, "A/D jog | C true-centre", colors.gray)
  display.writeAt(2, 18, "Arrows lift | W/S power", colors.gray)
end

local function signed(value, decimals, suffix)
  if value == nil then return "-" end
  return string.format("%+." .. tostring(decimals or 1) .. "f%s", tonumber(value) or 0, suffix or "")
end

local function navItems()
  local nav = state.status and state.status.navigation or {}
  local items = {}
  for _, waypoint in ipairs(nav.waypoints or {}) do
    items[#items + 1] = {
      kind = "waypoint",
      label = tostring(waypoint.label or "Waypoint"),
      waypoint = waypoint,
    }
  end
  items[#items + 1] = { kind = "direct", label = "[ENTER COORDS]" }
  items[#items + 1] = { kind = "clear", label = "[CLEAR NAV TARGET]" }
  return items
end

local function clampNavSelection()
  local items = navItems()
  state.navSelection = util.clamp(tonumber(state.navSelection) or 1, 1, math.max(1, #items))
  local visible = 8
  if state.navSelection < state.navScroll then state.navScroll = state.navSelection end
  if state.navSelection >= state.navScroll + visible then state.navScroll = state.navSelection - visible + 1 end
  state.navScroll = math.max(1, state.navScroll)
  return items
end

local function promptCoordinates()
  display.reset()
  local width = select(1, term.getSize())
  display.header("ATLASOS DESTINATION", "DIRECT", colors.orange)
  display.writeAt(2, 4, "World X:", colors.lightGray)
  term.setCursorPos(11, 4)
  term.setTextColor(colors.white)
  term.setCursorBlink(true)
  local xText = read()
  display.writeAt(2, 6, "World Z:", colors.lightGray)
  term.setCursorPos(11, 6)
  local zText = read()
  display.writeAt(2, 8, "Name (optional):", colors.lightGray)
  term.setCursorPos(2, 9)
  local name = read()
  term.setCursorBlink(false)

  local x, z = tonumber(xText), tonumber(zText)
  if not x or not z then
    setNotice("INVALID COORDINATES", 3000)
    return
  end
  name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
  sendNavigation("set_direct", {
    x = x,
    z = z,
    label = name,
    save = name ~= "",
  })
  state.navMenu = false
end

local function activateNavItem(item)
  if not item then return end
  if item.kind == "waypoint" then
    sendNavigation("activate_waypoint", { label = item.label })
    state.navMenu = false
  elseif item.kind == "direct" then
    promptCoordinates()
  elseif item.kind == "clear" then
    sendNavigation("clear", {})
    state.navMenu = false
  end
end

local function beginDeleteWaypoint(item)
  if not item or item.kind ~= "waypoint" then
    setNotice("SELECT A WAYPOINT", 1800)
    return
  end
  state.navDeleteConfirm = util.deepCopy(item.waypoint or { label = item.label })
end

local function confirmDeleteWaypoint()
  local waypoint = state.navDeleteConfirm
  if not waypoint then return end
  sendNavigation("delete_waypoint", { label = waypoint.label })
  state.navDeleteConfirm = nil
end

local function drawDeleteConfirmation(width)
  local waypoint = state.navDeleteConfirm or {}
  local nav = state.status and state.status.navigation or {}
  local target = nav.target or {}
  local active = target.active == true and
    tostring(target.label or ""):lower() == tostring(waypoint.label or ""):lower()

  display.writeAt(2, 4, "DELETE WAYPOINT?", colors.red)
  display.writeWrapped(2, 6, tostring(waypoint.label or "Waypoint"), width - 2, colors.white, nil, 2)
  if waypoint.x ~= nil and waypoint.z ~= nil then
    display.writeAt(2, 9, string.format("X %.0f  Z %.0f", tonumber(waypoint.x) or 0, tonumber(waypoint.z) or 0), colors.lightGray)
  end
  if active then
    display.writeWrapped(2, 11, "ACTIVE TARGET WILL ALSO CLEAR", width - 2, colors.orange, nil, 2)
  end

  display.button(2, 14, width - 2, "CONFIRM DELETE", true, true)
  display.button(2, 16, width - 2, "CANCEL", false, false)
  hit.navDeleteConfirm = { 2, 14, width - 1, 14 }
  hit.navDeleteCancel = { 2, 16, width - 1, 16 }
end

local function drawDestinationMenu(width)
  local nav = state.status and state.status.navigation or {}
  display.writeAt(2, 4, "DESTINATION", colors.orange)
  if not nav.programmable then
    display.writeWrapped(2, 6, tostring(nav.compatibilityError or "Atlas Navigation Compatibility unavailable"),
      width - 2, colors.red, nil, 4)
    display.button(2, 16, width - 2, "BACK", false, false)
    hit.navBack = { 2, 16, width - 1, 16 }
    return
  end

  if state.navDeleteConfirm then
    drawDeleteConfirmation(width)
    return
  end

  local target = nav.target or {}
  local activeLabel = target.active and tostring(target.label or "Navigation target") or "NONE"
  display.writeAt(2, 5, "ACTIVE: " .. util.truncate(activeLabel, width - 10), target.active and colors.lime or colors.gray)

  local items = clampNavSelection()
  hit.navRows = {}
  local row = 7
  for index = state.navScroll, math.min(#items, state.navScroll + 7) do
    local item = items[index]
    local selected = index == state.navSelection
    local prefix = selected and "> " or "  "
    local text = prefix .. util.truncate(item.label, width - 5)
    display.writeAt(2, row, text, selected and colors.orange or colors.white)
    hit.navRows[#hit.navRows + 1] = { box = { 2, row, width - 1, row }, index = index }
    row = row + 1
  end

  local selected = items[state.navSelection]
  local canDelete = selected and selected.kind == "waypoint"
  display.writeAt(2, 15, "Enter select | D delete", colors.gray)
  display.button(2, 16, 11, "SELECT", true, false)
  display.button(14, 16, width - 14, canDelete and "DELETE" or "--", false, canDelete)
  display.button(2, 17, width - 2, "BACK", false, false)
  hit.navSelect = { 2, 16, 12, 16 }
  if canDelete then hit.navDelete = { 14, 16, width - 1, 16 } end
  hit.navBack = { 2, 17, width - 1, 17 }
end

local function drawAuto(width)
  if state.navMenu then
    drawDestinationMenu(width)
    return
  end

  local telemetry = state.status and state.status.telemetry or nil
  local af = state.status and state.status.assist or {}
  local mission = state.status and state.status.mission or {}
  local nav = state.status and state.status.navigation or {}
  if not telemetry then
    display.writeWrapped(2, 5, "Waiting for telemetry from the onboard server.", width - 2, colors.lightGray, nil, 4)
    return
  end

  local missionActive = mission.autopilot or mission.arrival
  local missionLabel = mission.autopilot and ("FULL AUTO " .. tostring(mission.phase or ""))
    or (mission.arrival and "ARRIVED" or "NAV / MANUAL")
  display.writeAt(2, 4, "MISSION: " .. string.upper(util.truncate(missionLabel, width - 11)),
    mission.autopilot and colors.orange or (mission.arrival and colors.lime or colors.lightGray))
  display.button(2, 5, width - 2, missionActive and "DISENGAGE FULL AUTO" or "ENGAGE FULL AUTO", true, missionActive)
  hit.autopilot = { 2, 5, width - 1, 5 }

  display.button(2, 7, 11, af.steeringMode == "heading" and "HDG ON" or "HDG HOLD", af.steeringMode == "heading", false)
  display.button(14, 7, 11, af.steeringMode == "navigation" and "NAV ON" or "NAV STEER", af.steeringMode == "navigation", false)
  hit.headingToggle = { 2, 7, 12, 7 }
  hit.navigationToggle = { 14, 7, 24, 7 }

  display.button(2, 9, 11, af.altitudeMode == "hold" and "ALT ON" or "ALT HOLD", af.altitudeMode == "hold", false)
  display.button(14, 9, 11, "ASSIST OFF", false, true)
  hit.altitudeToggle = { 2, 9, 12, 9 }
  hit.assistOff = { 14, 9, 24, 9 }

  display.writeAt(2, 11, string.format("HDG %03.0f>%03.0f", telemetry.heading or 0, af.headingTarget or telemetry.heading or 0), colors.lightGray)
  display.button(16, 11, 4, "-5", false, false)
  display.button(21, 11, 4, "+5", false, false)
  hit.headingMinus = { 16, 11, 19, 11 }
  hit.headingPlus = { 21, 11, 24, 11 }

  display.writeAt(2, 13, string.format("ALT %.1f>%.1f", telemetry.altitude or 0, af.altitudeTarget or telemetry.altitude or 0), colors.lightGray)
  display.button(16, 13, 4, "-1", false, false)
  display.button(21, 13, 4, "+1", false, false)
  hit.altMinus1 = { 16, 13, 19, 13 }
  hit.altPlus1 = { 21, 13, 24, 13 }

  local target = nav.target or {}
  local destName
  if target.active then destName = tostring(target.label or "NAV TARGET")
  elseif telemetry.hasTarget then destName = "PHYSICAL TARGET"
  else destName = "NONE" end
  display.button(2, 15, width - 2, "DEST: " .. util.truncate(destName, width - 10), false, false)
  hit.destination = { 2, 15, width - 1, 15 }

  if telemetry.hasTarget then
    local displayDistance = tonumber(telemetry.horizontalDistance)
    if not displayDistance then
      local d = tonumber(telemetry.distance) or 0
      local y = math.abs(tonumber(telemetry.verticalOffset) or 0)
      displayDistance = math.sqrt(math.max(0, d * d - y * y))
    end
    display.writeAt(2, 16, string.format("BRG %+.0f  DST %.0fm", tonumber(telemetry.bearing) or 0, displayDistance), colors.lightGray)
    if mission.autopilot then
      display.writeAt(2, 17, string.format("SPD %.1f>%.1f %s", tonumber(mission.currentSpeed) or tonumber(telemetry.horizontalSpeed) or 0,
        tonumber(mission.targetSpeed) or 0, tostring(mission.phase or "")), colors.lightGray)
    else
      display.writeAt(2, 17, "V/S " .. signed(telemetry.verticalSpeed, 1, " m/s"), colors.lightGray)
    end
  elseif target.active and nav.activeSource == "gps" and nav.gpsAvailable ~= true then
    display.writeAt(2, 16, "GPS FIX: WAITING", colors.yellow)
  elseif not nav.programmable then
    display.writeAt(2, 16, "NAV SOURCE: UNAVAILABLE", colors.red)
  else
    display.writeAt(2, 16, "NAV TARGET: NONE", colors.gray)
  end
  display.writeAt(2, 18, state.status.autoflightReady and "FLIGHT ASSIST READY" or "FLIGHT ASSIST LOCKED",
    state.status.autoflightReady and colors.lime or colors.red)
end

local function formatTime(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function drawRadio(width)
  local rs = state.status and state.status.radio or {}
  display.writeAt(2, 4, "KESSOKU BAND RADIO", colors.magenta)
  local speakerCount = tonumber(rs.speakerCount) or (rs.speakerPresent and 1 or 0)
  local speakerText
  if speakerCount <= 0 then speakerText = "SPEAKER MISSING"
  elseif speakerCount == 1 then speakerText = "1 SPEAKER READY"
  else speakerText = tostring(speakerCount) .. " SPEAKERS READY" end
  display.writeAt(2, 5, speakerText, speakerCount > 0 and colors.lime or colors.red)
  local quality = tostring(rs.quality or "")
  local trackLine = string.format("TRACK %d/%d", tonumber(rs.index) or 0, tonumber(rs.libraryCount) or 0)
  if quality ~= "" then trackLine = trackLine .. "  " .. quality end
  display.writeAt(2, 6, util.truncate(trackLine, width - 3), rs.format == "pcm" and colors.lime or colors.lightGray)

  display.writeAt(2, 8, util.truncate(tostring(rs.title or "No track loaded"), width - 3), colors.white)
  display.writeAt(2, 9, util.truncate(tostring(rs.artist or "Music disk required"), width - 3), colors.lightGray)
  display.writeAt(2, 10, string.format("%s / %s", formatTime(rs.elapsed), formatTime(rs.duration)), colors.gray)

  display.button(2, 12, 7, "PREV", false, false)
  display.button(10, 12, 7, rs.playing and (rs.paused and "RESUME" or "PAUSE") or "PLAY", rs.playing and not rs.paused, false)
  display.button(18, 12, 7, "NEXT", false, false)
  hit.radioPrev = { 2, 12, 8, 12 }
  hit.radioPlay = { 10, 12, 16, 12 }
  hit.radioNext = { 18, 12, 24, 12 }

  display.button(2, 14, 11, rs.shuffle and "SHUFFLE ON" or "SHUFFLE", rs.shuffle, false)
  display.button(14, 14, 11, "RPT " .. string.upper(tostring(rs.repeatMode or "all")), rs.repeatMode ~= "off", false)
  hit.radioShuffle = { 2, 14, 12, 14 }
  hit.radioRepeat = { 14, 14, 24, 14 }

  display.button(2, 16, 5, "VOL-", false, false)
  display.writeAt(9, 16, string.format("VOL %.1f", tonumber(rs.volume) or 0), colors.lightGray)
  display.button(20, 16, 5, "VOL+", false, false)
  hit.radioVolMinus = { 2, 16, 6, 16 }
  hit.radioVolPlus = { 20, 16, 24, 16 }

  display.button(2, 18, 11, "RESCAN", false, false)
  display.button(14, 18, 11, "STOP", false, true)
  hit.radioRescan = { 2, 18, 12, 18 }
  hit.radioStop = { 14, 18, 24, 18 }
end

local function systemSettingsValues()
  return (((state.status or {}).settings or {}).values or {})
end

local function currentSystemFields()
  local page = systemPages[state.systemPage]
  if page == "AUTO" then return settingsModel.group("auto") end
  if page == "ASSIST" then return settingsModel.group("assist") end
  if page == "DISPLAY" then return settingsModel.group("display") end
  return {}
end

local function clampSystemSelection()
  local fields = currentSystemFields()
  state.systemSelection = util.clamp(tonumber(state.systemSelection) or 1, 1, math.max(1, #fields))
  return fields
end

local function selectedSystemField()
  local fields = clampSystemSelection()
  return fields[state.systemSelection]
end

local function telemetryCandidates()
  local result = { "auto" }
  for _, name in ipairs((((state.status or {}).telemetryDisplay or {}).candidates or {})) do
    result[#result + 1] = tostring(name)
  end
  return result
end

local function nextFromList(list, current, direction)
  local index = 1
  for i, value in ipairs(list) do
    if tostring(value or "") == tostring(current or "") then index = i; break end
  end
  index = ((index - 1 + direction) % #list) + 1
  return list[index]
end

local function adjustSystemSetting(direction)
  local field = selectedSystemField()
  if not field then return end
  local values = systemSettingsValues()
  local current = values[field.key]

  if field.kind == "boolean" then
    sendSetting("toggle", field.key)
  elseif field.kind == "scale" then
    sendSetting("set", field.key, nextFromList({ "auto", 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0 }, current, direction))
  elseif field.kind == "peripheral" then
    sendSetting("set", field.key, nextFromList(telemetryCandidates(), current or "auto", direction))
  elseif field.kind == "enum" then
    local options = field.options or { "auto" }
    sendSetting("set", field.key, nextFromList(options, current, direction))
  else
    sendSetting("adjust", field.key, direction)
  end
end

local function activateSystemSetting()
  local field = selectedSystemField()
  if not field then return end
  if field.kind == "boolean" or field.kind == "scale" or field.kind == "peripheral" or field.kind == "enum" then
    adjustSystemSetting(1)
  end
end

local function resetSystemSetting()
  local field = selectedSystemField()
  if field then sendSetting("reset", field.key) end
end

local function drawSystemTabs(width)
  hit.systemTabs = {}
  local base = math.floor(width / #systemPages)
  for index, page in ipairs(systemPages) do
    local x = (index - 1) * base + 1
    local buttonWidth = index == #systemPages and (width - x + 1) or base
    local label = page
    if page == "STATUS" then label = "STAT"
    elseif page == "ASSIST" then label = "PID"
    elseif page == "DISPLAY" then label = "DISP" end
    display.button(x, 4, buttonWidth, label, state.systemPage == index, false)
    hit.systemTabs[index] = { x, 4, x + buttonWidth - 1, 4 }
  end
end

local function drawSystemStatus(width)
  display.writeAt(2, 6, "SYSTEM STATUS", colors.orange)
  display.labelValue(7, "Pocket ID", os.getComputerID())
  display.labelValue(8, "Server ID", cfg.serverId)
  display.labelValue(9, "Link", state.online and "ONLINE" or "OFFLINE", state.online and colors.lime or colors.red)
  if state.status then
    display.labelValue(10, "Hardware", state.status.hardwareValid and "READY" or "LOCKED",
      state.status.hardwareValid and colors.lime or colors.red)
    display.labelValue(11, "Sensors", state.status.sensorsValid and "READY" or "DEGRADED",
      state.status.sensorsValid and colors.lime or colors.yellow)
    display.labelValue(12, "Assist", state.status.autoflightReady and "READY" or "LOCKED",
      state.status.autoflightReady and colors.lime or colors.yellow)
    local td = state.status.telemetryDisplay or {}
    local displayText = td.enabled == false and "OFF" or (td.bound and "ONLINE" or "WAITING")
    display.labelValue(13, "Telemetry", displayText,
      td.enabled == false and colors.gray or (td.bound and colors.lime or colors.yellow))
    local nav = state.status.navigation or {}
    display.labelValue(14, "Nav source", tostring(nav.activeSource or "none"):upper(),
      (nav.activeSource == "nav_table" or nav.activeSource == "gps") and colors.lime or colors.yellow)
    display.labelValue(15, "Uptime", util.formatDuration(state.status.uptimeMs or 0))
  end
  display.button(2, 17, width - 2, "ASSERT SAFE STATE", true, true)
  hit.safe = { 2, 17, width - 1, 17 }
  display.writeAt(2, 18, "SAFE before tuning flight.", colors.gray)
end

local function drawSettingsEditor(width, title)
  local fields = clampSystemSelection()
  local values = systemSettingsValues()
  display.writeAt(2, 6, title, colors.orange)
  hit.systemRows = {}

  local first = 1
  if state.systemSelection > 7 then first = state.systemSelection - 6 end
  local row = 7
  for index = first, math.min(#fields, first + 6) do
    local field = fields[index]
    local selected = index == state.systemSelection
    local value = settingsModel.format(field.key, values[field.key])
    local prefix = selected and "> " or "  "
    local available = math.max(5, width - #value - 4)
    local label = util.truncate(field.label, available)
    local line = prefix .. label
    display.writeAt(2, row, line, selected and colors.orange or colors.lightGray)
    display.writeAt(math.max(2, width - #value), row, value, selected and colors.white or colors.lightGray)
    hit.systemRows[#hit.systemRows + 1] = { box = { 2, row, width - 1, row }, index = index }
    row = row + 1
  end

  local field = selectedSystemField()
  if field then
    local locked = field.safeOnly and state.status and state.status.armed
    display.writeAt(2, 15, locked and "LOCKED WHILE ARMED" or
      (field.kind and "Tap/cycle value" or ("STEP " .. tostring(field.step or 1))),
      locked and colors.red or colors.gray)

    display.button(2, 17, 5, "-", false, false)
    display.button(8, 17, 10, "RESET", false, false)
    display.button(19, 17, width - 19, "+", false, false)
    hit.settingMinus = { 2, 17, 6, 17 }
    hit.settingReset = { 8, 17, 17, 17 }
    hit.settingPlus = { 19, 17, width - 1, 17 }
  end
  display.writeAt(2, 18, "Up/Down select  L/R edit", colors.gray)
end

local function drawDisplaySettings(width)
  drawSettingsEditor(width, "DISPLAY / NAV PREFS")
  local td = state.status and state.status.telemetryDisplay or {}
  if td and td.name then
    display.writeAt(2, 14, "BOUND: " .. util.truncate(td.name, width - 9), colors.orange)
  elseif td and td.enabled == false then
    display.writeAt(2, 14, "BOUND: DISABLED", colors.gray)
  else
    display.writeAt(2, 14, "BOUND: WAITING", colors.yellow)
  end
end

local function drawSystem(width)
  drawSystemTabs(width)
  local page = systemPages[state.systemPage]
  if page == "STATUS" then drawSystemStatus(width)
  elseif page == "AUTO" then drawSettingsEditor(width, "FULL AUTO TUNING")
  elseif page == "ASSIST" then drawSettingsEditor(width, "ASSIST PID TUNING")
  else drawDisplaySettings(width) end
end

local function draw()
  hit = {}
  display.reset()
  local width, height = term.getSize()
  local linkText = state.online and "LINK" or "NO LINK"
  display.header("ATLASOS " .. version.version, linkText, state.online and colors.lime or colors.red)
  if state.page == 1 then drawFlight(width)
  elseif state.page == 2 then drawAuto(width)
  elseif state.page == 3 then drawRadio(width)
  else drawSystem(width) end
  if state.noticeUntil > util.nowMillis() then
    -- Reserve the FLIGHT ARM row. Five-line notices previously painted over it.
    local noticeRows = math.min(3, math.max(1, height - 4))
    local noticeY = height - noticeRows
    display.fill(1, noticeY, width, noticeRows, colors.black)
    display.writeWrapped(2, noticeY, state.notice, width - 2, colors.yellow, colors.black, noticeRows)
  end
  drawTabs(width, height)
end

local function inside(box, x, y)
  return box and x >= box[1] and x <= box[3] and y >= box[2] and y <= box[4]
end

local function handleClick(x, y, width, height)
  if state.page == 2 and state.navMenu then
    if state.navDeleteConfirm then
      if inside(hit.navDeleteConfirm, x, y) then confirmDeleteWaypoint(); return end
      if inside(hit.navDeleteCancel, x, y) then state.navDeleteConfirm = nil; return end
      return
    end
    if inside(hit.navBack, x, y) then state.navMenu = false; return end
    if inside(hit.navSelect, x, y) then activateNavItem(navItems()[state.navSelection]); return end
    if inside(hit.navDelete, x, y) then beginDeleteWaypoint(navItems()[state.navSelection]); return end
    for _, row in ipairs(hit.navRows or {}) do
      if inside(row.box, x, y) then
        state.navSelection = row.index
        clampNavSelection()
        return
      end
    end
    return
  end
  if y == height then
    local base = math.floor(width / #pages)
    state.page = util.clamp(math.floor((x - 1) / math.max(1, base)) + 1, 1, #pages)
    return
  end
  if state.page == 1 then
    if inside(hit.liftMinus, x, y) then changeLevel("lift", -1)
    elseif inside(hit.liftPlus, x, y) then changeLevel("lift", 1)
    elseif inside(hit.liftBar, x, y) then setLevelFromBar("lift", x, hit.liftBar[1], hit.liftBar[3])
    elseif inside(hit.thrustMinus, x, y) then changeLevel("thrust", -1)
    elseif inside(hit.thrustPlus, x, y) then changeLevel("thrust", 1)
    elseif inside(hit.thrustBar, x, y) then setLevelFromBar("thrust", x, hit.thrustBar[1], hit.thrustBar[3])
    elseif inside(hit.reverse, x, y) then toggleReverse()
    elseif inside(hit.gyro, x, y) then toggleGyro()
    elseif inside(hit.rudderLeft, x, y) then state.mouseRudder = true; setRudder(-1)
    elseif inside(hit.rudderCenter, x, y) then centreRudder()
    elseif inside(hit.rudderRight, x, y) then state.mouseRudder = true; setRudder(1)
    elseif inside(hit.arm, x, y) then beginOrConfirmArm() end
  elseif state.page == 2 then
    if inside(hit.autopilot, x, y) then sendAssist("autopilot_toggle")
    elseif inside(hit.destination, x, y) then state.navMenu = true; state.navSelection = 1; state.navScroll = 1; state.navDeleteConfirm = nil
    elseif inside(hit.headingToggle, x, y) then sendAssist("heading_toggle")
    elseif inside(hit.navigationToggle, x, y) then sendAssist("navigation_toggle")
    elseif inside(hit.headingMinus, x, y) then sendAssist("heading_adjust", -5)
    elseif inside(hit.headingPlus, x, y) then sendAssist("heading_adjust", 5)
    elseif inside(hit.altitudeToggle, x, y) then sendAssist("altitude_toggle")
    elseif inside(hit.assistOff, x, y) then sendAssist("assist_off")
    elseif inside(hit.altMinus1, x, y) then sendAssist("altitude_adjust", -1)
    elseif inside(hit.altPlus1, x, y) then sendAssist("altitude_adjust", 1) end
  elseif state.page == 3 then
    if inside(hit.radioPrev, x, y) then sendRadio("previous")
    elseif inside(hit.radioPlay, x, y) then sendRadio("play_pause")
    elseif inside(hit.radioNext, x, y) then sendRadio("next")
    elseif inside(hit.radioShuffle, x, y) then sendRadio("shuffle")
    elseif inside(hit.radioRepeat, x, y) then sendRadio("repeat")
    elseif inside(hit.radioStop, x, y) then sendRadio("stop")
    elseif inside(hit.radioVolMinus, x, y) then sendRadio("volume_delta", -0.1)
    elseif inside(hit.radioVolPlus, x, y) then sendRadio("volume_delta", 0.1)
    elseif inside(hit.radioRescan, x, y) then sendRadio("rescan") end
  elseif state.page == 4 then
    for index, box in ipairs(hit.systemTabs or {}) do
      if inside(box, x, y) then
        state.systemPage = index
        state.systemSelection = 1
        return
      end
    end
    for _, row in ipairs(hit.systemRows or {}) do
      if inside(row.box, x, y) then
        state.systemSelection = row.index
        return
      end
    end
    if inside(hit.safe, x, y) then requestSafe("system page")
    elseif inside(hit.settingMinus, x, y) then adjustSystemSetting(-1)
    elseif inside(hit.settingPlus, x, y) then adjustSystemSetting(1)
    elseif inside(hit.settingReset, x, y) then resetSystemSetting() end
  end
end

local function handleDrag(x, y)
  -- Drag events are continuous input only. Never route a drag through discrete
  -- buttons such as ARM/SAFE, gyro, reverse, tabs, navigation, or radio.
  if state.page ~= 1 then return end
  if inside(hit.liftBar, x, y) then
    setLevelFromBar("lift", x, hit.liftBar[1], hit.liftBar[3])
  elseif inside(hit.thrustBar, x, y) then
    setLevelFromBar("thrust", x, hit.thrustBar[1], hit.thrustBar[3])
  end
end

local function syncFromStatus(status)
  if not status then return end
  local desired = status.desired or status.control
  if desired then
    state.control.lift = tonumber(desired.lift) or state.control.lift
    state.control.thrust = tonumber(desired.thrust) or state.control.thrust
    state.control.reverse = desired.reverse == true
    state.control.gyro = desired.gyro == true
  end
  if not status.armed then state.control.rudder = 0 end
end

local function handleMessage(sender, message, protocol)
  if sender ~= cfg.serverId or protocol ~= net.CONTROL_PROTOCOL or not net.valid(message) then return end
  if message.token ~= cfg.token then return end

  -- Replies are session-bound. Delayed messages from before a timeout/reconnect are
  -- ignored instead of overwriting the current Pocket state.
  if tostring(message.session or "") ~= tostring(state.session or "") then return end

  local bootId = tostring(message.serverBootId or "")
  local serial = tonumber(message.statusSerial) or 0
  if bootId ~= "" and bootId ~= state.serverBootId then
    state.serverBootId = bootId
    state.lastStatusSerial = 0
  end
  if serial > 0 and serial <= state.lastStatusSerial then return end
  if serial > 0 then state.lastStatusSerial = serial end

  state.lastReplyAt = util.nowMillis()
  state.online = true

  if message.kind == "RESYNC_REQUIRED" then
    beginResync("SERVER REQUESTED RESYNC")
    ping()
    return
  end

  if message.kind == "SYNC_ACK" then
    state.synced = true
    state.sequence = 0
  elseif not state.synced then
    -- Do not accept ordinary status/control replies until the authoritative SYNC
    -- handshake has completed.
    return
  end

  if message.status then
    state.status = message.status
    syncFromStatus(state.status)
    if state.safePending and state.status.armed ~= true then clearSafePending() end
  end

  if message.kind == "SYNC_ACK" then
    state.armNonce = nil
    setNotice("LINK RESYNCHRONIZED", 1800)
  elseif message.kind == "ARM_CHALLENGE" then
    state.armRequestAt = 0
    state.armConfirmAt = 0
    state.armNonce = message.nonce
    state.armExpiresAt = tonumber(message.expiresAt) or (util.nowMillis() + 5000)
    setNotice("TAP CONFIRM ARM", 4500)
  elseif message.kind == "ARMED" then
    state.armRequestAt = 0
    state.armConfirmAt = 0
    state.armNonce = nil
    state.armButtonLockUntil = util.nowMillis() + 750
    setNotice("CONTROLS ARMED", 2200)
  elseif message.kind == "SAFE_ACK" then
    state.armNonce = nil
    if message.status and message.status.armed ~= true then
      clearSafePending()
      neutraliseLocal()
      setNotice("SERVER CONFIRMED SAFE", 2400)
    end
  elseif message.kind == "ASSIST_ACK" then
    setNotice("ASSIST COMMAND ACCEPTED", 1300)
  elseif message.kind == "NAV_ACK" then
    setNotice(message.reason or "DESTINATION UPDATED", 2200)
  elseif message.kind == "RADIO_ACK" then
    setNotice(message.reason or "RADIO COMMAND ACCEPTED", 1600)
  elseif message.kind == "SETTINGS_ACK" then
    -- The edited value itself is the confirmation. Avoid covering the tuning
    -- controls with a transient notice after every single +/- adjustment.
    state.notice = message.reason or "SETTING SAVED"
    state.noticeUntil = 0
  elseif message.kind == "ARM_DENIED" or message.kind == "CONTROL_REJECT" or
      message.kind == "ASSIST_REJECT" or message.kind == "NAV_REJECT" or
      message.kind == "RADIO_REJECT" or message.kind == "SETTINGS_REJECT" or message.kind == "ERROR" then
    if message.kind == "ARM_DENIED" or message.kind == "CONTROL_REJECT" then
      state.armNonce = nil
      state.armRequestAt = 0
      state.armConfirmAt = 0
    end
    setNotice(message.reason or "COMMAND REJECTED", 3500)
  end
end

local function handleKey(key)
  if state.page == 4 then
    if key == keys.leftBracket then
      state.systemPage = state.systemPage <= 1 and #systemPages or state.systemPage - 1
      state.systemSelection = 1
      return
    elseif key == keys.rightBracket then
      state.systemPage = state.systemPage >= #systemPages and 1 or state.systemPage + 1
      state.systemSelection = 1
      return
    elseif state.systemPage > 1 then
      local fields = clampSystemSelection()
      if key == keys.up then
        state.systemSelection = util.clamp(state.systemSelection - 1, 1, #fields)
        return
      elseif key == keys.down then
        state.systemSelection = util.clamp(state.systemSelection + 1, 1, #fields)
        return
      elseif key == keys.left then
        adjustSystemSetting(-1)
        return
      elseif key == keys.right then
        adjustSystemSetting(1)
        return
      elseif key == keys.enter then
        activateSystemSetting()
        return
      elseif key == keys.backspace or key == keys.delete then
        resetSystemSetting()
        return
      end
    end
  end

  if state.page == 2 and state.navMenu then
    if state.navDeleteConfirm then
      if key == keys.enter or key == keys.d then confirmDeleteWaypoint()
      elseif key == keys.escape or key == keys.backspace then state.navDeleteConfirm = nil end
      return
    end
    local items = clampNavSelection()
    if key == keys.up then state.navSelection = util.clamp(state.navSelection - 1, 1, #items); clampNavSelection()
    elseif key == keys.down then state.navSelection = util.clamp(state.navSelection + 1, 1, #items); clampNavSelection()
    elseif key == keys.enter then activateNavItem(items[state.navSelection])
    elseif key == keys.d or key == keys.delete then beginDeleteWaypoint(items[state.navSelection])
    elseif key == keys.escape or key == keys.backspace then state.navMenu = false; state.navDeleteConfirm = nil end
    return
  end
  if key == keys.one then state.page = 1
  elseif key == keys.two then state.page = 2
  elseif key == keys.three then state.page = 3
  elseif key == keys.four then state.page = 4
  elseif key == keys.b and state.page == 2 then state.navMenu = true; state.navSelection = 1; state.navScroll = 1; state.navDeleteConfirm = nil
  elseif key == keys.x then requestSafe("keyboard X")
  elseif key == keys.enter then beginOrConfirmArm()
  elseif key == keys.up then changeLevel("lift", 1)
  elseif key == keys.down then changeLevel("lift", -1)
  elseif key == keys.w then changeLevel("thrust", 1)
  elseif key == keys.s then changeLevel("thrust", -1)
  elseif key == keys.a then setRudder(-1)
  elseif key == keys.d then setRudder(1)
  elseif key == keys.c then centreRudder()
  elseif key == keys.h then sendAssist("heading_toggle")
  elseif key == keys.n then sendAssist("navigation_toggle")
  elseif key == keys.v then sendAssist("altitude_toggle")
  elseif key == keys.m then sendAssist("autopilot_toggle")
  elseif key == keys.p then sendRadio("play_pause")
  elseif key == keys.leftBracket then sendRadio("previous")
  elseif key == keys.rightBracket then sendRadio("next")
  elseif key == keys.r then toggleReverse()
  elseif key == keys.g then toggleGyro()
  elseif key == keys.zero then
    if serverArmed() then
      state.control.lift = 0
      state.control.thrust = 0
      state.control.rudder = 0
      sendControl()
      sendAssist("rudder_center")
    end
  end
end

local function run()
  log.info("Volume V v0.5.5-dev2 Configurable Cockpit pocket started on modem " .. modemName)
  ping()
  local timer = os.startTimer(0.1)
  while true do
    draw()
    local event = { os.pullEventRaw() }
    local name = event[1]
    if name == "terminate" then requestSafe("pocket terminated"); error("Terminated", 0)
    elseif name == "rednet_message" then handleMessage(event[2], event[3], event[4])
    elseif name == "mouse_click" then
      local width, height = term.getSize(); handleClick(event[3], event[4], width, height)
    elseif name == "mouse_drag" then
      handleDrag(event[3], event[4])
    elseif name == "mouse_up" then
      if state.mouseRudder then state.mouseRudder = false; setRudder(0) end
    elseif name == "key" then handleKey(event[2])
    elseif name == "key_up" then
      if event[2] == keys.a and state.control.rudder == -1 then setRudder(0)
      elseif event[2] == keys.d and state.control.rudder == 1 then setRudder(0) end
    elseif name == "timer" and event[2] == timer then
      local now = util.nowMillis()
      if now - state.lastPingAt >= 500 then ping() end
      if state.lastReplyAt == 0 or now - state.lastReplyAt > 5000 then
        if state.online or state.synced then beginResync("LINK LOST - RESYNCING") end
      end
      if state.armNonce and now > state.armExpiresAt then
        state.armNonce = nil
        state.armConfirmAt = 0
        setNotice("ARM CHALLENGE EXPIRED", 2200)
      end
      if state.armRequestAt > 0 and now - state.armRequestAt > 2500 then
        state.armRequestAt = 0
        beginResync("ARM REQUEST TIMEOUT - RESYNCING")
        ping()
      elseif state.armConfirmAt > 0 and now - state.armConfirmAt > 2500 then
        state.armConfirmAt = 0
        beginResync("ARM CONFIRM TIMEOUT - RESYNCING")
        ping()
      end
      if state.safePending and now - state.safeSentAt >= 500 then transmitSafe() end
      timer = os.startTimer(0.1)
    end
  end
end

local ok, err = xpcall(run, function(value) return tostring(value) end)
display.reset()
display.header("ATLASOS STOPPED", "SAFE", colors.yellow)
display.writeWrapped(2, 5, "The server was asked to enter SAFE state.", select(1, term.getSize()) - 2, colors.lightGray, nil, 3)
display.writeAt(2, 9, "Type 'atlas' to restart.", colors.white)
if not ok then display.writeWrapped(2, 11, err, select(1, term.getSize()) - 2, colors.red, nil, 4) end
log.warn("Pocket controller stopped: " .. tostring(err))
