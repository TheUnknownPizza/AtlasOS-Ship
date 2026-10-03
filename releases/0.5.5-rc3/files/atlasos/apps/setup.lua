local rootRequire = require("cc.require")
require, package = rootRequire.make(_ENV, "/")
local requestedRole = ...
local config = require("atlasos.lib.config")
local util = require("atlasos.lib.util")
local net = require("atlasos.lib.net")
local log = require("atlasos.lib.log")
local version = require("atlasos.version")

local function heading(text)
  term.setBackgroundColor(colors.black); term.setTextColor(colors.orange); term.clear(); term.setCursorPos(1, 1)
  print("AtlasOS " .. version.version .. " - Setup")
  term.setTextColor(colors.lightGray); print("FICSIT Heavy Aeronautics Division")
  print(string.rep("-", math.min(40, select(1, term.getSize())))); term.setTextColor(colors.white); print(text); print("")
end
local function ask(prompt, default, hidden)
  local suffix = (default and default ~= "") and (" [" .. default .. "]") or ""
  local inline = prompt .. suffix .. ": "
  local width = select(1, term.getSize())
  if #inline <= width then
    write(inline)
  else
    print(prompt)
    if suffix ~= "" then print(suffix) end
    write("> ")
  end
  local value = util.trim(read(hidden and "*" or nil))
  if value == "" then return default or "" end
  return value
end
local function chooseRole()
  local role = util.trim(requestedRole or ""):lower()
  while role ~= "server" and role ~= "pocket" do role = ask("Install role (server/pocket)", nil, false):lower() end
  return role
end
local function setupServer()
  heading("ONBOARD SERVER")
  print("This computer stays aboard the vessel and owns the flight hardware.")
  print("The pocket computer is the only normal flight controller."); print("")
  local name = ask("Vessel name", "Vessel", false)
  local suggested = util.randomDigits(6)
  print(""); print("Choose a temporary six-digit pairing PIN.")
  local pin = ask("Pairing PIN", suggested, true)
  if not pin:match("^%d%d%d%d%d%d$") then error("Pairing PIN must contain exactly six digits", 0) end
  local cfg = config.defaults(); cfg.role = "server"; cfg.name = name; cfg.serverName = name
  cfg.safe = true; cfg.lastSafeReason = "fresh installation"; cfg.pairingOpen = true
  cfg.pairingPinHash = util.hash(pin); cfg.pairedPocketId = nil; cfg.token = nil
  config.save(cfg); os.setComputerLabel(name .. " Flight Server"); log.info("Configured onboard server")
  heading("SERVER CONFIGURED"); print("Computer ID: " .. os.getComputerID()); print("Vessel:      " .. name); print("")
  print("Write down the ID and six-digit PIN.")
  print("")
  term.setTextColor(colors.yellow)
  print("FLIGHT HARDWARE IS NOT COMMISSIONED YET.")
  term.setTextColor(colors.white)
  print("After reboot, stop AtlasOS with Ctrl+T and run:")
  print("  atlasctl ship setup")
  print("")
  print("Rebooting in 8 seconds..."); sleep(8); os.reboot()
end
local function waitForPair(serverId, pin, timeoutSeconds)
  local deadline = util.nowMillis() + timeoutSeconds * 1000
  while util.nowMillis() < deadline do
    net.send(serverId, "PAIR_REQUEST", { pin = pin, pocketName = os.getComputerLabel() or "Portable Flight Controller" }, net.PAIR_PROTOCOL)
    local remaining = math.max(0.2, math.min(2, (deadline - util.nowMillis()) / 1000))
    local sender, message, protocol = rednet.receive(net.PAIR_PROTOCOL, remaining)
    if sender == serverId and protocol == net.PAIR_PROTOCOL and net.valid(message) then
      if message.kind == "PAIR_ACCEPT" then return true, message end
      if message.kind == "PAIR_REJECT" then return false, message.reason or "Pairing rejected" end
    end
  end
  return false, "No pairing reply received"
end
local function setupPocket()
  heading("PORTABLE FLIGHT COMPUTER")
  print("This becomes the vessel's primary normal control interface."); print("")
  local modemName, modemError = net.openWireless(); if not modemName then error(modemError, 0) end
  local label = ask("Pocket computer label", "Portable Flight Controller", false); os.setComputerLabel(label)
  local serverId = tonumber(ask("Onboard server computer ID", nil, false)); if not serverId then error("Server ID must be a number", 0) end
  local pin = ask("Six-digit server pairing PIN", nil, true); if not pin:match("^%d%d%d%d%d%d$") then error("PIN must contain six digits", 0) end
  local operatorPin = ask("Operator PIN (blank = no lock)", "", true)
  print(""); print("Pairing with server " .. serverId .. "...")
  local ok, result = waitForPair(serverId, pin, 15)
  if not ok then printError("Pairing failed: " .. tostring(result)); return end
  local cfg = config.defaults(); cfg.role = "pocket"; cfg.name = label; cfg.serverId = serverId
  cfg.serverName = result.serverName or "Vessel"; cfg.token = result.token
  if operatorPin ~= "" then cfg.operatorPinHash = util.hash(operatorPin) end
  config.save(cfg); log.info("Paired pocket with server ID " .. serverId)
  heading("PAIRING COMPLETE"); print("Server: " .. tostring(cfg.serverName)); print("ID: " .. tostring(serverId)); print("")
  print("Rebooting in 5 seconds..."); sleep(5); os.reboot()
end
local role = chooseRole(); if role == "server" then setupServer() else setupPocket() end
