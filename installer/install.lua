local STAGING_ROOT = "/.atlas-installer/staging"
local PACKAGE_ID = "atlasos-ship"

local scriptDir = fs.getDir(shell.getRunningProgram())
local Transaction = dofile(fs.combine(scriptDir, "transaction.lua"))

local function fail(message)
    error(message, 0)
end

local function readFile(path)
    local handle = fs.open(path, "r")
    if not handle then
        fail("Cannot read " .. path)
    end

    local contents = handle.readAll()
    handle.close()
    return contents
end

local function decodeJson(label, text)
    local ok, value = pcall(textutils.unserialiseJSON, text)
    if not ok or type(value) ~= "table" then
        fail(label .. " is not valid JSON")
    end
    return value
end

local function confirm(message)
    write(message .. " [y/N] ")
    local answer = read()
    answer = answer and answer:lower() or ""
    return answer == "y" or answer == "yes"
end

local function main(...)
    local args = { ... }
    local version = args[1]
    local assumeYes = false

    for _, arg in ipairs(args) do
        if arg == "--yes" or arg == "-y" then
            assumeYes = true
        end
    end

    if not version or version:sub(1, 1) == "-" then
        print("Usage: install <version> [--yes]")
        return
    end

    local stageRoot = fs.combine(STAGING_ROOT, PACKAGE_ID, version)
    local manifestPath = fs.combine(stageRoot, "manifest.json")

    if not fs.exists(manifestPath) then
        fail("Staged manifest not found for " .. version .. ". Run stage.lua first.")
    end

    local manifestText = readFile(manifestPath)
    local manifest = decodeJson("Manifest", manifestText)

    if manifest.id ~= PACKAGE_ID then
        fail("Unexpected package id: " .. tostring(manifest.id))
    end

    if manifest.version ~= version then
        fail("Staged manifest version does not match requested version")
    end

    if type(manifest.files) ~= "table" then
        fail("Manifest files field is missing")
    end

    print("AtlasOS Ship installer transaction")
    print("Package: " .. manifest.id)
    print("Version: " .. manifest.version)
    print("Files: " .. #manifest.files)
    print()

    for _, file in ipairs(manifest.files) do
        print("  " .. tostring(file.path))
    end

    print()
    print("Existing files will be backed up before replacement.")
    print("Preserved and generated paths cannot be package targets.")
    print()

    if not assumeYes and not confirm("Install this staged package?") then
        print("Cancelled.")
        return
    end

    local result = Transaction.install(stageRoot, manifest, manifestText)

    print()
    print("Install complete.")
    print("Transaction: " .. result.transactionId)
    print("Backup: " .. result.backupRoot)
    print("Files installed: " .. result.fileCount)
end

main(...)
