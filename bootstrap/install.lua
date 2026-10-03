local argv = { ... }

local REPO_RAW = "https://raw.githubusercontent.com/TheUnknownPizza/AtlasOS-Ship/main"
local CHANNELS = {
  stable = REPO_RAW .. "/channels/stable.json",
  dev = REPO_RAW .. "/channels/dev.json",
}

local INSTALLER_FILES = {
  "sha256.lua",
  "transaction.lua",
  "stage.lua",
  "install.lua",
  "inspect.lua",
}

local BOOTSTRAP_ROOT = "/.atlas-installer/bootstrap"

local function hasColour()
  return term.isColor and term.isColor()
end

local function setColour(colour)
  if hasColour() then term.setTextColor(colour) end
end

local function resetColour()
  setColour(colors.white)
end

local function clear()
  if hasColour() then term.setBackgroundColor(colors.black) end
  resetColour()
  term.clear()
  term.setCursorPos(1, 1)
end

local function rule()
  local width = select(1, term.getSize())
  setColour(colors.gray)
  print(string.rep("-", math.min(width, 42)))
  resetColour()
end

local function heading(title)
  clear()
  setColour(colors.orange)
  print("ATLASOS SHIP")
  setColour(colors.lightGray)
  print("GitHub Bootstrap Installer")
  rule()
  setColour(colors.white)
  print(title)
  print("")
end

local function fail(message)
  setColour(colors.red)
  print("")
  print("INSTALLATION STOPPED")
  resetColour()
  print(tostring(message))
  print("")
  print("No further installation steps will be attempted.")
  return false
end

local function trim(value)
  return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function parseArgs()
  local options = {
    channel = "stable",
    assumeYes = false,
    noReboot = false,
    keepBootstrap = false,
  }

  for _, raw in ipairs(argv) do
    local arg = tostring(raw):lower()

    if arg == "stable" or arg == "dev" then
      options.channel = arg
    elseif arg == "--yes" or arg == "-y" then
      options.assumeYes = true
    elseif arg == "--no-reboot" then
      options.noReboot = true
    elseif arg == "--keep-bootstrap" then
      options.keepBootstrap = true
    elseif arg ~= "" then
      error(
        "Unknown argument '" .. tostring(raw) ..
        "'. Use: stable | dev | --yes | --no-reboot | --keep-bootstrap",
        0
      )
    end
  end

  return options
end

local function fetchText(url, label)
  if not http then
    error("HTTP API is unavailable. Enable HTTP in the CC:Tweaked server configuration.", 0)
  end

  if http.checkURL then
    local ok, reason = http.checkURL(url)
    if ok == false then
      error((label or "URL") .. " is blocked: " .. tostring(reason), 0)
    end
  end

  local response, err = http.get(url)
  if not response then
    error((label or "HTTP request") .. " failed: " .. tostring(err) .. "\n" .. url, 0)
  end

  local body = response.readAll()
  response.close()

  if type(body) ~= "string" or body == "" then
    error((label or "Download") .. " returned an empty response.\n" .. url, 0)
  end

  return body
end

local function decodeJson(label, text)
  local ok, value = pcall(textutils.unserialiseJSON, text)
  if not ok or type(value) ~= "table" then
    error(label .. " is not valid JSON.", 0)
  end
  return value
end

local function atomicWrite(path, contents)
  local parent = fs.getDir(path)
  if parent ~= "" then fs.makeDir(parent) end

  local partial = path .. ".part"
  if fs.exists(partial) then fs.delete(partial) end

  local handle = fs.open(partial, "wb")
  if not handle then
    error("Cannot write " .. partial, 0)
  end

  handle.write(contents)
  handle.close()

  if fs.exists(path) then fs.delete(path) end
  fs.move(partial, path)
end

local function confirm(message, defaultYes)
  local suffix = defaultYes and " [Y/n] " or " [y/N] "
  write(message .. suffix)

  local answer = trim(read()):lower()
  if answer == "" then return defaultYes end
  return answer == "y" or answer == "yes"
end

local function loadChannel(name)
  local url = CHANNELS[name]
  local text = fetchText(url, "Channel metadata")
  local channel = decodeJson("Channel metadata", text)

  if type(channel.version) ~= "string" or type(channel.manifest) ~= "string" then
    return nil, url
  end

  return channel, url
end

local function selectChannel(options)
  local channel, url = loadChannel(options.channel)

  if channel then
    return options.channel, channel, url
  end

  if options.channel ~= "stable" then
    error("The development channel is not currently published.", 0)
  end

  setColour(colors.yellow)
  print("The stable channel is not published yet.")
  resetColour()

  if options.assumeYes then
    error("Stable is unavailable. Rerun with 'dev' during release-candidate testing.", 0)
  end

  print("")
  if not confirm("Use the development channel instead?", false) then
    error("No release channel selected.", 0)
  end

  local dev, devUrl = loadChannel("dev")
  if not dev then
    error("The development channel is also unavailable.", 0)
  end

  return "dev", dev, devUrl
end

local function installMode()
  if fs.exists("/atlasos/config.db") and not fs.isDir("/atlasos/config.db") then
    return "UPDATE"
  end
  return "CLEAN INSTALL"
end

local function downloadInstallerTools()
  if fs.exists(BOOTSTRAP_ROOT) then
    fs.delete(BOOTSTRAP_ROOT)
  end
  fs.makeDir(BOOTSTRAP_ROOT)

  for index, name in ipairs(INSTALLER_FILES) do
    setColour(colors.lightGray)
    write(string.format("[%d/%d] ", index, #INSTALLER_FILES))
    resetColour()
    write(name .. " ... ")

    local url = REPO_RAW .. "/installer/" .. name
    local contents = fetchText(url, "Installer tool " .. name)
    atomicWrite(fs.combine(BOOTSTRAP_ROOT, name), contents)

    setColour(colors.lime)
    print("OK")
    resetColour()
  end
end

local function runTool(path, ...)
  local ok = shell.run(path, ...)
  if not ok then
    error("Tool failed: " .. path, 0)
  end
end

local function main()
  local options = parseArgs()

  heading("Preparing installation")

  local channelName, channel, channelUrl = selectChannel(options)
  local mode = installMode()

  setColour(colors.lightGray)
  print("Mode:    " .. mode)
  print("Channel: " .. channelName)
  print("Version: " .. channel.version)
  resetColour()
  print("")

  print("Release files come from GitHub.")
  print("Payload files are SHA-256 verified before install.")
  print("Existing managed files are backed up transactionally.")
  print("Machine-owned AtlasOS configuration is preserved on updates.")
  print("")

  if not options.assumeYes and not confirm("Continue with this installation?", false) then
    print("Cancelled.")
    return
  end

  heading("Downloading installer tools")
  downloadInstallerTools()

  heading("Staging " .. channel.version)
  print("Downloading and verifying release payload...")
  print("")
  runTool(fs.combine(BOOTSTRAP_ROOT, "stage.lua"), channelUrl)

  heading("Installing " .. channel.version)
  print("Applying the verified package transaction...")
  print("")
  runTool(fs.combine(BOOTSTRAP_ROOT, "install.lua"), channel.version, "--yes")

  if not options.keepBootstrap and fs.exists(BOOTSTRAP_ROOT) then
    fs.delete(BOOTSTRAP_ROOT)
  end

  heading("Installation complete")
  setColour(colors.lime)
  print("AtlasOS " .. channel.version .. " installed successfully.")
  resetColour()
  print("")
  print("Channel: " .. channelName)
  print("Mode:    " .. mode)
  print("")

  if options.noReboot then
    print("Reboot skipped (--no-reboot).")
    print("Run 'reboot' when ready.")
    return
  end

  if options.assumeYes or confirm("Reboot into AtlasOS now?", true) then
    os.reboot()
  else
    print("Run 'reboot' when ready.")
  end
end

local ok, err = pcall(main)
if not ok then
  fail(err)
end
