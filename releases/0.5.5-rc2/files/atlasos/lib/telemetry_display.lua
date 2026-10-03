local telemetryDisplay = {}

local SCALE_CANDIDATES = { 5.0, 4.5, 4.0, 3.5, 3.0, 2.5, 2.0, 1.5, 1.0, 0.5 }
local WIDE_MIN_WIDTH = 38
local WIDE_MIN_HEIGHT = 8
local COMPACT_MIN_WIDTH = 8
local COMPACT_MIN_HEIGHT = 6

local function normaliseOptions(options)
  options = type(options) == "table" and options or {}
  local scale = options.scale
  if scale ~= "auto" then
    scale = tonumber(scale)
    if not scale then scale = "auto" end
  end
  return {
    enabled = options.enabled ~= false,
    preferred = options.preferred and tostring(options.preferred) or nil,
    scale = scale or "auto",
  }
end

local function isDisplayPeripheral(name)
  local okMonitor, monitorType = pcall(peripheral.hasType, name, "monitor")
  if okMonitor and monitorType then return true end

  local okAtlas, atlasType = pcall(peripheral.hasType, name, "atlas_display")
  if okAtlas and atlasType then return true end

  local wrapped = peripheral.wrap(name)
  return wrapped ~= nil
    and type(wrapped.getSize) == "function"
    and type(wrapped.setCursorPos) == "function"
    and type(wrapped.write) == "function"
    and type(wrapped.clear) == "function"
end

function telemetryDisplay.candidates()
  local result = {}
  for _, name in ipairs(peripheral.getNames()) do
    if isDisplayPeripheral(name) then result[#result + 1] = name end
  end
  table.sort(result)
  return result
end

local function findDisplay(options)
  options = normaliseOptions(options)
  if not options.enabled then return nil, nil end

  if options.preferred and peripheral.isPresent(options.preferred) and isDisplayPeripheral(options.preferred) then
    local wrapped = peripheral.wrap(options.preferred)
    if wrapped then return options.preferred, wrapped end
  end

  for _, name in ipairs(telemetryDisplay.candidates()) do
    local wrapped = peripheral.wrap(name)
    if wrapped then return name, wrapped end
  end

  return nil, nil
end

local function clearDisplay(display)
  if not display then return end
  pcall(function()
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()
    display.setCursorPos(1, 1)
  end)
end

local function resetScale(runtime)
  runtime.scaleConfigured = false
  runtime.scale = nil
  runtime.width = nil
  runtime.height = nil
  runtime.lastScaleError = nil
  runtime.frame = nil
end

local function resetBinding(runtime, clearOld)
  if clearOld then clearDisplay(runtime.display) end
  runtime.name = nil
  runtime.display = nil
  resetScale(runtime)
end

local function optionsChanged(runtime, options)
  options = normaliseOptions(options)
  local previous = runtime.options or {}
  return previous.enabled ~= options.enabled
    or previous.preferred ~= options.preferred
    or tostring(previous.scale) ~= tostring(options.scale)
end

function telemetryDisplay.configure(runtime, options)
  options = normaliseOptions(options)
  local changed = optionsChanged(runtime, options)
  if changed then
    local bindingChanged = not runtime.options
      or runtime.options.enabled ~= options.enabled
      or runtime.options.preferred ~= options.preferred
    if bindingChanged then resetBinding(runtime, true)
    else resetScale(runtime) end
  end
  runtime.options = options
end

local function bind(runtime, options)
  telemetryDisplay.configure(runtime, options)
  local opts = runtime.options

  if not opts.enabled then
    if runtime.display then resetBinding(runtime, true) end
    return nil
  end

  if runtime.name and peripheral.isPresent(runtime.name) then
    if not opts.preferred or runtime.name == opts.preferred then
      local wrapped = peripheral.wrap(runtime.name)
      if wrapped then
        runtime.display = wrapped
        return wrapped
      end
    end
  end

  resetBinding(runtime, true)
  local name, display = findDisplay(opts)
  runtime.name = name
  runtime.display = display
  return display
end

local function readSize(display)
  local ok, width, height = pcall(display.getSize)
  if not ok then return nil, nil, tostring(width) end
  width = tonumber(width)
  height = tonumber(height)
  if not width or not height then return nil, nil, "display returned invalid size" end
  return width, height, nil
end

local function readScale(display)
  if type(display.getTextScale) ~= "function" then return nil end
  local ok, value = pcall(display.getTextScale)
  if not ok then return nil end
  return tonumber(value)
end

local function setAndMeasure(display, scale)
  if type(display.setTextScale) ~= "function" then
    local width, height, err = readSize(display)
    return width, height, readScale(display), err
  end

  local ok, err = pcall(display.setTextScale, scale)
  if not ok then return nil, nil, nil, tostring(err) end

  local width, height, sizeErr = readSize(display)
  if not width then return nil, nil, nil, sizeErr end

  local actual = readScale(display)
  if actual and math.abs(actual - scale) > 0.01 then
    return nil, nil, actual,
      string.format("requested text scale %.1f but display reports %.1f", scale, actual)
  end

  return width, height, actual or scale, nil
end

local function fits(width, height, minWidth, minHeight)
  return width and height and width >= minWidth and height >= minHeight
end

local function configureScale(runtime, display)
  if runtime.scaleConfigured then return end
  runtime.scaleConfigured = true

  local opts = runtime.options or normaliseOptions(nil)

  if type(display.setTextScale) ~= "function" then
    local width, height, err = readSize(display)
    runtime.width = width
    runtime.height = height
    runtime.scale = readScale(display)
    runtime.lastScaleError = err
    return
  end

  if opts.scale ~= "auto" then
    local requested = tonumber(opts.scale) or 0.5
    local width, height, actual, err = setAndMeasure(display, requested)
    runtime.width = width
    runtime.height = height
    runtime.scale = actual or requested
    runtime.lastScaleError = err
    return
  end

  local maxWidth, maxHeight, _, baseErr = setAndMeasure(display, 0.5)
  if not maxWidth then
    runtime.lastScaleError = baseErr
    return
  end

  local wantsWide = fits(maxWidth, maxHeight, WIDE_MIN_WIDTH, WIDE_MIN_HEIGHT)
  local minWidth = wantsWide and WIDE_MIN_WIDTH or COMPACT_MIN_WIDTH
  local minHeight = wantsWide and WIDE_MIN_HEIGHT or COMPACT_MIN_HEIGHT

  local chosenScale, chosenWidth, chosenHeight
  local lastErr

  for _, candidate in ipairs(SCALE_CANDIDATES) do
    local width, height, actual, err = setAndMeasure(display, candidate)
    if width and fits(width, height, minWidth, minHeight) then
      chosenScale = actual or candidate
      chosenWidth = width
      chosenHeight = height
      break
    end
    if err then lastErr = err end
  end

  if not chosenScale then
    local width, height, actual, err = setAndMeasure(display, 0.5)
    chosenScale = actual or 0.5
    chosenWidth = width or maxWidth
    chosenHeight = height or maxHeight
    lastErr = err or lastErr
  end

  runtime.scale = chosenScale
  runtime.width = chosenWidth
  runtime.height = chosenHeight
  runtime.lastScaleError = lastErr
end

local function fit(text, width)
  text = tostring(text or "")
  if #text <= width then return text end
  if width <= 1 then return text:sub(1, width) end
  return text:sub(1, width - 1) .. "~"
end

local function number(value, format, fallback)
  value = tonumber(value)
  if value == nil then return fallback or "-" end
  return string.format(format, value)
end

local function boolText(value)
  return value and "ON" or "OFF"
end

local BLIT = {
  [colors.white] = "0",
  [colors.orange] = "1",
  [colors.magenta] = "2",
  [colors.lightBlue] = "3",
  [colors.yellow] = "4",
  [colors.lime] = "5",
  [colors.pink] = "6",
  [colors.gray] = "7",
  [colors.lightGray] = "8",
  [colors.cyan] = "9",
  [colors.purple] = "a",
  [colors.blue] = "b",
  [colors.brown] = "c",
  [colors.green] = "d",
  [colors.red] = "e",
  [colors.black] = "f",
}

local function newFrame(width, height)
  local rows = {}
  local blank = string.rep(" ", width)
  local fg = string.rep(BLIT[colors.white], width)
  local bg = string.rep(BLIT[colors.black], width)
  for y = 1, height do
    rows[y] = { text = blank, fg = fg, bg = bg }
  end

  local cursorX, cursorY = 1, 1
  local textColor = colors.white
  local backgroundColor = colors.black

  local surface = {}

  function surface.setCursorPos(x, y)
    cursorX = math.max(1, math.floor(tonumber(x) or 1))
    cursorY = math.max(1, math.floor(tonumber(y) or 1))
  end

  function surface.setTextColor(color)
    textColor = color or colors.white
  end

  function surface.setBackgroundColor(color)
    backgroundColor = color or colors.black
  end

  local function splice(value, startAt, replacement)
    local before = startAt > 1 and value:sub(1, startAt - 1) or ""
    local afterAt = startAt + #replacement
    local after = afterAt <= #value and value:sub(afterAt) or ""
    return before .. replacement .. after
  end

  function surface.write(value)
    if cursorY < 1 or cursorY > height or cursorX > width then return end
    value = tostring(value or "")
    if value == "" then return end

    local available = width - cursorX + 1
    value = value:sub(1, available)
    if value == "" then return end

    local row = rows[cursorY]
    row.text = splice(row.text, cursorX, value)
    row.fg = splice(row.fg, cursorX, string.rep(BLIT[textColor] or BLIT[colors.white], #value))
    row.bg = splice(row.bg, cursorX, string.rep(BLIT[backgroundColor] or BLIT[colors.black], #value))
    cursorX = cursorX + #value
  end

  function surface.clearLine()
    if cursorY < 1 or cursorY > height then return end
    rows[cursorY] = {
      text = blank,
      fg = string.rep(BLIT[textColor] or BLIT[colors.white], width),
      bg = string.rep(BLIT[backgroundColor] or BLIT[colors.black], width),
    }
  end

  function surface.clear()
    local currentFg = string.rep(BLIT[textColor] or BLIT[colors.white], width)
    local currentBg = string.rep(BLIT[backgroundColor] or BLIT[colors.black], width)
    for y = 1, height do
      rows[y] = { text = blank, fg = currentFg, bg = currentBg }
    end
  end

  return surface, rows
end

local function framesCompatible(frame, width, height)
  return frame
    and frame.width == width
    and frame.height == height
    and type(frame.rows) == "table"
end

local function writeRun(display, x, y, text, fg, bg)
  display.setCursorPos(x, y)

  if type(display.blit) == "function" then
    display.blit(text, fg, bg)
    return
  end

  -- Fallback for terminal-like peripherals which do not expose blit().
  -- Split the changed run whenever foreground/background colours change.
  local offset = 1
  while offset <= #text do
    local fgCode = fg:sub(offset, offset)
    local bgCode = bg:sub(offset, offset)
    local finish = offset
    while finish + 1 <= #text
      and fg:sub(finish + 1, finish + 1) == fgCode
      and bg:sub(finish + 1, finish + 1) == bgCode do
      finish = finish + 1
    end

    local fgColor, bgColor = colors.white, colors.black
    for color, code in pairs(BLIT) do
      if code == fgCode then fgColor = color end
      if code == bgCode then bgColor = color end
    end

    display.setCursorPos(x + offset - 1, y)
    display.setTextColor(fgColor)
    display.setBackgroundColor(bgColor)
    display.write(text:sub(offset, finish))
    offset = finish + 1
  end
end

local function flushFrame(runtime, display, width, height, rows)
  local previous = runtime.frame
  local fullRedraw = not framesCompatible(previous, width, height)

  if fullRedraw then
    display.setBackgroundColor(colors.black)
    display.setTextColor(colors.white)
    display.clear()
  end

  for y = 1, height do
    local current = rows[y]
    local old = not fullRedraw and previous.rows[y] or nil

    if not old then
      writeRun(display, 1, y, current.text, current.fg, current.bg)
    elseif current.text ~= old.text or current.fg ~= old.fg or current.bg ~= old.bg then
      local first = 1
      while first <= width
        and current.text:sub(first, first) == old.text:sub(first, first)
        and current.fg:sub(first, first) == old.fg:sub(first, first)
        and current.bg:sub(first, first) == old.bg:sub(first, first) do
        first = first + 1
      end

      if first <= width then
        local last = width
        while last > first
          and current.text:sub(last, last) == old.text:sub(last, last)
          and current.fg:sub(last, last) == old.fg:sub(last, last)
          and current.bg:sub(last, last) == old.bg:sub(last, last) do
          last = last - 1
        end

        writeRun(
          display,
          first,
          y,
          current.text:sub(first, last),
          current.fg:sub(first, last),
          current.bg:sub(first, last)
        )
      end
    end
  end

  runtime.frame = {
    width = width,
    height = height,
    rows = rows,
  }
end

local function writeLine(display, width, height, row, text, color, background)
  if row < 1 or row > height then return end
  display.setCursorPos(1, row)
  display.setBackgroundColor(background or colors.black)
  display.setTextColor(color or colors.white)
  display.clearLine()
  display.write(fit(text, width))
end

local function writeAt(display, width, height, x, row, text, color, background)
  if row < 1 or row > height or x > width then return end
  display.setCursorPos(math.max(1, x), row)
  display.setBackgroundColor(background or colors.black)
  display.setTextColor(color or colors.white)
  display.write(fit(text, width - x + 1))
end

local function divider(display, width, height, row)
  writeLine(display, width, height, row, string.rep("-", width), colors.orange)
end

local function pair(display, width, height, row, leftLabel, leftValue, rightLabel, rightValue)
  if width < 28 then
    writeLine(display, width, height, row, tostring(leftLabel) .. ": " .. tostring(leftValue))
    return
  end

  local left = tostring(leftLabel) .. ": " .. tostring(leftValue)
  local right = tostring(rightLabel) .. ": " .. tostring(rightValue)
  local gap = math.max(1, width - #left - #right)
  writeLine(display, width, height, row, left .. string.rep(" ", gap) .. right)
end

local function missionText(status)
  local mission = status.mission or {}
  local mode = tostring(mission.mode or "assisted")
  if mode == "autopilot" then return "AUTO/" .. tostring(mission.phase or "-") end
  if mode == "arrival" then return "ARRIVED" end
  return mode:upper()
end

local function stateText(status)
  if status.linkHold then return "REMOTE HOLD", colors.yellow end
  if status.armed then return "ARMED", colors.orange end
  return "SAFE", colors.lime
end

local function navSourceText(status)
  local nav = status.navigation or {}
  local active = tostring(nav.activeSource or "none")
  if active == "nav_table" then return "NAV TABLE" end
  if active == "gps" then return "GPS" end
  local configured = tostring(nav.source or "auto")
  if configured == "auto" then return "AUTO/NONE" end
  return configured:upper()
end

local function radioText(status)
  local radio = status.radio or {}
  if tonumber(radio.speakerCount) and tonumber(radio.speakerCount) > 0 then
    if radio.playing then return radio.paused and "PAUSED" or "PLAYING" end
    return "READY"
  end
  return "OFFLINE"
end

local function compactTitle(width)
  if width >= 12 then return "ATLASOS SHIP" end
  if width >= 7 then return "ATLASOS" end
  return "AOS"
end

local function drawCompact(display, width, height, status)
  local data = status.telemetry or {}
  local assist = status.assist or {}
  local mission = status.mission or {}
  local state, stateColor = stateText(status)
  local row = 1

  writeLine(display, width, height, row, compactTitle(width), colors.orange)
  row = row + 1
  writeLine(display, width, height, row, state .. "  " .. missionText(status), stateColor)
  row = row + 1

  pair(display, width, height, row, "HDG", number(data.heading, "%03.0f"), "SPD", number(data.forwardSpeed, "%.1f"))
  row = row + 1
  pair(display, width, height, row, "ALT", number(data.altitude, "%.1f"), "V/S", number(data.verticalSpeed, "%+.1f"))
  row = row + 1
  pair(display, width, height, row, "RUD", number(assist.rudderCurrentDeg, "%+.1f"), "TGT", number(assist.rudderTargetDeg, "%+.1f"))
  row = row + 1

  if row <= height then
    pair(display, width, height, row, "LIFT", (status.control or {}).lift or "-", "THR", (status.control or {}).thrust or "-")
    row = row + 1
  end

  if row <= height and mission.mode == "autopilot" then
    pair(display, width, height, row, "AUTO", number(mission.currentSpeed, "%.1f") .. ">" .. number(mission.targetSpeed, "%.1f"),
      "DST", number(data.horizontalDistance or data.distance, "%.0f"))
    row = row + 1
  end

  if row <= height then
    writeLine(display, width, height, row, "NAV " .. navSourceText(status), colors.lightGray)
  end
end

local function drawWide(display, width, height, status)
  local data = status.telemetry or {}
  local assist = status.assist or {}
  local mission = status.mission or {}
  local control = status.control or {}
  local state, stateColor = stateText(status)
  local row = 1

  local title = " ATLASOS SHIP // TELEMETRY "
  writeLine(display, width, height, row, string.rep("=", width), colors.orange)
  local titleX = math.max(1, math.floor((width - #title) / 2) + 1)
  writeAt(display, width, height, titleX, row, title, colors.orange)
  row = row + 1

  local missionLabel = missionText(status)
  local stateLeft = "STATE " .. state
  local missionRight = "MISSION " .. missionLabel
  writeLine(display, width, height, row, stateLeft, stateColor)
  writeAt(display, width, height, math.max(1, width - #missionRight + 1), row, missionRight,
    mission.autopilot and colors.orange or (mission.arrival and colors.lime or colors.lightGray))
  row = row + 1
  divider(display, width, height, row)
  row = row + 1

  pair(display, width, height, row, "HEADING", number(data.heading, "%03.0f deg"), "SPEED", number(data.forwardSpeed, "%.1f m/s"))
  row = row + 1
  pair(display, width, height, row, "ALT", number(data.altitude, "%.1f m"), "V/S", number(data.verticalSpeed, "%+.1f m/s"))
  row = row + 1
  pair(display, width, height, row, "RUDDER", number(assist.rudderCurrentDeg, "%+.1f deg"),
    "TARGET", number(assist.rudderTargetDeg, "%+.1f deg"))
  row = row + 1
  pair(display, width, height, row, "LIFT", control.lift or "-", "THRUST", control.thrust or "-")
  row = row + 1
  pair(display, width, height, row, "REVERSE", boolText(control.reverse), "GYRO", boolText(control.gyro))
  row = row + 1

  if mission.mode == "autopilot" and row <= height then
    pair(display, width, height, row, "AUTO SPD",
      number(mission.currentSpeed, "%.1f") .. " > " .. number(mission.targetSpeed, "%.1f"),
      "DIST", number(data.horizontalDistance or data.distance, "%.1f m"))
    row = row + 1
  elseif data.hasTarget and row <= height then
    pair(display, width, height, row, "NAV", "TARGET ACTIVE", "DIST",
      number(data.horizontalDistance or data.distance, "%.1f m"))
    row = row + 1
  end

  if row <= height then
    divider(display, width, height, row)
    row = row + 1
  end

  if row <= height then
    local nav = status.navigation or {}
    local navValue = navSourceText(status)
    if nav.activeSource == "gps" then navValue = navValue .. (nav.gpsAvailable and " FIX" or " WAIT") end
    pair(display, width, height, row, "NAV SRC", navValue,
      "ALT HOLD", tostring(assist.altitudeMode or "-"):upper())
    row = row + 1
  end

  if row <= height then
    local age = tonumber(status.lastContactAgeMs)
    local link = age and string.format("%.1fs", age / 1000) or "never"
    pair(display, width, height, row, "POCKET", status.pairedPocketId or "-", "LINK AGE", link)
    row = row + 1
  end

  if row <= height then
    pair(display, width, height, row, "FLIGHT I/O", status.hardwareValid and "READY" or "LOCKED",
      "SENSORS", status.sensorsValid and "READY" or "LOCKED")
    row = row + 1
  end

  if row <= height then
    pair(display, width, height, row, "RADIO", radioText(status),
      "SERVER", tostring(status.serverId or os.getComputerID()))
  end
end

function telemetryDisplay.new(options)
  return {
    name = nil,
    display = nil,
    scaleConfigured = false,
    scale = nil,
    width = nil,
    height = nil,
    lastError = nil,
    lastScaleError = nil,
    frame = nil,
    options = normaliseOptions(options),
  }
end

function telemetryDisplay.refresh(runtime, options)
  telemetryDisplay.configure(runtime, options)
  if not runtime.options.enabled then
    if runtime.display then resetBinding(runtime, true) end
    return false
  end

  if runtime.name and peripheral.isPresent(runtime.name) then
    if not runtime.options.preferred or runtime.name == runtime.options.preferred then
      local wrapped = peripheral.wrap(runtime.name)
      if wrapped then
        runtime.display = wrapped
        return true
      end
    end
  end

  resetBinding(runtime, true)
  return bind(runtime, runtime.options) ~= nil
end

function telemetryDisplay.status(runtime, options)
  telemetryDisplay.configure(runtime, options)
  return {
    enabled = runtime.options.enabled,
    preferred = runtime.options.preferred,
    configuredScale = runtime.options.scale,
    bound = runtime.name ~= nil and peripheral.isPresent(runtime.name),
    name = runtime.name,
    scale = runtime.scale,
    width = runtime.width,
    height = runtime.height,
    lastError = runtime.lastError,
    lastScaleError = runtime.lastScaleError,
    candidates = telemetryDisplay.candidates(),
  }
end

function telemetryDisplay.render(runtime, status, options)
  local display = bind(runtime, options)
  if not display then
    if runtime.options and runtime.options.enabled == false then
      runtime.lastError = nil
      return true
    end
    return false, "no telemetry display attached"
  end

  local ok, err = pcall(function()
    configureScale(runtime, display)
    local width, height, sizeErr = readSize(display)
    if not width then error(sizeErr or "display size unavailable", 0) end

    runtime.width = width
    runtime.height = height

    local surface, rows = newFrame(width, height)

    if width >= WIDE_MIN_WIDTH and height >= WIDE_MIN_HEIGHT then
      drawWide(surface, width, height, status or {})
    else
      drawCompact(surface, width, height, status or {})
    end

    flushFrame(runtime, display, width, height, rows)
  end)

  if not ok then
    runtime.lastError = tostring(err)
    resetBinding(runtime, false)
    return false, runtime.lastError
  end

  runtime.lastError = nil
  return true
end

return telemetryDisplay
