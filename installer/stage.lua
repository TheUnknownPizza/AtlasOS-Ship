local DEFAULT_CHANNEL = "https://raw.githubusercontent.com/TheUnknownPizza/AtlasOS-Ship/main/channels/dev.json"
local STAGING_ROOT = "/.atlas-installer/staging"
local scriptDir = fs.getDir(shell.getRunningProgram())
local SHA256 = dofile(fs.combine(scriptDir, "sha256.lua"))

if not SHA256.selfTest() then
    error("SHA-256 self-test failed", 0)
end

local function fail(message)
    error(message, 0)
end

local function fetchText(url)
    local response, err = http.get(url)
    if not response then
        fail("HTTP request failed: " .. tostring(err))
    end

    local body = response.readAll()
    response.close()
    return body
end

local function decodeJson(label, text)
    local ok, value = pcall(textutils.unserialiseJSON, text)
    if not ok or type(value) ~= "table" then
        fail(label .. " is not valid JSON")
    end
    return value
end

local function requireField(tbl, key, expectedType, label)
    if type(tbl[key]) ~= expectedType then
        fail(label .. " field '" .. key .. "' must be " .. expectedType)
    end
end

local function validatePathList(manifest, key)
    local values = manifest[key]
    if values == nil then
        return
    end
    if type(values) ~= "table" then
        fail("Manifest field '" .. key .. "' must be an array")
    end
    for i, value in ipairs(values) do
        if type(value) ~= "string" then
            fail("Manifest field '" .. key .. "' entry " .. i .. " must be a string")
        end
    end
end

local function hasParentTraversal(path)
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            return true
        end
    end
    return false
end

local function validateDestinationPath(path, index)
    if path:sub(1, 1) ~= "/" then
        fail("Manifest file entry " .. index .. " path must be absolute")
    end
    if hasParentTraversal(path) then
        fail("Manifest file entry " .. index .. " path contains '..'")
    end
end

local function validateSourcePath(source, index)
    if source:match("^https?://") then
        return
    end
    if source:sub(1, 1) == "/" or hasParentTraversal(source) then
        fail("Manifest file entry " .. index .. " source must be a safe relative path or HTTP URL")
    end
end

local function validateManifest(manifest)
    requireField(manifest, "format", "number", "Manifest")
    requireField(manifest, "id", "string", "Manifest")
    requireField(manifest, "version", "string", "Manifest")
    requireField(manifest, "entrypoint", "string", "Manifest")
    requireField(manifest, "files", "table", "Manifest")

    if manifest.format ~= 1 then
        fail("Unsupported manifest format: " .. tostring(manifest.format))
    end
    if manifest.id ~= "atlasos-ship" then
        fail("Unexpected package id: " .. tostring(manifest.id))
    end

    for i, file in ipairs(manifest.files) do
        if type(file) ~= "table" then
            fail("Manifest file entry " .. i .. " must be an object")
        end
        if type(file.path) ~= "string" then
            fail("Manifest file entry " .. i .. " is missing a path")
        end
        if type(file.source) ~= "string" then
            fail("Manifest file entry " .. i .. " is missing a source")
        end
        if type(file.sha256) ~= "string" or not file.sha256:match("^[0-9a-fA-F]+$") or #file.sha256 ~= 64 then
            fail("Manifest file entry " .. i .. " has an invalid sha256")
        end
        validateDestinationPath(file.path, i)
        validateSourcePath(file.source, i)
    end

    validatePathList(manifest, "preserve")
    validatePathList(manifest, "generated")
end

local function baseUrl(url)
    local base = url:match("^(.*)/[^/]*$")
    if not base then
        fail("Cannot resolve manifest base URL")
    end
    return base
end

local function resolveSource(manifestUrl, source)
    if source:match("^https?://") then
        return source
    end
    return baseUrl(manifestUrl) .. "/" .. source
end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" then
        fs.makeDir(parent)
    end
end

local function writeFile(path, contents)
    ensureParent(path)
    local handle = fs.open(path, "wb")
    if not handle then
        fail("Cannot write " .. path)
    end
    handle.write(contents)
    handle.close()
end

local function stagePayloadPath(stageRoot, destinationPath)
    return fs.combine(stageRoot, "payload", destinationPath:sub(2))
end

local function main(...)
    local args = { ... }
    local channelUrl = args[1] or DEFAULT_CHANNEL

    print("AtlasOS Ship 4B staging test")
    print("Channel: " .. channelUrl)
    print()

    local channelText = fetchText(channelUrl)
    local channel = decodeJson("Channel", channelText)
    requireField(channel, "version", "string", "Channel")
    requireField(channel, "manifest", "string", "Channel")

    local manifestText = fetchText(channel.manifest)
    local manifest = decodeJson("Manifest", manifestText)
    validateManifest(manifest)

    if manifest.version ~= channel.version then
        fail("Channel version does not match manifest version")
    end

    local stageRoot = fs.combine(STAGING_ROOT, manifest.id, manifest.version)
    if fs.exists(stageRoot) then
        fs.delete(stageRoot)
    end
    fs.makeDir(stageRoot)

    writeFile(fs.combine(stageRoot, "channel.json"), channelText)
    writeFile(fs.combine(stageRoot, "manifest.json"), manifestText)

    print("Package: " .. manifest.id)
    print("Version: " .. manifest.version)
    print("Files: " .. #manifest.files)
    print()

    for i, file in ipairs(manifest.files) do
        local sourceUrl = resolveSource(channel.manifest, file.source)
        local destination = stagePayloadPath(stageRoot, file.path)
        local contents = fetchText(sourceUrl)
        local actualHash = SHA256.digest(contents)
        local expectedHash = file.sha256:lower()
        if actualHash ~= expectedHash then
            fail("SHA-256 mismatch for " .. file.path .. ": expected " .. expectedHash .. ", got " .. actualHash)
        end

        local partial = destination .. ".part"
        writeFile(partial, contents)
        if fs.exists(destination) then
            fs.delete(destination)
        end
        fs.move(partial, destination)

        print(string.format("[%d/%d] %s (%d bytes) verified", i, #manifest.files, file.path, #contents))
    end

    print()
    print("Staged at: " .. stageRoot)
    print("No live AtlasOS files were changed.")
    print("All staged payload files passed SHA-256 verification.")
end

main(...)
