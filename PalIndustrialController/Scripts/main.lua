local game = require("industrial_game")
local panel = require("industrial_panel")
local planner = require("industrial_planner")

local rowsPerPage = 6
local selection = 1
local snapshot, snapshotProfile
local goals, changedLabels = {}, {}
local query, editing = "", nil
local displayedPlan
local automation = false
local rejected, deliveries = {}, {}
local lastTickMessage
local lastCompleteStorage
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+[\\/])[^\\/]+$"))

local function log(message)
    print("[PalIndustrialController] " .. message .. "\n")
end

local function loadGoals(guild)
    local result = {}
    local path = directory .. "../targets-" .. guild .. ".tsv"
    local file = io.open(path, "r") or io.open(path .. ".previous", "r")
    if not file then return result end
    for line in file:lines() do
        local item, target = line:match("^([%w_]+)\t(%d+)$")
        target = tonumber(target)
        if item and target and target >= 1 and target <= 1000000 then result[item] = target end
    end
    file:close()
    return result
end

local function saveGoals(guild)
    local name = directory .. "../targets-" .. guild .. ".tsv"
    local file, reason = io.open(name .. ".tmp", "w")
    if not file then error(reason) end
    local ok, writeError = pcall(function()
        for item, target in pairs(goals) do
            assert(file:write(item, "\t", target, "\n"))
        end
    end)
    local closed, closeError = file:close()
    if not ok or not closed then error(writeError or closeError) end
    -- Lua's Windows rename does not replace an existing file.
    os.remove(name .. ".previous")
    local hadPrevious = os.rename(name, name .. ".previous")
    local moved, moveError = os.rename(name .. ".tmp", name)
    if not moved then
        if hadPrevious then os.rename(name .. ".previous", name) end
        error(moveError)
    end
end

local function displayRows(context)
    local items, result = {}, {}
    for item in pairs(snapshot.stock) do items[item] = true end
    for item in pairs(goals) do items[item] = true end
    for _, recipe in pairs(snapshot.recipes) do items[recipe.output] = true end
    for item in pairs(items) do
        local name = changedLabels[item]
        if not name then
            name = game.itemLabel(context, item)
            changedLabels[item] = name
        end
        if query == "" or name:lower():find(query, 1, true) or item:lower():find(query, 1, true) then
            result[#result + 1] = {
                id = item,
                label = name,
                target = goals[item],
                stock = snapshot.stock[item] or 0,
                pending = snapshot.pending[item] or 0,
            }
        end
    end
    table.sort(result, function(a, b)
        if (a.target ~= nil) ~= (b.target ~= nil) then return a.target ~= nil end
        if (a.stock > 0) ~= (b.stock > 0) then return a.stock > 0 end
        return a.label < b.label or (a.label == b.label and a.id < b.id)
    end)
    local previousName
    for i, row in ipairs(result) do
        local name = row.label
        if name == previousName or (result[i + 1] and name == result[i + 1].label) then
            row.label = name .. "  ·  " .. row.id
        end
        previousName = name
    end
    return result
end

local function draw(context, rows)
    local page = math.floor((selection - 1) / rowsPerPage) + 1
    local pages = math.max(1, math.ceil(#rows / rowsPerPage))
    local visible = {}
    for i = (page - 1) * rowsPerPage + 1, math.min(page * rowsPerPage, #rows) do
        local row = rows[i]
        row.selected = i == selection
        visible[#visible + 1] = row
    end
    local status = displayedPlan or "库存与目标管理 · 设定目标后预览下一步"
    if snapshot.incomplete then status = "据点或仓库正在同步 · 暂缓下单" end
    if automation then status = "自动补货运行中 · " .. status end
    panel.show(context, snapshot, visible, status, page, pages, query, automation)
end

local function expireRejections()
    local now = os.time()
    for id, expiry in pairs(rejected) do if expiry <= now then rejected[id] = nil end end
end

local function updatePlan(context, action, why)
    displayedPlan = nil
    if action and action.kind == "produce" then
        displayedPlan = ("计划生产 · %s  ×%d"):format(game.itemLabel(context, action.item), action.batches * action.recipe.count)
    elseif action and action.kind == "transfer" then
        displayedPlan = ("计划调拨 · %s  ×%d"):format(game.itemLabel(context, action.item), action.amount)
    elseif next(goals) then
        displayedPlan = why
    end
end

local function setTarget(profile, item, target)
    local previous = goals[item]
    goals[item] = target > 0 and target or nil
    local saved, message = pcall(saveGoals, profile)
    if not saved then
        goals[item] = previous
        error(message)
    end
end

local function position(rows, id)
    for i, row in ipairs(rows) do if row.id == id then return i end end
    return math.max(1, math.min(#rows, selection))
end

local function reconcileDeliveries(nextSnapshot)
    nextSnapshot.awaiting = {}
    local now = os.time()
    -- A removed warehouse's existing stock is no longer part of the delivery baseline.
    for id, storage in pairs(lastCompleteStorage or {}) do
        if not nextSnapshot.storage[id] then
            for item, delivery in pairs(deliveries) do
                delivery.expectedStock = delivery.expectedStock - (storage.stock[item] or 0)
            end
        end
    end
    lastCompleteStorage = nextSnapshot.storage
    for item, delivery in pairs(deliveries) do
        local stock = nextSnapshot.stock[item] or 0
        local queued = nextSnapshot.pending[item] or 0
        local missing = delivery.expectedStock - stock
        if missing <= 0 then
            deliveries[item] = nil
            log(("Automatic delivery confirmed: %s, stock=%d"):format(item, stock))
        else
            if queued > 0 then
                delivery.missingSince = nil
            else
                delivery.missingSince = delivery.missingSince or now
            end
            local timedOut = delivery.missingSince and now - delivery.missingSince >= 90
            if timedOut and not nextSnapshot.stationIds[delivery.station] then
                deliveries[item] = nil
                log("Released unconfirmed order from dismantled station: " .. item)
            elseif automation and timedOut then
                automation = false
                delivery.expired = true
                lastTickMessage = "未确认入库，补货已暂停 · " .. item
                log(lastTickMessage)
            end
            if deliveries[item] then
                nextSnapshot.awaiting[item] = true
                nextSnapshot.pending[item] = math.max(queued, missing)
            end
        end
    end
end

local function refresh(context, tick)
    local nextSnapshot = game.snapshot(context)
    if tick or not snapshot or #nextSnapshot.camps ~= #snapshot.camps or nextSnapshot.chests ~= snapshot.chests
        or #nextSnapshot.stations ~= #snapshot.stations or nextSnapshot.incomplete ~= snapshot.incomplete then
        local recipeCount = 0
        for _ in pairs(nextSnapshot.recipes) do recipeCount = recipeCount + 1 end
        log(("Scan camps=%d chests=%d stations=%d recipes=%d incomplete=%s"):format(
            #nextSnapshot.camps, nextSnapshot.chests, #nextSnapshot.stations, recipeCount, tostring(nextSnapshot.incomplete == true)))
    end
    if not nextSnapshot.incomplete then reconcileDeliveries(nextSnapshot) end
    if automation then
        if not context.currentCamp then
            lastTickMessage = "等待进入生产据点"
        else
            expireRejections()
            local action, why = planner.next(nextSnapshot, goals, rejected, context.currentCamp)
            if action and action.kind == "produce" then
                local started, reason = game.startOrder(context, action.station, action.recipe, action.batches, true)
                if started ~= nil then
                    local amount = action.batches * action.recipe.count
                    deliveries[action.item] = {
                        station = action.station.id,
                        expectedStock = (nextSnapshot.stock[action.item] or 0) +
                            (nextSnapshot.pending[action.item] or 0) + amount,
                    }
                    nextSnapshot.awaiting[action.item] = true
                    nextSnapshot.pending[action.item] = (nextSnapshot.pending[action.item] or 0) + amount
                end
                if started then
                    lastTickMessage = ("已下单 %s ×%d"):format(game.itemLabel(context, action.item), action.batches * action.recipe.count)
                    log(("Automatic order accepted: %s ×%d"):format(action.recipe.id, action.batches))
                elseif started == false then
                    lastTickMessage = "已提交订单，等待设备确认"
                else
                    rejected[action.station.id .. "/" .. action.recipe.id] = os.time() + 30
                    lastTickMessage = reason
                end
            elseif action and action.kind == "transfer" then
                local moved, reason = game.move(context, nextSnapshot, action)
                if moved then
                    lastTickMessage = ("已调拨 %s ×%d"):format(game.itemLabel(context, action.item), moved)
                    log(("Automatic transfer confirmed: %s ×%d"):format(action.item, moved))
                elseif moved == false then
                    automation = false
                    lastTickMessage = "原版未确认调拨，补货已暂停"
                    log(lastTickMessage)
                else
                    lastTickMessage = reason
                end
            else
                lastTickMessage = why
            end
        end
    end
    -- Only the planner's synchronous callback needs native references.
    for _, station in ipairs(nextSnapshot.stations) do station.model = nil end
    for _, camp in ipairs(nextSnapshot.camps) do camp.containers = nil end
    snapshot = nextSnapshot
end

local function handle(action, step)
    if action == "toggle" and panel.isOpen() then
        if editing then panel.endEdit(game.player()); editing = nil end
        panel.close()
        return
    end
    if action ~= "toggle" and action ~= "inspect"
        and not panel.isOpen() and not (automation and action == "refresh") then return end
    local context, reason = game.player()
    if not context then
        if action ~= "refresh" then log(reason) end
        return
    end
    local profile = context.world .. "-" .. context.guild
    if profile ~= snapshotProfile then
        snapshot, snapshotProfile, goals, selection = nil, profile, loadGoals(profile), 1
        changedLabels = {}
        lastCompleteStorage = nil
        query, displayedPlan, editing = "", nil, nil
        automation, rejected, deliveries, lastTickMessage = false, {}, {}, nil
    end
    if action == "confirm" then action = editing and "commit" or "automation" end
    if action == "automation" and not editing then
        automation = not automation
        if automation then
            for item, delivery in pairs(deliveries) do
                if delivery.expired then deliveries[item] = nil end
            end
        end
        lastTickMessage = automation and "等待下一次库存读取" or "补货已暂停"
        log(lastTickMessage)
    end
    local selectedItem
    if editing then
        if action ~= "commit" and action ~= "cancelEdit" then return end
        local completed = editing
        editing = nil
        local value = panel.endEdit(context)
        if action == "commit" and value then
            if completed.kind == "search" then
                query = value:match("^%s*(.-)%s*$"):lower()
                selection = 1
            else
                local target = tonumber(value)
                if target and target >= 0 and target <= 1000000 and target == math.floor(target) then
                    setTarget(profile, completed.item, target)
                    selectedItem = completed.item
                else
                    displayedPlan = "请输入 0 到 1000000 之间的整数"
                    draw(context, displayRows(context))
                    return
                end
            end
        end
    end
    if not snapshot or action == "toggle" or action == "inspect" or action == "refresh" then
        refresh(context, action == "inspect")
    end
    if action == "inspect" then return end
    if not panel.isOpen() and action ~= "toggle" then return end
    local rows = displayRows(context)
    selection = position(rows, selectedItem)
    if action == "search" then
        if panel.beginEdit(context, query, "搜索中文物品名或物品 ID") then editing = { kind = "search" } end
        return
    end
    if action == "target" and rows[selection] then
        local item = rows[selection].id
        if panel.beginEdit(context, tostring(goals[item] or ""), "输入目标库存，0 清除") then editing = { kind = "target", item = item } end
        return
    end
    if action == "select" then selection = math.max(1, math.min(#rows, selection + step)) end
    if action == "edit" and rows[selection] then
        local row = rows[selection]
        local target = math.max(0, math.min(1000000, (goals[row.id] or 0) + step))
        setTarget(profile, row.id, target)
        rows = displayRows(context)
        selection = position(rows, row.id)
    end
    local plan, why = planner.next(snapshot, goals)
    updatePlan(context, plan, why)
    if lastTickMessage and (automation or action == "automation" or action == "refresh") then
        displayedPlan = lastTickMessage
    end
    draw(context, rows)
end

local function schedule(action, step)
    ExecuteInGameThread(function()
        local ok, reason = xpcall(function() handle(action, step) end, debug.traceback)
        if not ok then
            if automation then
                automation = false
                lastTickMessage = "出现接口错误，补货已暂停"
            end
            log(reason)
        end
    end)
end

RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, function() schedule("toggle") end)
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, function() schedule("inspect") end)
RegisterKeyBind(Key.UP_ARROW, function() schedule("select", -1) end)
RegisterKeyBind(Key.DOWN_ARROW, function() schedule("select", 1) end)
RegisterKeyBind(Key.PAGE_UP, function() schedule("select", -rowsPerPage) end)
RegisterKeyBind(Key.PAGE_DOWN, function() schedule("select", rowsPerPage) end)
RegisterKeyBind(Key.F, { ModifierKey.CONTROL }, function() schedule("search") end)
RegisterKeyBind(Key.G, { ModifierKey.CONTROL }, function() schedule("target") end)
RegisterKeyBind(Key.F4, function() schedule("confirm") end)
RegisterKeyBind(Key.ESCAPE, function() schedule("cancelEdit") end)
RegisterKeyBind(Key.LEFT_ARROW, { ModifierKey.CONTROL }, function() schedule("edit", -10) end)
RegisterKeyBind(Key.RIGHT_ARROW, { ModifierKey.CONTROL }, function() schedule("edit", 10) end)
RegisterKeyBind(Key.LEFT_ARROW, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() schedule("edit", -100) end)
RegisterKeyBind(Key.RIGHT_ARROW, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() schedule("edit", 100) end)
RegisterLoadMapPreHook(function()
    local ok, reason = pcall(panel.close)
    if not ok then log(reason) end
    snapshot, snapshotProfile, editing = nil, nil, nil
    lastCompleteStorage = nil
    automation, rejected, deliveries, lastTickMessage = false, {}, {}, nil
end)
LoopAsync(8000, function()
    if automation or (panel.isOpen() and not editing) then schedule("refresh") end
    return false
end)
log("Loaded for Palworld 1.0.5.102999")
