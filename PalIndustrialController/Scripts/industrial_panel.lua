local game = require("industrial_game")
local M = {}
local rootPath
local editPath, editPanelPath, oldCursor

local width, height = 840, 540

local function color(r, g, b, alpha)
    return { R = r / 255, G = g / 255, B = b / 255, A = alpha or 1 }
end

local palette = {
    background = color(15, 25, 34, 0.98),
    card = color(24, 39, 51),
    line = color(48, 68, 83),
    accent = color(84, 218, 198),
    text = color(232, 245, 248),
    muted = color(157, 182, 197),
    warning = color(255, 187, 103),
}

local function construct(class, outer)
    local object = StaticConstructObject(StaticFindObject("/Script/UMG." .. class), outer)
    if not game.valid(object) then error("无法创建界面组件 " .. class) end
    return object
end

local function place(canvas, widget, x, y, w, h)
    local slot = canvas:AddChildToCanvas(widget)
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
    slot:SetPosition({ X = x - width / 2, Y = y - height / 2 })
    slot:SetSize({ X = w, Y = h })
    return slot
end

local function block(tree, canvas, x, y, w, h, fill)
    local widget = construct("Border", tree)
    widget:SetBrushColor(fill)
    widget:SetVisibility(4)
    place(canvas, widget, x, y, w, h)
end

local function label(tree, canvas, x, y, w, h, value, size, fill)
    local widget = construct("TextBlock", tree)
    local font = widget.Font
    font.Size = size
    widget:SetFont(font)
    widget:SetColorAndOpacity({ SpecifiedColor = fill, ColorUseRule = 0 })
    widget:SetText(FText(value))
    widget:SetVisibility(4)
    place(canvas, widget, x, y, w, h)
end

function M.beginEdit(context, initial, hint)
    local root = rootPath and StaticFindObject(rootPath)
    if not game.valid(root) then return false end
    local tree = root.WidgetTree
    local overlay = construct("CanvasPanel", tree)
    overlay:SetVisibility(4)
    place(tree.RootWidget, overlay, 0, 0, width, height):SetZOrder(1)
    block(tree, overlay, 170, 197, 500, 155, palette.background)
    block(tree, overlay, 170, 197, 500, 3, palette.accent)
    label(tree, overlay, 190, 213, 458, 30, hint, 19, palette.text)
    label(tree, overlay, 190, 307, 458, 30, "F4 确认   Esc 取消", 16, palette.muted)
    local box = construct("EditableTextBox", tree)
    box:SetText(FText(initial))
    box:SetIsReadOnly(false)
    box:SetForegroundColor(palette.background)
    box.SelectAllTextWhenFocused = true
    place(overlay, box, 190, 252, 460, 42)
    editPath = assert(box:GetFullName():match("%s(.+)$"))
    editPanelPath = assert(overlay:GetFullName():match("%s(.+)$"))
    local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    oldCursor = context.pc.bShowMouseCursor
    context.pc.bShowMouseCursor = true
    lib:SetInputMode_UIOnlyEx(context.pc, box, 0, false)
    box:SetKeyboardFocus()
    return true
end

function M.endEdit(context)
    if not editPath then return nil end
    local box = StaticFindObject(editPath)
    local value
    if game.valid(box) then
        value = box:GetText():ToString()
    end
    local overlay = editPanelPath and StaticFindObject(editPanelPath)
    if game.valid(overlay) then overlay:RemoveFromParent() end
    editPath, editPanelPath = nil, nil
    if context then
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        context.pc.bShowMouseCursor = oldCursor == true
        lib:SetInputMode_GameOnly(context.pc, false)
    end
    oldCursor = nil
    return value
end

function M.close()
    if not rootPath then return end
    local current = StaticFindObject(rootPath)
    rootPath = nil
    if game.valid(current) then current:RemoveFromParent() end
    editPath, editPanelPath, oldCursor = nil, nil, nil
end

function M.isOpen()
    return rootPath ~= nil
end

function M.show(context, snapshot, rows, status, page, pages, query, automation)
    local root = rootPath and StaticFindObject(rootPath)
    local tree, canvas
    if game.valid(root) then
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
        root:SetVisibility(4)
    end

    local function text(x, y, w, value, size, fill)
        label(tree, canvas, x, y, w, 40, value, size, fill or palette.text)
    end
    block(tree, canvas, 0, 0, width, height, palette.background)
    block(tree, canvas, 0, 0, width, 4, palette.accent)
    text(32, 23, 550, "帕鲁工业总控", 33)
    text(550, 31, 258, automation and "F4  暂停补货" or "F4  启动补货", 17,
        automation and palette.accent or palette.muted)
    text(32, 67, 620, status, 17, palette.muted)
    for i, card in ipairs({
        { "公会据点", #snapshot.camps },
        { "仓库", snapshot.chests },
        { "生产设备", #snapshot.stations },
    }) do
        local x = 32 + (i - 1) * 265
        block(tree, canvas, x, 110, 247, 80, palette.card)
        text(x + 16, 124, 125, card[1], 17, palette.muted)
        text(x + 16, 148, 180, tostring(card[2]), 26, palette.accent)
    end
    text(32, 213, 380, query == "" and "物品" or "筛选  " .. query, 18, palette.muted)
    text(449, 213, 125, "入库", 18, palette.muted)
    text(569, 213, 125, "排队/待搬", 18, palette.muted)
    text(689, 213, 125, "目标", 18, palette.muted)
    block(tree, canvas, 32, 250, 776, 1, palette.line)
    for i, row in ipairs(rows) do
        local y = 261 + (i - 1) * 35
        if row.selected then block(tree, canvas, 32, y - 2, 776, 33, palette.card) end
        local nameColor = row.selected and palette.accent or palette.text
        text(43, y, 386, row.label, 18, nameColor)
        text(449, y, 115, tostring(row.stock), 18)
        text(569, y, 115, tostring(row.pending), 18, palette.muted)
        text(689, y, 115, row.target and tostring(row.target) or "—", 18,
            row.target and row.stock < row.target and palette.warning or palette.text)
    end
    if #rows == 0 then text(43, 275, 700, query ~= "" and "没有匹配物品" or "等待仓库和设备数据", 19, palette.muted) end
    block(tree, canvas, 32, 488, 776, 1, palette.line)
    text(32, 505, 732, "Ctrl+F10 关闭   ↑/↓ 选择   PgUp/PgDn 翻页   Ctrl+F 搜索   Ctrl+G 设定目标", 14, palette.muted)
    text(768, 504, 60, ("%d/%d"):format(page, pages), 14, palette.muted)

    if not rootPath then
        root:AddToViewport(8900)
    end
    rootPath = assert(root:GetFullName():match("%s(.+)$"))
end

return M
