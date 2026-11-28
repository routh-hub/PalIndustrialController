local M = {}
local entryPattern = "^([PT])\t([%w_%-]+)\t(%x+)\t(%x+)\t(%d+)\t(%d+)\t([01])\t([%w_%-]+)\t(%d+)\t([%x,]*)"

-- A missing primary with a temporary or previous journal is ambiguous. Never
-- replay work from an older version of the file after an interrupted replacement.
local function exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

function M.replace(path, lines)
    local temp, backup = path .. ".tmp", path .. ".previous"
    local file, reason = io.open(temp, "wb")
    if not file then return nil, reason end
    local written, writeError = file:write(table.concat(lines, "\n"), #lines > 0 and "\n" or "")
    local closed, closeError = file:close()
    if not written or not closed then return nil, writeError or closeError end
    if os.rename(temp, path) then return true end
    -- Lua's Windows rename cannot replace an existing file.
    if not exists(path) then return nil, "无法写入 " .. path end
    os.remove(backup)
    local backedUp, backupError = os.rename(path, backup)
    if not backedUp then return nil, backupError end
    local moved, moveError = os.rename(temp, path)
    if not moved then os.rename(backup, path) end
    return moved, moveError
end

local function guid(value)
    return #value == 32 and value:match("^%x+$")
end

function M.read(path)
    local file = io.open(path, "rb")
    if not file then
        if exists(path .. ".tmp") or exists(path .. ".previous") then return nil, "任务记录写入中断" end
        -- A missing file is normal on first launch. Writes still require the
        -- file to be created successfully before any native request is issued.
        return {}
    end
    local records = {}
    local header = file:read("*l")
    local legacy = header == "PalIndustrialJournal\t1"
    local formatOk = legacy or header == "PalIndustrialJournal\t2"
    local pattern = entryPattern .. (legacy and "$" or "\t([01])$")
    for line in file:lines() do
        local kind, item, first, second, count, baseline, seen, recipe, since, storageKey, manual = line:match(pattern)
        local key = item
        if kind == "T" then key = false end
        count, baseline, since = tonumber(count), tonumber(baseline), tonumber(since)
        if not kind or not guid(first) or not guid(second) or not count or count < 1
            or math.type(count) ~= "integer" or math.type(baseline) ~= "integer" or records[key]
            or (recipe == "-") ~= (kind == "T") or math.type(since) ~= "integer" then
            formatOk = false
            break
        end
        records[key] = {
            kind = kind, item = item, first = first, second = second,
            count = count, baseline = baseline, seen = seen == "1", recipe = kind == "P" and recipe or nil,
            missingSince = since > 0 and since or nil, storageKey = storageKey, manual = manual == "1",
        }
    end
    file:close()
    if not formatOk then return nil, "任务记录损坏或版本不兼容" end
    return records
end

function M.write(path, records)
    local lines = {}
    for _, record in pairs(records) do
        if not record.item:match("^[%w_%-]+$")
            or (record.kind == "P" and not record.recipe:match("^[%w_%-]+$")) then
            return nil, "无法记录原版物品或配方 ID"
        end
        lines[#lines + 1] = table.concat({
            record.kind, record.item, record.first, record.second,
            record.count, record.baseline, record.seen and "1" or "0", record.recipe or "-", record.missingSince or 0,
            record.storageKey or "", record.manual and "1" or "0",
        }, "\t")
    end
    table.sort(lines)
    table.insert(lines, 1, "PalIndustrialJournal\t2")
    return M.replace(path, lines)
end

-- Keep the native queue, device output, and inferred unobserved quantity
-- disjoint. A delivery is only inferred after seeing work at the same station
-- and finding the matching quantity in the same camp with no station backlog.
function M.observe(record, snapshot, now)
    if record.manual then return "manual" end
    local camp = snapshot.campById[record.second]
    if not camp or camp.storageKey ~= record.storageKey then
        record.manual = true
        return "topology"
    end
    local station = snapshot.stationIds[record.first]
    local outstanding = 0
    local progressed = false
    if station and station.camp == record.second then
        local queued = station.activeRecipe == record.recipe and station.queueItem == record.item
            and station.queueCount or 0
        local buffered = station.outputItem == record.item and station.outputCount or 0
        outstanding = queued + buffered
        progressed = queued > 0 and not record.seen
    end
    local received = math.max(0, (camp.stock[record.item] or 0) - record.baseline)
    if station and station.camp == record.second and station.idle and record.seen and received >= record.count then
        return "received", 0
    end
    if outstanding == 0 then
        if not record.missingSince or record.missingSince > now then record.missingSince = now end
    else
        record.missingSince = nil
    end
    local missing = math.max(0, record.count - received - outstanding)
    if record.missingSince and now - record.missingSince >= 90 then
        record.manual = true
        return "uncertain"
    end
    return progressed and "seen" or "waiting", missing
end

return M
