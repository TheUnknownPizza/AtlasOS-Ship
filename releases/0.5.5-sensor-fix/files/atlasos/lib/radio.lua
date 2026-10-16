
-- AtlasOS Volume IV radio backend r5: native Atlas Audio + standard CC speaker support
local util = require("atlasos.lib.util")
local dfpwm = require("cc.audio.dfpwm")

local radio = {}

local DEFAULTS = {
  enabled = true,
  speaker = nil,
  atlasGroup = "atlasos",
  volume = 1.0,
  shuffle = false,
  repeatMode = "all",
  chunkBytes = 8 * 1024,
  pcmChunkBytes = 32 * 1024,
  libraryRoots = { "/disk/music", "/disk2/music", "/atlasos/music" },
}

local ATLAS_FORMATS = { m4a = true, aac = true, mp3 = true, wav = true }
local CC_FORMATS = { pcm = true, dfpwm = true }

local FORMAT_PRIORITY = {
  atlas = { m4a = 40, mp3 = 30, wav = 20, aac = 10 },
  cc = { pcm = 20, dfpwm = 10 },
  any = { pcm = 60, m4a = 50, mp3 = 40, wav = 30, aac = 20, dfpwm = 10 },
}

local function copyInto(target, source)
  for key in pairs(target) do target[key] = nil end
  for key, value in pairs(source) do target[key] = value end
end

function radio.ensureConfig(cfg)
  local existing = type(cfg.radio) == "table" and cfg.radio or nil
  local merged = util.deepMerge(DEFAULTS, existing or {})
  merged.volume = util.clamp(tonumber(merged.volume) or 1, 0, 3)
  merged.chunkBytes = util.clamp(util.round(tonumber(merged.chunkBytes) or (8 * 1024)), 1024, 16 * 1024)
  merged.pcmChunkBytes = util.clamp(util.round(tonumber(merged.pcmChunkBytes) or (32 * 1024)), 8 * 1024, 32 * 1024)
  merged.atlasGroup = tostring(merged.atlasGroup or "atlasos")
  if not merged.atlasGroup:match("^[A-Za-z0-9_.%-]+$") or #merged.atlasGroup > 32 then
    merged.atlasGroup = "atlasos"
  end
  if merged.repeatMode ~= "off" and merged.repeatMode ~= "one" and merged.repeatMode ~= "all" then
    merged.repeatMode = "all"
  end
  if not existing then
    cfg.radio = merged
    return cfg.radio
  end
  copyInto(existing, merged)
  cfg.radio = existing
  return existing
end

local function titleCase(text)
  text = tostring(text or "")
  text = text:gsub("%.dfpwm$", "")
  text = text:gsub("%.pcm$", "")
  text = text:gsub("%.m4a$", "")
  text = text:gsub("%.aac$", "")
  text = text:gsub("%.mp3$", "")
  text = text:gsub("%.wav$", "")
  text = text:gsub("^%d+[%s%._%-]+", "")
  text = text:gsub("[_%-]+", " ")
  text = text:gsub("%s+", " ")
  return (text:gsub("(%a)([%w']*)", function(first, rest)
    return first:upper() .. rest:lower()
  end))
end

local function parentName(path)
  local dir = fs.getDir(path)
  if dir == "" or dir == "/" then return "Unknown Artist" end
  return titleCase(fs.getName(dir))
end

local function trackFormat(path)
  local lower = tostring(path or ""):lower()
  if lower:sub(-6) == ".dfpwm" then return "dfpwm" end
  if lower:sub(-4) == ".pcm" then return "pcm" end
  if lower:sub(-4) == ".m4a" then return "m4a" end
  if lower:sub(-4) == ".aac" then return "aac" end
  if lower:sub(-4) == ".mp3" then return "mp3" end
  if lower:sub(-4) == ".wav" then return "wav" end
  return nil
end

local function stripExtension(path)
  local lower = tostring(path or ""):lower()
  lower = lower:gsub("%.dfpwm$", "")
  lower = lower:gsub("%.pcm$", "")
  lower = lower:gsub("%.m4a$", "")
  lower = lower:gsub("%.aac$", "")
  lower = lower:gsub("%.mp3$", "")
  lower = lower:gsub("%.wav$", "")
  return lower
end

local function formatSupported(backend, format)
  if backend == "atlas" then return ATLAS_FORMATS[format] == true end
  if backend == "cc" then return CC_FORMATS[format] == true end
  return ATLAS_FORMATS[format] == true or CC_FORMATS[format] == true
end

local function formatPriority(backend, format)
  local priorities = FORMAT_PRIORITY[backend or "any"] or FORMAT_PRIORITY.any
  return priorities[format] or 0
end

local function addTrack(list, seen, backend, path, title, artist, duration)
  if not path or not fs.exists(path) or fs.isDir(path) then return end
  local format = trackFormat(path)
  if not format or not formatSupported(backend, format) then return end

  local key = stripExtension(path)
  local existingIndex = seen[key]
  if existingIndex then
    local current = list[existingIndex]
    if formatPriority(backend, format) <= formatPriority(backend, current.format) then return end
  end

  local size = tonumber(fs.getSize(path)) or 0
  local calculatedDuration = tonumber(duration)
  if not calculatedDuration or calculatedDuration <= 0 then
    if format == "pcm" then calculatedDuration = size / 48000
    elseif format == "dfpwm" then calculatedDuration = size * 8 / 48000
    else calculatedDuration = 0 end
  end

  local entry = {
    path = path,
    title = tostring(title or titleCase(fs.getName(path))),
    artist = tostring(artist or parentName(path)),
    format = format,
    duration = calculatedDuration,
  }

  if existingIndex then
    list[existingIndex] = entry
  else
    list[#list + 1] = entry
    seen[key] = #list
  end
end

local function readPlaylist(path)
  local handle = fs.open(path, "r")
  if not handle then return nil end
  local raw = handle.readAll()
  handle.close()
  local decoded = raw and textutils.unserialize(raw) or nil
  if type(decoded) ~= "table" then return nil end
  return decoded
end

local function scanDirectory(path, list, seen, backend)
  if not fs.exists(path) or not fs.isDir(path) then return end

  local playlistPath = fs.combine(path, "playlist.db")
  local playlist = fs.exists(playlistPath) and readPlaylist(playlistPath) or nil
  if playlist then
    local artist = playlist.artist or parentName(fs.combine(path, "placeholder.m4a"))
    for _, entry in ipairs(type(playlist.tracks) == "table" and playlist.tracks or {}) do
      if type(entry) == "string" then
        addTrack(list, seen, backend, fs.combine(path, entry), nil, artist)
      elseif type(entry) == "table" then
        addTrack(
          list,
          seen,
          backend,
          fs.combine(path, tostring(entry.file or "")),
          entry.title,
          entry.artist or artist,
          entry.duration
        )
      end
    end
  end

  local names = fs.list(path)
  table.sort(names)
  for _, name in ipairs(names) do
    if name ~= "playlist.db" then
      local child = fs.combine(path, name)
      if fs.isDir(child) then
        scanDirectory(child, list, seen, backend)
      elseif trackFormat(name) then
        addTrack(list, seen, backend, child)
      end
    end
  end
end

function radio.scan(cfg, backend)
  local rcfg = radio.ensureConfig(cfg)
  local list, seen = {}, {}
  for _, root in ipairs(type(rcfg.libraryRoots) == "table" and rcfg.libraryRoots or {}) do
    scanDirectory(root, list, seen, backend)
  end
  return list
end

local function closeHandle(runtime)
  if runtime.handle then pcall(runtime.handle.close); runtime.handle = nil end
  runtime.decoder = nil
  runtime.pendingBuffer = nil
  runtime.pendingBytes = nil
  runtime.pendingSamples = nil
  runtime.pendingAccepted = nil
end

local function markIgnored(runtime, playbackId)
  if not playbackId then return end
  runtime.ignoredPlaybackIds = runtime.ignoredPlaybackIds or {}
  runtime.ignoredPlaybackIds[tostring(playbackId)] = true
end

local function stopAtlas(runtime, ignoreEvent)
  local playbackId = runtime.playbackId
  if ignoreEvent then markIgnored(runtime, playbackId) end
  local first = runtime.speakers and runtime.speakers[1]
  if first and first.device then pcall(first.device.stopGroup) end
  runtime.playbackId = nil
  runtime.atlasStartedAt = nil
end

local function stopStandard(runtime)
  for _, entry in ipairs(runtime.speakers or {}) do
    if entry.device then pcall(entry.device.stop) end
  end
  runtime.speakerReady = {}
  for _, entry in ipairs(runtime.speakers or {}) do
    runtime.speakerReady[entry.name] = true
  end
  runtime.bufferOutstanding = false
end

local function stopSpeaker(runtime, ignoreAtlasEvent)
  if runtime.backend == "atlas" then stopAtlas(runtime, ignoreAtlasEvent ~= false)
  else stopStandard(runtime) end
end

function radio.newRuntime(cfg)
  local runtime = {
    backend = nil,
    speakerName = nil,
    speaker = nil,
    speakerNames = {},
    speakers = {},
    speakerReady = {},
    library = {},
    index = 1,
    playing = false,
    paused = false,
    handle = nil,
    decoder = nil,
    pendingBuffer = nil,
    pendingBytes = nil,
    pendingAccepted = nil,
    bufferOutstanding = false,
    samplesAccepted = 0,
    playbackId = nil,
    ignoredPlaybackIds = {},
    atlasStartedAt = nil,
    atlasPausedElapsed = 0,
    status = "idle",
    error = nil,
    duckUntil = 0,
    lastScanAt = 0,
  }
  radio.bindSpeaker(cfg, runtime)
  radio.rescan(cfg, runtime)
  return runtime
end

local function collectSpeakers()
  local atlas, standard = {}, {}
  for _, name in ipairs(peripheral.getNames()) do
    local device = peripheral.wrap(name)
    if device then
      if peripheral.hasType(name, "atlas_speaker") then
        atlas[#atlas + 1] = { name = name, device = device, kind = "atlas" }
      elseif peripheral.hasType(name, "speaker") then
        standard[#standard + 1] = { name = name, device = device, kind = "cc" }
      end
    end
  end
  table.sort(atlas, function(a, b) return a.name < b.name end)
  table.sort(standard, function(a, b) return a.name < b.name end)
  return atlas, standard
end

function radio.bindSpeaker(cfg, runtime)
  local rcfg = radio.ensureConfig(cfg)
  local oldBackend = runtime.backend
  local previousReady = runtime.speakerReady or {}
  local requested = rcfg.speaker
  local atlas, standard = collectSpeakers()
  local backend, speakers

  if requested and peripheral.isPresent(requested) then
    if peripheral.hasType(requested, "atlas_speaker") then backend, speakers = "atlas", atlas
    elseif peripheral.hasType(requested, "speaker") then backend, speakers = "cc", standard end
  end

  if not backend then
    if #atlas > 0 then backend, speakers = "atlas", atlas
    elseif #standard > 0 then backend, speakers = "cc", standard end
  end

  speakers = speakers or {}
  if requested and #speakers > 1 then
    table.sort(speakers, function(left, right)
      if left.name == requested and right.name ~= requested then return true end
      if right.name == requested and left.name ~= requested then return false end
      return left.name < right.name
    end)
  end

  if oldBackend and oldBackend ~= backend and runtime.playing then
    if oldBackend == "atlas" then
      local oldFirst = runtime.speakers and runtime.speakers[1]
      markIgnored(runtime, runtime.playbackId)
      if oldFirst and oldFirst.device then pcall(oldFirst.device.stopGroup) end
      runtime.playbackId = nil
      runtime.atlasStartedAt = nil
    else
      stopStandard(runtime)
    end
    closeHandle(runtime)
    runtime.playing = false
    runtime.paused = false
    runtime.status = "speaker backend changed"
  end

  runtime.backend = backend
  runtime.speakers = speakers
  runtime.speakerNames = {}
  runtime.speakerReady = {}

  for _, entry in ipairs(speakers) do
    runtime.speakerNames[#runtime.speakerNames + 1] = entry.name
    if backend == "cc" then
      local ready = previousReady[entry.name]
      runtime.speakerReady[entry.name] = ready == nil and true or ready
    elseif backend == "atlas" and type(entry.device.setGroup) == "function" then
      pcall(entry.device.setGroup, rcfg.atlasGroup)
    end
  end

  runtime.speakerName = speakers[1] and speakers[1].name or nil
  runtime.speaker = speakers[1] and speakers[1].device or nil

  if #speakers == 0 then
    runtime.error = "speaker peripheral not found"
    runtime.backend = nil
    return false, runtime.error
  end

  if oldBackend ~= backend and runtime.library then
    radio.rescan(cfg, runtime)
  end

  if runtime.error == "speaker peripheral not found" or
      (type(runtime.error) == "string" and runtime.error:find("speaker playback failed", 1, true)) then
    runtime.error = nil
  end
  return true
end

function radio.rescan(cfg, runtime)
  local currentPath = runtime.library[runtime.index] and runtime.library[runtime.index].path or nil
  local backend = runtime.backend or "any"
  local ok, library = pcall(radio.scan, cfg, backend)
  if not ok then
    runtime.error = "music library scan failed: " .. tostring(library)
    runtime.status = "scan error"
    return #runtime.library
  end
  runtime.library = library
  runtime.lastScanAt = util.nowMillis()
  runtime.index = 1
  local foundCurrent = false
  if currentPath then
    for index, track in ipairs(runtime.library) do
      if track.path == currentPath then runtime.index = index; foundCurrent = true; break end
    end
  end
  if currentPath and not foundCurrent and (runtime.playing or runtime.paused) then
    stopSpeaker(runtime, true)
    closeHandle(runtime)
    runtime.playing = false
    runtime.paused = false
    runtime.samplesAccepted = 0
    runtime.status = "music disk removed"
  end
  if runtime.index > #runtime.library then runtime.index = math.max(1, #runtime.library) end
  if #runtime.library == 0 then
    runtime.status = "library empty"
    if backend == "atlas" then
      runtime.error = "no .m4a, .aac, .mp3, or .wav tracks found under the configured music roots"
    elseif backend == "cc" then
      runtime.error = "no .pcm or .dfpwm tracks found under the configured music roots"
    else
      runtime.error = "no supported audio tracks found under the configured music roots"
    end
  elseif runtime.error and runtime.error:find("no ", 1, true) then
    runtime.error = nil
  end
  return #runtime.library
end

local function openCurrentStandard(cfg, runtime)
  closeHandle(runtime)
  local track = runtime.library[runtime.index]
  if not track then return false, "radio library is empty" end
  if not radio.bindSpeaker(cfg, runtime) then return false, runtime.error end
  if runtime.backend ~= "cc" then return false, "standard speaker backend is not active" end
  local handle = fs.open(track.path, "rb")
  if not handle then return false, "unable to open " .. track.path end
  runtime.handle = handle
  runtime.decoder = track.format == "dfpwm" and dfpwm.make_decoder() or nil
  runtime.pendingBuffer = nil
  runtime.pendingBytes = nil
  runtime.pendingSamples = nil
  runtime.pendingAccepted = nil
  runtime.bufferOutstanding = false
  runtime.samplesAccepted = 0
  runtime.status = "playing"
  runtime.error = nil
  return true
end

local function readWholeFile(path)
  local handle = fs.open(path, "rb")
  if not handle then return nil, "unable to open " .. tostring(path) end
  local ok, data = pcall(handle.readAll)
  handle.close()
  if not ok then return nil, tostring(data) end
  return data
end

local function playCurrentAtlas(cfg, runtime)
  closeHandle(runtime)
  local track = runtime.library[runtime.index]
  if not track then return false, "radio library is empty" end
  if not radio.bindSpeaker(cfg, runtime) then return false, runtime.error end
  if runtime.backend ~= "atlas" then return false, "Atlas Audio backend is not active" end
  if not ATLAS_FORMATS[track.format] then return false, "Atlas Speaker cannot play " .. tostring(track.format) end

  local data, readError = readWholeFile(track.path)
  if not data then return false, "music disk read failed: " .. tostring(readError) end

  local rcfg = radio.ensureConfig(cfg)
  local volume = util.clamp(tonumber(rcfg.volume) or 1, 0, 1)
  if util.nowMillis() < (runtime.duckUntil or 0) then volume = math.min(volume, 0.25) end

  local first = runtime.speakers[1]
  if not first or not first.device then return false, "Atlas Speaker disappeared before playback" end
  for _, entry in ipairs(runtime.speakers) do
    if type(entry.device.setGroup) == "function" then pcall(entry.device.setGroup, rcfg.atlasGroup) end
  end

  local ok, playbackId = pcall(first.device.playGroup, data, track.format, volume)
  if not ok then return false, "Atlas Speaker playback failed: " .. tostring(playbackId) end

  runtime.playbackId = tostring(playbackId)
  runtime.atlasStartedAt = util.nowMillis()
  runtime.atlasPausedElapsed = 0
  runtime.samplesAccepted = 0
  runtime.status = "starting"
  runtime.error = nil
  return true
end

local function randomIndex(runtime)
  if #runtime.library <= 1 then return 1 end
  local candidate = runtime.index
  while candidate == runtime.index do candidate = math.random(1, #runtime.library) end
  return candidate
end

local function nextIndex(cfg, runtime, direction, naturalEnd)
  local rcfg = radio.ensureConfig(cfg)
  if #runtime.library == 0 then return nil end
  if naturalEnd and rcfg.repeatMode == "one" then return runtime.index end
  if rcfg.shuffle then return randomIndex(runtime) end
  local nextValue = runtime.index + direction
  if nextValue > #runtime.library then
    if rcfg.repeatMode == "off" and naturalEnd then return nil end
    nextValue = 1
  elseif nextValue < 1 then
    nextValue = #runtime.library
  end
  return nextValue
end

function radio.playIndex(cfg, runtime, index)
  if #runtime.library == 0 then radio.rescan(cfg, runtime) end
  if #runtime.library == 0 then return false, runtime.error or "radio library is empty" end
  runtime.index = util.clamp(util.round(index or runtime.index), 1, #runtime.library)
  stopSpeaker(runtime, true)
  closeHandle(runtime)

  local ok, err
  if runtime.backend == "atlas" then ok, err = playCurrentAtlas(cfg, runtime)
  else ok, err = openCurrentStandard(cfg, runtime) end

  if not ok then
    runtime.playing = false
    runtime.paused = false
    runtime.status = "error"
    runtime.error = err
    return false, err
  end
  runtime.playing = true
  runtime.paused = false
  return true, "playing " .. runtime.library[runtime.index].title
end

function radio.next(cfg, runtime, direction, naturalEnd)
  direction = direction and direction < 0 and -1 or 1
  local index = nextIndex(cfg, runtime, direction, naturalEnd == true)
  if not index then
    radio.stop(cfg, runtime)
    runtime.status = "playlist complete"
    return true, "playlist complete"
  end
  return radio.playIndex(cfg, runtime, index)
end

function radio.stop(cfg, runtime)
  stopSpeaker(runtime, true)
  closeHandle(runtime)
  runtime.playing = false
  runtime.paused = false
  runtime.samplesAccepted = 0
  runtime.atlasPausedElapsed = 0
  runtime.status = "stopped"
  runtime.error = nil
  return true, "radio stopped"
end

function radio.toggle(cfg, runtime)
  if runtime.backend == "atlas" then
    if not runtime.playing and not runtime.paused then
      return radio.playIndex(cfg, runtime, runtime.index)
    end

    local first = runtime.speakers and runtime.speakers[1]
    if not first or not first.device then return false, "Atlas Speaker is unavailable" end

    if runtime.paused then
      if type(first.device.resumeGroup) ~= "function" then
        return false, "Atlas Audio Beta 5 or newer is required for true resume"
      end
      local ok, err = pcall(first.device.resumeGroup)
      if not ok then return false, "Atlas Speaker resume failed: " .. tostring(err) end
      runtime.atlasStartedAt = util.nowMillis() - math.floor((runtime.atlasPausedElapsed or 0) * 1000)
      runtime.playing = true
      runtime.paused = false
      runtime.status = "resuming"
      runtime.error = nil
      return true, "radio resumed"
    end

    if type(first.device.pauseGroup) ~= "function" then
      return false, "Atlas Audio Beta 5 or newer is required for true pause"
    end
    if runtime.atlasStartedAt then
      runtime.atlasPausedElapsed = math.max(0, (util.nowMillis() - runtime.atlasStartedAt) / 1000)
    end
    local ok, err = pcall(first.device.pauseGroup)
    if not ok then return false, "Atlas Speaker pause failed: " .. tostring(err) end
    runtime.playing = false
    runtime.paused = true
    runtime.status = "pausing"
    runtime.error = nil
    return true, "radio paused"
  end

  if not runtime.playing then return radio.playIndex(cfg, runtime, runtime.index) end
  runtime.paused = not runtime.paused
  runtime.status = runtime.paused and "paused" or "playing"
  return true, runtime.paused and "radio paused" or "radio resumed"
end

function radio.setVolume(cfg, runtime, value)
  local rcfg = radio.ensureConfig(cfg)
  local maximum = runtime and runtime.backend == "atlas" and 1 or 3
  rcfg.volume = util.clamp(tonumber(value) or rcfg.volume, 0, maximum)
  if runtime and runtime.backend == "atlas" and runtime.playing then
    return true, string.format("radio volume %.1f (applies next track)", rcfg.volume)
  end
  return true, string.format("radio volume %.1f", rcfg.volume)
end

function radio.toggleShuffle(cfg)
  local rcfg = radio.ensureConfig(cfg)
  rcfg.shuffle = not rcfg.shuffle
  return true, "shuffle " .. (rcfg.shuffle and "on" or "off")
end

function radio.cycleRepeat(cfg)
  local rcfg = radio.ensureConfig(cfg)
  if rcfg.repeatMode == "all" then rcfg.repeatMode = "one"
  elseif rcfg.repeatMode == "one" then rcfg.repeatMode = "off"
  else rcfg.repeatMode = "all" end
  return true, "repeat " .. rcfg.repeatMode
end

function radio.duck(runtime, durationMs)
  runtime.duckUntil = math.max(runtime.duckUntil or 0, util.nowMillis() + (durationMs or 4000))
end

function radio.command(cfg, runtime, action, value)
  action = tostring(action or "")
  if action == "play_pause" then return radio.toggle(cfg, runtime)
  elseif action == "stop" then return radio.stop(cfg, runtime)
  elseif action == "next" then return radio.next(cfg, runtime, 1, false)
  elseif action == "previous" then return radio.next(cfg, runtime, -1, false)
  elseif action == "volume" then return radio.setVolume(cfg, runtime, value)
  elseif action == "volume_delta" then
    local rcfg = radio.ensureConfig(cfg)
    return radio.setVolume(cfg, runtime, rcfg.volume + (tonumber(value) or 0))
  elseif action == "shuffle" then return radio.toggleShuffle(cfg)
  elseif action == "repeat" then return radio.cycleRepeat(cfg)
  elseif action == "rescan" then
    radio.bindSpeaker(cfg, runtime)
    local count = radio.rescan(cfg, runtime)
    return true, "found " .. tostring(count) .. " track(s)"
  end
  return false, "unsupported radio command"
end

function radio.onSpeakerEmpty(runtime, speakerName)
  if runtime.backend ~= "cc" then return end
  if speakerName and runtime.speakerReady and runtime.speakerReady[speakerName] ~= nil then
    runtime.speakerReady[speakerName] = true
  end
end

function radio.onAtlasStarted(runtime, playbackId, format, targetCount)
  playbackId = tostring(playbackId or "")
  if runtime.backend ~= "atlas" or playbackId == "" or playbackId ~= tostring(runtime.playbackId or "") then return end
  runtime.playing = true
  runtime.paused = false
  runtime.status = "playing"
  runtime.error = nil
  runtime.atlasStartedAt = runtime.atlasStartedAt or util.nowMillis()
  runtime.atlasFormat = tostring(format or "")
  runtime.atlasTargets = tonumber(targetCount) or #runtime.speakers
end

function radio.onAtlasPaused(runtime, playbackId)
  playbackId = tostring(playbackId or "")
  if runtime.backend ~= "atlas" or playbackId ~= tostring(runtime.playbackId or "") then return end
  if runtime.atlasStartedAt then
    runtime.atlasPausedElapsed = math.max(0, (util.nowMillis() - runtime.atlasStartedAt) / 1000)
  end
  runtime.playing = false
  runtime.paused = true
  runtime.status = "paused"
  runtime.error = nil
end

function radio.onAtlasResumed(runtime, playbackId)
  playbackId = tostring(playbackId or "")
  if runtime.backend ~= "atlas" or playbackId ~= tostring(runtime.playbackId or "") then return end
  runtime.atlasStartedAt = util.nowMillis() - math.floor((runtime.atlasPausedElapsed or 0) * 1000)
  runtime.playing = true
  runtime.paused = false
  runtime.status = "playing"
  runtime.error = nil
end

function radio.onAtlasStopped(cfg, runtime, playbackId)
  playbackId = tostring(playbackId or "")
  if playbackId == "" then return end
  if runtime.ignoredPlaybackIds and runtime.ignoredPlaybackIds[playbackId] then
    runtime.ignoredPlaybackIds[playbackId] = nil
    return
  end
  if runtime.backend ~= "atlas" or playbackId ~= tostring(runtime.playbackId or "") then return end

  runtime.playbackId = nil
  runtime.atlasStartedAt = nil
  runtime.playing = false
  runtime.paused = false
  runtime.status = "track complete"
  runtime.error = nil
  return radio.next(cfg, runtime, 1, true)
end

function radio.onAtlasError(runtime, playbackId, code, message)
  playbackId = tostring(playbackId or "")
  if runtime.backend ~= "atlas" or playbackId ~= tostring(runtime.playbackId or "") then return end
  runtime.playing = false
  runtime.paused = false
  runtime.status = "error"
  runtime.error = "Atlas Audio " .. tostring(code or "error") .. ": " .. tostring(message or "unknown error")
  runtime.playbackId = nil
  runtime.atlasStartedAt = nil
end

local function speakersPresent(runtime)
  if not runtime.speakers or #runtime.speakers == 0 then return false end
  local expectedType = runtime.backend == "atlas" and "atlas_speaker" or "speaker"
  for _, entry in ipairs(runtime.speakers) do
    if not peripheral.isPresent(entry.name) or not peripheral.hasType(entry.name, expectedType) then return false end
  end
  return true
end

local function allSpeakersReady(runtime)
  if runtime.backend ~= "cc" then return true end
  if not runtime.speakers or #runtime.speakers == 0 then return false end
  for _, entry in ipairs(runtime.speakers) do
    if runtime.speakerReady[entry.name] ~= true then return false end
  end
  return true
end

local function resetSpeakerQueues(runtime)
  if runtime.backend ~= "cc" then return end
  for _, entry in ipairs(runtime.speakers or {}) do
    if entry.device then pcall(entry.device.stop) end
    runtime.speakerReady[entry.name] = true
  end
end

local function decodeSignedPcm(chunk)
  local buffer = {}
  for i = 1, #chunk do
    local value = string.byte(chunk, i)
    buffer[i] = value >= 128 and (value - 256) or value
  end
  return buffer
end

function radio.pump(cfg, runtime)
  local rcfg = radio.ensureConfig(cfg)
  if not rcfg.enabled or not runtime.playing or runtime.paused then return true end

  if not speakersPresent(runtime) then
    if not radio.bindSpeaker(cfg, runtime) then
      runtime.status = "speaker missing"
      return false, runtime.error
    end
  end

  if runtime.backend == "atlas" then
    return true
  end

  if not allSpeakersReady(runtime) then return true end

  if not runtime.handle then
    local ok, err = openCurrentStandard(cfg, runtime)
    if not ok then runtime.status = "error"; runtime.error = err; runtime.playing = false; return false, err end
  end

  if not runtime.pendingBuffer then
    local track = runtime.library[runtime.index]
    local readSize = track and track.format == "pcm" and rcfg.pcmChunkBytes or rcfg.chunkBytes
    local readOk, chunk = pcall(runtime.handle.read, readSize)
    if not readOk then
      runtime.error = "music disk read failed: " .. tostring(chunk)
      runtime.status = "read error"
      runtime.playing = false
      closeHandle(runtime)
      return false, runtime.error
    end
    if chunk == nil or chunk == "" then
      closeHandle(runtime)
      return radio.next(cfg, runtime, 1, true)
    end
    runtime.pendingBytes = #chunk

    if track and track.format == "pcm" then
      local ok, decoded = pcall(decodeSignedPcm, chunk)
      if not ok then
        runtime.error = "PCM decode failed: " .. tostring(decoded)
        runtime.status = "error"
        runtime.playing = false
        closeHandle(runtime)
        return false, runtime.error
      end
      runtime.pendingBuffer = decoded
    else
      local ok, decoded = pcall(runtime.decoder, chunk)
      if not ok then
        runtime.error = "DFPWM decode failed: " .. tostring(decoded)
        runtime.status = "error"
        runtime.playing = false
        closeHandle(runtime)
        return false, runtime.error
      end
      runtime.pendingBuffer = decoded
    end
    runtime.pendingSamples = #runtime.pendingBuffer
  end

  local volume = rcfg.volume
  if util.nowMillis() < (runtime.duckUntil or 0) then volume = math.min(volume, 0.25) end

  for _, entry in ipairs(runtime.speakers) do
    local ok, accepted = pcall(entry.device.playAudio, runtime.pendingBuffer, volume)
    if not ok then
      resetSpeakerQueues(runtime)
      radio.bindSpeaker(cfg, runtime)
      runtime.status = "speaker reconnecting"
      runtime.error = "speaker playback failed on " .. tostring(entry.name) .. ": " .. tostring(accepted)
      return true
    end
    if not accepted then
      resetSpeakerQueues(runtime)
      runtime.status = "speaker synchronizing"
      return true
    end
  end

  for _, entry in ipairs(runtime.speakers) do runtime.speakerReady[entry.name] = false end
  runtime.bufferOutstanding = true
  runtime.samplesAccepted = runtime.samplesAccepted + (runtime.pendingSamples or 0)
  runtime.pendingBuffer = nil
  runtime.pendingBytes = nil
  runtime.pendingSamples = nil
  runtime.status = "playing"
  if type(runtime.error) == "string" and runtime.error:find("speaker playback failed", 1, true) then
    runtime.error = nil
  end
  return true
end

function radio.status(cfg, runtime)
  local rcfg = radio.ensureConfig(cfg)
  local track = runtime.library[runtime.index]
  local elapsed
  if runtime.backend == "atlas" then
    if runtime.playing and runtime.atlasStartedAt then elapsed = math.max(0, (util.nowMillis() - runtime.atlasStartedAt) / 1000)
    elseif runtime.paused then elapsed = runtime.atlasPausedElapsed or 0
    else elapsed = 0 end
  else
    elapsed = (runtime.samplesAccepted or 0) / 48000
  end

  local quality
  if track then
    if runtime.backend == "atlas" then quality = "ATLAS " .. tostring(track.format):upper()
    else quality = track.format == "pcm" and "HI-FI PCM" or "DFPWM" end
  end

  return {
    enabled = rcfg.enabled == true,
    backend = runtime.backend,
    speakerPresent = runtime.speakers ~= nil and #runtime.speakers > 0,
    speakerName = runtime.speakerName,
    speakerNames = util.deepCopy(runtime.speakerNames or {}),
    speakerCount = runtime.speakers and #runtime.speakers or 0,
    libraryCount = #runtime.library,
    index = #runtime.library > 0 and runtime.index or 0,
    playing = runtime.playing == true,
    paused = runtime.paused == true,
    title = track and track.title or nil,
    artist = track and track.artist or nil,
    path = track and track.path or nil,
    format = track and track.format or nil,
    quality = quality,
    elapsed = elapsed,
    duration = track and track.duration or nil,
    volume = runtime.backend == "atlas" and util.clamp(rcfg.volume, 0, 1) or rcfg.volume,
    shuffle = rcfg.shuffle == true,
    repeatMode = rcfg.repeatMode,
    status = runtime.status,
    error = runtime.error,
    ducked = util.nowMillis() < (runtime.duckUntil or 0),
    playbackId = runtime.playbackId,
  }
end

return radio
