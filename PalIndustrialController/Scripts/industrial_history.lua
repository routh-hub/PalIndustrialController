local M = {}
local maxSamples, maxItems = 30, 128
local maxGap = 30
local maxEvents = 64

local function clearSamples(history)
    for index = #history, 1, -1 do history[index] = nil end
    history.utilActive = 0
    history.utilTotal = 0
end

function M.recordDelivery(history, item, amount, leadSec, at)
    if not item or type(amount) ~= "number" or amount <= 0 then return end
    history.deliveries = history.deliveries or {}
    local list = history.deliveries
    if #list >= maxEvents then table.remove(list, 1) end
    list[#list + 1] = { item = item, amount = amount, lead = leadSec, at = at or os.time() }
end

function M.recordTransfer(history, item, amount, at)
    if not item or type(amount) ~= "number" or amount <= 0 then return end
    history.internalTransfers = history.internalTransfers or {}
    local list = history.internalTransfers
    if #list >= maxEvents then table.remove(list, 1) end
    list[#list + 1] = { item = item, amount = amount, at = at or os.time() }
end

function M.record(history, snapshot, goals)
    if not next(goals) then return end
    if snapshot.incomplete then
        history.interrupted = true
        return
    end
    local last = history[#history]
    local topology = {}
    for id in pairs(snapshot.storage) do topology[#topology + 1] = id end
    table.sort(topology)
    topology = table.concat(topology, ",")
    if last and (history.interrupted or snapshot.at < last.at
        or snapshot.at - last.at > maxGap or last.topology ~= topology) then
        clearSamples(history)
        last = nil
    end
    history.interrupted = false
    if last and snapshot.at - last.at < 8 then return end
    local items = {}
    for item in pairs(goals) do items[#items + 1] = item end
    if #items == 0 then return end
    table.sort(items)
    local stock = {}
    for index = 1, math.min(maxItems, #items) do stock[items[index]] = snapshot.stock[items[index]] or 0 end
    if #history == maxSamples then table.remove(history, 1) end
    local active, total = 0, 0
    if snapshot.stations then
        for _, st in ipairs(snapshot.stations) do
            total = total + 1
            if not st.idle and not (st.energyRequired and st.energyWaiting) then
                active = active + 1
            end
        end
    end
    history.utilActive = (history.utilActive or 0) + active
    history.utilTotal = (history.utilTotal or 0) + total
    history[#history + 1] = { at = snapshot.at, stock = stock, topology = topology, active = active, total = total }
end

function M.metrics(history, item)
    if not history or history.interrupted then return nil end
    local last = history[#history]
    if not last or last.stock[item] == nil then return nil end
    local firstIndex = #history
    for index = #history - 1, 1, -1 do
        local sample = history[index]
        if sample.stock[item] == nil then break end
        firstIndex = index
    end
    local first = history[firstIndex]
    local sampleCount = #history - firstIndex + 1
    local span = last.at - first.at
    local netDelta = last.stock[item] - first.stock[item]
    local produced, leadSum, leadCount = 0, 0, 0
    for _, ev in ipairs(history.deliveries or {}) do
        if ev.item == item and ev.at >= first.at and ev.at <= last.at then
            produced = produced + ev.amount
            if type(ev.lead) == "number" and ev.lead > 0 then
                leadSum = leadSum + ev.lead
                leadCount = leadCount + 1
            end
        end
    end
    local internalMoved = 0
    for _, ev in ipairs(history.internalTransfers or {}) do
        if ev.item == item and ev.at >= first.at and ev.at <= last.at then
            internalMoved = internalMoved + ev.amount
        end
    end
    local consumed = math.max(0, produced - netDelta)
    local prodPerMin = span > 0 and (produced * 60 / span) or nil
    local consPerMin = span > 0 and (consumed * 60 / span) or nil
    local utilPct = nil
    local activeSum, totalSum = 0, 0
    for idx = firstIndex, #history do
        activeSum = activeSum + (history[idx].active or 0)
        totalSum = totalSum + (history[idx].total or 0)
    end
    if totalSum > 0 then utilPct = math.floor((activeSum / totalSum) * 100 + 0.5) end
    local series = {}
    for index = firstIndex, #history do
        series[#series + 1] = { at = history[index].at, count = history[index].stock[item] }
    end
    return {
        firstStock = first.stock[item],
        lastStock = last.stock[item],
        samples = sampleCount,
        span = span,
        netDelta = netDelta,
        produced = produced,
        consumed = consumed,
        internalMoved = internalMoved,
        prodPerMin = prodPerMin,
        consPerMin = consPerMin,
        avgLeadSec = leadCount > 0 and (leadSum / leadCount) or nil,
        utilizationPct = utilPct,
        series = series,
    }
end

function M.describe(history, item, label, forecastInfo)
    if history.interrupted then return { label, "据点或仓库读取中断，等待新的完整样本。" } end
    local rows = { label }
    local m = M.metrics(history, item)
    if not m then
        rows[2] = "没有该物品的连续样本。统计覆盖已设置目标的物品（最多 128 种）。"
        return rows
    end
    if m.samples < 2 then
        rows[2] = ("当前仓库库存  %d · 等待下一次观测"):format(m.lastStock)
        return rows
    end
    rows[2] = ("起始库存  %d    当前库存  %d    样本数  %d"):format(m.firstStock, m.lastStock, m.samples)
    rows[3] = ("%d 秒内库存净变化  %+d"):format(m.span, m.netDelta)
    local rateParts = {}
    if m.produced > 0 and m.prodPerMin then
        rateParts[#rateParts + 1] = ("实测产出 %.1f/分"):format(m.prodPerMin)
    else
        rateParts[#rateParts + 1] = "实测产出 0（窗口内无入库）"
    end
    if m.consumed > 0 and m.consPerMin then
        rateParts[#rateParts + 1] = ("估算消耗 %.1f/分"):format(m.consPerMin)
    else
        rateParts[#rateParts + 1] = "估算消耗 0"
    end
    if m.utilizationPct ~= nil then
        rateParts[#rateParts + 1] = ("设备利用率 %d%%"):format(m.utilizationPct)
    else
        rateParts[#rateParts + 1] = "设备利用率 未知"
    end
    rows[4] = table.concat(rateParts, "  ·  ")
    if forecastInfo and forecastInfo.recommended then
        rows[5] = ("需求预测：建议目标 %d（保底 %d · 可信度 %s · %s）"):format(
            forecastInfo.recommended, forecastInfo.floor, forecastInfo.confidenceLabel, forecastInfo.reason)
    end
    return rows, m.series
end

return M
