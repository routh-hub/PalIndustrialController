local M = {}

local defaultMaxBatch = 20
local maxDepth = 16

local roleSuitabilityBonus = {
    smelting = { [1] = true },
    manufacturing = { [5] = true },
    farming = { [2] = true, [3] = true, [10] = true },
    mining = { [8] = true, [7] = true },
}

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function block(code, message, item, camp, station, suitability)
    return { code = code, message = message, item = item, camp = camp, station = station, suitability = suitability }
end

local function orderStatus(snapshot, item)
    local stationId = snapshot.awaiting[item]
    local station = snapshot.stationIds[stationId]
    if station then
        if station.energyRequired and station.energyWaiting then
            return block("energy", "设备缺电，等待供电恢复", item, station.camp, station.id, 4)
        end
        if station.cannotApproach then
            return block("path", "帕鲁无法接近设备，请检查路径", item, station.camp, station.id, station.workSuitability)
        end
        if station.queueItem == item and (station.queueCount or 0) > 0 then
            return block("queue", "原版生产排队中", item, station.camp, station.id, station.workSuitability)
        end
        if station.outputItem == item and (station.outputCount or 0) > 0 then
            return block("delivery", "成品等待搬运", item, station.camp, station.id, 12)
        end
    end
    return block("delivery", "等待核验订单或入库", item, station and station.camp, stationId, 12)
end

function M.routeKey(source, destination, item)
    return source .. "/" .. destination .. "/" .. item
end

local function planItem(state, item, needed, preferredCamp, depth, visiting)
    if state.snapshot.unknownPending[item] then return nil, block("queue", "原版队列数量未知", item) end
    if state.snapshot.awaiting[item] then return nil, orderStatus(state.snapshot, item) end
    if needed <= 0 then return nil, block("queue", "等待在产物品", item) end
    if visiting[item] then return nil, block("recipe", "配方存在循环", item) end
    if depth > maxDepth or state.budget <= 0 then return nil, block("recipe", "配方依赖超过规划上限", item) end
    local choices = state.byOutput[item]
    if not choices then return nil, block("recipe", "缺少已解锁的配方或兼容设备", item) end

    local best, dependencies, reason = nil, {}, nil
    for _, choice in ipairs(choices) do
        local recipe, station = choice.recipe, choice.station
        local accessible = not state.onlyCamp or station.camp == state.onlyCamp
        local rejected = state.rejected[station.id .. "/" .. recipe.id]
        if state.disabledStations and state.disabledStations[station.id] then
            reason = reason or block("access", "设备已被手动禁用", item, station.camp, station.id, station.workSuitability)
        elseif not station.idle then
            local full = (station.outputCount or 0) > 0
            if station.energyRequired and station.energyWaiting then
                reason = reason or block("energy", "设备缺电，等待供电恢复", item, station.camp, station.id, 4)
            elseif station.cannotApproach then
                reason = reason or block("path", "帕鲁无法接近设备", item, station.camp, station.id, station.workSuitability)
            else
                reason = reason or block(full and "delivery" or "queue",
                    full and "设备有待搬产物" or "等待设备空闲", item, station.camp, station.id,
                    full and 12 or station.workSuitability)
            end
        elseif station.energyRequired and station.energyWaiting then
            reason = reason or block("energy", "空闲设备缺电，等待供电", item, station.camp, station.id, 4)
        elseif rejected then
            reason = reason or rejected.diagnostic
        else
            local camp = state.snapshot.campById[station.camp]
            local batchCap = state.adaptiveBatches and state.adaptiveBatches[item] or state.maxBatch
            local batches = math.min(batchCap, math.ceil(needed / recipe.count))
            local runnable = batches
            for _, material in ipairs(choice.materialOrder) do
                local reserve = state.goals[material] or 0
                local surplus = math.max(0, (state.snapshot.stock[material] or 0) - reserve)
                local localStock = math.min(surplus, camp.stock[material] or 0)
                local units = recipe.materials[material]
                runnable = math.min(runnable, math.floor(localStock / units))
                if localStock < units then
                    dependencies[#dependencies + 1] = {
                        camp = camp.id, item = material, localStock = localStock, surplus = surplus,
                        required = units, batchNeeds = batches * units,
                    }
                end
            end
            if runnable > 0 and accessible then
                local role = state.campRoles and state.campRoles[station.camp]
                local roleMatch = role and station.workSuitability and roleSuitabilityBonus[role]
                    and roleSuitabilityBonus[role][station.workSuitability] and 1 or 0
                local score = (station.camp == preferredCamp and 2 or 0) * (batchCap + 1)
                    + roleMatch * (batchCap + 1) + runnable
                if not best or best.score < score then
                    best = { kind = "produce", item = item, recipe = recipe, station = station,
                        batches = runnable, score = score }
                end
            elseif runnable > 0 then
                reason = reason or block("access", "等待进入目标据点", item, station.camp, station.id, station.workSuitability)
            end
        end
    end
    if best then return best end
    if #dependencies == 0 then
        return nil, reason or block("access", "等待进入有兼容设备的据点", item, choices[1].station.camp)
    end

    visiting[item] = true
    local checked = {}
    local firstBlock
    for _, dependency in ipairs(dependencies) do
        local key = dependency.camp .. "/" .. dependency.item .. "/" .. tostring(dependency.batchNeeds)
        if not checked[key] and state.budget > 0 then
            checked[key] = true
            state.budget = state.budget - 1
            if dependency.surplus >= dependency.required and state.onlyCamp and dependency.camp ~= state.onlyCamp then
                firstBlock = firstBlock or block("access", "进入目标据点后可调拨原料", dependency.item, dependency.camp)
            elseif dependency.surplus >= dependency.required then
                local bestSource, bestAmount
                for _, source in ipairs(state.snapshot.camps) do
                    local available = math.min(source.stock[dependency.item] or 0,
                        dependency.surplus - dependency.localStock, dependency.batchNeeds - dependency.localStock)
                    local route = M.routeKey(source.id, dependency.camp, dependency.item)
                    if source.id ~= dependency.camp and available > 0 then
                        if not state.rejected[route] and (not bestAmount or available > bestAmount) then
                            bestSource, bestAmount = source.id, available
                        elseif state.rejected[route] then
                            firstBlock = firstBlock or state.rejected[route].diagnostic
                        end
                    end
                end
                if bestSource then
                    visiting[item] = nil
                    return { kind = "transfer", item = dependency.item, source = bestSource,
                        destination = dependency.camp, amount = bestAmount }
                end
            else
                local pending = state.snapshot.pending[dependency.item] or 0
                local missing = dependency.batchNeeds - dependency.surplus - pending
                local action, blocked = planItem(state, dependency.item, missing, dependency.camp, depth + 1, visiting)
                if action then visiting[item] = nil; return action end
                if not state.byOutput[dependency.item] and blocked.code == "recipe" then
                    blocked = block("material", "缺料 · 无法安排上游生产", dependency.item, dependency.camp)
                end
                firstBlock = firstBlock or blocked
            end
        end
    end
    visiting[item] = nil
    return nil, firstBlock or reason or block("material", "依赖材料尚未就绪", item)
end

local function index(snapshot)
    local byOutput, materials = {}, {}
    for _, station in ipairs(snapshot.stations or {}) do
        for _, id in ipairs(sortedKeys(station.recipes or {})) do
            local recipe = snapshot.recipes and snapshot.recipes[id]
            if recipe then
                materials[id] = materials[id] or sortedKeys(recipe.materials or {})
                local choices = byOutput[recipe.output] or {}
                choices[#choices + 1] = { recipe = recipe, station = station, materialOrder = materials[id] }
                byOutput[recipe.output] = choices
            end
        end
    end
    return byOutput
end

function M.next(snapshot, goals, rejected, onlyCamp, options)
    if snapshot.incomplete then return nil, block("access", "库存未同步") end
    options = options or {}
    snapshot.recipesByOutput = snapshot.recipesByOutput or index(snapshot)
    local maxBatch = type(options.maxBatch) == "number" and options.maxBatch >= 1 and math.floor(options.maxBatch) or defaultMaxBatch
    local hysteresisPct = type(options.hysteresisPct) == "number" and options.hysteresisPct > 0 and options.hysteresisPct or 0
    local state = {
        snapshot = snapshot, goals = goals, byOutput = snapshot.recipesByOutput,
        rejected = rejected or {}, onlyCamp = onlyCamp, budget = 300,
        maxBatch = maxBatch,
        campRoles = options.campRoles,
        disabledStations = options.disabledStations,
        adaptiveBatches = options.adaptiveBatches,
    }
    local priorityBonus = options.priorityBonus or {}
    local shortage = {}
    for item, target in pairs(goals) do
        local stock = snapshot.stock[item] or 0
        local pending = snapshot.pending[item] or 0
        local needed = target - stock - pending
        local triggerGap = hysteresisPct > 0 and math.ceil(target * hysteresisPct / 100) or 1
        if needed > 0 and (pending > 0 or snapshot.awaiting[item] or needed >= triggerGap) then
            local score = (needed / target) + (priorityBonus[item] or 0)
            shortage[#shortage + 1] = { id = item, needed = needed, fraction = score }
        end
    end
    table.sort(shortage, function(a, b)
        return a.fraction > b.fraction or (a.fraction == b.fraction and a.id < b.id)
    end)
    local reason
    for _, goal in ipairs(shortage) do
        local action, blocked = planItem(state, goal.id, goal.needed, nil, 1, {})
        if action then
            action.goal = goal.id
            return action
        end
        if not reason then
            reason = { code = blocked.code, message = blocked.message, item = blocked.item,
                camp = blocked.camp, station = blocked.station, goal = goal.id, suitability = blocked.suitability }
        end
    end
    if reason then return nil, reason end
    if next(snapshot.awaiting) then return nil, orderStatus(snapshot, sortedKeys(snapshot.awaiting)[1]) end
    for item, target in pairs(goals) do
        if (snapshot.stock[item] or 0) < target then return nil, block("queue", "剩余缺口已有排队或待搬产物", item) end
    end
    return nil, block("covered", "目标已达标")
end

-- Computes real inventory breakdown per item: actual, reserved (floor), available, incoming, shortfall.
function M.inventorySummary(snapshot, goals, item)
    local actual = (snapshot and snapshot.stock and snapshot.stock[item]) or 0
    local target = goals and goals[item] or nil
    local reserved = target and math.min(actual, target) or 0
    local available = math.max(0, actual - reserved)
    local incoming = (snapshot and snapshot.pending and snapshot.pending[item]) or 0
    local shortfall = target and math.max(0, target - actual - incoming) or 0
    return {
        actual = actual,
        reserved = reserved,
        available = available,
        incoming = incoming,
        shortfall = shortfall,
        target = target,
    }
end

-- Returns a short recipe dependency preview for an item (e.g., "MetalIngot×2").
function M.dependencyChain(snapshot, item, itemLabelFn)
    if not snapshot or not item then return "" end
    snapshot.recipesByOutput = snapshot.recipesByOutput or index(snapshot)
    local choices = snapshot.recipesByOutput[item]
    if not choices or not choices[1] then return "" end
    local recipe = choices[1].recipe
    local parts = {}
    for _, mat in ipairs(choices[1].materialOrder) do
        local name = itemLabelFn and itemLabelFn(mat) or mat
        parts[#parts + 1] = ("%s×%d"):format(name, recipe.materials[mat])
    end
    return table.concat(parts, " + ")
end

return M
