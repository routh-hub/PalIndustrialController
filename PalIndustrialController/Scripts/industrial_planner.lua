local M = {}

local maxBatch = 20
local maxDepth = 16

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function planItem(state, item, needed, preferredCamp, depth, visiting)
    if state.snapshot.awaiting and state.snapshot.awaiting[item] then return nil, "等待成品入库" end
    if needed <= 0 then return nil, "等待在产物品" end
    if depth > maxDepth or visiting[item] then return nil, "配方存在循环" end
    local recipes = state.byOutput[item]
    if not recipes then return nil, "没有可用配方" end

    local best, dependencies, reason = nil, {}, nil
    for _, recipe in ipairs(recipes) do
        for _, station in ipairs(state.snapshot.stations) do
            if station.recipes[recipe.id] and (not state.onlyCamp or station.camp == state.onlyCamp) then
                if not station.idle then
                    reason = reason or "等待设备空闲"
                elseif not state.rejected[station.id .. "/" .. recipe.id] then
                    local camp = state.camps[station.camp]
                    local batches = math.min(maxBatch, math.ceil(needed / recipe.count))
                    local runnable = batches
                    for _, material in ipairs(recipe.materialOrder) do
                        local reserve = state.goals[material] or 0
                        local surplus = math.max(0, (state.snapshot.stock[material] or 0) - reserve)
                        local localStock = math.min(surplus, camp.stock[material] or 0)
                        local units = recipe.materials[material]
                        runnable = math.min(runnable, math.floor(localStock / units))
                        if localStock < units then
                            dependencies[#dependencies + 1] = {
                                camp = camp.id,
                                item = material,
                                localStock = localStock,
                                surplus = surplus,
                                required = units,
                                batchNeeds = batches * units,
                            }
                        end
                    end
                    if runnable > 0 then
                        local score = (station.camp == preferredCamp and 1 or 0) * (maxBatch + 1) + runnable
                        if not best or best.score < score then
                            best = { kind = "produce", item = item, recipe = recipe, station = station,
                                batches = runnable, score = score }
                        end
                    end
                end
            end
        end
    end
    if best then return best end
    if #dependencies == 0 then return nil, reason or "本站暂无空闲的兼容设备" end

    visiting[item] = true
    local checked = {}
    local firstBlock
    for _, dependency in ipairs(dependencies) do
        local key = dependency.camp .. "/" .. dependency.item .. "/" .. tostring(dependency.required)
        if not checked[key] and state.budget > 0 then
            checked[key] = true
            state.budget = state.budget - 1
            if dependency.surplus >= dependency.required then
                for _, source in ipairs(state.snapshot.camps) do
                    local available = source.stock[dependency.item] or 0
                    if source.id ~= dependency.camp and available > 0 then
                        visiting[item] = nil
                        return {
                            kind = "transfer",
                            item = dependency.item,
                            source = source.id,
                            destination = dependency.camp,
                            amount = math.min(available, dependency.surplus - dependency.localStock,
                                dependency.batchNeeds - dependency.localStock),
                        }
                    end
                end
            end
            local pending = state.snapshot.pending[dependency.item] or 0
            local missing = dependency.required - dependency.surplus - pending
            local action, blocked = planItem(state, dependency.item, missing, dependency.camp, depth + 1, visiting)
            if action then visiting[item] = nil; return action end
            firstBlock = firstBlock or (blocked == "没有可用配方" and "缺料 · " .. dependency.item or blocked)
        end
    end
    visiting[item] = nil
    return nil, firstBlock or "依赖材料尚未就绪"
end

function M.next(snapshot, goals, rejected, onlyCamp)
    if snapshot.incomplete then return nil, "库存未同步" end
    local state = { snapshot = snapshot, goals = goals, byOutput = {}, camps = {},
        rejected = rejected or {}, onlyCamp = onlyCamp, budget = 300 }
    for _, camp in ipairs(snapshot.camps) do state.camps[camp.id] = camp end
    for _, id in ipairs(sortedKeys(snapshot.recipes)) do
        local recipe = snapshot.recipes[id]
        recipe.materialOrder = sortedKeys(recipe.materials)
        local choices = state.byOutput[recipe.output] or {}
        choices[#choices + 1] = recipe
        state.byOutput[recipe.output] = choices
    end
    local shortage = {}
    for item, target in pairs(goals) do
        local needed = target - (snapshot.stock[item] or 0) - (snapshot.pending[item] or 0)
        if needed > 0 then shortage[#shortage + 1] = { id = item, needed = needed, fraction = needed / target } end
    end
    table.sort(shortage, function(a, b)
        return a.fraction > b.fraction or (a.fraction == b.fraction and a.id < b.id)
    end)
    local reason
    for _, goal in ipairs(shortage) do
        local action, blocked = planItem(state, goal.id, goal.needed, nil, 1, {})
        if action then return action end
        reason = reason or blocked
    end
    if not reason and snapshot.awaiting and next(snapshot.awaiting) then reason = "等待成品入库" end
    return nil, reason or "目标已覆盖"
end

return M
