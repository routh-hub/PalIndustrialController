local historyMod = require("industrial_history")

local M = {}

-- Read-only P3 What-If simulator.
-- Evaluates adding a station, upgrading worker rank, or nocturnal coverage while
-- strictly respecting upstream non-labor bottlenecks (never claims gain if upstream is blocked).
function M.simulate(snapshot, workforce, diagnostic, scenario)
    scenario = scenario or {}
    if not diagnostic or diagnostic.code == "covered" then
        return {
            feasible = false,
            bottleneck = "none",
            summary = "当前无活动瓶颈，暂不需要扩建模拟。",
            scenarios = {},
        }
    end
    local code = diagnostic.code
    if code == "material" or code == "recipe" or code == "energy" or code == "path" or code == "transport" or code == "access" or code == "recovery" then
        return {
            feasible = false,
            bottleneck = code,
            summary = ("当前受非劳动力阻塞（%s）限制：增加设备或更换帕鲁不会提升最终产出，请先解除上游阻塞。"):format(diagnostic.message or code),
            scenarios = {},
        }
    end

    local campId = diagnostic.camp
    local suit = diagnostic.suitability or (code == "delivery" and 12 or nil)
    local workers = (workforce and workforce.readable and campId and workforce.camps and workforce.camps[campId]) or {}
    local capable, maxRank, nocturnalCount = 0, 0, 0
    for _, pal in ipairs(workers) do
        local r = suit and pal.suitabilities and pal.suitabilities[suit] or 0
        if r > 0 and not (pal.disabled and pal.disabled[suit]) and not pal.dead then
            capable = capable + 1
            if r > maxRank then maxRank = r end
            if pal.nocturnal then nocturnalCount = nocturnalCount + 1 end
        end
    end

    local sameStations = 0
    for _, st in ipairs(snapshot and snapshot.stations or {}) do
        if st.camp == campId and (not suit or st.workSuitability == suit) then
            sameStations = sameStations + 1
        end
    end

    local scenarios = {}
    if capable > sameStations and sameStations > 0 then
        scenarios[#scenarios + 1] = {
            kind = "add_station",
            label = "扩建同类设备 (+1)",
            impact = "高（空闲人力充足，增加并行工位可直接降低排队等待）",
        }
    else
        scenarios[#scenarios + 1] = {
            kind = "add_station",
            label = "扩建同类设备 (+1)",
            impact = "中低（当前人力未明显富余，单加设备需同步补帕鲁）",
        }
    end

    local targetRank = scenario.targetRank or math.min(5, math.max(3, maxRank + 1))
    if targetRank > maxRank then
        scenarios[#scenarios + 1] = {
            kind = "upgrade_worker",
            label = ("提升核心工种等级 (Lv.%d → Lv.%d)"):format(maxRank, targetRank),
            impact = "高（原版每级工作适应性显著缩短单批制作耗时，且不增加占格）",
        }
    end

    if nocturnalCount == 0 then
        scenarios[#scenarios + 1] = {
            kind = "add_nocturnal",
            label = "引入夜行帕鲁或夜行性词条",
            impact = "中高（消除夜间停工空窗，提升全天有效连续吞吐）",
        }
    end

    return {
        feasible = true,
        bottleneck = code,
        camp = campId,
        suitability = suit,
        currentStations = sameStations,
        currentWorkers = capable,
        currentMaxRank = maxRank,
        summary = ("模拟基准：据点同类设备 %d 台，可用工人 %d 只（最高 Lv.%d，夜行 %d 只）"):format(
            sameStations, capable, maxRank, nocturnalCount),
        scenarios = scenarios,
    }
end

-- P3 Global Development Planner: inspects multi-camp structure, missing recipe stations, and camp roles.
function M.globalPlan(snapshot, goals, workforce, cfg)
    local plan = { recommendations = {} }
    if not snapshot then return plan end
    local roles = cfg and cfg.campRoles or {}
    local recipesByOut = {}
    for _, st in ipairs(snapshot.stations or {}) do
        for rId in pairs(st.recipes or {}) do
            local r = snapshot.recipes and snapshot.recipes[rId]
            if r then recipesByOut[r.output] = true end
        end
    end
    local missingCraft = {}
    for item in pairs(goals or {}) do
        if not recipesByOut[item] then missingCraft[#missingCraft + 1] = item end
    end
    table.sort(missingCraft)
    if #missingCraft > 0 then
        plan.recommendations[#plan.recommendations + 1] = {
            kind = "station_gap",
            message = ("有 %d 项库存目标缺少对应配方设备（如 %s），建议规划专精产线。"):format(#missingCraft, missingCraft[1]),
        }
    end
    if #(snapshot.camps or {}) >= 2 then
        local unassigned = 0
        for _, camp in ipairs(snapshot.camps) do
            if not roles[camp.id] or roles[camp.id] == "general" then
                unassigned = unassigned + 1
            end
        end
        if unassigned == #snapshot.camps then
            plan.recommendations[#plan.recommendations + 1] = {
                kind = "camp_roles",
                message = ("当前 %d 个据点均为综合分工，可在设置中区分冶炼/制造/采集据点以减少跨据点往返。"):format(#snapshot.camps),
            }
        end
    end
    if workforce and workforce.readable then
        for _, camp in ipairs(snapshot.camps or {}) do
            local w = workforce.camps and workforce.camps[camp.id] or {}
            if (camp.stationCount or 0) >= 3 and #w == 0 then
                plan.recommendations[#plan.recommendations + 1] = {
                    kind = "empty_camp_workers",
                    camp = camp.id,
                    message = ("据点 %s 有 %d 台设备但无在岗帕鲁，建议分配劳动力。"):format(camp.name or camp.id:sub(1, 6), camp.stationCount),
                }
            end
        end
    end
    return plan
end

-- P3 Adaptive Scheduler Feedback: bounded deterministic priority & batch tuning from real execution history.
function M.adaptiveWeights(history, goals, baseBatch)
    local priorityBonus, adaptiveBatches = {}, {}
    local cap = math.max(1, baseBatch or 20)
    if not history or history.interrupted then
        return { priorityBonus = priorityBonus, adaptiveBatches = adaptiveBatches }
    end
    for item in pairs(goals or {}) do
        local m = historyMod.metrics(history, item)
        if m and m.samples >= 3 then
            -- If net stock is falling despite production, grant a small bounded priority boost (<= 0.25).
            if m.netDelta < 0 then
                priorityBonus[item] = 0.20
            elseif m.consPerMin and m.consPerMin > 1 then
                priorityBonus[item] = 0.10
            end
            -- If observed delivery lead time is very long (>180s), use smaller batches so stock arrives sooner.
            if m.avgLeadSec and m.avgLeadSec > 180 then
                adaptiveBatches[item] = math.max(1, math.floor(cap / 2))
            else
                adaptiveBatches[item] = cap
            end
        end
    end
    return { priorityBonus = priorityBonus, adaptiveBatches = adaptiveBatches }
end

return M
