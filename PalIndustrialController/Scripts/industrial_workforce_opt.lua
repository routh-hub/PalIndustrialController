local M = {}

local suitNames = {
    [1] = "生火", [2] = "浇水", [3] = "播种", [4] = "发电",
    [5] = "手工作业", [6] = "采集", [7] = "伐木", [8] = "采矿",
    [9] = "采油", [10] = "制药", [11] = "冷却", [12] = "搬运", [13] = "牧场",
}

local defaultDwellSec = 120

local function isUnhealthy(pal)
    return pal.dead or (pal.sick and pal.sick > 0) or (pal.sanity and pal.sanity < 40)
        or (pal.stomachRate and pal.stomachRate < 0.25)
end

-- Builds a deterministic, lock-respecting workforce optimization plan.
-- Never overrides pal.disabled (player-locked work suitabilities) and enforces
-- anti-oscillation dwell cooldowns. When conflicting mods are detected, stays strictly advisory.
function M.plan(snapshot, workforce, diagnostic, state, options)
    options = options or {}
    state = state or {}
    state.lastChangeAt = state.lastChangeAt or {}
    local now = options.now or os.time()
    local dwell = options.dwellSeconds or defaultDwellSec
    local conflicts = options.conflicts or {}
    local advisoryOnly = #conflicts > 0 or options.advisoryOnly ~= false

    local result = {
        advisoryOnly = advisoryOnly,
        conflicts = conflicts,
        actions = {},
        suitDistribution = {},
        summary = "",
    }
    if not workforce or not workforce.readable then
        result.summary = "未读取实时帕鲁数据，跳过岗位优化分析。"
        return result
    end

    -- 1. Aggregate real suitability coverage across observed camps
    for _, workers in pairs(workforce.camps or {}) do
        for _, pal in ipairs(workers) do
            if not isUnhealthy(pal) and not pal.sleeping then
                for suit, rank in pairs(pal.suitabilities or {}) do
                    if rank > 0 and not (pal.disabled and pal.disabled[suit]) then
                        local b = result.suitDistribution[suit] or { count = 0, maxRank = 0 }
                        b.count = b.count + 1
                        if rank > b.maxRank then b.maxRank = rank end
                        result.suitDistribution[suit] = b
                    end
                end
            end
        end
    end

    -- 2. Identify active camp demands from busy/waiting stations and current diagnostic
    local campNeeds = {}
    for _, st in ipairs(snapshot and snapshot.stations or {}) do
        if not st.idle and st.workSuitability then
            campNeeds[st.camp] = campNeeds[st.camp] or {}
            campNeeds[st.camp][st.workSuitability] = (campNeeds[st.camp][st.workSuitability] or 0) + 1
        end
        if (st.outputCount or 0) > 0 then
            campNeeds[st.camp] = campNeeds[st.camp] or {}
            campNeeds[st.camp][12] = (campNeeds[st.camp][12] or 0) + 1
        end
    end
    if diagnostic and diagnostic.camp and diagnostic.suitability then
        campNeeds[diagnostic.camp] = campNeeds[diagnostic.camp] or {}
        campNeeds[diagnostic.camp][diagnostic.suitability] = (campNeeds[diagnostic.camp][diagnostic.suitability] or 0) + 2
    end

    -- 3. Generate lock-respecting, dwell-guarded optimization actions
    for campId, needs in pairs(campNeeds) do
        local workers = workforce.camps and workforce.camps[campId] or {}
        for suit, priority in pairs(needs) do
            local activeOnSuit = 0
            local bestReassign = nil
            for _, pal in ipairs(workers) do
                local rank = pal.suitabilities and pal.suitabilities[suit] or 0
                local locked = pal.disabled and pal.disabled[suit]
                if rank > 0 and not locked then
                    if isUnhealthy(pal) then
                        result.actions[#result.actions + 1] = {
                            kind = "rest", camp = campId, palName = pal.name, suit = suit,
                            reason = ("在岗「%s」帕鲁 %s 状态异常，建议先治疗或恢复 SAN"):format(suitNames[suit] or "?", pal.name),
                        }
                    elseif not pal.sleeping then
                        if pal.currentSuitability == suit then
                            activeOnSuit = activeOnSuit + 1
                        else
                            local key = campId .. "/" .. (pal.characterId or pal.name)
                            local lastAt = state.lastChangeAt[key]
                            if not lastAt or now - lastAt >= dwell then
                                local curBusy = pal.currentSuitability or 0
                                local curNeeded = curBusy > 0 and (needs[curBusy] or 0) or 0
                                local score = rank * 10 - curNeeded * 12
                                if not bestReassign or score > bestReassign.score then
                                    bestReassign = { pal = pal, key = key, rank = rank, fromSuit = curBusy, score = score }
                                end
                            end
                        end
                    end
                end
            end
            if activeOnSuit == 0 and bestReassign and bestReassign.score > 0 then
                state.lastChangeAt[bestReassign.key] = now
                result.actions[#result.actions + 1] = {
                    kind = "reassign",
                    camp = campId,
                    palName = bestReassign.pal.name,
                    fromSuit = bestReassign.fromSuit,
                    toSuit = suit,
                    priority = priority,
                    reason = ("建议将 %s 优先分配至「%s」(Lv.%d，未违反锁定且已过 %ds 防震荡冷却)"):format(
                        bestReassign.pal.name, suitNames[suit] or "?", bestReassign.rank, dwell),
                }
            end
        end
    end

    if #conflicts > 0 then
        result.summary = ("检测到同类 MOD（%s），岗位优化保持只读建议以避免抢占。"):format(table.concat(conflicts, ", "))
    elseif #result.actions == 0 then
        result.summary = "当前各据点在岗分工均衡，无须调整。"
    else
        result.summary = ("生成 %d 条岗位优化建议（严格尊重锁定岗位与健康限制）。"):format(#result.actions)
    end
    return result
end

return M
