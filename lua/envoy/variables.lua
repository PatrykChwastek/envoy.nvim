local M = {}

local BUILTINS = {
    ["$timestamp"]    = function() return tostring(os.time()) end,
    ["$isoTimestamp"] = function() return os.date("!%Y-%m-%dT%H:%M:%SZ") end,
    ["$randomInt"]    = function() return tostring(math.random(0, 1000)) end,
    ["$guid"] = function()
        math.randomseed(os.time())
        local t = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
        return t:gsub("[xy]", function(c)
            local v = c == "x" and math.random(0, 15) or math.random(8, 11)
            return string.format("%x", v)
        end)
    end,
}

--- Substitute all {{name}} references in str.
---@param str string
---@param vars table<string, string>
---@return string
function M.resolve(str, vars)
    return str:gsub("{{%s*(.-)%s*}}", function(name)
        if BUILTINS[name] then return BUILTINS[name]() end
        return vars[name] or ("{{" .. name .. "}}")
    end)
end

--- Load http-client.env.json or flat .env file.
--- JSON format: { "dev": { "baseUrl": "..." } }  or flat { "baseUrl": "..." }
---@param path string
---@param env_name? string
---@return table<string, string>
function M.load_env_file(path, env_name)
    local lines = vim.fn.readfile(path)
    if not lines or #lines == 0 then return {} end
    local text = table.concat(lines, "\n")

    local ok, data = pcall(vim.fn.json_decode, text)
    if ok and type(data) == "table" then
        local env = env_name or "dev"
        local source = data[env] or data
        if type(source) == "table" then
            local result = {}
            for k, v in pairs(source) do
                if type(v) ~= "table" then result[k] = tostring(v) end
            end
            return result
        end
    end

    -- Fallback: KEY=value lines
    local result = {}
    for _, line in ipairs(lines) do
        local k, v = line:match("^([%w_]+)=(.+)$")
        if k then result[k] = v end
    end
    return result
end

return M
