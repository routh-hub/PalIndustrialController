local journal = require("industrial_journal")

local M = {}

M.modes = { "vanilla_balanced", "automation", "max_efficiency" }

M.modePresets = {
    vanilla_balanced = { maxBatch = 10, scanSeconds = 10, hysteresisPct = 15 },
    automation = { maxBatch = 20, scanSeconds = 8, hysteresisPct = 0 },
    max_efficiency = { maxBatch = 50, scanSeconds = 6, hysteresisPct = 0 },
}

M.campRoles = { "general", "mining", "smelting", "manufacturing", "farming" }

M.forecastModes = { "off", "advisory", "enabled" }

function M.defaults()
    return {
        mode = "automation",
        language = "zh-CN",
        advisorEnabled = true,
        advisorStrategy = "balanced",
        advisorAdvanced = false,
        spoilerHide = false,
        forecastMode = "off",
        workforceOptEnabled = true,
        adaptiveEnabled = true,
        campRoles = {},
        disabledStations = {},
    }
end

function M.preset(cfg)
    return M.modePresets[cfg and cfg.mode] or M.modePresets.automation
end

function M.nextInList(list, current)
    for i, v in ipairs(list) do
        if v == current then return list[(i % #list) + 1] end
    end
    return list[1]
end

local function parseBool(v, fallback)
    if v == "1" or v == "true" then return true end
    if v == "0" or v == "false" then return false end
    return fallback
end

local function validChoice(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

function M.read(path)
    local cfg = M.defaults()
    local file = io.open(path, "rb") or io.open(path .. ".previous", "rb")
    if not file then return cfg end
    local header = file:read("*l")
    if header ~= "PalIndustrialConfig\t1" then
        file:close()
        return cfg, "配置文件版本不兼容，已回退默认配置"
    end
    for line in file:lines() do
        local key, value = line:match("^([%w_%.:%-]+)\t([^\r\n]*)\r?$")
        if key and value then
            if key == "mode" and validChoice(M.modes, value) then
                cfg.mode = value
            elseif key == "language" and (value == "zh-CN" or value == "en-US") then
                cfg.language = value
            elseif key == "advisorEnabled" then
                cfg.advisorEnabled = parseBool(value, true)
            elseif key == "advisorStrategy" and (value == "low_cost" or value == "balanced" or value == "max_throughput") then
                cfg.advisorStrategy = value
            elseif key == "advisorAdvanced" then
                cfg.advisorAdvanced = parseBool(value, false)
            elseif key == "spoilerHide" then
                cfg.spoilerHide = parseBool(value, false)
            elseif key == "forecastMode" and validChoice(M.forecastModes, value) then
                cfg.forecastMode = value
            elseif key == "workforceOptEnabled" then
                cfg.workforceOptEnabled = parseBool(value, true)
            elseif key == "adaptiveEnabled" then
                cfg.adaptiveEnabled = parseBool(value, true)
            else
                local campId = key:match("^role%.(%x+)$")
                if campId and validChoice(M.campRoles, value) then
                    cfg.campRoles[campId] = value
                end
                local stId = key:match("^disable%.(%x+)$")
                if stId and parseBool(value, false) then
                    cfg.disabledStations[stId] = true
                end
            end
        end
    end
    file:close()
    return cfg
end

function M.write(path, cfg)
    local lines = {
        "PalIndustrialConfig\t1",
        "mode\t" .. tostring(cfg.mode or "automation"),
        "language\t" .. tostring(cfg.language or "zh-CN"),
        "advisorEnabled\t" .. (cfg.advisorEnabled ~= false and "1" or "0"),
        "advisorStrategy\t" .. tostring(cfg.advisorStrategy or "balanced"),
        "advisorAdvanced\t" .. (cfg.advisorAdvanced == true and "1" or "0"),
        "spoilerHide\t" .. (cfg.spoilerHide == true and "1" or "0"),
        "forecastMode\t" .. tostring(cfg.forecastMode or "off"),
        "workforceOptEnabled\t" .. (cfg.workforceOptEnabled ~= false and "1" or "0"),
        "adaptiveEnabled\t" .. (cfg.adaptiveEnabled ~= false and "1" or "0"),
    }
    local roleLines = {}
    for campId, role in pairs(cfg.campRoles or {}) do
        if campId:match("^%x+$") and validChoice(M.campRoles, role) and role ~= "general" then
            roleLines[#roleLines + 1] = "role." .. campId .. "\t" .. role
        end
    end
    table.sort(roleLines)
    for _, l in ipairs(roleLines) do lines[#lines + 1] = l end

    local disLines = {}
    for stId, disabled in pairs(cfg.disabledStations or {}) do
        if disabled and stId:match("^%x+$") then
            disLines[#disLines + 1] = "disable." .. stId .. "\t1"
        end
    end
    table.sort(disLines)
    for _, l in ipairs(disLines) do lines[#lines + 1] = l end

    return journal.replace(path, lines)
end

return M
