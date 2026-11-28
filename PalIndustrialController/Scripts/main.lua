local game = require("industrial_game")
local panel = require("industrial_panel")
local dashboard = require("industrial_dashboard")
local planner = require("industrial_planner")
local journal = require("industrial_journal")
local configLoaded, configMod = pcall(require, "industrial_config")
local i18nLoaded, i18n = pcall(require, "industrial_i18n")
local advisorLoaded, advisor = pcall(require, "industrial_advisor")
local workforceLoaded, workforce = pcall(require, "industrial_workforce")
local workforceOptLoaded, workforceOpt = pcall(require, "industrial_workforce_opt")
local historyLoaded, history = pcall(require, "industrial_history")
local forecastLoaded, forecast = pcall(require, "industrial_forecast")
local simLoaded, simulator = pcall(require, "industrial_simulator")
local bpLoaded, blueprint = pcall(require, "industrial_blueprint")
local apiLoaded, extApi = pcall(require, "industrial_api")

local rowsPerPage = 6
local selected, settingSelection = {}, 1
local snapshot, snapshotProfile, workforceSnapshot
local goals, changedLabels = {}, {}
local cfg = configLoaded and configMod.defaults() or {
    mode = "automation", language = "zh-CN", advisorEnabled = true,
    advisorStrategy = "balanced", advisorAdvanced = false, spoilerHide = false,
    forecastMode = "off", workforceOptEnabled = true, adaptiveEnabled = true,
    campRoles = {}, disabledStations = {},
}
local query, editing, inventoryAll = "", nil, false
local targetDraft, targetError = nil, nil
local reviewChecked = false
local section, viewPage = "overview", 1
local cachedRows
local observations = {}
local transfers = {}
local workforceOptState = {}
local detectedConflicts = {}
local blueprintNotice, settingError
local lastDiagnostic
local displayedPlan
local automation = false
local rejected, deliveries = {}, {}
local journalPath, configPath, journalError, goalError
local blocked
local lastTickMessage
local refreshing = false
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+[\\/])[^\\/]+$"))

local function log(message)
    print("[PalIndustrialController] " .. message .. "\n")
end

local function t(key)
    if i18nLoaded then return i18n.t(cfg.language, key) end
    return key
end

local function saveConfig()
    if configLoaded and configPath then
        local ok, saved, reason = pcall(configMod.write, configPath, cfg)
        if ok and saved then return true end
        log("Config save failed: " .. tostring(ok and reason or saved))
    end
    return false
end

local function loadGoals(guild)
    local result = {}
    local path = directory .. "../targets-" .. guild .. ".tsv"
    local file = io.open(path, "r") or io.open(path .. ".previous", "r")
    if not file then return result end
    for line in file:lines() do
        local item, target = line:match("^([%w_%-]+)\t(%d+)\r?$")
        target = tonumber(target)
        if line ~= "" and not (item and target and target >= 1 and target <= 1000000 and not result[item]) then
            file:close()
            return {}, "库存目标文件损坏 · 补货已暂停"
        end
        if item then result[item] = target end
    end
    file:close()
    return result
end

local function saveGoals(guild)
    local name = directory .. "../targets-" .. guild .. ".tsv"
    local lines = {}
    for item, target in pairs(goals) do
        lines[#lines + 1] = item .. "\t" .. target
    end
    table.sort(lines)
    assert(journal.replace(name, lines))
end

local function planningInputs()
    local effective = goals
    if forecastLoaded and cfg.forecastMode == "enabled" then
        local ok, eff = pcall(forecast.effectiveGoals, goals, observations, cfg.forecastMode)
        if ok and eff then effective = eff end
    end
    local preset = configLoaded and configMod.preset(cfg) or { maxBatch = 20, hysteresisPct = 0 }
    local options = {
        maxBatch = preset.maxBatch,
        hysteresisPct = preset.hysteresisPct,
        campRoles = cfg.campRoles,
        disabledStations = cfg.disabledStations,
    }
    if simLoaded and cfg.adaptiveEnabled ~= false then
        local ok, weights = pcall(simulator.adaptiveWeights, observations, effective, preset.maxBatch)
        if ok and weights then
            options.priorityBonus = weights.priorityBonus
            options.adaptiveBatches = weights.adaptiveBatches
        end
    end
    return effective, options
end

local function itemLabel(context, item)
    if not changedLabels[item] then changedLabels[item] = game.itemLabel(context, item) end
    return changedLabels[item]
end

local function displayRows(context, scope)
    cachedRows = cachedRows or {}
    if cachedRows[scope] then return cachedRows[scope] end
    local items, result = {}, {}
    for item in pairs(goals) do items[item] = true end
    if scope ~= "goals" then
        for item in pairs(snapshot.stock) do items[item] = true end
        for item in pairs(snapshot.pending) do items[item] = true end
        for item in pairs(snapshot.unknownPending) do items[item] = true end
        for item in pairs(snapshot.manualReview) do items[item] = true end
        for _, recipe in pairs(snapshot.recipes) do items[recipe.output] = true end
    end
    for item in pairs(items) do
        local name = itemLabel(context, item)
        if scope ~= "search" or name:lower():find(query, 1, true) or item:lower():find(query, 1, true) then
            local summary = planner.inventorySummary(snapshot, goals, item)
            result[#result + 1] = {
                id = item,
                label = name,
                target = goals[item],
                stock = summary.actual,
                reserved = summary.reserved,
                available = summary.available,
                shortfall = summary.shortfall,
                queued = snapshot.unknownPending[item] and "?" or tostring(snapshot.queued[item] or 0),
                buffered = snapshot.buffered[item] or 0,
                inTransit = snapshot.manualReview[item] and "?" or (snapshot.inTransit[item] or 0),
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
    cachedRows[scope] = result
    return result
end

local function inventoryScope()
    if query ~= "" then return "search" end
    return inventoryAll and "all" or "goals"
end

-- Explicitly opt-in only (never auto-triggered on tab open or timer).
local function scanWorkforceOnDemand(context)
    if not workforceLoaded or not snapshot or cfg.advisorEnabled == false then return end
    local ok, result = pcall(workforce.scan, context, snapshot)
    if ok then
        if apiLoaded then
            local species, seen = {}, {}
            for _, entry in ipairs(result.species or {}) do
                species[#species + 1], seen[entry.id] = entry, true
            end
            for _, entry in ipairs(extApi.speciesSupplements()) do
                if not seen[entry.id] then
                    species[#species + 1], seen[entry.id] = entry, true
                end
            end
            result.species = species
        end
        workforceSnapshot = result
    else
        workforceLoaded = false
        workforceSnapshot = nil
        log("Workforce advisor scan disabled after error: " .. tostring(result))
    end
end

local function draw(context, rows, selection, plan)
    local status = displayedPlan or "库存与目标管理 · 设定目标后预览下一步"
    if snapshot.incomplete then status = "据点或仓库正在同步 · 暂缓下单" end
    if blocked then status = blocked end
    local function labelItem(id) return itemLabel(context, id) end
    local lang = cfg.language or "zh-CN"
    local en = lang == "en-US"
    local canAck = not journalError and not goalError and not automation
    local content
    if section == "overview" then
        content = dashboard.home(snapshot, goals, {
            lang = lang, itemLabel = labelItem, status = status, automation = automation,
            blocked = blocked, deliveries = deliveries,
            canAcknowledge = canAck, reviewChecked = reviewChecked,
            currentCamp = context.currentCamp, diagnostic = lastDiagnostic,
        })
    elseif section == "inventory" then
        content = {
            heading = en and "Stock and targets" or "库存与目标",
            scope = inventoryScope(),
            query = query,
            rows = rows,
            selection = selection,
            incomplete = snapshot.incomplete,
            targetDraft = targetDraft,
            targetError = targetError,
        }
    elseif section == "production" then
        content = dashboard.production(snapshot, deliveries, labelItem, lang, { canAcknowledge = canAck })
    elseif section == "logistics" then
        content = dashboard.logistics(snapshot, deliveries[false], transfers,
            context.currentCamp and plan or nil, labelItem, lang, { canAcknowledge = canAck })
    elseif section == "advisor" then
        local details = {}
        local stratName = advisorLoaded and advisor.strategyLabels[cfg.advisorStrategy] or "综合收益"
        if cfg.advisorEnabled == false then
            details = { en and "Pal advisor is turned off in Settings." or "帕鲁工业顾问已在「设置」中关闭。" }
        elseif advisorLoaded then
            local ok, result = pcall(advisor.describe, lastDiagnostic, context, snapshot, game.itemLabel, workforceSnapshot, {
                strategy = cfg.advisorStrategy,
                advanced = cfg.advisorAdvanced,
                spoilerHide = cfg.spoilerHide,
                currentCamp = context.currentCamp,
            })
            details = ok and result or { "工业顾问暂不可用" }
            if workforceOptLoaded and cfg.workforceOptEnabled ~= false and workforceSnapshot and workforceSnapshot.readable then
                local okOpt, optPlan = pcall(workforceOpt.plan, snapshot, workforceSnapshot, lastDiagnostic, workforceOptState, {
                    conflicts = detectedConflicts, advisoryOnly = true,
                })
                if okOpt and optPlan then
                    if optPlan.actions and optPlan.actions[1] then
                        details[#details + 1] = "岗位优化：" .. optPlan.actions[1].reason
                    elseif optPlan.summary and optPlan.summary ~= "" then
                        details[#details + 1] = "岗位优化：" .. optPlan.summary
                    end
                end
            end
            if simLoaded and cfg.advisorAdvanced then
                local okSim, sim = pcall(simulator.simulate, snapshot, workforceSnapshot, lastDiagnostic)
                if okSim and sim and sim.scenarios and sim.scenarios[1] then
                    details[#details + 1] = ("扩建模拟：%s → %s"):format(sim.scenarios[1].label, sim.scenarios[1].impact)
                end
                local okGlob, gPlan = pcall(simulator.globalPlan, snapshot, goals, workforceSnapshot, cfg)
                if okGlob and gPlan and gPlan.recommendations and gPlan.recommendations[1] then
                    details[#details + 1] = "全局规划：" .. gPlan.recommendations[1].message
                end
            end
        else
            details = { "工业顾问暂不可用" }
        end
        local canLiveScan = cfg.advisorEnabled ~= false and workforceLoaded and not workforceSnapshot
        content = {
            heading = en and "Pal advisor" or "帕鲁顾问",
            advisorEnabled = cfg.advisorEnabled ~= false,
            advanced = cfg.advisorAdvanced == true,
            strategyButton = (en and "Strategy: %s" or "策略：%s"):format(stratName),
            canLiveScan = canLiveScan,
            liveNotice = canLiveScan and (en and "Live worker scan is disabled by default because it previously caused crashes."
                or "已默认跳过在岗帕鲁与终端实时读取（上次实机曾导致游戏退出），仅在手动点击上方按钮时尝试。") or nil,
            details = details,
        }
    elseif section == "history" then
        local row = rows[selection]
        local metrics, estimate
        if historyLoaded and row then
            local okM, sampled = pcall(history.metrics, observations, row.id)
            if okM then metrics = sampled end
            if forecastLoaded and goals[row.id] and cfg.forecastMode ~= "off" then
                local okF, est = pcall(forecast.estimate, observations, row.id, goals[row.id])
                if okF then estimate = est end
            end
        end
        content = dashboard.stockTrend(row, metrics, estimate, lang)
        content.itemCount = #rows
    else
        content = dashboard.settings(cfg, settingSelection, detectedConflicts, blueprintNotice)
        content.notice = settingError
    end
    if content.rows then
        local perPage = rowsPerPage
        if section == "settings" then
            perPage = math.max(rowsPerPage, #content.rows)
        elseif (section == "production" or section == "logistics") and content.canTakeover then
            perPage = 5
        end
        content.pages = math.max(1, math.ceil(#content.rows / perPage))
        local activeIdx = content.selection or 1
        content.page = content.selection and math.floor((activeIdx - 1) / perPage) + 1
            or math.min(viewPage, content.pages)
        content.first = (content.page - 1) * perPage + 1
        content.last = math.min(content.page * perPage, #content.rows)
    end
    content.page = content.page or viewPage
    local modeLabel = blocked and t("status_manual") or (automation and t("status_running") or t("status_paused"))
    local shown, reason = pcall(panel.show, context, {
        title = t("title"),
        modeLabel = modeLabel,
        tabs = dashboard.localizedTabs(lang),
        section = section,
        lang = lang,
        automation = automation,
        blocked = blocked,
        content = content,
    })
    if shown then
        if type(reason) == "number" then viewPage = reason end
    else
        pcall(panel.close, context)
        log("Panel unavailable: " .. tostring(reason))
    end
end

local function activeRejections()
    local now = os.time()
    local active = {}
    for id, entry in pairs(rejected) do
        if entry.attempts >= 3 or entry.expiry > now then active[id] = entry end
    end
    return active
end

local function updatePlan(context, action, why)
    displayedPlan = nil
    if action and action.kind == "produce" then
        local verb = action.station.camp == context.currentCamp and "计划生产" or "到达目标据点后生产"
        displayedPlan = ("%s · %s  ×%d"):format(verb, game.itemLabel(context, action.item), action.batches * action.recipe.count)
    elseif action and action.kind == "transfer" then
        displayedPlan = ("计划调拨 · %s  ×%d"):format(game.itemLabel(context, action.item), action.amount)
    elseif next(goals) then
        displayedPlan = why.item and ("%s · %s"):format(why.message, game.itemLabel(context, why.item)) or why.message
    end
end

local function setTarget(profile, item, target)
    if goalError then error(goalError) end
    if not item:match("^[%w_%-]+$") then error("不能保存此物品 ID") end
    local previous = goals[item]
    goals[item] = target > 0 and target or nil
    local saved, message = pcall(saveGoals, profile)
    if not saved then
        goals[item] = previous
        error(message)
    end
    cachedRows = nil
end

local function position(rows, id)
    for i, row in ipairs(rows) do if row.id == id then return i end end
    return 1
end

local function saveJournal()
    local saved, reason = journal.write(journalPath, deliveries)
    if not saved then
        journalError = "任务记录无法保存 · 补货已暂停"
        error(reason)
    end
end

local function reconcileDeliveries(nextSnapshot)
    local previousBlocked = blocked
    blocked = journalError or goalError
    nextSnapshot.manualReview = {}
    local changed = false
    local awaitingSubmission = false
    local now = os.time()
    for key, record in pairs(deliveries) do
        if record.kind == "T" then
            record.manual = true
            nextSnapshot.manualReview[record.item] = true
            blocked = blocked or "调拨待核验 · 补货已暂停"
        else
            nextSnapshot.awaiting[record.item] = record.first
            if not nextSnapshot.incomplete then
                local since, manual = record.missingSince, record.manual == true
                local state, missing = journal.observe(record, nextSnapshot, now)
                if since ~= record.missingSince or manual ~= (record.manual == true) then changed = true end
                nextSnapshot.inTransit[record.item] = missing
                if state == "received" then
                    local leadSec = record.startedAt and math.max(1, now - record.startedAt) or nil
                    if historyLoaded then
                        pcall(history.recordDelivery, observations, record.item, record.count, leadSec, now)
                    end
                    if apiLoaded then
                        extApi.emit("delivery", { item = record.item, count = record.count, leadSec = leadSec, at = now })
                    end
                    deliveries[key], nextSnapshot.awaiting[record.item] = nil, nil
                    changed = true
                    log("Delivery inferred from station and camp stock: " .. record.item)
                elseif state == "seen" then
                    record.seen, changed = true, true
                end
            end
            if record.manual and deliveries[key] then
                nextSnapshot.manualReview[record.item] = true
                blocked = blocked or ("订单待核验 · " .. record.item)
            elseif not record.seen then
                awaitingSubmission = true
            end
        end
    end
    if blocked then
        automation = false
        if blocked ~= previousBlocked then reviewChecked = false end
    else
        reviewChecked = false
    end
    if changed then saveJournal() end
    nextSnapshot.pending = {}
    for _, category in ipairs({ nextSnapshot.queued, nextSnapshot.buffered, nextSnapshot.inTransit }) do
        for item, count in pairs(category) do
            nextSnapshot.pending[item] = (nextSnapshot.pending[item] or 0) + count
        end
    end
    return awaitingSubmission
end

local function execute(context, nextSnapshot, action)
    local result, reason, code, key
    if action.kind == "produce" then
        local count = action.batches * action.recipe.count
        local camp = nextSnapshot.campById[action.station.camp]
        key = action.station.id .. "/" .. action.recipe.id
        local now = os.time()
        result, reason, code = game.startOrder(context, action.station, action.recipe, action.batches, function()
            deliveries[action.item] = {
                kind = "P", item = action.item, first = action.station.id,
                second = camp.id, count = count, baseline = camp.stock[action.item] or 0, recipe = action.recipe.id,
                missingSince = now, startedAt = now, storageKey = camp.storageKey,
            }
            saveJournal()
        end)
        if result ~= nil then
            rejected[key] = nil
            nextSnapshot.awaiting[action.item] = action.station.id
            nextSnapshot.pending[action.item] = (nextSnapshot.pending[action.item] or 0) + count
            if result then
                deliveries[action.item].seen = true
                saveJournal()
                nextSnapshot.queued[action.item] = (nextSnapshot.queued[action.item] or 0) + count
                action.station.queueItem, action.station.queueCount = action.item, count
                log(("Automatic order accepted: %s ×%d"):format(action.recipe.id, action.batches))
                return ("已下单 %s ×%d"):format(game.itemLabel(context, action.item), count)
            end
            nextSnapshot.inTransit[action.item] = count
            return "已提交订单，等待设备确认"
        end
    else
        key = planner.routeKey(action.source, action.destination, action.item)
        result, reason, code = game.move(context, nextSnapshot, action, function(amount)
            deliveries[false] = {
                kind = "T", item = action.item, first = action.source,
                second = action.destination, count = amount, baseline = 0,
            }
            saveJournal()
        end)
        if result then
            local now = os.time()
            rejected[key] = nil
            deliveries[false] = nil
            saveJournal()
            local ev = {
                at = now, item = action.item, amount = result,
                source = action.source, destination = action.destination,
            }
            dashboard.addTransfer(transfers, ev)
            if historyLoaded then pcall(history.recordTransfer, observations, action.item, result, now) end
            if apiLoaded then extApi.emit("transfer", ev) end
            log(("Automatic transfer confirmed: %s ×%d"):format(action.item, result))
            return ("已调拨 %s ×%d"):format(game.itemLabel(context, action.item), result)
        end
        if result == false then
            automation = false
            deliveries[false].manual = true
            nextSnapshot.manualReview[action.item] = true
            blocked = "调拨待核验 · 补货已暂停"
            reviewChecked = false
            saveJournal()
            log(blocked)
            return blocked
        end
    end
    local previous = rejected[key]
    local attempts = previous and previous.attempts + 1 or 1
    rejected[key] = {
        attempts = attempts,
        expiry = os.time() + 30,
        diagnostic = {
            code = code or (action.kind == "transfer" and "transport" or "unknown"),
            message = reason,
            item = action.item,
            goal = action.goal,
            camp = action.destination or (action.station and action.station.camp),
            station = action.station and action.station.id,
            suitability = action.station and action.station.workSuitability,
        },
    }
    return reason
end

local function refresh(context, scheduled, inspect)
    local nextSnapshot = game.snapshot(context)
    nextSnapshot.at = os.time()
    if inspect or not snapshot or #nextSnapshot.camps ~= #snapshot.camps or nextSnapshot.chests ~= snapshot.chests
        or #nextSnapshot.stations ~= #snapshot.stations or nextSnapshot.incomplete ~= snapshot.incomplete then
        local recipeCount = 0
        for _ in pairs(nextSnapshot.recipes) do recipeCount = recipeCount + 1 end
        log(("Scan camps=%d chests=%d stations=%d recipes=%d incomplete=%s"):format(
            #nextSnapshot.camps, nextSnapshot.chests, #nextSnapshot.stations, recipeCount, tostring(nextSnapshot.incomplete == true)))
    end
    local awaitingSubmission = reconcileDeliveries(nextSnapshot)
    if automation and scheduled then
        if awaitingSubmission then
            lastTickMessage = "原版订单待确认 · 暂缓新请求"
        elseif not context.currentCamp then
            lastTickMessage = "等待进入生产据点"
        else
            local effectiveGoals, planOpts = planningInputs()
            local action, why = planner.next(nextSnapshot, effectiveGoals, activeRejections(), context.currentCamp, planOpts)
            if action then
                lastTickMessage = execute(context, nextSnapshot, action)
            else
                lastTickMessage = why.message
            end
        end
    end
    for _, station in ipairs(nextSnapshot.stations) do station.model = nil end
    for _, camp in ipairs(nextSnapshot.camps) do camp.containers = nil end
    snapshot = nextSnapshot
    cachedRows = nil
    if historyLoaded then
        local ok, reason = pcall(history.record, observations, nextSnapshot, goals)
        if not ok then historyLoaded = false; log(reason) end
    end
    if apiLoaded then
        extApi.emit("snapshot", {
            at = nextSnapshot.at, camps = #nextSnapshot.camps, chests = nextSnapshot.chests,
            stations = #nextSnapshot.stations, incomplete = nextSnapshot.incomplete == true,
        })
    end
end

local function applySettingValue(key, newValue)
    if not configLoaded then return end
    local previous = cfg[key]
    if previous == newValue then return end
    cfg[key] = newValue
    if saveConfig() then
        settingError = nil
        if key == "advisorEnabled" and not cfg.advisorEnabled then workforceSnapshot = nil end
    else
        cfg[key] = previous
        settingError = t("settings_save_error")
    end
end

local function toggleSetting(idx, direction)
    if not configLoaded then return end
    local key = dashboard.settingKeys[idx]
    local previous = cfg[key]
    if key == "mode" or key == "forecastMode" then
        local choices = key == "mode" and configMod.modes or configMod.forecastModes
        for index, option in ipairs(choices) do
            if option == previous then
                applySettingValue(key, choices[(index - 1 + direction) % #choices + 1])
                break
            end
        end
    elseif key == "language" then
        applySettingValue("language", i18nLoaded and i18n.nextLanguage(cfg.language) or "zh-CN")
    elseif key == "advisorEnabled" or key == "adaptiveEnabled" then
        applySettingValue(key, previous == false)
    elseif key == "spoilerHide" then
        applySettingValue(key, not previous)
    end
end

local function exportBlueprint(profile)
    if not bpLoaded then return end
    local bpPath = directory .. "../blueprint-" .. profile .. ".tsv"
    local ok, written, reason = pcall(blueprint.export, bpPath, goals, cfg, profile)
    local saved = ok and written
    blueprintNotice = saved and t("blueprint_saved") or t("blueprint_failed")
    log(blueprintNotice)
    if not saved then log(tostring(ok and reason or written)) end
    for index, key in ipairs(dashboard.settingKeys) do
        if key == "blueprint" then settingSelection = index; break end
    end
end

local function closePanel(context)
    if editing then panel.endEdit(context); editing = nil end
    targetDraft, targetError = nil, nil
    panel.close(context)
end

local function handle(action, step)
    if action == "click" then
        if not panel.isOpen() then return end
        local hit = panel.hitTest()
        if not hit then return end
        action, step = hit.action, hit
    end

    if (action == "toggle" or action == "close") and panel.isOpen() then
        closePanel(game.player())
        return
    end
    if action == "cancelEdit" and panel.isOpen() and not editing then
        if not panel.isTextFocused() then
            closePanel(game.player())
        end
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
        snapshot, snapshotProfile, workforceSnapshot, selected, settingSelection = nil, profile, nil, {}, 1
        goals, goalError = loadGoals(profile)
        changedLabels = {}
        query, displayedPlan, editing, inventoryAll = "", nil, nil, false
        targetDraft, targetError, reviewChecked = nil, nil, false
        section, viewPage, observations, lastDiagnostic = "overview", 1, {}, nil
        cachedRows, transfers, workforceOptState, blueprintNotice, settingError = nil, {}, {}, nil, nil
        automation, rejected, lastTickMessage = false, {}, nil
        journalPath = directory .. "../orders-" .. profile .. ".tsv"
        configPath = directory .. "../config-" .. profile .. ".tsv"
        if configLoaded then cfg = configMod.read(configPath) end
        if workforceLoaded then
            local extra = apiLoaded and extApi.extraConflicts() or {}
            detectedConflicts = workforce.detectConflicts(directory .. "../../", extra)
        end
        deliveries, journalError = journal.read(journalPath)
        deliveries = deliveries or {}
        blocked = journalError or goalError
    end

    -- Handle Enter key inside inline search / target EditableTextBox
    if action == "enter" then
        local focused = panel.focusedInput()
        if editing then
            action = "commit"
        elseif focused == "search" then
            action = "applySearch"
        elseif focused == "target" then
            action = "saveTarget"
        else
            return
        end
    end

    -- F4 confirms active text input or toggles automation
    if action == "confirm" then
        local focused = panel.focusedInput()
        if editing then
            action = "commit"
        elseif focused == "search" then
            action = "applySearch"
        elseif focused == "target" then
            action = "saveTarget"
        else
            action = "automation"
        end
    end

    -- While an inline text field has keyboard focus, ignore non-editing keyboard navigation shortcuts
    -- so arrow keys / Home / letters don't steal input from typing.
    if panel.isTextFocused() and (action == "view" or action == "home" or action == "select" or action == "page") then
        return
    end

    local selectedItem
    if action == "tab" and not editing then
        section, viewPage = step.section or "overview", 1
        targetDraft, targetError = nil, nil
        if section == "production" or section == "logistics" then reviewChecked = true end
    elseif action == "viewReview" and not editing then
        section, viewPage = (type(step) == "table" and step.section) or "production", 1
        reviewChecked = true
    elseif action == "jumpItem" and not editing then
        section, viewPage = "inventory", 1
        selectedItem = type(step) == "table" and step.item or nil
        if selectedItem and not goals[selectedItem] then inventoryAll = true end
        targetDraft, targetError = nil, nil
    elseif action == "home" and not editing then
        section, viewPage = "overview", 1
    elseif action == "view" and not editing then
        section, viewPage = dashboard.step(section, step or 1), 1
        targetDraft, targetError = nil, nil
        if section == "production" or section == "logistics" then reviewChecked = true end
    elseif action == "applySearch" and not editing and section == "inventory" then
        local text = panel.readSearchText() or ""
        query = text:match("^%s*(.-)%s*$"):lower()
        selected.inventory, targetDraft, targetError, cachedRows = nil, nil, nil, nil
    elseif action == "clearSearch" and not editing and section == "inventory" then
        query = ""
        selected.inventory, targetDraft, targetError, cachedRows = nil, nil, nil, nil
    elseif action == "inventoryScope" and not editing and section == "inventory" then
        if query ~= "" then
            query = ""
        else
            inventoryAll = not inventoryAll
        end
        selected.inventory, targetDraft, targetError, cachedRows = nil, nil, nil, nil
    elseif action == "page" and not editing then
        local dir = type(step) == "table" and (step.step or 1) or (step or 1)
        if section == "inventory" or section == "history" or section == "settings" then
            action, step = "select", dir * rowsPerPage
        else
            viewPage = math.max(1, viewPage + dir)
        end
    elseif action == "advisorStrategy" and not editing and section == "advisor" and advisorLoaded then
        cfg.advisorStrategy = advisor.nextStrategy(cfg.advisorStrategy)
        saveConfig()
    elseif action == "advisorAdvanced" and not editing and section == "advisor" then
        cfg.advisorAdvanced = not cfg.advisorAdvanced
        saveConfig()
    elseif action == "exportBlueprint" and not editing then
        exportBlueprint(profile)
    elseif action == "contextAction" and not editing and section == "settings" then
        exportBlueprint(profile)
    elseif action == "selectSetting" and not editing and section == "settings" then
        settingSelection = math.max(1, math.min(#dashboard.settingKeys, step.index or 1))
    elseif action == "toggleSetting" and not editing and section == "settings" then
        local idx = type(step) == "table" and step.index or settingSelection
        settingSelection = math.max(1, math.min(#dashboard.settingKeys, idx))
        toggleSetting(settingSelection, type(step) == "table" and (step.step or 1) or 1)
    elseif action == "setSettingValue" and not editing and section == "settings" and type(step) == "table" then
        applySettingValue(step.id, step.value)
    end

    if action == "automation" and not editing then
        automation = not automation and not blocked
        if automation then rejected = {} end
        lastTickMessage = automation and "等待下一次库存读取" or "补货已暂停"
        log(lastTickMessage)
    end
    if action == "acknowledge" and not editing and not automation and not journalError then
        local changed = false
        for key, record in pairs(deliveries) do
            if record.manual then deliveries[key], changed = nil, true end
        end
        if changed then
            reviewChecked = false
            saveJournal()
            log("Player acknowledged unresolved orders or transfers")
        end
    end

    if editing then
        if action ~= "commit" and action ~= "cancelEdit" then return end
        local completed = editing
        editing = nil
        local value = panel.endEdit(context)
        if action == "commit" and value then
            if completed.kind == "search" then
                query = value:match("^%s*(.-)%s*$"):lower()
                selected.inventory, cachedRows = nil, nil
            else
                local target = tonumber(value)
                if target and target >= 0 and target <= 1000000 and target == math.floor(target) then
                    setTarget(profile, completed.item, target)
                    selectedItem = completed.item
                else
                    local rows = displayRows(context, inventoryScope())
                    draw(context, rows, position(rows, completed.item))
                    editing = panel.beginEdit(context, value, t("target_invalid"), cfg.language) and completed or nil
                    return
                end
            end
        end
    end

    if not snapshot or action == "toggle" or action == "inspect" or action == "refresh" or action == "acknowledge" then
        refresh(context, action == "refresh", action == "inspect")
    end
    if action == "inspect" then return end
    if not panel.isOpen() and action ~= "toggle" then return end
    if action == "refresh" and panel.isTextFocused() then return end

    -- Explicit opt-in live workforce scan (never automatic!)
    if (action == "liveWorkforceScan" or (action == "contextAction" and section == "advisor"))
        and section == "advisor" and cfg.advisorEnabled ~= false then
        scanWorkforceOnDemand(context)
    end

    local scope = section == "inventory" and inventoryScope() or (section == "history" and "goals" or nil)
    local rows = scope and displayRows(context, scope) or {}
    local selection = position(rows, selectedItem or selected[section])

    if action == "search" then
        section, viewPage = "inventory", 1
        rows = displayRows(context, inventoryScope())
        selection = position(rows, selected.inventory)
        draw(context, rows, selection)
        panel.focusSearch(context)
        return
    end
    if action == "target" and section == "inventory" and rows[selection] then
        if not panel.focusTarget(context) then
            local item = rows[selection].id
            if panel.beginEdit(context, tostring(goals[item] or ""), t("target_prompt"), cfg.language) then
                editing = { kind = "target", item = item }
            end
        end
        return
    end
    if action == "selectRow" and section == "inventory" and type(step) == "table" then
        selection = math.max(1, math.min(#rows, step.index or 1))
        targetDraft, targetError = nil, nil
    end
    if action == "saveTarget" and section == "inventory" and rows[selection] then
        local row = rows[selection]
        local raw = (panel.readTargetText() or ""):match("^%s*(.-)%s*$")
        local target = raw == "" and 0 or tonumber(raw)
        if target and target >= 0 and target <= 1000000 and target == math.floor(target) then
            setTarget(profile, row.id, target)
            targetDraft, targetError = nil, nil
            rows = displayRows(context, inventoryScope())
            selection = position(rows, row.id)
        else
            targetDraft, targetError = raw, t("target_invalid")
        end
    end
    if action == "clearTarget" and section == "inventory" and rows[selection] then
        local row = rows[selection]
        setTarget(profile, row.id, 0)
        targetDraft, targetError = nil, nil
        rows = displayRows(context, inventoryScope())
        selection = position(rows, row.id)
    end
    if action == "stepTarget" and section == "inventory" and rows[selection] then
        local row = rows[selection]
        local delta = type(step) == "table" and (step.step or 0) or (step or 0)
        local current = tonumber((panel.readTargetText() or ""):match("^%s*(.-)%s*$")) or goals[row.id] or 0
        local target = math.max(0, math.min(1000000, math.floor(current) + delta))
        setTarget(profile, row.id, target)
        targetDraft, targetError = nil, nil
        rows = displayRows(context, inventoryScope())
        selection = position(rows, row.id)
    end
    if action == "select" then
        local delta = type(step) == "table" and (step.step or 1) or (step or 1)
        if section == "inventory" or section == "history" then
            selection = math.max(1, math.min(#rows, selection + delta))
            targetDraft, targetError = nil, nil
        elseif section == "settings" then
            settingSelection = math.max(1, math.min(#dashboard.settingKeys, settingSelection + delta))
        end
    end
    if action == "edit" then
        if section == "inventory" and rows[selection] then
            local row = rows[selection]
            local target = math.max(0, math.min(1000000, (goals[row.id] or 0) + step))
            setTarget(profile, row.id, target)
            targetDraft, targetError = nil, nil
            rows = displayRows(context, inventoryScope())
            selection = position(rows, row.id)
        elseif section == "settings" then
            toggleSetting(settingSelection, step < 0 and -1 or 1)
        end
    end

    if rows[selection] then selected[section] = rows[selection].id end
    local effectiveGoals, planOpts = planningInputs()
    local plan, why = planner.next(snapshot, effectiveGoals, activeRejections(), context.currentCamp, planOpts)
    if not context.currentCamp and plan then
        why = {
            code = "access",
            message = "等待进入生产据点",
            item = plan.item,
            camp = plan.destination or plan.station.camp,
            goal = plan.goal,
        }
    end
    if blocked then
        lastDiagnostic = { code = "recovery", message = blocked }
    else
        lastDiagnostic = why
    end
    if apiLoaded then
        extApi.emit("plan", { action = plan and plan.kind or "none", diagnostic = lastDiagnostic })
    end
    updatePlan(context, plan, why)
    if lastTickMessage and (automation or action == "automation" or action == "refresh") then
        displayedPlan = lastTickMessage
    end
    draw(context, rows, selection, plan)
    if action == "selectRow" and section == "inventory" and rows[selection] then
        panel.focusTarget(context)
    end
end

local function schedule(action, step)
    if action == "refresh" then
        if refreshing then return end
        refreshing = true
    end
    ExecuteInGameThread(function()
        local ok, reason = xpcall(function() handle(action, step) end, debug.traceback)
        if action == "refresh" then refreshing = false end
        if not ok then
            if automation then
                automation = false
                lastTickMessage = "出现接口错误，补货已暂停"
            end
            log(reason)
        end
    end)
end

if apiLoaded then
    extApi.bindProviders({
        getStatus = function()
            return {
                version = "0.4.0-rc.2",
                automation = automation,
                blocked = blocked,
                mode = cfg.mode,
                forecastMode = cfg.forecastMode,
                conflicts = detectedConflicts,
            }
        end,
        getMetrics = function(item)
            return historyLoaded and history.metrics(observations, item) or nil
        end,
        simulate = function(scenario)
            return simLoaded and simulator.simulate(snapshot, workforceSnapshot, lastDiagnostic, scenario) or nil
        end,
    })
    extApi.installGlobal()
end

-- Real mouse click & Enter bindings (active only when panel is open)
if Key.LEFT_MOUSE_BUTTON then
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
        if panel.isOpen() then schedule("click") end
    end)
end
if Key.RETURN then
    RegisterKeyBind(Key.RETURN, function()
        if panel.isOpen() then schedule("enter") end
    end)
end

-- Retained keyboard shortcuts for power users
RegisterKeyBind(Key.F10, { ModifierKey.CONTROL }, function() schedule("toggle") end)
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL }, function() schedule("view", 1) end)
RegisterKeyBind(Key.F9, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() schedule("view", -1) end)
RegisterKeyBind(Key.LEFT_ARROW, function() schedule("view", -1) end)
RegisterKeyBind(Key.RIGHT_ARROW, function() schedule("view", 1) end)
RegisterKeyBind(Key.HOME, function() schedule("home") end)
RegisterKeyBind(Key.HOME, { ModifierKey.CONTROL }, function() schedule("inventoryScope") end)
RegisterKeyBind(Key.UP_ARROW, function() schedule("select", -1) end)
RegisterKeyBind(Key.DOWN_ARROW, function() schedule("select", 1) end)
RegisterKeyBind(Key.PAGE_UP, function() schedule("page", -1) end)
RegisterKeyBind(Key.PAGE_DOWN, function() schedule("page", 1) end)
RegisterKeyBind(Key.F, { ModifierKey.CONTROL }, function() schedule("search") end)
RegisterKeyBind(Key.G, { ModifierKey.CONTROL }, function() schedule("target") end)
RegisterKeyBind(Key.E, { ModifierKey.CONTROL }, function() schedule("advisorStrategy") end)
RegisterKeyBind(Key.D, { ModifierKey.CONTROL }, function() schedule("advisorAdvanced") end)
RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, function() schedule("contextAction") end)
RegisterKeyBind(Key.F4, function() schedule("confirm") end)
RegisterKeyBind(Key.R, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() schedule("acknowledge") end)
RegisterKeyBind(Key.ESCAPE, function() schedule("cancelEdit") end)
RegisterKeyBind(Key.LEFT_ARROW, { ModifierKey.CONTROL }, function() schedule("edit", -10) end)
RegisterKeyBind(Key.RIGHT_ARROW, { ModifierKey.CONTROL }, function() schedule("edit", 10) end)
RegisterKeyBind(Key.LEFT_ARROW, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() schedule("edit", -100) end)
RegisterKeyBind(Key.RIGHT_ARROW, { ModifierKey.CONTROL, ModifierKey.SHIFT }, function() schedule("edit", 100) end)
RegisterLoadMapPreHook(function()
    local ok, reason = pcall(panel.close)
    if not ok then log(reason) end
    snapshot, snapshotProfile, workforceSnapshot, editing = nil, nil, nil, nil
    targetDraft, targetError, reviewChecked = nil, nil, false
    automation, rejected, deliveries, lastTickMessage, blocked = false, {}, {}, nil, nil
    cachedRows, transfers, workforceOptState = nil, {}, {}
end)
LoopAsync(8000, function()
    if automation or (panel.isOpen() and not editing and not panel.isTextFocused()) then schedule("refresh") end
    return false
end)
log("Loaded v0.4.0-rc.2")
