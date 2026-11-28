local M = {}

M.strategies = { "low_cost", "balanced", "max_throughput" }

M.strategyLabels = {
    low_cost = "低成本",
    balanced = "综合收益",
    max_throughput = "极限产能",
}

local suitabilityNames = {
    [1] = "生火", [2] = "浇水", [3] = "播种", [4] = "发电",
    [5] = "手工作业", [6] = "采集", [7] = "伐木", [8] = "采矿",
    [9] = "采油", [10] = "制药", [11] = "冷却", [12] = "搬运", [13] = "牧场",
}

local sickNames = {
    [1] = "感冒", [2] = "扭伤", [3] = "暴食", [4] = "胃溃疡",
    [5] = "骨折", [6] = "虚弱", [7] = "抑郁", [8] = "不安",
}

local nonLaborReasons = {
    access = "当前瓶颈为据点访问或同步限制：请进入目标据点等待仓库和设备同步，引入帕鲁无法解决此阻塞。",
    recipe = "当前瓶颈为配方或兼容设备缺失：请检查科技解锁并建造对应工作台，引入帕鲁无法解决此阻塞。",
    material = "当前瓶颈为上游原料短缺：请先补充上游材料或建立采集/上游产线，单纯增加加工帕鲁无法缓解缺料。",
    transport = "当前瓶颈为仓库格或调拨路径受阻：请清理目标仓库空位并核对箱子权限，非帕鲁劳动力问题。",
    energy = "当前瓶颈为据点供电不足或能源模块异常：请先检查发电机与储能设施，再核对发电帕鲁。",
    path = "当前瓶颈为设备寻路受阻：帕鲁无法接近该设备，请调整设备摆放间距与通道。",
    recovery = "当前处于人工核验暂停状态：请对照原版队列与仓库，确认物资去向后按 Ctrl+Shift+R 接管。",
    unknown = "当前原因尚无法自动归因，请查看原版设备状态与 UE4SS 日志。",
}

local defaultCatalog = {
    { id = "FlameBambi", name = "燎火鹿", tier = 1, nocturnal = false, food = 3, suits = { [1] = 1 }, note = "前期低成本生火" },
    { id = "FoxMage", name = "焰巫狐", tier = 1, nocturnal = false, food = 3, suits = { [1] = 2, [5] = 3, [12] = 2 }, note = "早中期手工与生火兼顾" },
    { id = "Baphomet", name = "炎魔羊", tier = 2, nocturnal = true, food = 5, suits = { [1] = 2, [5] = 2, [8] = 1, [12] = 2 }, note = "夜行生火与手工" },
    { id = "Horus", name = "荷鲁斯", tier = 3, nocturnal = false, food = 7, suits = { [1] = 3, [12] = 3 }, note = "高阶生火与高速搬运" },
    { id = "Umihebi_Fire", name = "腾炎龙", tier = 3, nocturnal = false, food = 7, suits = { [1] = 4 }, note = "高阶生火专精，注意通道宽度" },
    { id = "Monkey", name = "新叶猿", tier = 1, nocturnal = false, food = 2, suits = { [3] = 1, [5] = 1, [7] = 1, [12] = 1 }, note = "前期低食量多面手" },
    { id = "FlowerRabbit", name = "踏春兔", tier = 1, nocturnal = false, food = 3, suits = { [3] = 2, [5] = 2, [12] = 2 }, note = "中前期小型手工与搬运" },
    { id = "CatMage", name = "暗巫猫", tier = 2, nocturnal = true, food = 4, suits = { [5] = 2, [10] = 2, [12] = 2 }, note = "夜行手工与搬运，夜间持续" },
    { id = "Anubis", name = "阿努比斯", tier = 2, nocturnal = false, food = 6, suits = { [5] = 4, [8] = 3, [12] = 2 }, note = "高阶手工核心，兼顾采矿搬运" },
    { id = "BirdDragon", name = "烽歌龙", tier = 1, nocturnal = true, food = 6, suits = { [1] = 2, [12] = 3 }, note = "夜行搬运兼生火" },
    { id = "HadesBird", name = "雷冥鸟", tier = 2, nocturnal = true, food = 7, suits = { [12] = 3 }, note = "夜行高速搬运专精" },
    { id = "CatVampire", name = "夜幕魔蝠", tier = 2, nocturnal = true, food = 5, suits = { [6] = 2, [8] = 2, [12] = 2 }, note = "夜行搬运与采矿" },
    { id = "Yeti", name = "白绒雪怪", tier = 2, nocturnal = false, food = 7, suits = { [5] = 2, [7] = 3, [11] = 2, [12] = 4 }, note = "高阶搬运专精" },
    { id = "ElecCat", name = "伏特喵", tier = 1, nocturnal = false, food = 2, suits = { [4] = 1, [5] = 1, [12] = 1 }, note = "前期低成本发电" },
    { id = "ElecPanda", name = "暴电熊", tier = 2, nocturnal = false, food = 7, suits = { [4] = 3, [5] = 2, [12] = 3 }, note = "中期主力发电与搬运" },
    { id = "ThunderDragonMan", name = "波鲁杰克斯", tier = 3, nocturnal = false, food = 7, suits = { [4] = 4, [5] = 2, [12] = 3 }, note = "高阶发电与搬运核心" },
    { id = "Penguin", name = "企丸丸", tier = 1, nocturnal = false, food = 2, suits = { [2] = 1, [5] = 1, [11] = 1, [12] = 1 }, note = "前期低成本浇水" },
    { id = "Umihebi", name = "覆海龙", tier = 3, nocturnal = false, food = 7, suits = { [2] = 4 }, note = "高阶浇水专精" },
    { id = "HerculesBeetle", name = "碎岩龟", tier = 2, nocturnal = false, food = 4, suits = { [8] = 3 }, note = "中期采矿专精" },
    { id = "BlackMetalDragon", name = "魔渊龙", tier = 3, nocturnal = true, food = 9, suits = { [8] = 4, [5] = 1 }, note = "高阶夜行采矿" },
    { id = "VioletFairy", name = "薇莉塔", tier = 2, nocturnal = false, food = 3, suits = { [3] = 2, [5] = 2, [10] = 3, [12] = 2 }, note = "制药与手工兼顾" },
}

function M.nextStrategy(current)
    for i, id in ipairs(M.strategies) do
        if id == current then return M.strategies[(i % #M.strategies) + 1] end
    end
    return "balanced"
end

function M.suitabilityName(id)
    return suitabilityNames[id] or "未知工种"
end

local function campLabel(snapshot, campId)
    if not campId then return "未知据点" end
    local camp = snapshot and snapshot.campById and snapshot.campById[campId]
    local short = campId:sub(1, 6)
    if not camp or camp.name == campId or camp.name:find("テンプレート名", 1, true) then
        return "据点 " .. short
    end
    return camp.name .. " · " .. short
end

local function isPalUnhealthy(pal)
    return pal.dead or (pal.sick and pal.sick > 0) or (pal.sanity and pal.sanity < 40)
        or (pal.stomachRate and pal.stomachRate < 0.25)
end

local function palStateTag(pal)
    local tags = {}
    if pal.dead then tags[#tags + 1] = "濒死" end
    if pal.sick and pal.sick > 0 then tags[#tags + 1] = sickNames[pal.sick] or "生病" end
    if pal.sanity and pal.sanity < 40 then tags[#tags + 1] = ("低SAN(%.0f)"):format(pal.sanity) end
    if pal.stomachRate and pal.stomachRate < 0.25 then tags[#tags + 1] = "饥饿" end
    if pal.sleeping then tags[#tags + 1] = "睡眠中" end
    if pal.nocturnal then tags[#tags + 1] = "夜行" end
    if #tags == 0 then tags[1] = "状态正常" end
    return table.concat(tags, "/")
end

local function summarizeCamp(workers)
    local summary = {
        total = #workers,
        healthy = 0,
        sick = 0,
        lowSan = 0,
        hungry = 0,
        sleeping = 0,
        nocturnal = 0,
        bySuit = {},
    }
    for _, pal in ipairs(workers) do
        local sick = pal.dead or (pal.sick and pal.sick > 0)
        local lowSan = pal.sanity and pal.sanity < 40
        local hungry = pal.stomachRate and pal.stomachRate < 0.25
        if sick then summary.sick = summary.sick + 1 end
        if lowSan then summary.lowSan = summary.lowSan + 1 end
        if hungry then summary.hungry = summary.hungry + 1 end
        if pal.sleeping then summary.sleeping = summary.sleeping + 1 end
        if pal.nocturnal then summary.nocturnal = summary.nocturnal + 1 end
        if not sick and not lowSan and not hungry then summary.healthy = summary.healthy + 1 end
        for suit, rank in pairs(pal.suitabilities or {}) do
            if rank > 0 and not (pal.disabled and pal.disabled[suit]) then
                local bucket = summary.bySuit[suit] or { count = 0, maxRank = 0 }
                bucket.count = bucket.count + 1
                if rank > bucket.maxRank then bucket.maxRank = rank end
                summary.bySuit[suit] = bucket
            end
        end
    end
    return summary
end

local function effectiveRank(pal, suit)
    local rank = pal.suitabilities and pal.suitabilities[suit] or 0
    if rank <= 0 then return 0, false end
    if pal.disabled and pal.disabled[suit] then return rank, true end
    return rank, false
end

local function findOwnedCandidates(workforce, snapshot, targetCamp, suit)
    local candidates = {}
    if not workforce or not suit then return candidates end

    -- 1. Palbox reserve first (zero opportunity cost on active camps)
    for _, pal in ipairs(workforce.palbox or {}) do
        local rank, disabled = effectiveRank(pal, suit)
        if rank > 0 and not pal.dead then
            local score = rank * 25 + (pal.nocturnal and 12 or 0) - (isPalUnhealthy(pal) and 20 or 0)
                - (disabled and 15 or 0) + 40 -- priority bonus for idle Palbox reserve
            candidates[#candidates + 1] = {
                source = "palbox",
                pal = pal,
                rank = rank,
                disabled = disabled,
                score = score,
                opportunityCost = "终端闲置，几乎无机会成本",
            }
        end
    end

    -- 2. Other camps' workers (explicit opportunity cost)
    for campId, workers in pairs(workforce.camps or {}) do
        if campId ~= targetCamp then
            local campSuitCount = 0
            for _, w in ipairs(workers) do
                local r, dis = effectiveRank(w, suit)
                if r > 0 and not dis and not isPalUnhealthy(w) then campSuitCount = campSuitCount + 1 end
            end
            for _, pal in ipairs(workers) do
                local rank, disabled = effectiveRank(pal, suit)
                if rank > 0 and not pal.dead then
                    local busySuit = pal.currentSuitability or 0
                    local idleBonus = busySuit == 0 and 15 or 0
                    local surplusBonus = campSuitCount >= 2 and 10 or -15
                    local score = rank * 22 + (pal.nocturnal and 10 or 0) + idleBonus + surplusBonus
                        - (isPalUnhealthy(pal) and 20 or 0) - (disabled and 25 or 0)
                    local costText
                    if busySuit > 0 then
                        costText = ("来自%s，正在执行「%s」"):format(campLabel(snapshot, campId), M.suitabilityName(busySuit))
                    else
                        costText = ("来自%s（当前空闲，同工种余量 %d）"):format(campLabel(snapshot, campId), campSuitCount)
                    end
                    candidates[#candidates + 1] = {
                        source = "other_camp",
                        camp = campId,
                        pal = pal,
                        rank = rank,
                        disabled = disabled,
                        score = score,
                        opportunityCost = costText,
                    }
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.rank ~= b.rank then return a.rank > b.rank end
        return (a.pal.name or "") < (b.pal.name or "")
    end)
    return candidates
end

local workPassiveCatalog = {
    CraftSpeed_up2 = { label = "工匠精神", kind = "speed", weight = 5 },
    PAL_CorporateSlave = { label = "社畜", kind = "speed", weight = 4 },
    CraftSpeed_up1 = { label = "认真", kind = "speed", weight = 3 },
    PAL_Conceited = { label = "自恋狂", kind = "speed", weight = 2 },
    Nocturnal = { label = "夜行性", kind = "nocturnal", weight = 4 },
    PAL_FullStomach_Down_2 = { label = "节食大师", kind = "sustain", weight = 3 },
    PAL_FullStomach_Down_1 = { label = "小胃口", kind = "sustain", weight = 2 },
    PAL_Sanity_Down_2 = { label = "工作狂", kind = "sustain", weight = 3 },
    PAL_Sanity_Down_1 = { label = "积极思维", kind = "sustain", weight = 2 },
}

local function findBreedingParents(workforce)
    local parents = {}
    if not workforce then return parents end
    local function inspect(pal, where)
        if not pal or not pal.passives or #pal.passives == 0 then return end
        local score, labels = 0, {}
        for _, pid in ipairs(pal.passives) do
            local info = workPassiveCatalog[pid]
            if info then
                score = score + info.weight
                labels[#labels + 1] = info.label
            end
        end
        if score > 0 then
            parents[#parents + 1] = { name = pal.name, where = where, score = score, labels = labels }
        end
    end
    for _, pal in ipairs(workforce.palbox or {}) do inspect(pal, "终端") end
    for _, workers in pairs(workforce.camps or {}) do
        for _, pal in ipairs(workers) do inspect(pal, "据点") end
    end
    table.sort(parents, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return (a.name or "") < (b.name or "")
    end)
    return parents
end

local function scoreSpecies(entry, suit, strategy, playerLevel, campSummary)
    local rank = entry.suits and entry.suits[suit] or 0
    if rank <= 0 then return nil end
    local food = entry.food or 4
    local tier = entry.tier or 2
    local nocturnal = entry.nocturnal and 1 or 0
    local size = entry.size or "medium"
    local sizePenalty = size == "large" and 8 or (size == "small" and -3 or 0)
    local suitCount = 0
    local synergyBonus = 0
    for sId, sRank in pairs(entry.suits) do
        suitCount = suitCount + 1
        if sId ~= suit and sRank >= 2 and campSummary and campSummary.bySuit then
            local b = campSummary.bySuit[sId]
            if not b or b.count == 0 then synergyBonus = synergyBonus + 4 end
        end
    end
    synergyBonus = math.min(synergyBonus, 8)
    local longTerm = playerLevel and ((tier == 3 and playerLevel < 38) or (tier == 2 and playerLevel < 20))
    local score
    if strategy == "low_cost" then
        score = rank * 16 - tier * 18 - food * 3 + nocturnal * 8 - sizePenalty + synergyBonus + math.min(suitCount, 3) * 2
        if longTerm then score = score - 25 end
    elseif strategy == "max_throughput" then
        score = rank * 35 + nocturnal * 14 - (suitCount > 3 and 4 or 0) - food * 0.5 - (size == "large" and 2 or 0) + synergyBonus * 0.5
    else -- balanced
        score = rank * 24 + nocturnal * 12 - tier * 6 - food * 2 - sizePenalty * 0.7 + synergyBonus + (suitCount <= 3 and 4 or 0)
        if longTerm then score = score - 12 end
    end
    return score, rank, longTerm
end

local function recommendSpecies(workforce, suit, strategy, campSummary, spoilerHide)
    if not suit then return {} end
    local catalog = (workforce and workforce.species and #workforce.species > 0) and workforce.species or defaultCatalog
    local playerLevel = workforce and workforce.playerLevel
    local ownedMap = workforce and workforce.ownedSpecies or nil
    local ranked = {}
    for _, entry in ipairs(catalog) do
        local owned = ownedMap and (ownedMap[entry.id] or 0) > 0 or false
        local score, rank, longTerm = scoreSpecies(entry, suit, strategy, playerLevel, campSummary)
        if score and not (spoilerHide and longTerm and not owned) then
            ranked[#ranked + 1] = {
                id = entry.id,
                name = entry.name,
                rank = rank,
                tier = entry.tier,
                nocturnal = entry.nocturnal,
                food = entry.food,
                size = entry.size or "medium",
                owned = owned,
                ownedKnown = ownedMap ~= nil,
                note = entry.note,
                longTerm = longTerm == true,
                score = score,
            }
        end
    end
    table.sort(ranked, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.name < b.name
    end)
    return ranked
end

local function inferSuitability(diagnostic, snapshot)
    if not diagnostic then return nil end
    if diagnostic.suitability then return diagnostic.suitability end
    if diagnostic.code == "delivery" then return 12 end
    if diagnostic.code == "energy" then return 4 end
    if diagnostic.station and snapshot and snapshot.stationIds then
        local st = snapshot.stationIds[diagnostic.station]
        if st and st.workSuitability then return st.workSuitability end
    end
    return nil
end

function M.analyze(diagnostic, snapshot, workforce, options)
    options = options or {}
    local strategy = M.strategyLabels[options.strategy] and options.strategy or "balanced"
    local targetCamp = (diagnostic and diagnostic.camp) or options.currentCamp
    local hasWorkforce = workforce and workforce.readable == true
    local campWorkers = (hasWorkforce and targetCamp and workforce.camps and workforce.camps[targetCamp]) or {}
    local campSummary = hasWorkforce and summarizeCamp(campWorkers) or nil
    local code = diagnostic and diagnostic.code or "covered"
    local suit = inferSuitability(diagnostic, snapshot)

    local analysis = {
        code = code,
        strategy = strategy,
        strategyLabel = M.strategyLabels[strategy],
        camp = targetCamp,
        suitability = suit,
        suitabilityName = suit and M.suitabilityName(suit) or nil,
        hasWorkforce = hasWorkforce,
        campSummary = campSummary,
        isLaborBottleneck = false,
        laborFinding = nil,
        ownedCandidates = {},
        speciesCandidates = {},
        cultivation = {},
    }

    if code == "covered" then
        analysis.headline = diagnostic and diagnostic.message or "当前规划可执行，没有需要处理的生产瓶颈。"
        return analysis
    end

    -- Strictly avoid attributing non-labor bottlenecks to Pal labor
    if code == "material" or code == "recipe" or code == "transport" or code == "recovery"
        or code == "access" or code == "path" or code == "unknown" then
        analysis.headline = diagnostic.message
        analysis.nonLaborAdvice = nonLaborReasons[code] or nonLaborReasons.unknown
        return analysis
    end

    -- Energy bottleneck: verify power module first, optionally report electric Pal availability
    if code == "energy" then
        analysis.headline = diagnostic.message
        analysis.nonLaborAdvice = nonLaborReasons.energy
        if hasWorkforce and suit == 4 then
            local elecBucket = campSummary.bySuit[4]
            if not elecBucket or elecBucket.count == 0 then
                analysis.isLaborBottleneck = true
                analysis.laborFinding = "该据点缺少启用「发电」的在岗帕鲁。"
                analysis.ownedCandidates = findOwnedCandidates(workforce, snapshot, targetCamp, 4)
                analysis.speciesCandidates = recommendSpecies(workforce, 4, strategy, campSummary, options.spoilerHide)
            else
                analysis.laborFinding = ("该据点已有 %d 只发电帕鲁（最高 Lv.%d），请先核查发电机数量与储能。"):format(
                    elecBucket.count, elecBucket.maxRank)
            end
        end
        return analysis
    end

    -- Queue or delivery: check real worker evidence when available
    analysis.headline = diagnostic.message
    if not hasWorkforce then
        analysis.laborFinding = "当前未读取到实时帕鲁劳动力快照，无法判断帕鲁是否缺员、休息或生病。"
        return analysis
    end
    if not suit then
        analysis.laborFinding = "当前设备所需工种未知，请先查看原版设备面板确认所需适应性。"
        return analysis
    end

    local capable, healthyCapable, disabledCapable, distracted, sleepingList, unhealthyList = 0, 0, 0, {}, {}, {}
    for _, pal in ipairs(campWorkers) do
        local rank, disabled = effectiveRank(pal, suit)
        if rank > 0 then
            capable = capable + 1
            if disabled then
                disabledCapable = disabledCapable + 1
            elseif isPalUnhealthy(pal) then
                unhealthyList[#unhealthyList + 1] = pal
            elseif pal.sleeping then
                sleepingList[#sleepingList + 1] = pal
            else
                healthyCapable = healthyCapable + 1
                if pal.currentSuitability and pal.currentSuitability > 0 and pal.currentSuitability ~= suit then
                    distracted[#distracted + 1] = pal
                end
            end
        end
    end

    analysis.isLaborBottleneck = true
    local sName = M.suitabilityName(suit)
    if capable == 0 then
        analysis.laborFinding = ("该据点缺少具备「%s」适应性的在岗帕鲁（当前共 %d 只工人）。"):format(sName, #campWorkers)
    elseif disabledCapable == capable then
        analysis.laborFinding = ("据点内 %d 只具备「%s」的帕鲁均被玩家手动关闭了该工种，建议保持尊重锁定或手动开启。"):format(disabledCapable, sName)
    elseif healthyCapable == 0 and #unhealthyList > 0 then
        analysis.laborFinding = ("据点内「%s」帕鲁状态异常（%s：%s），请优先治疗/补充食物与温泉恢复 SAN。"):format(
            sName, unhealthyList[1].name, palStateTag(unhealthyList[1]))
    elseif healthyCapable == 0 and #sleepingList > 0 then
        analysis.laborFinding = ("据点内 %d 只「%s」帕鲁当前正在夜间休息，可考虑夜行帕鲁以保持夜间连续产出。"):format(#sleepingList, sName)
    elseif #distracted > 0 and #distracted == healthyCapable then
        local first = distracted[1]
        analysis.laborFinding = ("据点内「%s」帕鲁（如 %s）正忙于「%s」，可优先调整工作优先级或增配专精帕鲁。"):format(
            sName, first.name, M.suitabilityName(first.currentSuitability))
    else
        analysis.laborFinding = ("据点内已有 %d 只可用「%s」帕鲁，若仍积压说明工位并行度或适应性等级不足。"):format(healthyCapable, sName)
    end

    analysis.ownedCandidates = findOwnedCandidates(workforce, snapshot, targetCamp, suit)
    analysis.speciesCandidates = recommendSpecies(workforce, suit, strategy, campSummary, options.spoilerHide)

    if options.advanced then
        local parents = findBreedingParents(workforce)
        local parentLine
        if #parents > 0 then
            local pText = {}
            for i = 1, math.min(2, #parents) do
                pText[#pText + 1] = ("%s[%s:%s]"):format(parents[i].name, parents[i].where, table.concat(parents[i].labels, "+"))
            end
            parentLine = "· 已有优质亲本：" .. table.concat(pText, " / ") .. "（可优先定向配种）"
        else
            parentLine = "· 已有亲本：当前未检测到高工作速度/夜行被动词条，建议先捕捉筛选词条。"
        end
        analysis.cultivation = {
            "高级培养（结合真实词条与通用规则，不虚构吞吐百分比）：",
            parentLine,
            "· 词条方向：优先工作速度（工匠精神/认真/社畜）；夜产线配夜行性；长时岗位补节食/稳SAN。",
            "· 浓缩/强化：4星浓缩全工种 +1；帕鲁之魂提工作速度；野生分布请对照原版图鉴。",
        }
    end
    return analysis
end

function M.describe(diagnostic, context, snapshot, itemLabel, workforce, options)
    options = options or {}
    local analysis = M.analyze(diagnostic, snapshot, workforce, options)
    local result = {}
    local labelFn = function(id)
        if type(itemLabel) == "function" then return itemLabel(context, id) end
        return tostring(id)
    end

    if analysis.code == "covered" then
        result[#result + 1] = analysis.headline
        if analysis.hasWorkforce and analysis.campSummary then
            local cs = analysis.campSummary
            result[#result + 1] = ("当前据点劳动力：在岗 %d 只 · 健康 %d · 异常/低SAN %d · 睡眠 %d"):format(
                cs.total, cs.healthy, cs.sick + cs.lowSan, cs.sleeping)
            local topSuits = {}
            for _, sId in ipairs({ 5, 1, 8, 12, 4, 2 }) do
                local b = cs.bySuit[sId]
                if b then topSuits[#topSuits + 1] = ("%s×%d(Lv%d)"):format(M.suitabilityName(sId), b.count, b.maxRank) end
            end
            if #topSuits > 0 then
                result[#result + 1] = "工种覆盖：" .. table.concat(topSuits, "  ")
            end
        else
            result[#result + 1] = "没有检测到需要处理的生产瓶颈。"
        end
        result[#result + 1] = ("策略：%s（Ctrl+E 切换）  ·  高级培养：%s（Ctrl+D 展开/折叠）"):format(
            analysis.strategyLabel, options.advanced and "已展开" or "已折叠")
        if snapshot and snapshot.at then
            result[#result + 1] = "数据观测于  " .. os.date("%H:%M:%S", snapshot.at)
        end
        return result
    end

    result[#result + 1] = analysis.headline
    local chain = {}
    if diagnostic and diagnostic.goal then chain[#chain + 1] = "目标 " .. labelFn(diagnostic.goal) end
    if diagnostic and diagnostic.item and diagnostic.item ~= diagnostic.goal then
        chain[#chain + 1] = "阻塞 " .. labelFn(diagnostic.item)
    end
    if analysis.camp then chain[#chain + 1] = campLabel(snapshot, analysis.camp) end
    if #chain > 0 then result[#result + 1] = "因果链：" .. table.concat(chain, "  →  ") end

    if analysis.nonLaborAdvice then
        result[#result + 1] = analysis.nonLaborAdvice
    end
    if analysis.laborFinding then
        result[#result + 1] = "劳动力观测：" .. analysis.laborFinding
    end

    if analysis.isLaborBottleneck then
        if #analysis.ownedCandidates > 0 then
            local best = analysis.ownedCandidates[1]
            local line = ("优先调配已有帕鲁：%s（%s Lv.%d · %s · %s）"):format(
                best.pal.name, analysis.suitabilityName, best.rank, palStateTag(best.pal), best.opportunityCost)
            if best.disabled then line = line .. " [该工种已手动关闭]" end
            result[#result + 1] = line
            if analysis.ownedCandidates[2] then
                local second = analysis.ownedCandidates[2]
                result[#result + 1] = ("备选已有帕鲁：%s（Lv.%d · %s）"):format(
                    second.pal.name, second.rank, second.opportunityCost)
            end
        else
            result[#result + 1] = "已有帕鲁（终端与其余据点）中未检出合适的空余候补。"
        end

        if #analysis.speciesCandidates > 0 then
            local picks = {}
            for i = 1, math.min(3, #analysis.speciesCandidates) do
                local sp = analysis.speciesCandidates[i]
                local flags = {}
                if sp.ownedKnown then flags[#flags + 1] = sp.owned and "已拥有" or "未拥有" end
                if sp.nocturnal then flags[#flags + 1] = "夜行" end
                if sp.size == "large" then flags[#flags + 1] = "大体型" end
                if sp.longTerm then flags[#flags + 1] = "长期" end
                local suffix = #flags > 0 and ("·" .. table.concat(flags, "/")) or ""
                picks[#picks + 1] = ("%s(Lv.%d%s)"):format(sp.name, sp.rank, suffix)
            end
            result[#result + 1] = ("图鉴推荐[%s]：%s（捕捉分布请对照原版图鉴）"):format(
                analysis.strategyLabel, table.concat(picks, " / "))
        end
    end

    if options.advanced and #analysis.cultivation > 0 then
        for _, line in ipairs(analysis.cultivation) do
            result[#result + 1] = line
        end
    else
        result[#result + 1] = ("策略：%s（Ctrl+E）  ·  高级培养：%s（Ctrl+D）"):format(
            analysis.strategyLabel, options.advanced and "已展开" or "已折叠")
    end

    if snapshot and snapshot.at then
        result[#result + 1] = "库存读取于  " .. os.date("%H:%M:%S", snapshot.at)
    end
    return result
end

return M
