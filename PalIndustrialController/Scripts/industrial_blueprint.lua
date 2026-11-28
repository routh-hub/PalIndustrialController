local journal = require("industrial_journal")
local configMod = require("industrial_config")

local M = {}

local HEADER = "PalIndustrialBlueprint\t1"

function M.export(path, goals, cfg, name)
    local lines = {
        HEADER,
        "meta\tname\t" .. tostring(name or "default"):gsub("[\t\r\n]", " "),
        "meta\texportedAt\t" .. tostring(os.time()),
    }
    if cfg then
        lines[#lines + 1] = "config\tmode\t" .. tostring(cfg.mode or "automation")
        lines[#lines + 1] = "config\tforecastMode\t" .. tostring(cfg.forecastMode or "off")
        local roleKeys = {}
        for campId in pairs(cfg.campRoles or {}) do roleKeys[#roleKeys + 1] = campId end
        table.sort(roleKeys)
        for _, campId in ipairs(roleKeys) do
            local role = cfg.campRoles[campId]
            if campId:match("^%x+$") and role and role ~= "general" then
                lines[#lines + 1] = "role\t" .. campId .. "\t" .. role
            end
        end
    end
    local items = {}
    for item in pairs(goals or {}) do items[#items + 1] = item end
    table.sort(items)
    for _, item in ipairs(items) do
        local target = goals[item]
        if item:match("^[%w_%-]+$") and type(target) == "number" and target >= 1 and target <= 1000000 then
            lines[#lines + 1] = "target\t" .. item .. "\t" .. tostring(math.floor(target))
        end
    end
    return journal.replace(path, lines)
end

function M.import(path)
    local file = io.open(path, "rb")
    if not file then return nil, "未找到蓝图文件" end
    local header = file:read("*l")
    if header ~= HEADER then
        file:close()
        return nil, "蓝图文件格式或版本不兼容"
    end
    local bp = { meta = {}, targets = {}, campRoles = {} }
    for line in file:lines() do
        if line ~= "" then
            local kind, k, v = line:match("^([%w_]+)\t([%w_%-]+)\t([^\r\n]*)\r?$")
            if not kind then
                file:close()
                return nil, "蓝图行格式损坏"
            end
            if kind == "meta" then
                bp.meta[k] = v
            elseif kind == "config" then
                if k == "mode" and configMod.modePresets[v] then bp.mode = v end
                if k == "forecastMode" and (v == "off" or v == "advisory" or v == "enabled") then bp.forecastMode = v end
            elseif kind == "role" then
                if k:match("^%x+$") then bp.campRoles[k] = v end
            elseif kind == "target" then
                local num = tonumber(v)
                if not num or num < 1 or num > 1000000 or math.type(num) ~= "integer" then
                    file:close()
                    return nil, "蓝图目标数量无效：" .. tostring(k)
                end
                bp.targets[k] = num
            else
                file:close()
                return nil, "未知蓝图字段类型：" .. tostring(kind)
            end
        end
    end
    file:close()
    return bp
end

function M.mergeTargets(existing, incoming, strategy)
    local result = {}
    if strategy ~= "replace" then
        for k, v in pairs(existing or {}) do result[k] = v end
    end
    for k, v in pairs(incoming or {}) do
        if strategy == "replace" then
            result[k] = v
        else
            result[k] = math.max(result[k] or 0, v)
        end
    end
    return result
end

return M
