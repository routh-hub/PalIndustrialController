local game = require("industrial_game")

local M = {}

-- Verified against CXXHeaderDump/Pal_enums.hpp (EPalWorkSuitability)
M.suitabilityNames = {
    [1] = "生火",
    [2] = "浇水",
    [3] = "播种",
    [4] = "发电",
    [5] = "手工作业",
    [6] = "采集",
    [7] = "伐木",
    [8] = "采矿",
    [9] = "采油",
    [10] = "制药",
    [11] = "冷却",
    [12] = "搬运",
    [13] = "牧场",
}

-- Verified against CXXHeaderDump/Pal_enums.hpp (EPalBaseCampWorkerSickType)
M.sickNames = {
    [0] = "健康",
    [1] = "感冒",
    [2] = "扭伤",
    [3] = "暴食",
    [4] = "胃溃疡",
    [5] = "骨折",
    [6] = "虚弱",
    [7] = "抑郁",
    [8] = "不安",
}

local nameCache = {}
local speciesCache

-- Verified vanilla Palworld base-suitability baseline (fallback if DataTable iteration is unavailable).
-- Capture regions & exact spawn odds are intentionally NOT fabricated here.
local baselineSpecies = {
    { id = "FoxMage", name = "焰巫狐", tier = 1, nocturnal = false, food = 3, size = "small", suits = { [1] = 2, [5] = 3, [12] = 2 }, note = "早中期手工与生火兼顾，请对照图鉴分布获取" },
    { id = "FireKirin", name = "火麒麟", tier = 2, nocturnal = false, food = 7, size = "large", suits = { [1] = 2, [7] = 1 }, note = "中期生火候补，请对照图鉴分布获取" },
    { id = "FlameBambi", name = "燎火鹿", tier = 1, nocturnal = false, food = 3, size = "small", suits = { [1] = 1 }, note = "前期低成本生火，请对照图鉴分布获取" },
    { id = "Umihebi_Fire", name = "腾炎龙", tier = 3, nocturnal = false, food = 7, size = "large", suits = { [1] = 4 }, note = "高阶纯生火专精，体积较大注意熔炉通道" },
    { id = "Anubis", name = "阿努比斯", tier = 2, nocturnal = false, food = 6, size = "small", suits = { [5] = 4, [8] = 3, [12] = 2 }, note = "高阶手工作业核心，兼顾采矿与搬运" },
    { id = "Monkey", name = "新叶猿", tier = 1, nocturnal = false, food = 2, size = "small", suits = { [3] = 1, [5] = 1, [7] = 1, [12] = 1, [6] = 1 }, note = "前期低食量多面手，容易获取" },
    { id = "SweetsSheep", name = "棉花糖", tier = 1, nocturnal = false, food = 2, size = "small", suits = { [5] = 1, [13] = 1 }, note = "前期低成本手工候补" },
    { id = "CatMage", name = "暗巫猫", tier = 2, nocturnal = true, food = 4, size = "small", suits = { [5] = 2, [10] = 2, [12] = 2 }, note = "夜行手工与搬运，夜间不中断" },
    { id = "CatVampire", name = "夜幕魔蝠", tier = 2, nocturnal = true, food = 5, size = "medium", suits = { [6] = 2, [8] = 2, [12] = 2 }, note = "夜行搬运与采矿，夜间持续运行" },
    { id = "BirdDragon", name = "烽歌龙", tier = 1, nocturnal = true, food = 6, size = "medium", suits = { [1] = 2, [12] = 3 }, note = "夜行搬运兼生火，中前期实用" },
    { id = "LeafMonkey", name = "翠叶鼠", tier = 1, nocturnal = false, food = 1, size = "small", suits = { [3] = 1, [5] = 1, [6] = 1, [7] = 1, [10] = 1 }, note = "前期极低成本，适合初期工作台" },
    { id = "ThunderDragonMan", name = "波鲁杰克斯", tier = 3, nocturnal = false, food = 7, size = "medium", suits = { [4] = 4, [5] = 2, [12] = 3 }, note = "高阶发电与搬运核心，后期推荐" },
    { id = "ElecCat", name = "伏特喵", tier = 1, nocturnal = false, food = 2, size = "small", suits = { [4] = 1, [5] = 1, [12] = 1 }, note = "前期低成本发电与手工" },
    { id = "RaijinDaughter", name = "雷鸣童子", tier = 1, nocturnal = false, food = 2, size = "small", suits = { [4] = 1, [5] = 1, [12] = 1 }, note = "前期小型发电，不易卡地形" },
    { id = "ElecPanda", name = "暴电熊", tier = 2, nocturnal = false, food = 7, size = "large", suits = { [4] = 3, [5] = 2, [7] = 2, [12] = 3 }, note = "中期主力发电与搬运" },
    { id = "Umihebi", name = "覆海龙", tier = 3, nocturnal = false, food = 7, size = "large", suits = { [2] = 4 }, note = "高阶纯浇水专精，注意设备周边通道" },
    { id = "Penguin", name = "企丸丸", tier = 1, nocturnal = false, food = 2, size = "small", suits = { [2] = 1, [5] = 1, [11] = 1, [12] = 1 }, note = "前期低成本浇水与搬运" },
    { id = "WeaselDragon", name = "疾旋鼬", tier = 1, nocturnal = false, food = 3, size = "small", suits = { [6] = 1, [11] = 1 }, note = "前期小型冷却" },
    { id = "Yeti", name = "白绒雪怪", tier = 2, nocturnal = false, food = 7, size = "large", suits = { [5] = 2, [7] = 3, [11] = 2, [12] = 4 }, note = "高搬运等级，适合大宗仓库搬运" },
    { id = "BluePlatypus", name = "冲浪鸭", tier = 1, nocturnal = false, food = 2, size = "small", suits = { [2] = 1, [5] = 1, [12] = 1 }, note = "前期低成本浇水/搬运" },
    { id = "HerculesBeetle", name = "碎岩龟", tier = 2, nocturnal = false, food = 4, size = "medium", suits = { [8] = 3 }, note = "中期采矿专精，不分散岗位" },
    { id = "BlackMetalDragon", name = "魔渊龙", tier = 3, nocturnal = true, food = 9, size = "large", suits = { [8] = 4, [5] = 1 }, note = "高阶夜行采矿，注意饱食与通道" },
    { id = "FlowerRabbit", name = "踏春兔", tier = 1, nocturnal = false, food = 3, size = "small", suits = { [3] = 2, [5] = 2, [6] = 1, [7] = 1, [12] = 2 }, note = "中前期小型多面手，搬运与手工均衡" },
    { id = "VioletFairy", name = "薇莉塔", tier = 2, nocturnal = false, food = 3, size = "small", suits = { [3] = 2, [5] = 2, [6] = 2, [10] = 3, [12] = 2 }, note = "制药与手工兼顾，食量适中" },
    { id = "LilyQueen", name = "百合女王", tier = 3, nocturnal = false, food = 6, size = "medium", suits = { [3] = 4, [5] = 3, [6] = 2, [10] = 3 }, note = "高阶播种/手工/制药兼顾" },
    { id = "Baphomet", name = "炎魔羊", tier = 2, nocturnal = true, food = 5, size = "medium", suits = { [1] = 2, [5] = 2, [8] = 1, [12] = 2 }, note = "夜行生火与手工，夜间不停工" },
    { id = "Horus", name = "荷鲁斯", tier = 3, nocturnal = false, food = 7, size = "medium", suits = { [1] = 3, [12] = 3 }, note = "高阶生火与搬运，移动速度快" },
    { id = "DarkScorpion", name = "冥铠蝎", tier = 3, nocturnal = true, food = 8, size = "large", suits = { [7] = 2, [8] = 3 }, note = "高阶夜行采矿，请对照图鉴分布获取" },
    { id = "HadesBird", name = "雷冥鸟", tier = 2, nocturnal = true, food = 7, size = "medium", suits = { [12] = 3 }, note = "夜行高速搬运专精，夜间持续清运成品" },
}

local function localizedSpeciesName(db, characterId)
    if not characterId or characterId == "" then return "未知帕鲁" end
    local clean = characterId:gsub("^BOSS_", ""):gsub("^GYM_", "")
    if nameCache[clean] then return nameCache[clean] end
    if game.valid(db) then
        local ok, label = pcall(function()
            local out = {}
            db:GetLocalizedCharacterName(FName(clean), out)
            local text = out.OutText or out.outText
            if text then return text:ToString() end
        end)
        if ok and label and label ~= "" and label ~= "None" then
            nameCache[clean] = label
            return label
        end
    end
    for _, entry in ipairs(baselineSpecies) do
        if entry.id == clean then
            nameCache[clean] = entry.name
            return entry.name
        end
    end
    return clean
end

local function readDisabledSuitabilities(saveParam)
    local disabled = {}
    pcall(function()
        local pref = saveParam.WorkSuitabilityOptionInfo
        if pref and pref.OffWorkSuitabilityList then
            local list = pref.OffWorkSuitabilityList
            for i = 1, #list do
                local suit = list[i]
                if type(suit) == "number" and suit >= 1 and suit <= 13 then
                    disabled[suit] = true
                end
            end
        end
    end)
    return disabled
end

local function readPalParameter(param, db, location, campId)
    if not game.valid(param) then return nil end
    local pal = {
        location = location,
        camp = campId,
        characterId = "Unknown",
        name = "未知帕鲁",
        level = 1,
        rank = 1,
        sanity = 100,
        stomachRate = 1,
        sick = 0,
        sleeping = false,
        nocturnal = false,
        dead = false,
        currentSuitability = 0,
        suitabilities = {},
        disabled = {},
        passives = {},
    }
    pcall(function()
        local sp = param.SaveParameter
        if sp then
            local cid = game.name(sp.CharacterID)
            if cid then pal.characterId = cid end
            if type(sp.CurrentWorkSuitability) == "number" then
                pal.currentSuitability = sp.CurrentWorkSuitability
            end
            pal.disabled = readDisabledSuitabilities(sp)
        end
    end)
    pal.name = localizedSpeciesName(db, pal.characterId)
    pcall(function() pal.level = param:GetLevel() end)
    pcall(function() pal.rank = param:GetRank() end)
    pcall(function() pal.sanity = param:GetSanityValue() end)
    pcall(function() pal.stomachRate = param:GetFullStomachRate() end)
    pcall(function() pal.sick = param:GetWorkerSick() end)
    pcall(function() pal.sleeping = param:IsSleeping() == true end)
    pcall(function() pal.nocturnal = param:IsNocturnal() == true end)
    pcall(function() pal.dead = param:IsDead() == true end)
    for suit = 1, 13 do
        local ok, rank = pcall(function() return param:GetWorkSuitabilityRankWithCharacterRank(suit) end)
        if ok and type(rank) == "number" and rank > 0 then
            pal.suitabilities[suit] = rank
        end
    end
    pcall(function()
        local list = param:GetPassiveSkillList()
        if list then
            for i = 1, #list do
                local skill = game.name(list[i])
                if skill then pal.passives[#pal.passives + 1] = skill end
            end
        end
    end)
    return pal
end

local function readContainerPals(container, db, location, campId, maxSlots)
    local result = {}
    if not game.valid(container) then return result end
    local ok, slots = pcall(function() return container.SlotArray end)
    if not ok or not slots then return result end
    local limit = math.min(#slots, maxSlots or 64)
    for i = 1, limit do
        local slot = slots[i]
        if game.valid(slot) then
            local okH, handle = pcall(function() return slot:GetHandle() end)
            if okH and game.valid(handle) then
                local okP, param = pcall(function() return handle:TryGetIndividualParameter() end)
                if okP and game.valid(param) then
                    local pal = readPalParameter(param, db, location, campId)
                    if pal then result[#result + 1] = pal end
                end
            end
        end
    end
    return result
end

local function loadSpeciesCatalog(db)
    if speciesCache then return speciesCache end
    local catalog = {}
    local seen = {}
    for _, entry in ipairs(baselineSpecies) do
        local copy = {
            id = entry.id,
            name = localizedSpeciesName(db, entry.id),
            tier = entry.tier,
            nocturnal = entry.nocturnal,
            food = entry.food,
            size = entry.size or "medium",
            suits = entry.suits,
            note = entry.note,
            source = "builtin_verified",
        }
        catalog[#catalog + 1] = copy
        seen[entry.id] = true
    end
    -- Supplement from live MonsterParameterDataTable when UE4SS supports ForEachRow.
    if game.valid(db) then
        pcall(function()
            local dt = db.MonsterParameterDataTable
            if game.valid(dt) and dt.ForEachRow then
                local suitFields = {
                    [1] = "WorkSuitability_EmitFlame",
                    [2] = "WorkSuitability_Watering",
                    [3] = "WorkSuitability_Seeding",
                    [4] = "WorkSuitability_GenerateElectricity",
                    [5] = "WorkSuitability_Handcraft",
                    [6] = "WorkSuitability_Collection",
                    [7] = "WorkSuitability_Deforest",
                    [8] = "WorkSuitability_Mining",
                    [9] = "WorkSuitability_OilExtraction",
                    [10] = "WorkSuitability_ProductMedicine",
                    [11] = "WorkSuitability_Cool",
                    [12] = "WorkSuitability_Transport",
                    [13] = "WorkSuitability_MonsterFarm",
                }
                local added = 0
                dt:ForEachRow(function(rowName, row)
                    if added >= 1000 then return end
                    local id = type(rowName) == "string" and rowName or (game.name(rowName) or tostring(rowName))
                    if seen[id] or id:find("^BOSS_") or id:find("^GYM_") or id:find("^RAID_") or id:find("^PREDATOR_") then
                        return
                    end
                    if row.IsUncapturable == true or row.IsBoss == true or row.IsTowerBoss == true or row.IsRaidBoss == true then
                        return
                    end
                    local suits, maxSuit = {}, 0
                    for sIdx, field in pairs(suitFields) do
                        local v = row[field]
                        if type(v) == "number" and v > 0 then
                            suits[sIdx] = v
                            if v > maxSuit then maxSuit = v end
                        end
                    end
                    if maxSuit > 0 then
                        local food = type(row.FoodAmount) == "number" and row.FoodAmount or 4
                        local noct = row.Nocturnal == true
                        local radius = type(row.MeshCapsuleRadius) == "number" and row.MeshCapsuleRadius or 55
                        local size = radius >= 90 and "large" or (radius <= 45 and "small" or "medium")
                        local tier = maxSuit >= 4 and 3 or (maxSuit >= 3 and 2 or 1)
                        catalog[#catalog + 1] = {
                            id = id,
                            name = localizedSpeciesName(db, id),
                            tier = tier,
                            nocturnal = noct,
                            food = food,
                            size = size,
                            suits = suits,
                            note = "来自本机游戏实时种族表，捕捉分布请查阅游戏内图鉴",
                            source = "live_db",
                        }
                        seen[id] = true
                        added = added + 1
                    end
                end)
            end
        end)
    end
    speciesCache = catalog
    return catalog
end

function M.baselineCatalog()
    return baselineSpecies
end

local function cleanSpeciesId(characterId)
    if not characterId then return nil end
    return characterId:gsub("^BOSS_", ""):gsub("^GYM_", "")
end

function M.detectConflicts(modsParentDir, extraMods)
    local found = {}
    if not modsParentDir then return found end
    local candidates = { "PalWorkPriority", "PalAutoAssign", "AutoBaseManager" }
    if extraMods then
        for _, m in ipairs(extraMods) do candidates[#candidates + 1] = m end
    end
    for _, name in ipairs(candidates) do
        local f = io.open(modsParentDir .. name .. "/enabled.txt", "rb")
        if f then
            f:close()
            found[#found + 1] = name
        end
    end
    return found
end

-- Strictly read-only, on-demand workforce & Palbox snapshot.
-- Never writes to any game object, Pal parameter, or save file.
function M.scan(context, snapshot)
    local result = {
        at = os.time(),
        camps = {},
        palbox = {},
        ownedSpecies = {},
        totalWorkers = 0,
        playerLevel = nil,
        species = baselineSpecies,
        readable = false,
    }
    if not context or not snapshot then return result end

    local db
    pcall(function()
        local utility = StaticFindObject("/Script/Pal.Default__PalUtility")
        if game.valid(utility) and utility.GetDatabaseCharacterParameter then
            db = utility:GetDatabaseCharacterParameter(context.pc)
        end
    end)
    pcall(function()
        local pawn = context.pawn
        if not game.valid(pawn) and game.valid(context.pc) and context.pc.K2_GetPawn then
            pawn = context.pc:K2_GetPawn()
        end
        if game.valid(pawn) and pawn.GetCharacterParameterComponent then
            local comp = pawn:GetCharacterParameterComponent()
            if game.valid(comp) then
                local lv = comp.GetLevel and comp:GetLevel()
                if type(lv) == "number" and lv > 0 then
                    result.playerLevel = lv
                elseif comp.GetIndividualParameter then
                    local ip = comp:GetIndividualParameter()
                    if game.valid(ip) and ip.GetLevel then
                        lv = ip:GetLevel()
                        if type(lv) == "number" and lv > 0 then result.playerLevel = lv end
                    end
                end
            end
        end
        if not result.playerLevel then
            local ps = context.playerState
            if game.valid(ps) and ps.GetPlayerLevel then
                local lv = ps:GetPlayerLevel()
                if type(lv) == "number" and lv > 0 then result.playerLevel = lv end
            end
        end
    end)

    local baseIds = context.playerState and context.playerState.GuildBelongTo
        and context.playerState.GuildBelongTo.BaseCampIds
    if baseIds then
        for i = 1, #baseIds do
            local guid = baseIds[i]
            local id = game.guid(guid)
            if id and snapshot.campById[id] then
                local out = {}
                local found = context.baseManager:TryGetModel(guid, out)
                local model = out.OutModel
                if found and game.valid(model) then
                    local wd = model.WorkerDirector
                    local workers = {}
                    if game.valid(wd) and game.valid(wd.CharacterContainer) then
                        workers = readContainerPals(wd.CharacterContainer, db, "camp", id, 64)
                        result.readable = true
                    end
                    result.camps[id] = workers
                    result.totalWorkers = result.totalWorkers + #workers
                end
            end
        end
    end

    pcall(function()
        local storages = FindAllOf("PalPlayerDataPalStorage") or {}
        for i = 1, #storages do
            local storage = storages[i]
            if game.valid(storage) and game.guid(storage.OwnerPlayerUId) == context.playerId then
                local tc = storage.TargetContainer
                if game.valid(tc) then
                    local capacity = 960
                    pcall(function()
                        if type(storage.PageNum) == "number" and type(storage.SlotNumInPage) == "number" then
                            local total = storage.PageNum * storage.SlotNumInPage
                            if total > 0 then capacity = math.min(total, 1920) end
                        end
                    end)
                    result.palbox = readContainerPals(tc, db, "palbox", nil, capacity)
                    break
                end
            end
        end
    end)

    for _, workers in pairs(result.camps) do
        for _, pal in ipairs(workers) do
            local sid = cleanSpeciesId(pal.characterId)
            if sid then result.ownedSpecies[sid] = (result.ownedSpecies[sid] or 0) + 1 end
        end
    end
    for _, pal in ipairs(result.palbox) do
        local sid = cleanSpeciesId(pal.characterId)
        if sid then result.ownedSpecies[sid] = (result.ownedSpecies[sid] or 0) + 1 end
    end

    result.species = loadSpeciesCatalog(db)
    return result
end

return M
