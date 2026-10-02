local DEFAULT_CHANNEL = "https://raw.githubusercontent.com/TheUnknownPizza/AtlasOS-Ship/main/channels/dev.json"

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

local function requireField(tbl, key, expectedType)
    if type(tbl[key]) ~= expectedType then
        fail("Manifest field '" .. key .. "' must be " .. expectedType)
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

local function validateManifest(manifest)
    requireField(manifest, "format", "number")
    requireField(manifest, "id", "string")
    requireField(manifest, "version", "string")
    requireField(manifest, "entrypoint", "string")
    requireField(manifest, "files", "table")

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
    end

    validatePathList(manifest, "preserve")
    validatePathList(manifest, "generated")
end

local function main(...)
    local args = { ... }
    local channelUrl = args[1] or DEFAULT_CHANNEL

    print("AtlasOS Ship 4B manifest inspector")
    print("Channel: " .. channelUrl)
    print()

    local channel = decodeJson("Channel", fetchText(channelUrl))
    if type(channel.version) ~= "string" or type(channel.manifest) ~= "string" then
        fail("Channel must contain string fields 'version' and 'manifest'")
    end

    print("Channel version: " .. channel.version)
    print("Manifest: " .. channel.manifest)
    print()

    local manifest = decodeJson("Manifest", fetchText(channel.manifest))
    validateManifest(manifest)

    if manifest.version ~= channel.version then
        fail("Channel version does not match manifest version")
    end

    print("Package: " .. manifest.id)
    print("Version: " .. manifest.version)
    print("Entrypoint: " .. manifest.entrypoint)
    print("Files: " .. #manifest.files)

    for i, file in ipairs(manifest.files) do
        print(string.format("  %d. %s <- %s", i, file.path, file.source))
    end

    print("Preserved paths: " .. #(manifest.preserve or {}))
    print("Generated paths: " .. #(manifest.generated or {}))
    print()
    print("No files were installed. Inspection only.")
end

main(...)
