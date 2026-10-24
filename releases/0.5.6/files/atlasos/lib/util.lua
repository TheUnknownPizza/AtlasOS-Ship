local util = {}

function util.trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

function util.clamp(value, minimum, maximum)
  value = tonumber(value) or minimum
  if value < minimum then return minimum end
  if value > maximum then return maximum end
  return value
end

function util.round(value)
  value = tonumber(value) or 0
  if value >= 0 then return math.floor(value + 0.5) end
  return math.ceil(value - 0.5)
end

function util.tableCount(value)
  local count = 0
  if type(value) ~= "table" then return count end
  for _ in pairs(value) do count = count + 1 end
  return count
end

function util.deepCopy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = util.deepCopy(child) end
  return result
end

function util.deepMerge(defaults, saved)
  local result = util.deepCopy(defaults or {})
  for key, value in pairs(saved or {}) do
    if type(value) == "table" and type(result[key]) == "table" then
      result[key] = util.deepMerge(result[key], value)
    else
      result[key] = value
    end
  end
  return result
end

function util.readAll(path)
  if not fs.exists(path) or fs.isDir(path) then return nil end
  local handle = fs.open(path, "r")
  if not handle then return nil end
  local data = handle.readAll()
  handle.close()
  return data
end

function util.atomicWrite(path, data)
  local directory = fs.getDir(path)
  if directory ~= "" and not fs.exists(directory) then
    local ok, err = pcall(fs.makeDir, directory)
    if not ok then return false, "Could not create " .. directory .. ": " .. tostring(err) end
  end
  if directory ~= "" and not fs.isDir(directory) then
    return false, directory .. " is not a directory"
  end

  local temporary = path .. ".tmp"
  local handle, err = fs.open(temporary, "w")
  if not handle then return false, err end
  handle.write(tostring(data or ""))
  handle.close()

  if fs.exists(path) then fs.delete(path) end
  local moved, moveError = pcall(fs.move, temporary, path)
  if not moved then
    if fs.exists(temporary) then fs.delete(temporary) end
    return false, moveError
  end
  return fs.exists(path), fs.exists(path) and nil or "File vanished after write"
end

function util.hash(value)
  -- Accidental-use interlock only, not cryptographic security.
  local hash = 5381
  local text = tostring(value or "")
  for index = 1, #text do
    hash = (hash * 33 + string.byte(text, index)) % 4294967296
  end
  return string.format("%08x", hash)
end

local randomSeeded = false
local function seedRandom()
  if randomSeeded then return end
  local epoch = os.epoch and os.epoch("utc") or math.floor(os.time() * 1000)
  math.randomseed((epoch + os.getComputerID() * 7919) % 2147483647)
  for _ = 1, 5 do math.random() end
  randomSeeded = true
end

function util.token(length)
  seedRandom()
  local alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
  local out = {}
  for index = 1, (length or 32) do
    local position = math.random(1, #alphabet)
    out[index] = alphabet:sub(position, position)
  end
  return table.concat(out)
end

function util.randomDigits(length)
  seedRandom()
  local out = {}
  for index = 1, (length or 6) do out[index] = tostring(math.random(0, 9)) end
  return table.concat(out)
end

function util.nowMillis()
  if os.epoch then return os.epoch("utc") end
  return math.floor(os.time() * 3600000)
end

function util.formatDuration(milliseconds)
  local seconds = math.max(0, math.floor((tonumber(milliseconds) or 0) / 1000))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local remaining = seconds % 60
  if hours > 0 then return string.format("%dh %02dm %02ds", hours, minutes, remaining) end
  return string.format("%dm %02ds", minutes, remaining)
end

function util.truncate(value, width)
  local text = tostring(value or "")
  width = math.max(0, tonumber(width) or 0)
  if #text <= width then return text end
  if width <= 3 then return text:sub(1, width) end
  return text:sub(1, width - 3) .. "..."
end

function util.center(value, width)
  local text = tostring(value or "")
  width = tonumber(width) or #text
  if #text >= width then return text:sub(1, width) end
  local left = math.floor((width - #text) / 2)
  local right = width - #text - left
  return string.rep(" ", left) .. text .. string.rep(" ", right)
end

function util.findWirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    local wrapped = peripheral.wrap(name)
    if wrapped and type(wrapped.isWireless) == "function" then
      local ok, wireless = pcall(wrapped.isWireless)
      if ok and wireless then return name, wrapped end
    end
  end
  return nil, nil
end

function util.peripheralTypes(name)
  return { peripheral.getType(name) }
end

function util.hasPeripheralType(name, wanted)
  for _, kind in ipairs(util.peripheralTypes(name)) do
    if kind == wanted then return true end
  end
  return false
end

function util.peripheralTypeText(name)
  local cleaned = {}
  for _, value in ipairs(util.peripheralTypes(name)) do
    if value ~= nil then cleaned[#cleaned + 1] = tostring(value) end
  end
  if #cleaned == 0 then return "unknown" end
  return table.concat(cleaned, ", ")
end

function util.listPeripheralsByType(wanted)
  local result = {}
  for _, name in ipairs(peripheral.getNames()) do
    if util.hasPeripheralType(name, wanted) then result[#result + 1] = name end
  end
  table.sort(result)
  return result
end

function util.inverseSide(side)
  local inverse = {
    top = "bottom", bottom = "top",
    left = "right", right = "left",
    front = "back", back = "front",
  }
  return inverse[side]
end

function util.isNeutralControl(control)
  control = control or {}
  return (tonumber(control.lift) or 0) == 0
    and (tonumber(control.thrust) or 0) == 0
    and control.reverse ~= true
    and (tonumber(control.rudder) or 0) == 0
end

function util.moveToward(current, target, step)
  current, target, step = tonumber(current) or 0, tonumber(target) or 0, math.max(1, tonumber(step) or 1)
  if current < target then return math.min(target, current + step) end
  if current > target then return math.max(target, current - step) end
  return current
end

function util.copyRecursive(source, destination)
  if not fs.exists(source) then return false, "Source does not exist" end
  if fs.isDir(source) then
    if not fs.exists(destination) then fs.makeDir(destination) end
    for _, child in ipairs(fs.list(source)) do
      local ok, err = util.copyRecursive(fs.combine(source, child), fs.combine(destination, child))
      if not ok then return false, err end
    end
  else
    local data = util.readAll(source)
    if data == nil then return false, "Could not read " .. source end
    local ok, err = util.atomicWrite(destination, data)
    if not ok then return false, err end
  end
  return true
end

return util
