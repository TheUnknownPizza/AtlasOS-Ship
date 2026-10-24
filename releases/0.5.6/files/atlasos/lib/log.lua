local util = require("atlasos.lib.util")

local log = {}
local path = "/atlasos/logs/system.log"
local maxBytes = 65536

local function rotateIfNeeded()
  if not fs.exists(path) then return end
  if fs.getSize(path) <= maxBytes then return end
  local old = path .. ".old"
  if fs.exists(old) then fs.delete(old) end
  fs.move(path, old)
end

function log.write(level, message)
  rotateIfNeeded()
  if not fs.exists("/atlasos/logs") then fs.makeDir("/atlasos/logs") end
  local handle = fs.open(path, "a")
  if not handle then return false end
  local line = string.format("[%d] [%-5s] %s\n", util.nowMillis(), tostring(level or "INFO"), tostring(message or ""))
  handle.write(line)
  handle.close()
  return true
end

function log.info(message) return log.write("INFO", message) end
function log.warn(message) return log.write("WARN", message) end
function log.error(message) return log.write("ERROR", message) end

function log.tail(count)
  count = tonumber(count) or 20
  local raw = util.readAll(path)
  if not raw then return {} end
  local lines = {}
  for line in raw:gmatch("[^\n]+") do lines[#lines + 1] = line end
  local first = math.max(1, #lines - count + 1)
  local result = {}
  for index = first, #lines do result[#result + 1] = lines[index] end
  return result
end

function log.path() return path end

return log
