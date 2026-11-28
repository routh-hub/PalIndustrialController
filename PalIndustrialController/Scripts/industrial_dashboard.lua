local i18n = require("industrial_i18n")
local planner = require("industrial_planner")

local M = {}

M.tabs = {
    { id = "overview", label = "首页", key = "tab_overview" },
    { id = "inventory", label = "库存", key = "tab_inventory" },
    { id = "production", label = "生产作业", key = "tab_production" },
    { id = "logistics", label = "据点调拨", key = "tab_logistics" },
    { id = "advisor", label = "帕鲁顾问", key = "tab_advisor" },
    { id = "history", label = "库存趋势", key = "tab_history" },
    { id = "settings", label = "设置", key = "tab_settings" },
}

function M.localizedTabs(lang)
    local out = {}
    for _, tab in ipairs(M.tabs) do
        out[#out + 1] = { id = tab.id, label = i18n.t(lang, tab.key) }
    end
    return out
end

local function collectReviewOrders(snapshot, deliveries, itemLabel, en)
    local items, targetSection = {}, "production"
    if not deliveries then return items, targetSection end
    local pendingTransfer = deliveries[false]
    if pendingTransfer and pendingTransfer.manual then
        targetSection = "logistics"
        items[#items + 1] = (en and "Transfer · %s ×%d (%s → %s)" or "调拨 · %s ×%d（%s → %s）"):format(
            itemLabel(pendingTransfer.item), pendingTransfer.count or 0,
            M.campLabel(snapshot, pendingTransfer.first), M.campLabel(snapshot, pendingTransfer.second))
    end
    local prod = {}
    for key, record in pairs(deliveries) do
        if key ~= false and record.manual then prod[#prod + 1] = record end
    end
    table.sort(prod, function(a, b) return (a.item or "") < (b.item or "") end)
    for _, record in ipairs(prod) do
        targetSection = "production"
        items[#items + 1] = (en and "Order · %s ×%d (%s)" or "生产单 · %s ×%d（%s）"):format(
            itemLabel(record.item), record.count or 0, M.campLabel(snapshot, record.second))
    end
    return items, targetSection
end

function M.home(snapshot, goals, state)
    local en = state.lang == "en-US"
    local shortages, total = {}, 0
    for item, target in pairs(goals) do
        local stock = snapshot.stock[item] or 0
        if not snapshot.incomplete and stock < target then
            shortages[#shortages + 1] = {
                item = item, stock = stock, target = target,
                review = snapshot.manualReview and snapshot.manualReview[item] == true or false,
            }
        end
        total = total + 1
    end
    table.sort(shortages, function(a, b)
        if a.review ~= b.review then return a.review end
        local ratioA, ratioB = a.stock / a.target, b.stock / b.target
        return ratioA < ratioB or (ratioA == ratioB and a.item < b.item)
    end)
    local list = {}
    for index = 1, math.min(4, #shortages) do
        local entry = shortages[index]
        entry.label = state.itemLabel(entry.item)
        list[index] = entry
    end
    local reviewOrders, reviewSection = collectReviewOrders(snapshot, state.deliveries, state.itemLabel, en)
    local headline, detail
    if state.blocked then
        headline = en and "Order needs your review" or "有待核验的订单"
        if #reviewOrders > 0 then
            detail = reviewOrders[1]
            if #reviewOrders > 1 then
                detail = detail .. (en and (" (+%d more)"):format(#reviewOrders - 1) or ("（另有 %d 条）"):format(#reviewOrders - 1))
            end
        else
            detail = state.blocked
            local reviewItem = state.blocked:match("^订单待核验 · ([%w_%-]+)$")
            if reviewItem then
                detail = (en and "Pending order · %s" or "待核验订单 · %s"):format(state.itemLabel(reviewItem))
            end
        end
    elseif snapshot.incomplete then
        headline = en and "Reading base inventory" or "正在读取据点库存"
        detail = en and "Orders wait until the inventory scan completes." or "库存同步完成后才会自动下单。"
    elseif total == 0 then
        headline = en and "Set your first stock target" or "先设一个库存目标"
        detail = en and "Open Inventory to pick an item and set how many to keep." or "进入库存页选择物品并设定目标数量，再启动自动补货。"
    elseif #shortages == 0 then
        headline = state.automation and (en and "All stock targets met" or "库存目标都达成了")
            or (en and "All targets met · Paused" or "目标已达标 · 当前暂停")
        detail = en and "Nothing needs replenishing right now." or "当前库存充足，如需持续盯库可保持启动。"
    else
        headline = state.automation and (en and "Restock is running" or "自动补货运行中")
            or (en and "Restock is paused" or "自动补货已暂停")
        detail = state.status
        if state.automation then
            local general = {
                energy = en and "Restore power at the affected base" or "先恢复据点供电",
                path = en and "Clear the path to the station" or "先清理设备周围的通道",
                access = en and "Move to the target base to dispatch" or "进入对应据点后继续下单",
            }
            local issue = general[state.diagnostic and state.diagnostic.code]
            if issue then headline = issue end
        end
    end
    return {
        heading = en and "Restock overview" or "补货总览",
        headline = headline,
        detail = detail,
        warning = state.blocked ~= nil,
        blocked = state.blocked ~= nil,
        automation = state.automation == true,
        canAcknowledge = state.canAcknowledge == true,
        reviewChecked = state.reviewChecked == true,
        reviewOrders = reviewOrders,
        reviewSection = reviewSection,
        shortages = list,
        shortageCount = #shortages,
        targetCount = total,
        unread = snapshot.incomplete,
        campCount = #snapshot.camps,
        chestCount = snapshot.chests,
        stationCount = #snapshot.stations,
        currentCamp = state.currentCamp and M.campLabel(snapshot, state.currentCamp),
    }
end

function M.step(current, direction)
    for index, tab in ipairs(M.tabs) do
        if tab.id == current then
            return M.tabs[(index - 1 + direction) % #M.tabs + 1].id
        end
    end
    return "inventory"
end

function M.campLabel(snapshot, id)
    if not id then return "未知据点" end
    local camp = snapshot.campById[id]
    local prefix = id:sub(1, 6)
    if not camp then return "据点 " .. prefix end
    if not camp.name or camp.name == id or camp.name:find("テンプレート名", 1, true) then return "据点 " .. prefix end
    return camp.name .. " · " .. prefix
end

function M.production(snapshot, deliveries, itemLabel, lang, reviewState)
    local rows, seenAlerts, ordinary, shown = {}, {}, {}, {}
    local en = lang == "en-US"
    local hasManual = false
    local function add(station, record)
        local item = station.queueItem or station.outputItem or (record and record.item)
        if not item then return end
        local status = en and "Game order" or "原版订单"
        local warning = false
        if record then
            status = record.manual and (en and "Needs review" or "需人工核验") or (en and "Auto restock" or "自动补货")
            warning = record.manual == true
            if record.manual then hasManual = true end
        end
        if station.energyRequired and station.energyWaiting then
            status = status .. (en and " · No power" or " · 缺电")
            warning = true
        elseif station.cannotApproach then
            status = status .. (en and " · Path blocked" or " · 路径受阻")
            warning = true
        else
            local deps = planner.dependencyChain(snapshot, item, itemLabel)
            if deps ~= "" then status = status .. " · " .. deps end
        end
        local target = warning and seenAlerts or ordinary
        target[#target + 1] = {
            cells = {
                itemLabel(item),
                M.campLabel(snapshot, station.camp),
                station.id:sub(1, 6),
                station.queueUnknown and "?" or tostring(station.queueCount or 0),
                tostring(station.outputCount or 0),
                status,
            },
            warning = warning,
        }
    end
    local byStation = {}
    for _, record in pairs(deliveries) do
        if record.kind == "P" then
            local items = byStation[record.first] or {}
            items[record.item] = record
            byStation[record.first] = items
        end
    end
    for _, station in ipairs(snapshot.stations) do
        local item = station.queueItem or station.outputItem
        if item then
            local record = byStation[station.id] and byStation[station.id][item]
            if record then shown[record] = true end
            add(station, record)
        end
    end
    local pendingRecords = {}
    for _, record in pairs(deliveries) do
        if record.kind == "P" and not shown[record] then pendingRecords[#pendingRecords + 1] = record end
    end
    table.sort(pendingRecords, function(a, b) return a.item < b.item end)
    for _, record in ipairs(pendingRecords) do
        if record.manual then hasManual = true end
        rows[#rows + 1] = {
            cells = {
                itemLabel(record.item),
                M.campLabel(snapshot, record.second),
                record.first:sub(1, 6),
                "—",
                "—",
                record.manual and (en and "Needs review" or "需人工核验") or (en and "Awaiting confirmation" or "等待核验"),
            },
            warning = true,
        }
    end
    for _, row in ipairs(seenAlerts) do rows[#rows + 1] = row end
    for _, row in ipairs(ordinary) do rows[#rows + 1] = row end
    return {
        heading = en and "Production orders" or "生产作业",
        rows = rows,
        canTakeover = hasManual and reviewState and reviewState.canAcknowledge == true,
        reviewPrompt = hasManual and (en and "Verify these orders in-game, then confirm takeover." or "核对下方订单与仓库物资后，点击确认接管。") or nil,
        empty = lang == "en-US" and "No active production orders." or "没有已观测到的生产订单。",
    }
end

function M.addTransfer(history, event)
    if #history == 20 then table.remove(history, 1) end
    history[#history + 1] = event
end

function M.logistics(snapshot, pending, history, plan, itemLabel, lang, reviewState)
    local rows = {}
    local en = lang == "en-US"
    local hasManual = pending and pending.manual == true
    local function row(event, state, warning)
        rows[#rows + 1] = {
            cells = {
                itemLabel(event.item),
                M.campLabel(snapshot, event.source),
                M.campLabel(snapshot, event.destination),
                tostring(event.amount),
                state,
            },
            warning = warning,
        }
    end
    if pending then
        row({ item = pending.item, source = pending.first, destination = pending.second, amount = pending.count },
            en and "Needs review" or "待人工核验", true)
    elseif plan and plan.kind == "transfer" then
        row(plan, en and "Scheduled" or "待执行", true)
    end
    for i = #history, 1, -1 do
        local event = history[i]
        row(event, (en and "Verified " or "已核验 ") .. os.date("%H:%M", event.at))
    end
    return {
        heading = en and "Base transfers" or "据点调拨",
        rows = rows,
        canTakeover = hasManual and reviewState and reviewState.canAcknowledge == true,
        reviewPrompt = hasManual and (en and "Check source and destination chests, then confirm takeover." or "核对来源与目标仓库物品数量后，点击确认接管。") or nil,
        empty = lang == "en-US" and "No planned or completed transfers." or "当前没有计划或已记录的调拨。",
    }
end

M.settingKeys = {
    "mode", "language", "forecastMode", "advisorEnabled", "spoilerHide", "adaptiveEnabled", "blueprint", "conflicts",
}

function M.settings(cfg, selection, conflicts, notice)
    local lang = cfg.language
    local en = lang == "en-US"
    local function enabled(value) return i18n.t(lang, value and "yes" or "no") end
    local hasConflicts = #conflicts > 0
    local entries = {
        mode = {
            kind = "choice",
            label = en and "Restock mode" or "补货模式",
            value = i18n.t(lang, "mode_" .. cfg.mode),
            current = cfg.mode,
            options = {
                { id = "vanilla_balanced", label = i18n.t(lang, "mode_vanilla_balanced") },
                { id = "automation", label = i18n.t(lang, "mode_automation") },
                { id = "max_efficiency", label = i18n.t(lang, "mode_max_efficiency") },
            },
            description = en and "Changes order batch size and how far stock can fall before restocking."
                or "决定单次下单的批量，以及库存差多少才发起补货。",
        },
        language = {
            kind = "choice",
            label = en and "Language" or "界面语言",
            value = i18n.t(lang, "langName"),
            current = cfg.language,
            options = {
                { id = "zh-CN", label = "简体中文" },
                { id = "en-US", label = "English" },
            },
            description = en and "In-game item names follow Palworld's language." or "物品名称跟随游戏本身的语言。",
        },
        forecastMode = {
            kind = "choice",
            label = en and "Demand forecast" or "需求预测",
            value = i18n.t(lang, "forecast_" .. cfg.forecastMode),
            current = cfg.forecastMode,
            options = {
                { id = "off", label = i18n.t(lang, "forecast_off") },
                { id = "advisory", label = i18n.t(lang, "forecast_advisory") },
                { id = "enabled", label = i18n.t(lang, "forecast_enabled") },
            },
            description = en and "Use recent stock changes to suggest a higher target. Your saved target is the minimum."
                or "根据近期库存变化建议提高补货量。你设的库存目标仍是保底。",
        },
        advisorEnabled = {
            kind = "toggle",
            label = en and "Pal advisor" or "帕鲁顾问",
            value = enabled(cfg.advisorEnabled ~= false),
            checked = cfg.advisorEnabled ~= false,
            description = en and "Get advice on the current production bottleneck." or "针对现在影响生产的问题给出建议。",
        },
        spoilerHide = {
            kind = "toggle",
            label = en and "Hide undiscovered Pals" or "隐藏图鉴剧透",
            value = enabled(cfg.spoilerHide),
            checked = cfg.spoilerHide == true,
            description = en and "Hide advanced recommendations for Pals you don't own." or "隐藏还未拥有的高阶帕鲁推荐。",
        },
        adaptiveEnabled = {
            kind = "toggle",
            label = en and "Adaptive scheduling" or "自适应调度",
            value = enabled(cfg.adaptiveEnabled ~= false),
            checked = cfg.adaptiveEnabled ~= false,
            description = en and "Use recent results to adjust order priority and batch size." or "根据近期的补货情况调整优先级和单次下单量。",
        },
        blueprint = {
            kind = "action",
            label = en and "Export blueprint" or "导出蓝图",
            value = i18n.t(lang, "btn_export"),
            description = notice or (en and "Save your current stock targets and selected settings to a file."
                or "把当前库存目标和部分设置保存为蓝图文件。"),
        },
        conflicts = {
            kind = "info",
            label = en and "Mod compatibility" or "模组兼容",
            value = hasConflicts and (en and "Conflicts detected" or "检测到同类模组") or (en and "No known conflicts" or "暂无已知冲突"),
            description = hasConflicts and table.concat(conflicts, ", ") or (en and "No conflicting automation mods detected." or "未检测到冲突的同类自动化模组。"),
        },
    }
    local rows = {}
    for _, id in ipairs(M.settingKeys) do
        local entry = entries[id]
        rows[#rows + 1] = {
            id = id, kind = entry.kind, label = entry.label, value = entry.value,
            checked = entry.checked, current = entry.current, options = entry.options,
            description = entry.description,
        }
    end
    return {
        heading = en and "Settings" or "设置",
        rows = rows,
        selection = selection or 1,
    }
end

function M.stockTrend(item, metrics, forecast, lang)
    local en = lang == "en-US"
    local content = { heading = en and "Stock trends" or "库存趋势" }
    if not item then
        content.empty = en and "Set a stock target to start tracking an item." or "设定库存目标后，这里会开始记录该物品。"
        return content
    end
    content.item = item
    content.series = metrics and metrics.series
    if not metrics or metrics.samples < 2 then
        content.empty = en and "Waiting for another complete stock reading." or "正在等待下一次完整的库存采样。"
        return content
    end
    content.metrics = {
        { label = en and "Stock change" or "库存变化", value = ("%+d"):format(metrics.netDelta) },
        { label = en and "Received" or "补货入库", value = tostring(metrics.produced) },
        { label = en and "Est. use / min" or "估算消耗／分", value = ("%.1f"):format(metrics.consPerMin or 0) },
    }
    content.period = (en and "%d readings over %ds" or "%d 次采样 · 最近 %d 秒"):format(metrics.samples, metrics.span)
    if metrics.utilizationPct then
        content.period = content.period .. (en and "   ·   Stations with orders %d%%" or "   ·   设备订单占用 %d%%"):format(metrics.utilizationPct)
    end
    if forecast and forecast.recommended then
        content.forecast = (en and "Suggested target %d · Minimum %d" or "建议目标 %d · 保底 %d"):format(
            forecast.recommended, forecast.floor)
        local confidence = ({ low = en and "Low" or "低", medium = en and "Medium" or "中", high = en and "High" or "高" })[forecast.confidence]
        if confidence then content.forecast = content.forecast .. (en and " · Confidence " or " · 可信度 ") .. confidence end
    end
    return content
end

return M
