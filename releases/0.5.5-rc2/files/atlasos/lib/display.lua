local util = require("atlasos.lib.util")

local display = {}

display.theme = {
  background = colors.black,
  panel = colors.gray,
  panelDark = colors.lightGray,
  text = colors.white,
  muted = colors.lightGray,
  accent = colors.orange,
  good = colors.lime,
  warning = colors.yellow,
  bad = colors.red,
}

local function color(value)
  if term.isColor() then term.setTextColor(value) end
end

local function background(value)
  if term.isColor() then term.setBackgroundColor(value) end
end

function display.reset()
  background(display.theme.background)
  color(display.theme.text)
  term.clear()
  term.setCursorPos(1, 1)
  term.setCursorBlink(false)
end

function display.writeAt(x, y, text, textColor, backgroundColor)
  local width, height = term.getSize()
  if y < 1 or y > height then return end
  term.setCursorPos(math.max(1, x), y)
  if backgroundColor then background(backgroundColor) end
  if textColor then color(textColor) end
  term.write(util.truncate(text, math.max(0, width - math.max(1, x) + 1)))
  background(display.theme.background)
  color(display.theme.text)
end

-- Write word-wrapped text and return the next unused row. This is deliberately
-- terminal-size aware: pocket computers are only 26 characters wide.
function display.writeWrapped(x, y, text, maxWidth, textColor, backgroundColor, maxLines)
  local termWidth, termHeight = term.getSize()
  x = math.max(1, tonumber(x) or 1)
  y = math.max(1, tonumber(y) or 1)
  maxWidth = math.max(1, math.min(tonumber(maxWidth) or (termWidth - x + 1), termWidth - x + 1))
  maxLines = math.max(1, tonumber(maxLines) or termHeight)

  local lines = {}
  for paragraph in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        while #word > maxWidth do
          if line ~= "" then
            lines[#lines + 1] = line
            line = ""
          end
          lines[#lines + 1] = word:sub(1, maxWidth)
          word = word:sub(maxWidth + 1)
        end
        if word ~= "" then
          local candidate = line == "" and word or (line .. " " .. word)
          if #candidate <= maxWidth then
            line = candidate
          else
            lines[#lines + 1] = line
            line = word
          end
        end
      end
      if line ~= "" then lines[#lines + 1] = line end
    end
  end

  local available = math.min(maxLines, termHeight - y + 1)
  local clipped = #lines > available
  for index = 1, available do
    local line = lines[index] or ""
    if clipped and index == available then line = util.truncate(line .. "...", maxWidth) end
    display.writeAt(x, y + index - 1, line, textColor, backgroundColor)
  end
  return y + available
end

function display.fill(x, y, width, height, backgroundColor)
  background(backgroundColor or display.theme.panel)
  local line = string.rep(" ", math.max(0, width))
  for row = y, y + height - 1 do
    term.setCursorPos(x, row)
    term.write(line)
  end
  background(display.theme.background)
end

function display.header(title, statusText, statusColor)
  local width = term.getSize()
  display.fill(1, 1, width, 2, display.theme.panel)
  display.writeAt(2, 1, title, display.theme.accent, display.theme.panel)
  if statusText then
    local text = tostring(statusText)
    display.writeAt(math.max(2, width - #text), 1, text, statusColor or display.theme.text, display.theme.panel)
  end
  display.writeAt(2, 2, "FICSIT HEAVY AERONAUTICS", display.theme.muted, display.theme.panel)
end

function display.labelValue(y, label, value, valueColor)
  local width = term.getSize()
  display.writeAt(2, y, label, display.theme.muted)
  local text = tostring(value or "-")
  display.writeAt(math.max(2, width - #text), y, text, valueColor or display.theme.text)
end

function display.button(x, y, width, text, active, danger)
  local bg = display.theme.panel
  local fg = display.theme.text
  if active then bg = danger and display.theme.bad or display.theme.accent end
  display.fill(x, y, width, 1, bg)
  local centered = util.center(text, width)
  display.writeAt(x, y, centered, fg, bg)
end

return display
