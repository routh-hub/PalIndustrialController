package.path = "PalIndustrialController/Scripts/?.lua;" .. package.path

local game = require("industrial_game")
local planner = require("industrial_planner")
local journal = require("industrial_journal")
local advisor = require("industrial_advisor")
local workforce = require("industrial_workforce")
local dashboard = require("industrial_dashboard")
local history = require("industrial_history")
local passed = 0

local function test(name, run)
    local ok, message = xpcall(run, debug.traceback)
    if not ok then error(name .. "\n" .. message, 0) end
    passed = passed + 1
    print("PASS " .. name)
end

local function equal(actual, expected)
    assert(actual == expected, ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
end

local ore, ingot, product = "Ore", "Ingot", "Product"

test("Snapshot adapter follows five mocked bases, additions, removal and temporarily missing models", function()
    local function guid(n) return { A = n, B = 0, C = 0, D = 0 } end
    local function valid() return true end
    local function asName(name) return { ToString = function() return name end } end
    local guild = guid(900)
    local ids, bases, chests, registered = {}, {}, {}, {}
    for n = 1, 5 do
        local campId, chestId, containerId = guid(n), guid(100 + n), guid(200 + n)
        local base = { IsValid = valid, IsAvailable = valid, GetGroupIdBelongTo = function() return guild end,
            GetBaseCampName = function() return asName("Camp " .. n) end }
        local slot = { IsValid = valid, StackCount = n, ItemId = { StaticId = asName(ore) } }
        local container = { IsValid = valid, GetId = function() return { ID = containerId } end, ItemSlotArray = { slot } }
        local chest = { IsValid = valid, GetBaseCampIdBelongTo = function() return campId end,
            GetInstanceId = function() return chestId end, GetModelInstanceId = function() return chestId end,
            GetItemContainerModule = function()
                return { IsValid = valid, GetContainer = function() return container end }
            end,
        }
        bases[n], chests[n], registered[100 + n] = base, chest, chest
        if n < 5 then ids[n] = campId end
    end
    local context = {
        guild = game.guid(guild),
        playerState = { GuildBelongTo = { BaseCampIds = ids }, GetTechnologyData = function() return { IsValid = valid } end },
        baseManager = { TryGetModel = function(_, id, result)
            result.OutModel = bases[id.A]
            return result.OutModel ~= nil
        end },
        mapManager = { FindConcreteModel = function(_, id) return registered[id.A] end,
            FindModel = function() return { IsValid = valid } end },
    }
    FindAllOf = function(class) return class == "PalMapObjectItemChestModel" and chests or {} end
    StaticFindObject = function()
        return { GetItemRecipeDataTableAccess = function() return { IsValid = valid } end }
    end
    local snapshot = game.snapshot(context)
    equal(#snapshot.camps, 4)
    equal(snapshot.stock[ore], 10)
    ids[#ids + 1] = guid(5)
    snapshot = game.snapshot(context)
    equal(#snapshot.camps, 5)
    equal(snapshot.stock[ore], 15)
    equal(snapshot.campById[game.guid(guid(5))].stock[ore], 5)
    local missing = bases[2]
    bases[2] = nil
    snapshot = game.snapshot(context)
    equal(snapshot.incomplete, true)
    equal(planner.next(snapshot, { [ore] = 50 }), nil)
    table.remove(ids, 2)
    snapshot = game.snapshot(context)
    equal(snapshot.incomplete, nil)
    equal(#snapshot.camps, 4)
    equal(snapshot.stock[ore], 13)
    bases[2], ids[#ids + 1] = missing, guid(2)
    snapshot = game.snapshot(context)
    equal(#snapshot.camps, 5)
    equal(snapshot.stock[ore], 15)
    registered[104] = nil
    equal(game.snapshot(context).stock[ore], 11)
end)

test("Recipe eligibility is shared across stations and reread on the next snapshot", function()
    local function guid(n) return { A = n, B = 0, C = 0, D = 0 } end
    local function valid() return true end
    local camp, guild = guid(1), guid(2)
    local base = { IsValid = valid, IsAvailable = valid, GetGroupIdBelongTo = function() return guild end }
    FName = function(value) return { ToString = function() return value end } end
    local models = {}
    for _, id in ipairs({ guid(3), guid(4) }) do
        models[#models + 1] = {
            IsValid = valid, GetBaseCampIdBelongTo = function() return camp end,
            GetInstanceId = function() return id end, GetModelInstanceId = function() return id end,
            RecipeIds = { FName("craft") }, GetCurrentRecipeId = function() return FName("None") end,
            GetRemainCreateNum = function() return 0 end, GetProductSlot = function() return nil end,
        }
    end
    local eligible, unlockChecks, denyChecks, rowChecks = true, 0, 0, 0
    local technology = {
        IsValid = valid,
        IsUnlockCraftRecipe = function() unlockChecks = unlockChecks + 1; return eligible end,
        IsDeniedRecipe = function() denyChecks = denyChecks + 1; return false end,
    }
    local access = { IsValid = valid, BP_FindRow = function()
        rowChecks = rowChecks + 1
        return { Product_Id = FName(product), Product_Count = 1 }
    end }
    local context = {
        guild = game.guid(guild),
        playerState = { GuildBelongTo = { BaseCampIds = { camp } }, GetTechnologyData = function() return technology end },
        baseManager = { TryGetModel = function(_, _, result) result.OutModel = base; return true end },
        mapManager = { FindConcreteModel = function() return base end, FindModel = function() return base end },
    }
    FindAllOf = function(class) return class == "PalMapObjectConvertItemModel" and models or {} end
    StaticFindObject = function() return { GetItemRecipeDataTableAccess = function() return access end } end

    local snapshot = game.snapshot(context)
    equal(#snapshot.stations, 2)
    equal(snapshot.stations[1].recipes.craft, true)
    equal(snapshot.stations[2].recipes.craft, true)
    equal(unlockChecks, 1)
    equal(denyChecks, 1)
    equal(rowChecks, 1)

    eligible = false
    snapshot = game.snapshot(context)
    equal(snapshot.stations[1].recipes.craft, nil)
    equal(snapshot.stations[2].recipes.craft, nil)
    equal(unlockChecks, 2)
    equal(denyChecks, 1)
    equal(rowChecks, 1)
end)

local function chain()
    local a, b, c = { id = "a", stock = {} }, { id = "b", stock = {} }, { id = "c", stock = {} }
    return {
        camps = { a, b, c }, campById = { a = a, b = b, c = c }, stock = {}, pending = {},
        storage = {}, stations = {
            { id = "oven", camp = "b", recipes = { refine = true }, idle = true, outputCount = 0 },
            { id = "bench", camp = "c", recipes = { craft = true }, idle = true, outputCount = 0 },
        },
        recipes = {
            refine = { id = "refine", output = ingot, count = 3, materials = { [ore] = 2 } },
            craft = { id = "craft", output = product, count = 2, materials = { [ingot] = 2 } },
        },
        awaiting = {}, unknownPending = {}, stationIds = {},
    }
end

test("Three-camp dependency produces locally for a goal at a different camp", function()
    local state = chain()
    local goals = { [product] = 9 }
    state.stock[ore], state.campById.a.stock[ore] = 20, 20
    local action = planner.next(state, goals, nil, "b")
    equal(action.kind, "transfer")
    equal(action.source, "a")
    equal(action.destination, "b")
    equal(action.amount, 8)
    state.campById.b.stock[ore], state.campById.a.stock[ore] = 8, 12
    action = planner.next(state, goals, nil, "b")
    equal(action.kind, "produce")
    equal(action.batches, 4)
    equal(action.goal, product)
    state.stock[ingot], state.campById.b.stock[ingot] = 12, 12
    local unavailable, why = planner.next(state, goals, nil, "b")
    equal(unavailable, nil)
    equal(why.code, "access")
    equal(why.camp, "c")
    action = planner.next(state, goals, nil, "c")
    equal(action.amount, 10)
    state.campById.c.stock[ingot] = 10
    action = planner.next(state, goals, nil, "c")
    equal(action.kind, "produce")
    equal(action.batches, 5)
end)

test("Shared ingredients respect aggregate stock targets and batch rounding", function()
    local state = chain()
    state.stock[ingot], state.campById.c.stock[ingot] = 14, 14
    local goals = { [product] = 15, [ingot] = 10 }
    local action = planner.next(state, goals, nil, "c")
    equal(action.batches, 2)
    state.stock[ingot], state.campById.c.stock[ingot], state.pending[product] = 10, 10, 4
    local unavailable, why = planner.next(state, goals, nil, "c")
    equal(unavailable, nil)
    equal(why.code, "material")
    equal(why.item, ore)
end)

test("A blocked transfer route allows another source", function()
    local state = chain()
    state.stock[ingot], state.campById.a.stock[ingot], state.campById.b.stock[ingot] = 7, 5, 2
    local rejected = { [planner.routeKey("a", "c", ingot)] = { diagnostic = { code = "transport" } } }
    local action = planner.next(state, { [product] = 6 }, rejected, "c")
    equal(action.source, "b")
    equal(action.amount, 2)
end)

test("Queue, transport, incomplete stocks, and unknown backlog prevent duplicate work", function()
    local state = chain()
    local goals = { [product] = 10 }
    state.stock[ingot], state.campById.c.stock[ingot] = 20, 20
    state.pending[product] = 10
    local action, why = planner.next(state, goals, nil, "c")
    equal(action, nil)
    equal(why.code, "queue")
    state.pending[product], state.awaiting[product] = 0, "bench"
    action, why = planner.next(state, goals, nil, "c")
    equal(action, nil)
    equal(why.code, "delivery")
    local bench = state.stations[2]
    state.stationIds.bench = bench
    bench.queueItem, bench.queueCount, state.pending[product] = product, 10, 10
    action, why = planner.next(state, goals, nil, "c")
    equal(action, nil)
    equal(why.code, "queue")
    equal(why.station, "bench")
    bench.queueCount, bench.outputItem, bench.outputCount = 0, product, 10
    action, why = planner.next(state, goals, nil, "c")
    equal(action, nil)
    equal(why.message, "成品等待搬运")
    state.pending[product] = 0
    state.awaiting[product], state.unknownPending[product] = nil, true
    action, why = planner.next(state, goals, nil, "c")
    equal(action, nil)
    equal(why.code, "queue")
    state.incomplete = true
    action, why = planner.next(state, goals, nil, "c")
    equal(action, nil)
    equal(why.code, "access")
end)

test("Cyclic recipes stop within the planning budget", function()
    local state = chain()
    state.recipes.refine.materials = { [product] = 1 }
    local action, why = planner.next(state, { [product] = 10 })
    equal(action, nil)
    equal(why.message, "配方存在循环")
end)

local idA, idB = string.rep("a", 32), string.rep("b", 32)
local function temporaryPath()
    local path = os.tmpname()
    if package.config:sub(1, 1) == "\\" and path:sub(1, 1) == "\\" then
        return (os.getenv("TEMP") or ".") .. path
    end
    return path
end

test("Task journal round trips production and transfer and fails closed on partial data", function()
    local path = temporaryPath()
    os.remove(path)
    equal(next(assert(journal.read(path))), nil)
    local record = { kind = "P", item = product, first = idA, second = idB, count = 12, baseline = 24,
        seen = true, recipe = "craft", missingSince = 100, storageKey = idB }
    local file = assert(io.open(path, "wb"))
    assert(file:write("PalIndustrialJournal\t1\n", table.concat({
        "P", product, idA, idB, "12", "24", "1", "craft", "100", idB,
    }, "\t"), "\n"))
    file:close()
    local legacy = assert(journal.read(path))[product]
    equal(legacy.count, 12)
    equal(legacy.manual, false)
    local shipment = { kind = "T", item = ingot, first = idB, second = idA, count = 4, baseline = 0 }
    assert(journal.write(path, { [product] = record, [false] = shipment }))
    local current = assert(journal.read(path))
    equal(current[product].baseline, 24)
    equal(current[product].seen, true)
    equal(current[product].missingSince, 100)
    equal(current[product].storageKey, idB)
    equal(current[false].count, 4)
    assert(journal.write(path, {}))
    equal(next(assert(journal.read(path))), nil)
    file = assert(io.open(path, "ab"))
    assert(file:write("P\tbad\n"))
    file:close()
    equal(journal.read(path), nil)
    local interrupted = temporaryPath()
    os.remove(interrupted)
    file = assert(io.open(interrupted .. ".tmp", "wb"))
    file:close()
    equal(journal.read(interrupted), nil)
    os.remove(interrupted .. ".tmp")
    os.remove(path)
    os.remove(path .. ".previous")
end)

test("Receipt requires matching equipment, camp and no outstanding station work", function()
    local record = { item = product, first = idA, second = idB, count = 10, baseline = 20,
        recipe = "craft", storageKey = idA }
    local station = { camp = idB, queueItem = product, queueCount = 6, outputItem = product, outputCount = 2,
        activeRecipe = "craft" }
    local state = { stationIds = { [idA] = station },
        campById = { [idB] = { stock = { [product] = 20 }, storageKey = idA } },
        stock = { [product] = 500 } }
    local status, missing = journal.observe(record, state, 100)
    equal(status, "seen")
    equal(missing, 2)
    record.seen = true
    station.queueCount, station.outputCount, station.idle = 0, 0, true
    equal(journal.observe(record, state, 110), "waiting")
    equal(journal.observe(record, state, 200), "uncertain")
    state.campById[idB].stock[product] = 30
    state.stationIds[idA] = nil
    equal(journal.observe(record, state, 201), "manual")
    record.manual = false
    equal(journal.observe(record, state, 201), "uncertain")
    state.stationIds[idA] = station
    equal(journal.observe(record, state, 201), "manual")
    record.manual = false
    equal(journal.observe(record, state, 201), "received")
    state.campById[idB].storageKey = idB
    equal(journal.observe(record, state, 201), "topology")
    record.kind = "P"
    local path = temporaryPath()
    assert(journal.write(path, { [product] = record }))
    local restarted = assert(journal.read(path))[product]
    os.remove(path)
    equal(restarted.manual, true)
    state.campById[idB].storageKey = idA
    equal(journal.observe(restarted, state, 202), "manual")
    state.campById[idB] = nil
    equal(journal.observe(restarted, state, 203), "manual")
end)

test("Native transfer verifies both container deltas and persists intent first", function()
    local observations = {}
    local function mockSlot(item, count)
        return { ItemId = { StaticId = { ToString = function() return item end } }, StackCount = count,
            IsValid = function() return true end, IsMaxStack = function() return false end,
            GetSlotId = function() return "slot" end }
    end
    local from, into = mockSlot(ingot, 5), mockSlot(ingot, 0)
    local function mockContainer(slot, id)
        return { ItemSlotArray = { slot }, GetId = function() return id end,
            GetItemStackCount64 = function() return slot.StackCount end }
    end
    local mode = "partial"
    local network = { IsValid = function() return true end, RequestMoveToContainer_ToServer = function(_, ticket, id, slots)
        equal(observations[#observations], 4)
        equal(ticket, "ticket")
        equal(id, "destination")
        equal(slots[1].Num, 4)
        if mode ~= "async" then from.StackCount = from.StackCount - 2 end
        if mode == "partial" then into.StackCount = into.StackCount + 2 end
    end }
    FName = function(value) return value end
    StaticFindObject = function(path)
        if path:find("KismetGuidLibrary", 1, true) then return { NewGuid = function() return "ticket" end } end
        return { GetNetworkTransmitter = function()
            return { IsValid = function() return true end, GetItem = function() return network end }
        end }
    end
    local state = { campById = {
        a = { id = "a", containers = { mockContainer(from, "source") } },
        b = { id = "b", containers = { mockContainer(into, "destination") } },
    } }
    local action = { source = "a", destination = "b", item = ingot, amount = 4 }
    local context = { currentCamp = "b" }
    local function persist(count) observations[#observations + 1] = count end
    equal(game.move({ currentCamp = "a" }, state, action, persist), nil)
    equal(#observations, 0)
    equal(game.move(context, state, action, persist), 2)
    equal(from.StackCount + into.StackCount, 5)
    from.StackCount, into.StackCount, mode = 5, 0, "async"
    equal(game.move(context, state, action, persist), false)
    from.StackCount, into.StackCount, mode = 5, 0, "mismatch"
    equal(pcall(game.move, context, state, action, persist), false)
    from.StackCount, into.StackCount, mode = 5, 0, "partial"
    equal(pcall(game.move, context, state, action, function() error("disk full") end), false)
    equal(from.StackCount, 5)
    equal(into.StackCount, 0)
end)

test("Native production refuses remote execution and records intent before submitting", function()
    local calls = {}
    local function name(value) return { ToString = function() return value end } end
    local factory = {
        IsValid = function() return true end, GetBaseCampIdBelongTo = function() return { A = 1, B = 0, C = 0, D = 0 } end,
        GetProductSlot = function() return { IsValid = function() return true end, StackCount = 0 } end,
        GetCurrentRecipeId = function() return name(calls[3] and "craft" or "None") end,
        GetRemainCreateNum = function() return calls[3] and 2 or 0 end,
        IsTransportToStorage = function() return false end,
    }
    local settings = {
        IsValid = function() return true end, SelectRecipe = function(self, id) self.id = id end,
        SetProductNumByInput = function(self, batch) self.batch = batch end,
        GetRecipeId = function(self) return name(self.id) end,
        GetProductNum = function(self) return self.batch end,
    }
    local check = 0
    FName = function(value) return value end
    StaticFindObject = function() return {} end
    StaticConstructObject = function()
        return { ProductSettingModel = settings, CanStartProduction = function() return check end,
            IsValid = function() return true end, Initialize = function() end,
            UpdateProductSetting_TransportToStorage = function() calls[#calls + 1] = "transport" end,
            StartProduction = function() calls[#calls + 1] = "submit" end,
        }
    end
    local camp = game.guid(factory:GetBaseCampIdBelongTo())
    local station = { camp = camp, idle = true, recipes = { craft = true }, model = factory }
    local recipe = { id = "craft" }
    local function persist() calls[#calls + 1] = "persist" end
    equal(game.startOrder({}, station, recipe, 2, persist), nil)
    equal(#calls, 0)
    check = 5
    local started, _, code = game.startOrder({ currentCamp = camp }, station, recipe, 2, persist)
    equal(started, nil)
    equal(code, "energy")
    equal(#calls, 0)
    check = 0
    equal(game.startOrder({ currentCamp = camp }, station, recipe, 2, persist), true)
    equal(table.concat(calls, ","), "persist,transport,submit")
end)

test("Read-only diagnostics identify evidence and avoid attributing queue waits to Pal labor", function()
    local result = advisor.describe({ code = "queue", message = "等待设备空闲", goal = product,
        camp = "b" }, {}, { campById = { b = { name = "测试据点" } }, at = 200 }, function(_, item) return item end)
    equal(result[1], "等待设备空闲")
    assert(table.concat(result, "\n"):find("测试据点", 1, true))
    assert(table.concat(result, "\n"):find("无法判断帕鲁是否缺员", 1, true))
end)

test("P0 planner surfaces power outage, blocked path, and full destination chest cleanly", function()
    local state = chain()
    state.stock[ingot], state.campById.c.stock[ingot] = 20, 20
    local bench = state.stations[2]
    state.stationIds.bench = bench
    bench.energyRequired, bench.energyWaiting = true, true
    local action, why = planner.next(state, { [product] = 10 }, nil, "c")
    equal(action, nil)
    equal(why.code, "energy")
    equal(why.suitability, 4)
    bench.energyWaiting, bench.idle, bench.cannotApproach = false, false, true
    action, why = planner.next(state, { [product] = 10 }, nil, "c")
    equal(action, nil)
    equal(why.code, "path")

    -- Full destination warehouse refuses transfer without modifying stock
    local function mockSlot(item, count, full)
        return { ItemId = { StaticId = { ToString = function() return item end } }, StackCount = count,
            IsValid = function() return true end, IsMaxStack = function() return full end,
            GetSlotId = function() return "slot" end }
    end
    local fromSlot = mockSlot(ingot, 5, false)
    local fullSlot = mockSlot(ore, 9999, true)
    local moveCalls = 0
    FName = function(value) return value end
    StaticFindObject = function(path)
        if path:find("KismetGuidLibrary", 1, true) then return { NewGuid = function() return "t" end } end
        return { GetNetworkTransmitter = function()
            return { IsValid = function() return true end, GetItem = function()
                return { IsValid = function() return true end,
                    RequestMoveToContainer_ToServer = function() moveCalls = moveCalls + 1 end }
            end }
        end }
    end
    local moveState = { campById = {
        a = { id = "a", containers = { { ItemSlotArray = { fromSlot }, GetItemStackCount64 = function() return 5 end } } },
        b = { id = "b", containers = { { ItemSlotArray = { fullSlot }, GetItemStackCount64 = function() return 0 end } } },
    } }
    local moved, moveReason = game.move({ currentCamp = "b" }, moveState, { source = "a", destination = "b", item = ingot, amount = 2 }, function() end)
    equal(moved, nil)
    equal(moveReason, "目的地无可用仓库格")
    equal(moveCalls, 0)
end)

test("P1 workforce adapter reads workers, disabled preferences, and Palbox strictly read-only", function()
    local function guid(n) return { A = n, B = 0, C = 0, D = 0 } end
    local function valid() return true end
    local function asName(v) return { ToString = function() return v end } end
    local campGuid, ownerGuid = guid(10), guid(77)
    local campId = game.guid(campGuid)
    local function mockPal(cid, suits, offSuits, san, sick, curSuit)
        local param = {
            IsValid = valid,
            SaveParameter = {
                CharacterID = asName(cid),
                CurrentWorkSuitability = curSuit or 0,
                WorkSuitabilityOptionInfo = { OffWorkSuitabilityList = offSuits or {} },
            },
            GetLevel = function() return 30 end,
            GetRank = function() return 2 end,
            GetSanityValue = function() return san or 95 end,
            GetFullStomachRate = function() return 0.8 end,
            GetWorkerSick = function() return sick or 0 end,
            IsSleeping = function() return false end,
            IsNocturnal = function() return false end,
            IsDead = function() return false end,
            GetWorkSuitabilityRankWithCharacterRank = function(_, s) return suits[s] or 0 end,
            GetPassiveSkillList = function() return { asName("CraftSpeed_up2") } end,
        }
        return { IsValid = valid, GetHandle = function()
            return { IsValid = valid, TryGetIndividualParameter = function() return param end }
        end }
    end
    local campModel = {
        IsValid = valid,
        WorkerDirector = {
            IsValid = valid,
            CharacterContainer = { IsValid = valid, SlotArray = {
                mockPal("VioletFairy", { [3] = 3, [5] = 3 }, { 5 }, 85, 0, 3),
            } },
        },
    }
    local palboxSlots = {}
    for i = 1, 600 do
        palboxSlots[i] = { IsValid = valid, GetHandle = function() return nil end }
    end
    palboxSlots[1] = mockPal("Anubis", { [5] = 4, [8] = 3, [12] = 2 }, {}, 100, 0, 0)
    palboxSlots[600] = mockPal("CatMage", { [5] = 2, [10] = 2, [12] = 2 }, {}, 95, 0, 0)
    local palbox = {
        IsValid = valid,
        OwnerPlayerUId = ownerGuid,
        PageNum = 32,
        SlotNumInPage = 30,
        TargetContainer = { IsValid = valid, SlotArray = palboxSlots },
    }
    local mockDb = {
        IsValid = valid,
        GetLocalizedCharacterName = function(_, name, out) out.OutText = name end,
        MonsterParameterDataTable = {
            IsValid = valid,
            ForEachRow = function(_, cb)
                cb(asName("NPC_Merchant"), { IsUncapturable = true, WorkSuitability_Handcraft = 3, FoodAmount = 2 })
                cb(asName("TestNewPal"), { IsUncapturable = false, WorkSuitability_EmitFlame = 3, FoodAmount = 5, Nocturnal = true })
            end,
        },
    }
    FName = asName
    FindAllOf = function(cls) return cls == "PalPlayerDataPalStorage" and { palbox } or {} end
    StaticFindObject = function()
        return { IsValid = valid, GetDatabaseCharacterParameter = function() return mockDb end }
    end
    local ctx = {
        playerId = game.guid(ownerGuid),
        pawn = {
            IsValid = valid,
            GetCharacterParameterComponent = function()
                return { IsValid = valid, GetLevel = function() return 25 end }
            end,
        },
        playerState = { GuildBelongTo = { BaseCampIds = { campGuid } } },
        baseManager = { TryGetModel = function(_, _, out) out.OutModel = campModel; return true end },
    }
    local snap = { campById = { [campId] = { id = campId, name = "主基地" } } }
    local wf = workforce.scan(ctx, snap)
    equal(wf.readable, true)
    equal(wf.playerLevel, 25)
    equal(wf.totalWorkers, 1)
    equal(wf.camps[campId][1].disabled[5], true)
    equal(#wf.palbox, 2)
    equal(wf.palbox[1].characterId, "Anubis")
    equal(wf.palbox[1].suitabilities[5], 4)
    equal(wf.palbox[2].characterId, "CatMage")
    local byId = {}
    for _, sp in ipairs(wf.species) do byId[sp.id] = sp end
    equal(byId.Anubis_Alt, nil)
    equal(byId.NPC_Merchant, nil)
    assert(byId.LeafMonkey and byId.CatMage and byId.DarkScorpion and byId.HadesBird and byId.TestNewPal)
    equal(byId.DarkScorpion.suits[8], 3)
    equal(byId.DarkScorpion.suits[5], nil)
    equal(byId.HadesBird.suits[12], 3)
end)

test("P1 advisor separates non-labor blockers, prioritizes owned Palbox, respects locks and strategies", function()
    local snap = {
        at = 1000,
        campById = {
            campA = { id = "campA", name = "加工据点" },
            campB = { id = "campB", name = "矿场据点" },
        },
    }
    local wf = {
        readable = true,
        playerLevel = 18,
        camps = {
            campA = {
                { name = "薇莉塔", suitabilities = { [3] = 2, [5] = 2 }, disabled = { [5] = true }, sanity = 90, stomachRate = 0.7, sick = 0, currentSuitability = 3 },
            },
            campB = {
                { name = "阿努比斯-矿场", suitabilities = { [5] = 4, [8] = 3 }, disabled = {}, sanity = 95, stomachRate = 0.8, sick = 0, currentSuitability = 8 },
            },
        },
        palbox = {
            { name = "焰巫狐-终端", suitabilities = { [1] = 2, [5] = 3 }, disabled = {}, sanity = 100, stomachRate = 0.9, sick = 0, currentSuitability = 0 },
        },
    }

    -- Material blocker must NOT claim Pal labor solves it
    local mat = advisor.analyze({ code = "material", message = "缺料", item = ore, goal = product, camp = "campA" }, snap, wf)
    equal(mat.isLaborBottleneck, false)
    assert(mat.nonLaborAdvice:find("原料短缺", 1, true))
    equal(#mat.ownedCandidates, 0)

    -- Handcraft queue blocker with disabled worker in campA -> detects player lock, recommends Palbox first, then campB with opportunity cost
    local hc = advisor.analyze({ code = "queue", message = "原版生产排队中", item = product, goal = product, camp = "campA", suitability = 5 },
        snap, wf, { strategy = "low_cost", advanced = true })
    equal(hc.isLaborBottleneck, true)
    assert(hc.laborFinding:find("手动关闭", 1, true))
    equal(hc.ownedCandidates[1].source, "palbox")
    equal(hc.ownedCandidates[1].pal.name, "焰巫狐-终端")
    equal(hc.ownedCandidates[2].source, "other_camp")
    assert(hc.ownedCandidates[2].opportunityCost:find("采矿", 1, true))
    assert(#hc.cultivation >= 3)

    -- Strategy difference: low_cost vs max_throughput for kindling (1)
    local lowKind = advisor.analyze({ code = "queue", message = "排队", item = ingot, camp = "campA", suitability = 1 },
        snap, wf, { strategy = "low_cost" })
    local maxKind = advisor.analyze({ code = "queue", message = "排队", item = ingot, camp = "campA", suitability = 1 },
        snap, wf, { strategy = "max_throughput" })
    assert(lowKind.speciesCandidates[1].id ~= maxKind.speciesCandidates[1].id)
    equal(maxKind.speciesCandidates[1].id, "Umihebi_Fire")
    equal(maxKind.speciesCandidates[1].longTerm, true)
    equal(advisor.nextStrategy("low_cost"), "balanced")
    equal(advisor.nextStrategy("max_throughput"), "low_cost")
end)

test("P2 dashboard tabs, production alerts, transfer ring buffer, and history series work cleanly", function()
    equal(#dashboard.tabs, 7)
    equal(dashboard.step("overview", 1), "inventory")
    equal(dashboard.step("overview", -1), "settings")
    local snap = {
        camps = { { id = "abcdef123456", name = "据点甲", chestCount = 4, stationCount = 2 } },
        campById = { abcdef123456 = { id = "abcdef123456", name = "据点甲" } },
        chests = 4,
        stations = {
            { id = "111111222222", camp = "abcdef123456", queueItem = product, queueCount = 5, outputCount = 0, energyRequired = true, energyWaiting = true },
        },
        stock = { [product] = 10 },
    }
    local state = { currentCamp = "abcdef123456", itemLabel = function(id) return id end }
    local home = dashboard.home(snap, {}, state)
    equal(home.targetCount, 0)
    equal(home.blocked, false)
    snap.manualReview = { [product] = true }
    state.blocked, state.canAcknowledge = "订单待核验 · " .. product, true
    state.deliveries = { [product] = { kind = "P", item = product, first = "111111222222", second = "abcdef123456", count = 5, manual = true } }
    home = dashboard.home(snap, { [product] = 50, [ore] = 50 }, state)
    equal(home.shortages[1].item, product)
    equal(home.shortageCount, 2)
    equal(home.blocked, true)
    equal(home.reviewSection, "production")
    equal(#home.reviewOrders, 1)
    equal(home.canAcknowledge, true)
    state.canAcknowledge = false
    equal(dashboard.home(snap, { [product] = 50 }, state).canAcknowledge, false)
    snap.incomplete = true
    equal(dashboard.home(snap, { [product] = 50 }, state).shortageCount, 0)
    snap.incomplete = false
    local prod = dashboard.production(snap, {}, function(id) return id end)
    equal(#prod.rows, 1)
    equal(prod.rows[1].warning, true)
    assert(prod.rows[1].cells[6]:find("缺电", 1, true))
    local logBuf = {}
    for i = 1, 25 do
        dashboard.addTransfer(logBuf, { at = 100 + i, item = ingot, source = "abcdef123456", destination = "abcdef123456", amount = i })
    end
    equal(#logBuf, 20)
    equal(logBuf[1].amount, 6)
    local hist = {}
    for i = 1, 3 do
        history.record(hist, { at = 100 + i * 10, stock = { [product] = i * 5 }, storage = { s1 = true } }, { [product] = 50 })
    end
    local lines, series = history.describe(hist, product, "产品")
    equal(#series, 3)
    assert(lines[3]:find("+10", 1, true))
end)

test("Stock history has a fixed bound and resets after gaps, changes and incomplete reads", function()
    local samples = {}
    local state = { stock = { [ore] = 20 }, storage = { a = true } }
    for index = 1, 60 do
        state.at, state.stock[ore] = 100 + 8 * index, index
        history.record(samples, state, { [ore] = 10 })
    end
    equal(#samples, 30)
    equal(history.describe(samples, ore, ore)[3], "232 秒内库存净变化  +29")
    state.incomplete = true
    history.record(samples, state, { [ore] = 10 })
    assert(history.describe(samples, ore, ore)[2]:find("读取中断", 1, true))
    state.incomplete, state.at = false, state.at + 8
    history.record(samples, state, { [ore] = 10 })
    equal(#samples, 1)
    state.storage.b, state.at = true, state.at + 8
    history.record(samples, state, { [ore] = 10 })
    equal(#samples, 1)
    state.at = state.at + 60
    history.record(samples, state, { [ore] = 10 })
    equal(#samples, 1)
end)

test("P2 UMG panel enforces clipping, auto-wrap, real UButton hit targets, and non-overlapping layout across all 7 tabs", function()
    local panel = require("industrial_panel")
    local widgets, objs, nextId = {}, {}, 1
    local inputModeLog = {}
    local function makeObj(cls)
        local id = cls .. "_" .. nextId
        nextId = nextId + 1
        local o = {
            _cls = cls, _full = cls .. " /Transient." .. id, Font = { Size = 14 },
            _hovered = false, _pressed = false, _focused = false, _text = "",
            IsValid = function() return true end,
            GetFullName = function(self) return self._full end,
            SetVisibility = function(self, v) self._vis = v end,
            SetBrushColor = function() end,
            SetBackgroundColor = function() end,
            SetFont = function(self, f) self._fontSize = f.Size end,
            SetColorAndOpacity = function() end,
            SetText = function(self, t) self._text = type(t) == "table" and t.v or tostring(t) end,
            GetText = function(self) return { ToString = function() return self._text end } end,
            SetHintText = function(self, t) self._hint = type(t) == "table" and t.v or tostring(t) end,
            SetIsReadOnly = function() end,
            SetForegroundColor = function() end,
            SetKeyboardFocus = function(self) self._focused = true end,
            HasKeyboardFocus = function(self) return self._focused end,
            IsHovered = function(self) return self._hovered end,
            IsPressed = function(self) return self._pressed end,
            SetClipping = function(self, c) self._clip = c end,
            SetAutoWrapText = function(self, w) self._wrap = w end,
            SetTextOverflowPolicy = function(self, p) self._overflow = p end,
            RemoveFromParent = function() end,
            AddToViewport = function() end,
            ClearChildren = function() widgets = {} end,
            AddChildToCanvas = function(_, child)
                local slot = { _widget = child }
                slot.SetAnchors = function() end
                slot.SetPosition = function(s, p) s.x = p.X + 490; s.y = p.Y + 310 end
                slot.SetSize = function(s, sz) s.w = sz.X; s.h = sz.Y end
                slot.SetZOrder = function() end
                widgets[#widgets + 1] = slot
                return slot
            end,
            SetInputMode_UIOnlyEx = function(_, _, _, _, flush) inputModeLog[#inputModeLog + 1] = "UIOnly:" .. tostring(flush) end,
            SetInputMode_GameOnly = function() inputModeLog[#inputModeLog + 1] = "GameOnly" end,
        }
        objs["/Transient." .. id] = o
        return o
    end
    FText = function(v) return { v = tostring(v) } end
    StaticFindObject = function(path) return objs[path] or makeObj(path) end
    StaticConstructObject = function(cls) return makeObj(cls._cls or "Widget") end

    local snap = {
        at = 1000, chests = 4, stock = { [product] = 10 },
        camps = { { id = "abcdef1234567890abcdef1234567890", name = "据点甲", chestCount = 4, stationCount = 2 } },
        campById = { abcdef1234567890abcdef1234567890 = { id = "abcdef1234567890abcdef1234567890", name = "据点甲" } },
        stations = { { id = "11111122222233333344444455555566", camp = "abcdef1234567890abcdef1234567890", queueItem = product, queueCount = 5, outputCount = 0 } },
    }
    local pc = { IsValid = function() return true end, bShowMouseCursor = false }
    local ctx = { pc = pc, currentCamp = "abcdef1234567890abcdef1234567890" }
    local advDetails = advisor.describe(
        { code = "queue", message = "原版生产排队中", item = product, goal = product, camp = ctx.currentCamp, suitability = 5 },
        ctx, snap, function(_, id) return id end,
        { readable = true, playerLevel = 18, camps = { [ctx.currentCamp] = {} }, palbox = {} },
        { strategy = "balanced", advanced = true, currentCamp = ctx.currentCamp }
    )
    local obs = {}
    for i = 1, 4 do history.record(obs, { at = 100 + i * 10, stock = { [product] = i * 5 }, storage = { s1 = true } }, { [product] = 50 }) end
    local cfg = require("industrial_config").defaults()
    local settings = dashboard.settings(cfg, 7, {}, "Blueprint saved")
    settings.first, settings.last, settings.page, settings.pages = 1, #settings.rows, 1, 1
    local stockRow = { label = "产品", stock = 10, target = 50, queued = 5, buffered = 2, inTransit = "?" }
    local stockRows = {}
    for i = 1, 6 do stockRows[i] = stockRow end
    local transfers = {
        { item = product, amount = 3, source = ctx.currentCamp, destination = ctx.currentCamp, at = 1000 },
    }
    local manualDeliveries = {
        [product] = { kind = "P", item = product, first = "11111122222233333344444455555566", second = ctx.currentCamp, count = 5, manual = true },
    }
    local views = {
        overview = dashboard.home(snap, { [product] = 50 }, {
            currentCamp = ctx.currentCamp, itemLabel = function(id) return id end,
            deliveries = manualDeliveries, blocked = "订单待核验 · " .. product,
            canAcknowledge = true, reviewChecked = true,
        }),
        inventory = { heading = "库存与目标", scope = "goals", query = "产品", rows = stockRows, selection = 2 },
        production = dashboard.production(snap, manualDeliveries, function(id) return id end, "zh-CN", { canAcknowledge = true }),
        logistics = dashboard.logistics(snap, nil, transfers, nil, function(id) return id end),
        advisor = { heading = "帕鲁顾问", advisorEnabled = true, canLiveScan = true, strategyButton = "策略：综合收益", details = advDetails, liveNotice = "手动读取可能导致游戏退出。" },
        history = dashboard.stockTrend(stockRow, history.metrics(obs, product), nil, "zh-CN"),
        settings = settings,
    }
    views.history.itemCount = 2
    for i = 1, 20 do advDetails[#advDetails + 1] = "Additional recommendation " .. tostring(i) end
    for _, tab in ipairs(dashboard.tabs) do
        panel.show(ctx, { tabs = dashboard.tabs, section = tab.id, automation = true, content = views[tab.id] })
        equal(pc.bShowMouseCursor, true)
        local labels, wrappedCount, buttons, textBoxes = {}, 0, 0, 0
        for _, s in ipairs(widgets) do
            assert(s.x >= 0 and s.y >= 0 and s.x + s.w <= 980 and s.y + s.h <= 620, "out of bounds in " .. tab.id)
            local w = s._widget
            if w._cls:find("Button", 1, true) then
                buttons = buttons + 1
                equal(w._vis, 0)
            elseif w._cls:find("EditableTextBox", 1, true) then
                textBoxes = textBoxes + 1
                equal(w._vis, 0)
            elseif w._cls:find("TextBlock", 1, true) then
                equal(w._clip, 1)
                equal(w._vis, 3) -- HitTestInvisible so clicks reach underlying UButton
                for _, other in ipairs(labels) do
                    local overlapX = s.x < other.x + other.w and other.x < s.x + s.w
                    local overlapY = s.y < other.y + other.h and other.y < s.y + s.h
                    assert(not (overlapX and overlapY), tab.id .. ": overlapping labels " .. w._text .. " / " .. other._widget._text)
                end
                labels[#labels + 1] = s
                if w._wrap then wrappedCount = wrappedCount + 1 end
            end
        end
        assert(buttons >= 8, tab.id .. ": expected real clickable UButtons (7 nav + close + page controls)")
        if tab.id == "inventory" then assert(textBoxes == 2, "inventory must expose inline search + target EditableTextBoxes") end
        if tab.id == "advisor" then assert(wrappedCount >= 2) end
    end
    views.advisor.page = 100
    local lastPage = panel.show(ctx, { tabs = dashboard.tabs, section = "advisor", content = views.advisor })
    assert(lastPage > 1 and lastPage < 100)
    panel.close(ctx)
    equal(pc.bShowMouseCursor, false)
    equal(inputModeLog[1], "UIOnly:true")
    equal(inputModeLog[#inputModeLog], "GameOnly")
end)

test("P0 config persistence, hysteresis, camp roles, disabled stations, and inventory summary", function()
    local configMod = require("industrial_config")
    local path = temporaryPath()
    os.remove(path)
    local cfg = configMod.defaults()
    cfg.mode = "vanilla_balanced"
    cfg.language = "en-US"
    cfg.forecastMode = "advisory"
    cfg.spoilerHide = true
    cfg.campRoles[idA] = "smelting"
    cfg.disabledStations[idB] = true
    assert(configMod.write(path, cfg))
    local loaded = configMod.read(path)
    os.remove(path)
    os.remove(path .. ".previous")
    equal(loaded.mode, "vanilla_balanced")
    equal(loaded.language, "en-US")
    equal(loaded.forecastMode, "advisory")
    equal(loaded.spoilerHide, true)
    equal(loaded.campRoles[idA], "smelting")
    equal(loaded.disabledStations[idB], true)

    -- Hysteresis skips micro-shortfall (<15%) when no order is in flight
    local state = chain()
    state.stock[ingot], state.campById.c.stock[ingot] = 20, 20
    state.stock[product] = 95
    local action, why = planner.next(state, { [product] = 100 }, nil, "c", { hysteresisPct = 15 })
    equal(action, nil)
    equal(why.code, "queue")
    -- Disabled station is skipped cleanly
    state.stock[product] = 50
    action, why = planner.next(state, { [product] = 100 }, nil, "c", { disabledStations = { bench = true } })
    equal(action, nil)
    equal(why.message, "设备已被手动禁用")
    -- Inventory summary breakdown & recipe dependency chain
    local sum = planner.inventorySummary(state, { [product] = 100 }, product)
    equal(sum.actual, 50)
    equal(sum.reserved, 50)
    equal(sum.available, 0)
    equal(sum.shortfall, 50)
    assert(planner.dependencyChain(state, product):find("Ingot×2", 1, true))
end)

test("P1 advisor uses owned species, body size, spoiler hide, and real breeding parent passives", function()
    local snap = { at = 1000, campById = { campA = { id = "campA", name = "主基地" } } }
    local wf = {
        readable = true, playerLevel = 15,
        ownedSpecies = { FoxMage = 1, Anubis = 1 },
        camps = { campA = {} },
        palbox = {
            { name = "焰巫狐", characterId = "FoxMage", suitabilities = { [1] = 2, [5] = 3 }, disabled = {}, sanity = 100, stomachRate = 0.9, sick = 0, passives = { "CraftSpeed_up2", "Nocturnal" } },
        },
    }
    local res = advisor.analyze({ code = "queue", message = "排队", item = ingot, camp = "campA", suitability = 1 },
        snap, wf, { strategy = "low_cost", advanced = true, spoilerHide = true })
    assert(#res.speciesCandidates >= 1)
    -- Umihebi_Fire (tier 3, unowned, longTerm for Lv15) must be hidden when spoilerHide=true
    for _, sp in ipairs(res.speciesCandidates) do
        assert(sp.id ~= "Umihebi_Fire", "spoilerHide should mask unowned high-tier species")
    end
    -- Dynamic cultivation must identify the real Palbox parent with CraftSpeed_up2 + Nocturnal
    local cultText = table.concat(res.cultivation, "\n")
    assert(cultText:find("焰巫狐", 1, true) and cultText:find("工匠精神", 1, true) and cultText:find("夜行性", 1, true))
end)

test("P2 real production/consumption/utilization metrics, demand forecasting, i18n, and workforce optimizer", function()
    local forecast = require("industrial_forecast")
    local wfOpt = require("industrial_workforce_opt")
    local i18n = require("industrial_i18n")

    equal(i18n.t("en-US", "tab_overview"), "Home")
    equal(i18n.t("zh-CN", "tab_overview"), "首页")

    -- Simulate 6 samples with 2 deliveries and steady consumption + 1 internal transfer (must not count as consumption!)
    local obs = {}
    local stBusy = { id = "s1", camp = "a", idle = false }
    local stIdle = { id = "s2", camp = "a", idle = true }
    for i = 1, 6 do
        local at = 1000 + i * 10
        local stock = 100 - (i - 1) * 4
        if i == 3 then history.recordDelivery(obs, product, 10, 45, at) end
        if i == 4 then history.recordTransfer(obs, product, 50, at) end
        history.record(obs, { at = at, stock = { [product] = stock }, storage = { s1 = true }, stations = { stBusy, stIdle } }, { [product] = 80 })
    end
    local m = history.metrics(obs, product)
    equal(m.produced, 10)
    equal(m.netDelta, -20)
    equal(m.consumed, 30) -- produced(10) - netDelta(-20) = 30; internal transfer(50) NOT counted!
    equal(m.utilizationPct, 50)
    equal(m.avgLeadSec, 45)

    local est = forecast.estimate(obs, product, 80)
    assert(est.confidence == "medium" or est.confidence == "high")
    assert(est.recommended > 80 and est.recommended <= est.cap)
    local effOff = forecast.effectiveGoals({ [product] = 80 }, obs, "off")
    equal(effOff[product], 80)
    local effOn = forecast.effectiveGoals({ [product] = 80 }, obs, "enabled")
    equal(effOn[product], est.recommended)

    -- Workforce optimizer respects locked jobs (disabled), enforces dwell cooldown, and honors mod conflicts
    local optState = {}
    local wfSnap = {
        readable = true,
        camps = {
            c = {
                { name = "锁定工", characterId = "LockedPal", suitabilities = { [5] = 4 }, disabled = { [5] = true }, sanity = 100, stomachRate = 0.9, sick = 0, currentSuitability = 0 },
                { name = "空闲工", characterId = "FreePal", suitabilities = { [5] = 3 }, disabled = {}, sanity = 100, stomachRate = 0.9, sick = 0, currentSuitability = 0 },
            },
        },
    }
    local snap = { stations = { { id = "b1", camp = "c", idle = false, workSuitability = 5, outputCount = 0 } } }
    local plan1 = wfOpt.plan(snap, wfSnap, nil, optState, { now = 1000, conflicts = { "PalWorkPriority" } })
    equal(plan1.advisoryOnly, true)
    assert(plan1.summary:find("PalWorkPriority", 1, true))
    equal(#plan1.actions, 1)
    equal(plan1.actions[1].palName, "空闲工") -- locked pal was NOT touched!
    -- Within 120s dwell cooldown, should NOT churn again
    local plan2 = wfOpt.plan(snap, wfSnap, nil, optState, { now = 1050 })
    equal(#plan2.actions, 0)
end)

test("P3 simulator, global planner, adaptive feedback, blueprints, and extension API", function()
    local sim = require("industrial_simulator")
    local bp = require("industrial_blueprint")
    local extApi = require("industrial_api")

    -- Upstream material block must NOT claim adding stations/Pals improves throughput
    local matSim = sim.simulate({}, {}, { code = "material", message = "缺料" })
    equal(matSim.feasible, false)
    equal(#matSim.scenarios, 0)

    -- Labor queue bottleneck yields actionable What-If scenarios
    local snap = {
        camps = {
            { id = idA, name = "A", stationCount = 4 },
            { id = idB, name = "B", stationCount = 1 },
        },
        stations = { { id = "s1", camp = idA, workSuitability = 5, recipes = { craft = true } } },
        recipes = { craft = { output = product } },
    }
    local wf = {
        readable = true,
        camps = {
            [idA] = {
                { name = "工1", suitabilities = { [5] = 2 }, disabled = {}, nocturnal = false },
                { name = "工2", suitabilities = { [5] = 2 }, disabled = {}, nocturnal = false },
            },
            [idB] = {},
        },
    }
    local labSim = sim.simulate(snap, wf, { code = "queue", camp = idA, suitability = 5 })
    equal(labSim.feasible, true)
    assert(#labSim.scenarios >= 2)

    local gPlan = sim.globalPlan(snap, { [product] = 50, MissingItem = 10 }, wf, { campRoles = {} })
    assert(#gPlan.recommendations >= 2)

    -- Blueprint export / import / fail-closed validation / merge
    local path = temporaryPath()
    os.remove(path)
    assert(bp.export(path, { [product] = 100, [ingot] = 40 }, { mode = "max_efficiency", forecastMode = "advisory", campRoles = { [idA] = "smelting" } }, "test-bp"))
    local imported = assert(bp.import(path))
    equal(imported.mode, "max_efficiency")
    equal(imported.targets[product], 100)
    equal(imported.campRoles[idA], "smelting")
    local merged = bp.mergeTargets({ [product] = 150, [ore] = 20 }, imported.targets, "merge")
    equal(merged[product], 150)
    equal(merged[ingot], 40)
    equal(merged[ore], 20)
    os.remove(path)
    os.remove(path .. ".previous")

    -- Extension API: fault-isolated subscribers & global handle
    extApi.resetForTests()
    local received = 0
    assert(extApi.subscribe("delivery", function() error("third-party crash") end))
    assert(extApi.subscribe("delivery", function(ev) received = ev.count end))
    extApi.emit("delivery", { count = 7 })
    equal(received, 7)
    extApi.bindProviders({ getStatus = function() return { version = "0.4.0-rc.1" } end })
    local pub = extApi.installGlobal()
    equal(pub.version, "1.0.0")
    equal(_G.PalIndustrialControllerAPI.getStatus().version, "0.4.0-rc.1")
end)

assert(loadfile("PalIndustrialController/Scripts/main.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_config.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_i18n.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_forecast.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_workforce_opt.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_simulator.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_blueprint.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_api.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_panel.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_workforce.lua"))
assert(loadfile("PalIndustrialController/Scripts/industrial_dashboard.lua"))
print(("%d regression cases passed (%s)"):format(passed, _VERSION))
