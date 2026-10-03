local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")
local config = require("atlasos.lib.config")
local log = require("atlasos.lib.log")
local version = require("atlasos.version")

local cfg = config.load()
term.setBackgroundColor(colors.black)
term.setTextColor(colors.orange)
term.clear()
term.setCursorPos(1, 1)
print("ATLASOS " .. version.version)
term.setTextColor(colors.lightGray)
print("FICSIT Heavy Aeronautics Division")
print("")

if not cfg.role then
  print("First-run setup required.")
  shell.run("/atlasos/apps/setup.lua")
  return
end

log.info("Booting role " .. tostring(cfg.role))
local program
if cfg.role == "server" then program = "/atlasos/apps/server.lua"
elseif cfg.role == "pocket" then program = "/atlasos/apps/pocket.lua"
else error("Unknown AtlasOS role: " .. tostring(cfg.role), 0) end

local ok = shell.run(program)
if not ok then
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.red)
  print("")
  print("AtlasOS did not exit cleanly.")
  print("CraftOS shell remains available for recovery.")
  print("Run 'atlasctl diagnostics' or 'atlas' to retry.")
end
