local game = require("industrial_game")
local M = {}

local rootPath
local oldCursor
local inputCaptured = false
local hitTargets = {}
local searchBoxPath, targetBoxPath
local editPath, editPanelPath

local width, height = 980, 620
local bodyX, bodyWidth = 204, 750

local function color(r, g, b, alpha)
    return { R = r / 255, G = g / 255, B = b / 255, A = alpha or 1 }
end

local palette = {
    background = color(17, 21, 32, 0.99),
    surface = color(26, 31, 45),
    card = color(34, 41, 60),
    tabActive = color(46, 58, 86),
    button = color(44, 54, 78),
    buttonPrimary = color(64, 108, 178),
    buttonGood = color(44, 128, 98),
    buttonWarn = color(152, 92, 54),
    buttonDanger = color(112, 52, 58),
    line = color(58, 68, 87),
    accent = color(179, 200, 255),
    barFill = color(96, 120, 185),
    text = color(243, 246, 251),
    muted = color(179, 189, 211),
    good = color(135, 224, 188),
    warning = color(255, 205, 136),
    warnBg = color(52, 41, 42),
}

local function construct(class, outer)
    local object = StaticConstructObject(StaticFindObject("/Script/UMG." .. class), outer)
    if not game.valid(object) then error("无法创建界面组件 " .. class) end
    return object
end

local function fullPath(object)
    local name = object and object.GetFullName and object:GetFullName()
    return name and name:match("%s(.+)$") or nil
end

local function place(canvas, widget, x, y, w, h)
    local slot = canvas:AddChildToCanvas(widget)
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
    slot:SetPosition({ X = x - width / 2, Y = y - height / 2 })
    slot:SetSize({ X = w, Y = h })
    return slot
end

local function block(tree, canvas, x, y, w, h, fill, visibility)
    local widget = construct("Border", tree)
    widget:SetBrushColor(fill)
    widget:SetVisibility(visibility or 3) -- 3=HitTestInvisible, 0=Visible
    place(canvas, widget, x, y, w, h)
    return widget
end

local function label(tree, canvas, x, y, w, h, value, size, fill, wrap)
    local widget = construct("TextBlock", tree)
    local font = widget.Font
    font.Size = size
    widget:SetFont(font)
    widget:SetColorAndOpacity({ SpecifiedColor = fill, ColorUseRule = 0 })
    widget:SetText(FText(value))
    widget:SetVisibility(3) -- HitTestInvisible so clicks pass through to underlying UButton
    pcall(function()
        if widget.SetClipping then widget:SetClipping(1) end -- EWidgetClipping::ClipToBounds
    end)
    if wrap then
        pcall(function()
            if widget.SetAutoWrapText then widget:SetAutoWrapText(true) end
        end)
    else
        pcall(function()
            if widget.SetTextOverflowPolicy then widget:SetTextOverflowPolicy(1) end -- Ellipsis
        end)
    end
    place(canvas, widget, x, y, w, h)
    return widget
end

local function button(tree, canvas, x, y, w, h, fill, action, textValue, textSize, textFill)
    local widget = construct("Button", tree)
    pcall(function()
        if widget.SetBackgroundColor then widget:SetBackgroundColor(fill) end
        if widget.SetColorAndOpacity then widget:SetColorAndOpacity(color(255, 255, 255, 1)) end
    end)
    widget:SetVisibility(0) -- ESlateVisibility::Visible (real interactive UMG button)
    place(canvas, widget, x, y, w, h)
    local path = fullPath(widget)
    if path and action then
        hitTargets[#hitTargets + 1] = { path = path, action = action }
    end
    if textValue and textValue ~= "" then
        local sz = textSize or 14
        local ty = y + math.max(2, math.floor((h - (sz + 8)) / 2))
        label(tree, canvas, x + 8, ty, math.max(12, w - 16), math.max(20, h - 4), tostring(textValue), sz, textFill or palette.text)
    end
    return widget
end

local function textBox(tree, canvas, x, y, w, h, initial, hint)
    local box = construct("EditableTextBox", tree)
    box:SetText(FText(initial or ""))
    box:SetIsReadOnly(false)
    pcall(function()
        if box.SetHintText and hint then box:SetHintText(FText(hint)) end
    end)
    box:SetForegroundColor(palette.background)
    box.SelectAllTextWhenFocused = true
    box:SetVisibility(0)
    place(canvas, box, x, y, w, h)
    return box, fullPath(box)
end

local function estimateWrappedLines(value, size, maxWidth)
    local text = tostring(value or "")
    if text == "" or maxWidth <= 0 then return 1 end
    local pxPerPt = 1.35
    local widthPx = 0
    for _, code in utf8.codes(text) do
        widthPx = widthPx + (code > 127 and (size * pxPerPt) or (size * pxPerPt * 0.56))
    end
    return math.max(1, math.ceil(widthPx / maxWidth))
end

local function captureInput(context, focusWidget)
    if not context or not game.valid(context.pc) then return end
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if not inputCaptured then
        oldCursor = context.pc.bShowMouseCursor
        inputCaptured = true
    end
    context.pc.bShowMouseCursor = true
    if game.valid(lib) and lib.SetInputMode_UIOnlyEx then
        pcall(function() lib:SetInputMode_UIOnlyEx(context.pc, focusWidget, 0, true) end)
    end
end

local function releaseInput(context)
    if not inputCaptured then return end
    inputCaptured = false
    local pc = context and context.pc
    if not game.valid(pc) then
        local fallback = game.player()
        pc = fallback and fallback.pc
    end
    if game.valid(pc) then
        pc.bShowMouseCursor = oldCursor == true
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        if game.valid(lib) and lib.SetInputMode_GameOnly then
            pcall(function() lib:SetInputMode_GameOnly(pc, false) end)
        end
    end
    oldCursor = nil
end

local function readBoxText(path)
    if not path then return nil end
    local box = StaticFindObject(path)
    if game.valid(box) then
        local ok, text = pcall(function() return box:GetText():ToString() end)
        if ok then return text end
    end
    return nil
end

local function isWidgetFocused(path)
    if not path then return false end
    local widget = StaticFindObject(path)
    if not game.valid(widget) then return false end
    local ok, focused = pcall(function()
        if widget.HasKeyboardFocus then return widget:HasKeyboardFocus() == true end
        return false
    end)
    return ok and focused == true
end

local function isWidgetHovered(path)
    if not path then return false end
    local widget = StaticFindObject(path)
    if not game.valid(widget) then return false end
    local ok, hovered = pcall(function()
        if widget.IsHovered then return widget:IsHovered() == true end
        return false
    end)
    return ok and hovered == true
end

function M.readSearchText()
    return readBoxText(searchBoxPath)
end

function M.readTargetText()
    return readBoxText(targetBoxPath)
end

function M.focusedInput()
    if editPath and isWidgetFocused(editPath) then return "modal" end
    if searchBoxPath and isWidgetFocused(searchBoxPath) then return "search" end
    if targetBoxPath and isWidgetFocused(targetBoxPath) then return "target" end
    return nil
end

function M.isTextFocused()
    return M.focusedInput() ~= nil
end

function M.focusSearch(context)
    local box = searchBoxPath and StaticFindObject(searchBoxPath)
    if game.valid(box) then
        captureInput(context, box)
        pcall(function() box:SetKeyboardFocus() end)
        return true
    end
    return false
end

function M.focusTarget(context)
    local box = targetBoxPath and StaticFindObject(targetBoxPath)
    if game.valid(box) then
        captureInput(context, box)
        pcall(function() box:SetKeyboardFocus() end)
        return true
    end
    return false
end

-- Resolves which real UMG UButton was clicked (reverse Z-order so top-most controls win).
-- Returns nil when clicking an EditableTextBox so Slate focuses the text field cleanly.
function M.hitTest()
    if editPath and isWidgetHovered(editPath) then return nil end
    if searchBoxPath and isWidgetHovered(searchBoxPath) then return nil end
    if targetBoxPath and isWidgetHovered(targetBoxPath) then return nil end
    for i = #hitTargets, 1, -1 do
        local entry = hitTargets[i]
        local widget = StaticFindObject(entry.path)
        if game.valid(widget) then
            local ok, hit = pcall(function()
                local pressed = widget.IsPressed and widget:IsPressed() == true
                local hovered = widget.IsHovered and widget:IsHovered() == true
                return pressed or hovered
            end)
            if ok and hit then return entry.action end
        end
    end
    return nil
end

function M.beginEdit(context, initial, hint, lang)
    local root = rootPath and StaticFindObject(rootPath)
    if not game.valid(root) then return false end
    local tree = root.WidgetTree
    local overlay = construct("CanvasPanel", tree)
    overlay:SetVisibility(0)
    place(tree.RootWidget, overlay, 0, 0, width, height):SetZOrder(1)
    block(tree, overlay, 240, 225, 500, 165, palette.background, 0)
    block(tree, overlay, 240, 225, 500, 3, palette.accent)
    label(tree, overlay, 260, 242, 460, 30, hint, 18, palette.text)
    local box, boxPath = textBox(tree, overlay, 260, 282, 460, 40, initial, hint)
    button(tree, overlay, 260, 336, 130, 36, palette.buttonPrimary, { action = "commit" },
        lang == "en-US" and "Save" or "确认保存", 14)
    button(tree, overlay, 402, 336, 110, 36, palette.button, { action = "cancelEdit" },
        lang == "en-US" and "Cancel" or "取消", 14)
    editPath = assert(boxPath)
    editPanelPath = assert(fullPath(overlay))
    captureInput(context, box)
    pcall(function() box:SetKeyboardFocus() end)
    return true
end

function M.endEdit(context)
    if not editPath then return nil end
    local value = readBoxText(editPath)
    local overlay = editPanelPath and StaticFindObject(editPanelPath)
    if game.valid(overlay) then overlay:RemoveFromParent() end
    editPath, editPanelPath = nil, nil
    if rootPath then
        local root = StaticFindObject(rootPath)
        captureInput(context, game.valid(root) and root or nil)
    else
        releaseInput(context)
    end
    return value
end

function M.close(context)
    hitTargets = {}
    searchBoxPath, targetBoxPath = nil, nil
    editPath, editPanelPath = nil, nil
    if rootPath then
        local current = StaticFindObject(rootPath)
        rootPath = nil
        if game.valid(current) then current:RemoveFromParent() end
    end
    releaseInput(context)
end

function M.isOpen()
    return rootPath ~= nil
end

local function fallbackMode(view, en)
    if view.blocked then return en and "Needs review" or "需人工核验" end
    if view.automation then return en and "Restock active" or "补货运行中" end
    return en and "Restock paused" or "补货已暂停"
end

local function drawHome(ui, data, en)
    local left, right, top = bodyX, 617, 152
    ui.box(left, top, 397, 264, data.warning and palette.warnBg or palette.card)
    ui.box(left, top, 4, 264, data.warning and palette.warning or palette.accent)
    ui.wrap(left + 22, top + 20, 353, 72, data.headline or "", 24, data.warning and palette.warning or palette.text)
    ui.wrap(left + 22, top + 98, 353, 66, data.detail or "", 15, palette.muted)

    if data.blocked then
        ui.button(left + 22, top + 186, 158, 42, palette.buttonWarn,
            { action = "viewReview", section = data.reviewSection or "production" },
            en and "View orders" or "查看订单", 15)
        if data.canAcknowledge and data.reviewChecked then
            ui.button(left + 194, top + 186, 172, 42, palette.buttonGood,
                { action = "acknowledge" },
                en and "Confirm takeover" or "确认接管", 15)
        elseif data.canAcknowledge then
            ui.text(left + 22, top + 234, 353, 22,
                en and "Inspect the order first, then confirm takeover." or "请先点「查看订单」核对，核对后可确认接管。",
                13, palette.muted)
        end
    else
        local restockLabel = data.automation and (en and "Pause restock" or "暂停补货") or (en and "Start restock" or "启动补货")
        local restockFill = data.automation and palette.buttonWarn or palette.buttonGood
        if (data.targetCount or 0) == 0 then
            ui.button(left + 22, top + 186, 168, 42, palette.buttonPrimary,
                { action = "tab", section = "inventory" },
                en and "Set stock target" or "去设库存目标", 15)
            ui.button(left + 202, top + 186, 166, 42, restockFill,
                { action = "automation" }, restockLabel, 15)
        else
            ui.button(left + 22, top + 186, 210, 42, restockFill,
                { action = "automation" }, restockLabel, 16)
        end
    end

    ui.box(right, top, 337, 264, palette.surface)
    ui.text(right + 18, top + 16, 290, 26, en and "Below target" or "未达目标", 17)
    local shortages = data.shortages or {}
    if #shortages == 0 then
        local message = data.unread and (en and "Waiting for stock readings" or "等待库存同步")
            or (data.targetCount == 0 and (en and "No targets set yet" or "还没有库存目标")
                or (en and "All targets met" or "没有缺口"))
        ui.text(right + 18, top + 62, 301, 28, message, 15, palette.muted)
    end
    for index, row in ipairs(shortages) do
        local y = top + 48 + (index - 1) * 46
        local tone = row.review and palette.warning or palette.accent
        ui.button(right + 12, y, 313, 40, palette.card, { action = "jumpItem", item = row.item })
        ui.text(right + 20, y + 5, 186, 24, row.label, 14)
        local quantity = row.review and (en and "Review" or "待核验") or ("%d / %d"):format(row.stock, row.target)
        ui.text(right + 212, y + 5, 105, 24, quantity, 14, tone)
        ui.box(right + 20, y + 32, 295, 3, palette.line)
        local filled = math.floor(295 * math.max(0, math.min(1, row.stock / row.target)))
        if filled > 0 then ui.box(right + 20, y + 32, filled, 3, tone) end
    end
    if data.shortageCount and data.shortageCount > #shortages then
        ui.button(right + 18, top + 234, 200, 24, palette.surface,
            { action = "tab", section = "inventory" },
            (en and "+%d more in Inventory" or "另有 %d 项，去库存查看"):format(data.shortageCount - #shortages),
            12, palette.accent)
    end

    ui.box(left, 434, bodyWidth, 84, palette.surface)
    ui.text(left + 18, 448, 714, 26, data.currentCamp or (en and "Outside a guild base" or "角色当前不在据点内"), 15)
    if data.campCount then
        local coverage = (en and "%d bases    %d chests    %d stations" or "%d 个据点    %d 个仓库    %d 台设备"):format(
            data.campCount, data.chestCount or 0, data.stationCount or 0)
        ui.text(left + 18, 478, 714, 24, coverage, 13, palette.muted)
    end
end

local function drawInventory(ui, data, en)
    local x, infoX = bodyX, 680
    -- Inline search box + Search / Clear / Scope toggle
    local _, sPath = ui.textBox(x, 130, 254, 34, data.query or "", en and "Search item name or ID" or "搜索物品名或 ID")
    searchBoxPath = sPath
    ui.button(x + 260, 130, 68, 34, palette.buttonPrimary, { action = "applySearch" }, en and "Search" or "搜索", 14)
    if (data.query or "") ~= "" then
        ui.button(x + 334, 130, 64, 34, palette.button, { action = "clearSearch" }, en and "Clear" or "清除", 14)
    end
    local scopeLabel = data.scope == "all" and (en and "Showing: All" or "显示：全部物品")
        or (data.scope == "search" and (en and "Show all" or "显示全部") or (en and "Showing: Targets" or "显示：已设目标"))
    ui.button(infoX, 130, 152, 34, palette.button, { action = "inventoryScope" }, scopeLabel, 13)
    if data.incomplete then
        ui.text(infoX + 160, 135, 114, 24, en and "Syncing..." or "正在同步", 13, palette.warning)
    end

    -- Left item list (clickable rows)
    ui.box(x, 174, 460, 354, palette.surface)
    ui.text(x + 14, 182, 224, 24, en and "Item" or "物品", 13, palette.muted)
    ui.text(x + 250, 182, 84, 24, en and "In stock" or "库存", 13, palette.muted)
    ui.text(x + 346, 182, 98, 24, en and "Target" or "目标", 13, palette.muted)
    ui.box(x + 12, 210, 436, 1, palette.line)

    local rows = data.rows or {}
    local first, last = data.first or 1, data.last or math.min(6, #rows)
    for index = first, last do
        local row = rows[index]
        local y = 218 + (index - first) * 50
        local focused = index == data.selection
        ui.button(x + 6, y, 448, 44, focused and palette.tabActive or palette.surface,
            { action = "selectRow", index = index })
        if focused then
            ui.box(x + 6, y, 3, 44, palette.accent)
        else
            ui.box(x + 12, y + 44, 436, 1, palette.line)
        end
        ui.text(x + 14, y + 9, 224, 26, row.label, 15, focused and palette.accent or palette.text)
        local needsAttention = row.inTransit == "?" or (row.target and row.stock < row.target)
        ui.text(x + 250, y + 9, 84, 26, data.incomplete and "—" or row.stock, 15, needsAttention and palette.warning or palette.text)
        ui.text(x + 346, y + 9, 98, 26, row.target or "—", 15, palette.muted)
    end
    if #rows == 0 then
        local empty = data.scope == "goals"
            and (en and "Search an item above or click 'Showing: Targets' to browse all items."
                or "在上方搜索物品，或点右侧「显示：已设目标」切换全部物品。")
            or (en and "No matching items." or "没有找到符合条件的物品。")
        ui.wrap(x + 16, 232, 428, 72, empty, 15, palette.muted)
    end

    -- Right direct target editor card
    local row = rows[data.selection]
    if not row then return end
    ui.box(infoX, 174, 274, 354, palette.card)
    ui.wrap(infoX + 16, 188, 242, 54, row.label, 19)
    local description, tone
    if data.incomplete then
        description, tone = en and "Waiting for inventory sync" or "等待库存同步", palette.muted
    elseif row.inTransit == "?" then
        description, tone = en and "Order needs review" or "此物品的订单待核验", palette.warning
    elseif not row.target then
        description, tone = en and "No stock target" or "尚未设置库存目标", palette.muted
    elseif row.stock < row.target then
        description, tone = (en and "%d short of target" or "距离目标还差 %d"):format(row.target - row.stock), palette.warning
    else
        description, tone = en and "Stock target met" or "库存已达目标", palette.good
    end
    ui.text(infoX + 16, 246, 242, 26, description, 15, tone)
    ui.box(infoX + 16, 278, 242, 1, palette.line)
    if not data.incomplete then
        local facts = {
            { en and "Queued" or "待生产", row.queued },
            { en and "Ready for pickup" or "待搬运", row.buffered },
            { en and "Awaiting confirmation" or "待确认入库", row.inTransit },
        }
        local fy = 286
        for _, fact in ipairs(facts) do
            if fact[2] ~= nil and tostring(fact[2]) ~= "0" then
                ui.text(infoX + 16, fy, 178, 22, fact[1], 13, palette.muted)
                ui.text(infoX + 202, fy, 56, 22, fact[2], 13)
                fy = fy + 24
            end
        end
    end

    ui.box(infoX + 16, 364, 242, 1, palette.line)
    ui.text(infoX + 16, 372, 242, 22, en and "Stock target" or "目标数量", 13, palette.muted)
    local initialTarget = data.targetDraft or (row.target and tostring(row.target) or "")
    local _, tPath = ui.textBox(infoX + 16, 398, 138, 34, initialTarget, en and "0 to clear" or "0 清除")
    targetBoxPath = tPath
    ui.button(infoX + 160, 398, 46, 34, palette.button, { action = "stepTarget", step = -10 }, "-10", 13)
    ui.button(infoX + 212, 398, 46, 34, palette.button, { action = "stepTarget", step = 10 }, "+10", 13)
    ui.button(infoX + 16, 442, 134, 34, palette.buttonPrimary, { action = "saveTarget" }, en and "Save target" or "保存目标", 14)
    ui.button(infoX + 156, 442, 102, 34, palette.button, { action = "clearTarget" }, en and "Clear" or "清除目标", 13)
    if data.targetError then
        ui.wrap(infoX + 16, 484, 242, 34, data.targetError, 13, palette.warning)
    end
end

local function drawOrders(ui, data, en)
    local topY = 144
    if data.canTakeover then
        ui.box(bodyX, 132, bodyWidth, 44, palette.warnBg)
        ui.text(bodyX + 14, 142, 566, 24, data.reviewPrompt or "", 14, palette.warning)
        ui.button(bodyX + 592, 137, 146, 34, palette.buttonGood, { action = "acknowledge" },
            en and "Confirm takeover" or "确认接管", 14)
        topY = 186
    end
    local rows = data.rows or {}
    local first = data.first or 1
    local maxVisible = data.canTakeover and 5 or 6
    local last = math.min(data.last or math.min(maxVisible, #rows), first + maxVisible - 1)
    for index = first, last do
        local row = rows[index]
        local cells = row.cells
        local y = topY + (index - first) * 62
        local tone = row.warning and palette.warning or palette.accent
        ui.box(bodyX, y, bodyWidth, 56, row.warning and palette.warnBg or palette.surface)
        ui.box(bodyX, y, 3, 56, tone)
        ui.text(bodyX + 17, y + 4, 301, 26, cells[1], 16)
        ui.text(bodyX + 327, y + 6, 190, 22, cells[2] .. " / " .. cells[3], 13, palette.muted)
        ui.text(bodyX + 528, y + 6, 204, 22, (en and "Queued %s · Ready %s" or "排队 %s   待搬 %s"):format(cells[4], cells[5]), 14)
        ui.text(bodyX + 17, y + 31, 710, 22, cells[6], 13, row.warning and tone or palette.muted)
    end
    if #rows == 0 then ui.text(bodyX, topY + 12, bodyWidth, 30, data.empty, 16, palette.muted) end
end

local function drawTransfers(ui, data, en)
    local topY = 144
    if data.canTakeover then
        ui.box(bodyX, 132, bodyWidth, 44, palette.warnBg)
        ui.text(bodyX + 14, 142, 566, 24, data.reviewPrompt or "", 14, palette.warning)
        ui.button(bodyX + 592, 137, 146, 34, palette.buttonGood, { action = "acknowledge" },
            en and "Confirm takeover" or "确认接管", 14)
        topY = 186
    end
    local rows = data.rows or {}
    local first = data.first or 1
    local maxVisible = data.canTakeover and 5 or 6
    local last = math.min(data.last or math.min(maxVisible, #rows), first + maxVisible - 1)
    for index = first, last do
        local row = rows[index]
        local cells = row.cells
        local y = topY + (index - first) * 62
        ui.box(bodyX, y, bodyWidth, 56, row.warning and palette.warnBg or palette.surface)
        ui.text(bodyX + 15, y + 5, 344, 25, ("%s × %s"):format(cells[1], cells[4]), 16)
        ui.text(bodyX + 557, y + 5, 176, 24, cells[5], 14, row.warning and palette.warning or palette.good)
        ui.text(bodyX + 15, y + 31, 235, 22, cells[2], 14, palette.muted)
        ui.text(bodyX + 265, y + 31, 30, 22, "→", 14, palette.accent)
        ui.text(bodyX + 309, y + 31, 235, 22, cells[3], 14, palette.muted)
    end
    if #rows == 0 then
        ui.wrap(bodyX, topY + 12, bodyWidth, 62, data.empty or (en and "No transfers." or "暂无调拨。"), 16, palette.muted)
    end
end

local function drawSettings(ui, data, en)
    local rows = data.rows or {}
    local first = data.first or 1
    local last = data.last or #rows
    local stepY = (#rows > 6) and 47 or 62
    local rowH = (#rows > 6) and 42 or 52
    local ctrlH = (#rows > 6) and 32 or 38
    local ctrlOff = math.floor((rowH - ctrlH) / 2)
    local lblOff = math.floor((rowH - 24) / 2)
    for index = first, last do
        local row = rows[index]
        local y = 148 + (index - first) * stepY
        local active = index == data.selection
        ui.button(bodyX, y, 296, rowH, active and palette.tabActive or palette.surface,
            { action = "selectSetting", index = index })
        if active then ui.box(bodyX, y, 3, rowH, palette.accent) end
        ui.text(bodyX + 14, y + lblOff, 272, 24, row.label, 14, active and palette.text or palette.muted)

        local ctrlX, ctrlW = bodyX + 302, 150
        if row.kind == "toggle" then
            ui.button(ctrlX, y + ctrlOff, ctrlW, ctrlH, row.checked and palette.buttonGood or palette.button,
                { action = "toggleSetting", index = index, step = 1 }, row.value, 13)
        elseif row.kind == "choice" then
            ui.button(ctrlX, y + ctrlOff, ctrlW, ctrlH, palette.button,
                { action = "toggleSetting", index = index, step = 1 }, row.value .. " ▸", 13)
        elseif row.kind == "action" then
            ui.button(ctrlX, y + ctrlOff, ctrlW, ctrlH, palette.buttonPrimary,
                { action = "exportBlueprint" }, row.value, 13)
        else
            ui.box(ctrlX, y + ctrlOff, ctrlW, ctrlH, palette.surface)
            ui.text(ctrlX + 10, y + ctrlOff + 5, ctrlW - 20, 22, row.value, 12, palette.muted)
        end
    end

    local row = rows[data.selection]
    if not row then return end
    local x = 671
    ui.box(x, 148, 283, 366, palette.card)
    ui.wrap(x + 18, 166, 247, 50, row.label, 19)
    ui.wrap(x + 18, 222, 247, 86, row.description or "", 14, palette.muted)
    if row.kind == "choice" and row.options then
        for i, opt in ipairs(row.options) do
            local oy = 318 + (i - 1) * 44
            local isCur = opt.id == row.current
            ui.button(x + 18, oy, 247, 36, isCur and palette.buttonPrimary or palette.button,
                { action = "setSettingValue", id = row.id, value = opt.id },
                (isCur and "● " or "○ ") .. opt.label, 14)
        end
    elseif row.kind == "toggle" then
        ui.button(x + 18, 330, 247, 42, row.checked and palette.buttonGood or palette.button,
            { action = "toggleSetting", index = data.selection, step = 1 },
            (row.checked and (en and "Status: ON (click to turn off)" or "当前：已开启（点击关闭）")
                or (en and "Status: OFF (click to turn on)" or "当前：已关闭（点击开启）")), 14)
    elseif row.kind == "action" then
        ui.button(x + 18, 330, 247, 42, palette.buttonPrimary,
            { action = "exportBlueprint" }, en and "Export blueprint" or "导出蓝图", 15)
    end
    if data.notice then
        ui.wrap(x + 18, 464, 247, 40, data.notice, 13, palette.warning)
    end
end

local function drawTrend(ui, series, y, en)
    if not series or #series < 2 then return end
    local x, w = bodyX, bodyWidth
    ui.box(x, y, w, 158, palette.surface)
    local minV, maxV = series[1].count, series[1].count
    for _, sample in ipairs(series) do
        minV, maxV = math.min(minV, sample.count), math.max(maxV, sample.count)
    end
    ui.box(x + 16, y + 118, w - 32, 1, palette.line)
    local slot = math.floor((w - 40) / #series)
    for index, sample in ipairs(series) do
        local ratio = minV == maxV and 0.5 or (sample.count - minV) / (maxV - minV)
        local bar = math.floor(8 + ratio * 81)
        ui.box(x + 20 + (index - 1) * slot, y + 118 - bar, math.max(3, slot - 5), bar,
            index == #series and palette.accent or palette.barFill)
    end
    ui.text(x + 17, y + 126, 325, 24, (en and "First  %d" or "最初  %d"):format(series[1].count), 13, palette.muted)
    ui.text(x + w - 171, y + 126, 155, 24, (en and "Latest  %d" or "最近  %d"):format(series[#series].count), 13, palette.accent)
end

local function drawHistory(ui, data, en)
    if data.item then
        ui.text(bodyX, 144, 410, 32, data.item.label, 19)
        ui.text(bodyX + 418, 148, 180, 26, (en and "In stock  %d" or "当前库存  %d"):format(data.item.stock), 15, palette.accent)
        if (data.itemCount or 0) > 1 then
            ui.button(bodyX + 606, 144, 68, 32, palette.button, { action = "select", step = -1 }, en and "Prev" or "上一个", 13)
            ui.button(bodyX + 682, 144, 68, 32, palette.button, { action = "select", step = 1 }, en and "Next" or "下一个", 13)
        end
    end
    if data.empty then
        ui.wrap(bodyX, 206, bodyWidth, 58, data.empty, 16, palette.muted)
        return
    end
    for index, metric in ipairs(data.metrics or {}) do
        local x = bodyX + (index - 1) * 254
        ui.box(x, 192, 242, 76, palette.card)
        ui.text(x + 16, 200, 210, 24, metric.label, 13, palette.muted)
        ui.text(x + 16, 227, 210, 32, metric.value, 21)
    end
    ui.text(bodyX, 282, bodyWidth, 24, data.period or "", 13, palette.muted)
    drawTrend(ui, data.series, 312, en)
    if data.forecast then ui.text(bodyX, 490, bodyWidth, 30, data.forecast, 15, palette.accent) end
end

local function drawAdvisor(ui, data, en)
    if data.advisorEnabled ~= false then
        ui.button(bodyX, 132, 188, 32, palette.button, { action = "advisorStrategy" },
            data.strategyButton or (en and "Switch strategy" or "切换策略"), 13)
        ui.button(bodyX + 198, 132, 156, 32, palette.button, { action = "advisorAdvanced" },
            data.advanced and (en and "Hide advanced" or "收起高级建议") or (en and "Show advanced" or "展开高级建议"), 13)
        if data.canLiveScan then
            ui.button(bodyX + 364, 132, 224, 32, palette.buttonWarn, { action = "liveWorkforceScan" },
                en and "Try live Pal scan (risky)" or "尝试读取在岗帕鲁（高风险）", 13)
        end
    end
    local top, bottom = 176, 534
    if data.liveNotice then
        ui.box(bodyX, top, bodyWidth, 42, palette.warnBg)
        ui.wrap(bodyX + 14, top + 8, bodyWidth - 28, 28, data.liveNotice, 13, palette.warning)
        top = top + 52
    end
    local pages, used = {{}}, 0
    for _, line in ipairs(data.details or {}) do
        local boxHeight = math.max(30, math.min(110, estimateWrappedLines(line, 15, bodyWidth - 40) * 24 + 6))
        if used + boxHeight > bottom - top then
            pages[#pages + 1] = {}
            used = 0
        end
        local page = pages[#pages]
        page[#page + 1] = { message = line, height = boxHeight, offset = used }
        used = used + boxHeight + 6
    end
    local current = math.min(data.page or 1, #pages)
    for _, entry in ipairs(pages[current]) do
        local y = top + entry.offset
        ui.box(bodyX, y, bodyWidth, entry.height, palette.surface)
        ui.wrap(bodyX + 15, y + 3, bodyWidth - 30, entry.height - 4, entry.message, 15)
    end
    return current, #pages
end

function M.show(context, view)
    local root = rootPath and StaticFindObject(rootPath)
    local tree, canvas
    local opening = not game.valid(root)
    if not opening then
        tree = root.WidgetTree
        canvas = tree.RootWidget
        canvas:ClearChildren()
    else
        rootPath = nil
        root = construct("UserWidget", context.pc)
        tree = construct("WidgetTree", root)
        root.WidgetTree = tree
        canvas = construct("CanvasPanel", tree)
        tree.RootWidget = canvas
        root:SetVisibility(0)
        canvas:SetVisibility(0)
    end

    hitTargets = {}
    searchBoxPath, targetBoxPath = nil, nil

    local ui = {}
    function ui.box(x, y, w, h, fill, vis) return block(tree, canvas, x, y, w, h, fill, vis) end
    function ui.text(x, y, w, h, value, size, fill)
        if value ~= nil and value ~= "" then
            return label(tree, canvas, x, y, w, h, tostring(value), size, fill or palette.text)
        end
    end
    function ui.wrap(x, y, w, h, value, size, fill)
        if value ~= nil and value ~= "" then
            return label(tree, canvas, x, y, w, h, tostring(value), size, fill or palette.text, true)
        end
    end
    function ui.button(x, y, w, h, fill, action, textValue, textSize, textFill)
        return button(tree, canvas, x, y, w, h, fill, action, textValue, textSize, textFill)
    end
    function ui.textBox(x, y, w, h, initial, hint)
        return textBox(tree, canvas, x, y, w, h, initial, hint)
    end

    local en = view.lang == "en-US"
    local data = view.content or {}
    local section = view.section

    -- Opaque backdrop swallows clicks inside the panel
    ui.box(0, 0, width, height, palette.background, 0)
    ui.box(0, 0, width, 3, palette.accent)
    ui.text(26, 22, 520, 40, view.title or "帕鲁工业总控", 24)

    -- Status badge + Top-right Close button
    local tone = view.blocked and palette.warning or (view.automation and palette.good or palette.muted)
    ui.box(588, 20, 246, 38, palette.surface)
    ui.box(600, 35, 8, 8, tone)
    ui.text(618, 27, 208, 24, view.modeLabel or fallbackMode(view, en), 15, tone)
    ui.button(848, 20, 106, 38, palette.buttonDanger, { action = "close" },
        en and "✕  Close" or "✕  关闭", 14)
    ui.box(26, 74, 928, 1, palette.line)

    -- Left navigation sidebar (real clickable UButtons)
    ui.box(22, 92, 158, 452, palette.surface)
    ui.text(36, 104, 132, 22, en and "OPERATIONS" or "日常管理", 12, palette.muted)
    for index, tab in ipairs(view.tabs or {}) do
        local y = index <= 3 and (132 + (index - 1) * 44) or (302 + (index - 4) * 44)
        local active = tab.id == section
        ui.button(28, y, 146, 38, active and palette.tabActive or palette.surface,
            { action = "tab", section = tab.id }, tab.label, 15, active and palette.text or palette.muted)
        if active then ui.box(28, y, 3, 38, palette.accent) end
    end
    ui.box(34, 266, 134, 1, palette.line)
    ui.text(36, 276, 132, 22, en and "TOOLS" or "其他工具", 12, palette.muted)

    -- Main page heading & content
    ui.text(bodyX, 92, bodyWidth, 34, data.heading, 23)
    local page, pages = data.page or 1, data.pages or 1
    if section == "overview" then drawHome(ui, data, en)
    elseif section == "inventory" then drawInventory(ui, data, en)
    elseif section == "production" then drawOrders(ui, data, en)
    elseif section == "logistics" then drawTransfers(ui, data, en)
    elseif section == "settings" then drawSettings(ui, data, en)
    elseif section == "history" then drawHistory(ui, data, en)
    elseif section == "advisor" then page, pages = drawAdvisor(ui, data, en) end

    -- Clean footer (no bulky shortcut wall)
    ui.box(26, 556, 928, 1, palette.line)
    ui.text(26, 574, 500, 24,
        en and "Click controls directly · Ctrl+F10 toggle" or "点击界面直接操作 · Ctrl+F10 打开或关闭",
        13, palette.muted)
    if pages > 1 then
        ui.button(676, 568, 88, 34, palette.button, { action = "page", step = -1 },
            en and "Prev" or "上一页", 13)
        ui.text(772, 574, 78, 24, ("%d / %d"):format(page, pages), 13, palette.muted)
        ui.button(858, 568, 96, 34, palette.button, { action = "page", step = 1 },
            en and "Next" or "下一页", 13)
    end

    if opening then
        root:AddToViewport(8900)
        captureInput(context, root)
    elseif not inputCaptured then
        captureInput(context, root)
    end
    rootPath = assert(fullPath(root))
    return section == "advisor" and page or nil
end

return M
