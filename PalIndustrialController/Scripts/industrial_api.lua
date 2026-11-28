-- P3 Open Ecosystem Extension API (versioned, read-only & fault-isolated).
-- Third-party UE4SS Lua mods can inspect state or subscribe to lifecycle events
-- via _G.PalIndustrialControllerAPI without breaking P0 core guarantees.
local M = {}

M.API_VERSION = "1.0.0"

local subscribers = {
    snapshot = {},
    plan = {},
    delivery = {},
    transfer = {},
}
local extraConflictMods = {}
local speciesSupplements = {}
local providers = {}

function M.bindProviders(p)
    providers = p or {}
end

function M.subscribe(event, fn)
    if not subscribers[event] or type(fn) ~= "function" then return false end
    local list = subscribers[event]
    if #list >= 32 then return false end
    list[#list + 1] = fn
    return true
end

function M.emit(event, payload)
    local list = subscribers[event]
    if not list then return end
    for i = 1, #list do
        pcall(list[i], payload)
    end
end

function M.registerConflictMod(modName)
    if type(modName) ~= "string" or modName == "" or #extraConflictMods >= 32 then return false end
    extraConflictMods[#extraConflictMods + 1] = modName
    return true
end

function M.extraConflicts()
    return extraConflictMods
end

function M.registerSpeciesSupplement(entry)
    if type(entry) ~= "table" or type(entry.id) ~= "string" or type(entry.suits) ~= "table" then return false end
    if #speciesSupplements >= 128 then return false end
    speciesSupplements[#speciesSupplements + 1] = entry
    return true
end

function M.speciesSupplements()
    return speciesSupplements
end

function M.publicHandle()
    return {
        version = M.API_VERSION,
        subscribe = M.subscribe,
        registerConflictMod = M.registerConflictMod,
        registerSpeciesSupplement = M.registerSpeciesSupplement,
        getStatus = function()
            return providers.getStatus and providers.getStatus() or nil
        end,
        getMetrics = function(item)
            return providers.getMetrics and providers.getMetrics(item) or nil
        end,
        simulate = function(scenario)
            return providers.simulate and providers.simulate(scenario) or nil
        end,
    }
end

function M.installGlobal()
    _G.PalIndustrialControllerAPI = M.publicHandle()
    return _G.PalIndustrialControllerAPI
end

function M.resetForTests()
    for k in pairs(subscribers) do subscribers[k] = {} end
    extraConflictMods = {}
    speciesSupplements = {}
    providers = {}
end

return M
