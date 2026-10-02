local Transaction = {}

local INSTALLER_ROOT = "/.atlas-installer"
local BACKUP_ROOT = fs.combine(INSTALLER_ROOT, "backups")
local INSTALLED_ROOT = fs.combine(INSTALLER_ROOT, "installed")

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" then
        fs.makeDir(parent)
    end
end

local function writeText(path, contents)
    ensureParent(path)
    local handle = fs.open(path, "w")
    if not handle then
        error("Cannot write " .. path, 0)
    end
    handle.write(contents)
    handle.close()
end

local function writeJson(path, value)
    writeText(path, textutils.serialiseJSON(value))
end

local function copyFile(source, destination)
    ensureParent(destination)
    if fs.exists(destination) then
        fs.delete(destination)
    end
    fs.copy(source, destination)
end

local function replaceFile(source, destination)
    local partial = destination .. ".atlas-new"
    ensureParent(destination)

    if fs.exists(partial) then
        fs.delete(partial)
    end

    fs.copy(source, partial)

    if fs.exists(destination) then
        fs.delete(destination)
    end

    fs.move(partial, destination)
end

local function protectedBy(path, protectedPaths)
    for _, protected in ipairs(protectedPaths or {}) do
        if path == protected then
            return true
        end

        local prefix = protected
        if prefix:sub(-1) ~= "/" then
            prefix = prefix .. "/"
        end

        if path:sub(1, #prefix) == prefix then
            return true
        end
    end

    return false
end

local function validatePlan(stageRoot, manifest)
    local preserve = manifest.preserve or {}
    local generated = manifest.generated or {}
    local files = {}

    for i, file in ipairs(manifest.files) do
        local destination = file.path

        if protectedBy(destination, preserve) then
            error("Package file overlaps preserved path: " .. destination, 0)
        end

        if protectedBy(destination, generated) then
            error("Package file overlaps generated path: " .. destination, 0)
        end

        local payload = fs.combine(stageRoot, "payload", destination:sub(2))
        if not fs.exists(payload) or fs.isDir(payload) then
            error("Staged payload is missing: " .. destination, 0)
        end

        if fs.exists(destination) and fs.isDir(destination) then
            error("Install destination is a directory: " .. destination, 0)
        end

        files[i] = {
            path = destination,
            payload = payload,
            existed = fs.exists(destination),
        }
    end

    return files
end

local function makeTransactionId(manifest)
    local epoch = os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000)
    return tostring(epoch) .. "-" .. manifest.version:gsub("[^%w%._%-]", "_")
end

local function backupExisting(files, backupRoot)
    for _, file in ipairs(files) do
        if file.existed then
            local backupPath = fs.combine(backupRoot, "files", file.path:sub(2))
            copyFile(file.path, backupPath)
            file.backup = backupPath
        end
    end
end

local function backupInstalledState(manifest, backupRoot)
    local statePath = fs.combine(INSTALLED_ROOT, manifest.id, "manifest.json")
    local state = {
        path = statePath,
        existed = fs.exists(statePath),
    }

    if state.existed then
        if fs.isDir(statePath) then
            error("Installed package state is unexpectedly a directory", 0)
        end

        state.backup = fs.combine(backupRoot, "package-state", "manifest.json")
        copyFile(statePath, state.backup)
    end

    return state
end

local function restoreInstalledState(state)
    if fs.exists(state.path) then
        fs.delete(state.path)
    end

    if state.existed then
        copyFile(state.backup, state.path)
    end
end

local function rollbackFiles(files)
    for i = #files, 1, -1 do
        local file = files[i]
        local partial = file.path .. ".atlas-new"

        if fs.exists(partial) then
            fs.delete(partial)
        end

        if fs.exists(file.path) then
            fs.delete(file.path)
        end

        if file.existed then
            copyFile(file.backup, file.path)
        end
    end
end

function Transaction.install(stageRoot, manifest, manifestText)
    local files = validatePlan(stageRoot, manifest)
    local transactionId = makeTransactionId(manifest)
    local backupRoot = fs.combine(BACKUP_ROOT, manifest.id, transactionId)
    local journalPath = fs.combine(backupRoot, "transaction.json")

    fs.makeDir(backupRoot)

    local installedState = backupInstalledState(manifest, backupRoot)
    backupExisting(files, backupRoot)

    local journal = {
        format = 1,
        package = manifest.id,
        version = manifest.version,
        state = "prepared",
        backupRoot = backupRoot,
        files = {},
        installedState = {
            path = installedState.path,
            existed = installedState.existed,
            backup = installedState.backup,
        },
    }

    for i, file in ipairs(files) do
        journal.files[i] = {
            path = file.path,
            existed = file.existed,
            backup = file.backup,
        }
    end

    writeJson(journalPath, journal)

    journal.state = "applying"
    writeJson(journalPath, journal)

    local ok, err = pcall(function()
        for _, file in ipairs(files) do
            replaceFile(file.payload, file.path)
        end

        local installedManifest = fs.combine(INSTALLED_ROOT, manifest.id, "manifest.json")
        local installedPartial = installedManifest .. ".part"
        writeText(installedPartial, manifestText)

        if fs.exists(installedManifest) then
            fs.delete(installedManifest)
        end

        fs.move(installedPartial, installedManifest)
    end)

    if not ok then
        local rollbackOk, rollbackErr = pcall(function()
            rollbackFiles(files)
            restoreInstalledState(installedState)
        end)

        journal.state = rollbackOk and "rolled_back" or "rollback_failed"
        journal.error = tostring(err)
        if not rollbackOk then
            journal.rollbackError = tostring(rollbackErr)
        end
        writeJson(journalPath, journal)

        if not rollbackOk then
            error("Install failed and rollback also failed: " .. tostring(err) .. " / " .. tostring(rollbackErr), 0)
        end

        error("Install failed and was rolled back: " .. tostring(err), 0)
    end

    journal.state = "complete"
    writeJson(journalPath, journal)

    return {
        transactionId = transactionId,
        backupRoot = backupRoot,
        journalPath = journalPath,
        fileCount = #files,
    }
end

return Transaction
