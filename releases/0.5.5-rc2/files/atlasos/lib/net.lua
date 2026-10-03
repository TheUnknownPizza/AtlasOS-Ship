local util = require("atlasos.lib.util")
local version = require("atlasos.version")

local net = {
  CONTROL_PROTOCOL = "atlasos.control.v3",
  PAIR_PROTOCOL = "atlasos.pair.v3",
}

function net.openWireless()
  local name = util.findWirelessModem()
  if not name then return nil, "No wireless modem found" end
  if not rednet.isOpen(name) then rednet.open(name) end
  return name
end

function net.envelope(kind, payload)
  local message = payload or {}
  message.atlasos = true
  message.protocolVersion = version.protocol
  message.kind = kind
  message.sentAt = util.nowMillis()
  return message
end

function net.send(id, kind, payload, protocol)
  return rednet.send(id, net.envelope(kind, payload), protocol or net.CONTROL_PROTOCOL)
end

function net.valid(message)
  return type(message) == "table"
    and message.atlasos == true
    and tonumber(message.protocolVersion) == version.protocol
    and type(message.kind) == "string"
end

function net.host(protocol, hostname)
  pcall(rednet.unhost, protocol)
  return pcall(rednet.host, protocol, hostname)
end

return net
