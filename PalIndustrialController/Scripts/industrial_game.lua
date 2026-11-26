local M = {}

function M.valid(object)
    return object and object:IsValid()
end

function M.guid(value)
    if not value then return nil end
    local a, b, c, d = value.A, value.B, value.C, value.D
    if not (a and b and c and d) or (a == 0 and b == 0 and c == 0 and d == 0) then return nil end
    return ("%08x%08x%08x%08x"):format(a & 0xffffffff, b & 0xffffffff, c & 0xffffffff, d & 0xffffffff)
end

function M.name(value)
    local name = value and value:ToString()
    if name and name ~= "" and name ~= "None" then return name end
end

function M.player()
    local pc = FindFirstOf("PalPlayerController")
    if not M.valid(pc) or not pc:IsLocalController() then return nil, "请先进入本地世界" end
    local pawn = pc:K2_GetPawn()
    if not M.valid(pawn) then return nil, "正在加载角色" end
    if not pc:HasAuthority() then return nil, "请在单人或房主模式下使用" end
    local utility = StaticFindObject("/Script/Pal.Default__PalUtility")
    local playerState = utility:GetLocalPlayerState(pc)
    if not M.valid(playerState) or not M.valid(playerState.GuildBelongTo) then return nil, "正在加载公会" end
    local guild = M.guid(playerState.GuildBelongTo:GetId())
    if not guild then return nil, "正在加载公会" end
    local gameState = FindFirstOf("PalGameStateInGame")
    if not M.valid(gameState) then return nil, "世界尚未就绪" end
    local world = gameState:GetWorldSaveDirectoryName():ToString():upper()
    if not world:match("^[%w_%-]+$") then return nil, "无法识别存档目录" end
    local playerId = M.guid(pc:GetPlayerUId())
    if not playerId then return nil, "玩家尚未就绪" end
    local manager = utility:GetBaseCampManager(pc)
    local mapManager = utility:GetMapObjectManager(pc)
    if not M.valid(manager) or not M.valid(mapManager) then return nil, "据点正在加载" end
    local currentCamp
    local camp = manager:GetInRangedBaseCamp(pawn:K2_GetActorLocation(), 0)
    if M.valid(camp) and camp:IsAvailable() and M.guid(camp:GetGroupIdBelongTo()) == guild then
        currentCamp = M.guid(camp:GetId())
    end
    return { pc = pc, playerState = playerState, playerId = playerId, guild = guild, world = world,
        currentCamp = currentCamp, baseManager = manager, mapManager = mapManager }
end

local function unpackRecipe(access, id)
    local result = {}
    local row = access:BP_FindRow(FName(id), result)
    local output = M.name(row.Product_Id)
    local count = row.Product_Count
    if not output or type(count) ~= "number" or count < 1 then return nil end
    local materials = {}
    for i = 1, 5 do
        local material = M.name(row["Material" .. i .. "_Id"])
        local units = row["Material" .. i .. "_Count"]
        if material and units > 0 then
            materials[material] = (materials[material] or 0) + units
        end
    end
    return { id = id, output = output, count = count, materials = materials }
end

local function readSlot(slot)
    if not M.valid(slot) then error("仓库有未同步的物品格") end
    local amount = slot.StackCount
    if amount < 0 then error("无效的物品数量") end
    if amount == 0 then return nil, 0 end
    local item = M.name(slot.ItemId.StaticId)
    if not item then error("库存内存在无法识别的物品") end
    return item, amount
end

local function addStock(stock, item, amount)
    if item then stock[item] = (stock[item] or 0) + amount end
end

local function registeredCamp(context, model, camps)
    if not M.valid(model) or model.bDisposed then return end
    local camp = camps[M.guid(model:GetBaseCampIdBelongTo())]
    if not camp then return end
    local id = model:GetInstanceId()
    local key = M.guid(id)
    if not key or not M.valid(context.mapManager:FindConcreteModel(id)) then return end
    local parent = context.mapManager:FindModel(model:GetModelInstanceId())
    if not M.valid(parent) then return end
    local process = parent.BuildProcess
    if M.valid(process) and not process:IsCompleted() then return end
    return camp, key
end

local function readStorage(context, camps, snapshot)
    for _, chest in ipairs(FindAllOf("PalMapObjectItemChestModel") or {}) do
        local camp = registeredCamp(context, chest, camps)
        if camp then
            local privateOwner = M.guid(chest.PrivateLockPlayerUId)
            if not privateOwner or privateOwner == context.playerId then
                local module = chest:GetItemContainerModule()
                local container = M.valid(module) and module:GetContainer()
                if M.valid(container) then
                    local key = M.guid(container:GetId().ID)
                    local storage = key and snapshot.storage[key]
                    if not key then
                        snapshot.incomplete = true
                    elseif not storage then
                        storage = { camp = camp.id, stock = {} }
                        snapshot.storage[key] = storage
                        local slots = container.ItemSlotArray
                        local size = #slots
                        if size > 4096 then error("仓库格数异常") end
                        for i = 1, size do
                            local item, amount = readSlot(slots[i])
                            addStock(storage.stock, item, amount)
                            addStock(camp.stock, item, amount)
                            addStock(snapshot.stock, item, amount)
                        end
                        camp.containers[#camp.containers + 1] = container
                        snapshot.chests = snapshot.chests + 1
                    elseif storage.camp ~= camp.id then
                        error("同一个仓库属于多个据点")
                    end
                else
                    snapshot.incomplete = true
                end
            end
        end
    end
end

local function readStations(context, camps, snapshot)
    local utility = StaticFindObject("/Script/Pal.Default__PalMasterDataTablesUtility")
    local access = utility:GetItemRecipeDataTableAccess(context.pc)
    if not M.valid(access) then error("配方表还未就绪") end
    local technology = context.playerState:GetTechnologyData()
    if not M.valid(technology) then error("科技列表还未就绪") end
    local checkedRecipe = {}
    local function recipe(id)
        if not id then return nil end
        if not checkedRecipe[id] then
            checkedRecipe[id] = true
            snapshot.recipes[id] = unpackRecipe(access, id)
        end
        return snapshot.recipes[id]
    end
    for _, model in ipairs(FindAllOf("PalMapObjectConvertItemModel") or {}) do
        local camp, id = registeredCamp(context, model, camps)
        if camp and not snapshot.stationIds[id] then
            local station = { id = id, camp = camp.id, recipes = {}, model = model }
            local ids = model.RecipeIds
            for i = 1, #ids do
                local recipeId = M.name(ids[i])
                if recipeId and technology:IsUnlockCraftRecipe(FName(recipeId)) and not technology:IsDeniedRecipe(FName(recipeId)) then
                    local row = recipe(recipeId)
                    if row then station.recipes[recipeId] = true end
                end
            end
            local current = recipe(M.name(model:GetCurrentRecipeId()))
            local remaining = model:GetRemainCreateNum()
            local outputSlot = model:GetProductSlot()
            local item, amount = nil, 0
            if M.valid(outputSlot) then
                item, amount = readSlot(outputSlot)
                addStock(snapshot.pending, item, amount)
            end
            if current and remaining > 0 then
                addStock(snapshot.pending, current.output, remaining * current.count)
            end
            station.idle = remaining == 0 and amount == 0 and current == nil
            snapshot.stations[#snapshot.stations + 1] = station
            snapshot.stationIds[id] = true
        end
    end
    table.sort(snapshot.stations, function(a, b) return a.id < b.id end)
end

function M.snapshot(context)
    local snapshot = { camps = {}, stock = {}, storage = {}, pending = {}, stations = {}, stationIds = {}, recipes = {}, chests = 0 }
    local camps = {}
    local baseIds = context.playerState.GuildBelongTo.BaseCampIds
    for i = 1, #baseIds do
        local guid = baseIds[i]
        local id = M.guid(guid)
        local result = {}
        local found = context.baseManager:TryGetModel(guid, result)
        local model = result.OutModel
        if not found or not M.valid(model) then
            snapshot.incomplete = true
        elseif id and not camps[id] and model:IsAvailable() and M.guid(model:GetGroupIdBelongTo()) == context.guild then
            local camp = { id = id, stock = {}, containers = {} }
            camps[id] = camp
            snapshot.camps[#snapshot.camps + 1] = camp
        end
    end
    table.sort(snapshot.camps, function(a, b) return a.id < b.id end)
    readStorage(context, camps, snapshot)
    readStations(context, camps, snapshot)
    return snapshot
end

function M.itemLabel(context, id)
    local ok, label = pcall(function()
        local output = {}
        local utility = StaticFindObject("/Script/Pal.Default__PalUIUtility")
        utility:GetItemName(context.pc, FName(id), output)
        local value = output.outName or output.OutName
        if value then return value:ToString() end
    end)
    return ok and label and label ~= "" and label or id
end

local function prepareOrder(context, station, recipe, batches)
    local factory = station.model
    local convertClass = StaticFindObject("/Script/Pal.PalUIConvertItemModel")
    local view = StaticConstructObject(convertClass, context.pc)
    if not M.valid(view) then return nil, "无法创建生产请求" end
    view:Initialize(factory)
    local settings = view.ProductSettingModel
    if not M.valid(settings) then return nil, "设备生产设置未就绪" end
    settings:SelectRecipe(FName(recipe.id))
    settings:SetProductNumByInput(batches)
    if M.name(settings:GetRecipeId()) ~= recipe.id or settings:GetProductNum() ~= batches then
        return nil, "原版面板无法接受该批量"
    end
    local result = view:CanStartProduction()
    if result ~= 0 then
        local reasons = { [1] = "配方不可用", [2] = "设备脱离加载范围", [3] = "能源模块不可用",
            [4] = "原版判定缺少材料", [5] = "能源不足" }
        return nil, reasons[result] or ("原版生产校验返回 " .. tostring(result))
    end
    return view
end

function M.startOrder(context, station, recipe, batches, enableTransport)
    local factory = station.model
    if not station.idle or not station.recipes[recipe.id] or not M.valid(factory) or factory.bDisposed then
        return nil, "设备已变动"
    end
    if context.currentCamp ~= station.camp then return nil, "等待进入生产据点" end
    if M.guid(factory:GetBaseCampIdBelongTo()) ~= station.camp then return nil, "设备已移动" end
    if M.name(factory:GetCurrentRecipeId()) or factory:GetRemainCreateNum() ~= 0 then return nil, "设备已接单" end
    local view, why = prepareOrder(context, station, recipe, batches)
    if not view then return nil, why end
    if enableTransport and not factory:IsTransportToStorage() then
        view:UpdateProductSetting_TransportToStorage(true)
    end
    view:StartProduction()
    return M.name(factory:GetCurrentRecipeId()) == recipe.id and factory:GetRemainCreateNum() > 0,
        "已提交原版订单，等待设备确认"
end

local function campById(snapshot, id)
    for _, camp in ipairs(snapshot.camps) do if camp.id == id then return camp end end
end

local function destinationSlot(container, item)
    local slots = container.ItemSlotArray
    local empty
    for i = 1, #slots do
        local slot = slots[i]
        local existing, amount = readSlot(slot)
        if amount == 0 then empty = true end
        if existing == item and not slot:IsMaxStack() then return true end
    end
    return empty
end

function M.move(context, snapshot, request)
    local source, destination = campById(snapshot, request.source), campById(snapshot, request.destination)
    if not source or not destination or source.id == destination.id then return nil, "调拨路径不可用" end
    local item = FName(request.item)
    local utility = StaticFindObject("/Script/Pal.Default__PalUtility")
    local transmitter = utility:GetNetworkTransmitter(context.pc)
    local network = M.valid(transmitter) and transmitter:GetItem()
    if not M.valid(network) then return nil, "物品移动接口尚未就绪" end
    local guidLibrary = StaticFindObject("/Script/Engine.Default__KismetGuidLibrary")
    for _, from in ipairs(source.containers) do
        if from:GetItemStackCount64(item) > 0 then
            local slots = from.ItemSlotArray
            for i = 1, #slots do
                local slot = slots[i]
                local id, available = readSlot(slot)
                if id == request.item then
                    for _, into in ipairs(destination.containers) do
                        if destinationSlot(into, request.item) then
                            local beforeSource = from:GetItemStackCount64(item)
                            local beforeDestination = into:GetItemStackCount64(item)
                            local amount = math.min(available, request.amount)
                            network:RequestMoveToContainer_ToServer(guidLibrary:NewGuid(), into:GetId(),
                                { { SlotId = slot:GetSlotId(), Num = amount } })
                            local removed = beforeSource - from:GetItemStackCount64(item)
                            local received = into:GetItemStackCount64(item) - beforeDestination
                            if removed == received and received > 0 and received <= amount then return received end
                            if removed ~= 0 or received ~= 0 then error("调拨前后物品数量不一致") end
                            return false, "原版尚未确认调拨"
                        end
                    end
                    return nil, "目的地无可用仓库格"
                end
            end
        end
    end
    return nil, "来源仓库缺料"
end

return M
