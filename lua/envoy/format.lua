local M = {}

local function has_jq()
    return vim.fn.executable("jq") == 1
end

--- Run jq on a string, return formatted output or nil + error message.
local function jq_format(text)
    local result = vim.fn.system({ "jq", "." }, text)
    if vim.v.shell_error ~= 0 then
        return nil, vim.trim(result)
    end
    return vim.trim(result), nil
end

--- Format JSON using built-in formatter (no jq required).
local function builtin_format(text)
    local ok, data = pcall(vim.fn.json_decode, text)
    if not ok then return nil, "invalid JSON" end
    return require("envoy.elastic").pretty_json(data), nil
end

--- Format the JSON body of the request under the cursor in-place.
function M.format_body()
    local bufnr  = vim.api.nvim_get_current_buf()
    local lnum   = vim.fn.line(".")
    local lines  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    local parser   = require("envoy.parser")
    local requests = parser.parse(lines)
    local req      = parser.request_at_line(requests, lnum)

    if not req or not req.body_line_start then
        vim.notify("[envoy] No JSON body found at cursor", vim.log.levels.WARN)
        return
    end

    local body_lines = vim.api.nvim_buf_get_lines(
        bufnr, req.body_line_start - 1, req.body_line_end, false)
    local body = table.concat(body_lines, "\n")

    local formatted, err
    if has_jq() then
        formatted, err = jq_format(body)
    else
        formatted, err = builtin_format(body)
    end

    if err then
        vim.notify("[envoy] Format error: " .. err, vim.log.levels.ERROR)
        return
    end

    local new_lines = vim.split(formatted, "\n")
    vim.api.nvim_buf_set_lines(bufnr, req.body_line_start - 1, req.body_line_end, false, new_lines)
end

--- formatexpr — called by gq / = on a line range.
--- Returns 0 if handled, 1 to fall back to Neovim default.
function M.formatexpr()
    -- Only engage when inside a JSON-looking region
    local start_lnum = vim.v.lnum
    local end_lnum   = vim.v.lnum + vim.v.count - 1
    local lines      = vim.api.nvim_buf_get_lines(0, start_lnum - 1, end_lnum, false)
    local text       = table.concat(lines, "\n")

    if not vim.trim(text):match("^[{%[]") then return 1 end

    local formatted, err
    if has_jq() then
        formatted, err = jq_format(text)
    else
        formatted, err = builtin_format(text)
    end

    if err then return 1 end

    local new_lines = vim.split(formatted, "\n")
    vim.api.nvim_buf_set_lines(0, start_lnum - 1, end_lnum, false, new_lines)
    return 0
end

return M
