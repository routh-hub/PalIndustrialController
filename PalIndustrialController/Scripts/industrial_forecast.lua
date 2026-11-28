local historyMod = require("industrial_history")

local M = {}

local confidenceLabels = {
    low = "低（回退固定目标）",
    medium = "中",
    high = "高",
}

local function ewmaConsumptionPerMin(history, item)
    if not history or history.interrupted or #history < 3 then return nil, 0 end
    local alpha = 0.35
    local ewma = nil
    local intervals = 0
    for i = 2, #history do
        local prev, cur = history[i - 1], history[i]
        local a, b = prev.stock[item], cur.stock[item]
        local dt = cur.at - prev.at
        if a ~= nil and b ~= nil and dt > 0 then
            local produced = 0
            for _, ev in ipairs(history.deliveries or {}) do
                if ev.item == item and ev.at > prev.at and ev.at <= cur.at then
                    produced = produced + ev.amount
                end
            end
            -- Internal guild transfers do not change aggregate stock and are never counted as consumption.
            local drop = math.max(0, produced - (b - a))
            local ratePerMin = drop * 60 / dt
            ewma = ewma == nil and ratePerMin or (alpha * ratePerMin + (1 - alpha) * ewma)
            intervals = intervals + 1
        end
    end
    return ewma, intervals
end

-- Pure read-only demand forecast for a single item.
-- Never lowers target below player's explicit floor, and caps spikes safely.
function M.estimate(history, item, floorTarget, options)
    options = options or {}
    local floor = math.max(1, math.floor(floorTarget or 1))
    local cap = math.max(floor * (options.maxMultiplier or 2), floor + 200)
    if not history or history.interrupted then
        return {
            item = item, floor = floor, recommended = floor,
            confidence = "low", confidenceLabel = confidenceLabels.low,
            reason = "观测中断，保持固定目标",
        }
    end
    local m = historyMod.metrics(history, item)
    local ewma, intervals = ewmaConsumptionPerMin(history, item)
    if not m or not ewma or intervals < 3 or m.span < 24 then
        return {
            item = item, floor = floor, recommended = floor,
            confidence = "low", confidenceLabel = confidenceLabels.low,
            samples = m and m.samples or 0,
            reason = "连续样本不足（需 ≥4 样本），保持固定目标",
        }
    end
    local leadMin = (m.avgLeadSec and m.avgLeadSec / 60) or (options.defaultLeadMin or 2.0)
    local safety = math.ceil(ewma * leadMin * 0.5)
    local raw = math.ceil(ewma * leadMin + safety)
    local recommended = math.max(floor, math.min(cap, math.max(floor, floor + raw)))
    if ewma < 0.05 then
        recommended = floor
    end
    local confidence = intervals >= 8 and "high" or "medium"
    return {
        item = item,
        floor = floor,
        recommended = recommended,
        cap = cap,
        consPerMin = ewma,
        leadMin = leadMin,
        samples = m.samples,
        confidence = confidence,
        confidenceLabel = confidenceLabels[confidence],
        reason = ewma < 0.05 and "当前近零消耗，维持保底目标"
            or ("平滑消耗 %.1f/分，提前期 %.1f分"):format(ewma, leadMin),
    }
end

-- Computes effective planning goals without mutating player's saved goals table.
function M.effectiveGoals(goals, history, forecastMode, options)
    if forecastMode ~= "enabled" or not history or history.interrupted then
        return goals, {}
    end
    local effective, forecasts = {}, {}
    for item, target in pairs(goals) do
        local info = M.estimate(history, item, target, options)
        forecasts[item] = info
        if info.confidence ~= "low" and info.recommended > target then
            effective[item] = info.recommended
        else
            effective[item] = target
        end
    end
    return effective, forecasts
end

return M
