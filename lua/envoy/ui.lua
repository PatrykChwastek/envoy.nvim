local M = {}

local BUF_NAME = "__envoy__"
local _buf     = nil
local _win     = nil

local function get_or_create_buf()
    if _buf and vim.api.nvim_buf_is_valid(_buf) then return _buf end
    _buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(_buf, BUF_NAME)
    vim.bo[_buf].buftype   = "nofile"
    vim.bo[_buf].buflisted = false
    vim.bo[_buf].swapfile  = false
    vim.bo[_buf].filetype  = "envoy-result"
    require("envoy.syntax").apply_result(_buf)

    local o    = { buffer = _buf, silent = true }
    local keys = require("envoy.types").config.keys
    vim.keymap.set("n", "q", "<C-w>c", o)
    vim.keymap.set("n", keys.help, function() require("envoy.help").show() end, o)
    if keys.run_last and keys.run_last ~= "" then
        vim.keymap.set("n", keys.run_last,
            function() require("envoy").run_last() end,
            vim.tbl_extend("force", o, { desc = "envoy: run last" }))
    end
    if keys.pick and keys.pick ~= "" then
        vim.keymap.set("n", keys.pick, function()
            local http_buf
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
                if vim.bo[b].filetype == "http" and vim.api.nvim_buf_is_loaded(b) then
                    http_buf = b
                    break
                end
            end
            if not http_buf then
                vim.notify("[envoy] No .http buffer open", vim.log.levels.WARN)
                return
            end

            local envoy    = require("envoy")
            local parser   = require("envoy.parser")
            local executor = require("envoy.executor")
            local lines    = vim.api.nvim_buf_get_lines(http_buf, 0, -1, false)
            local requests, file_vars = parser.parse(lines)

            require("envoy.picker").pick(requests, function(choices)
                local resolved_list = {}
                for _, choice in ipairs(choices) do
                    resolved_list[#resolved_list + 1] = envoy._resolve_req_pub(choice, file_vars, http_buf)
                end
                envoy._last = resolved_list

                if #resolved_list == 1 then
                    local resolved = resolved_list[1]
                    M.show_loading(resolved.name or resolved.url)
                    executor.run(resolved, function(result)
                        M.show_result(result, resolved)
                    end)
                else
                    M.show_loading(string.format("Running %d requests…", #resolved_list))
                    local results = {}
                    local pending = #resolved_list
                    for i, resolved in ipairs(resolved_list) do
                        local idx = i
                        executor.run(resolved, function(result)
                            results[idx] = { result = result, req = resolved }
                            pending = pending - 1
                            if pending == 0 then
                                vim.schedule(function() M.show_multi_result(results) end)
                            end
                        end)
                    end
                end
            end)
        end, vim.tbl_extend("force", o, { desc = "envoy: pick & run" }))
    end

    -- Keep indent-fold settings scoped to this buffer only.
    local fold = require("envoy.fold")
    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = _buf,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            if not vim.api.nvim_win_is_valid(win) then return end
            vim.wo[win].foldmethod   = "indent"
            vim.wo[win].foldtext     = "v:lua.require('envoy.fold').json_foldtext()"
            vim.wo[win].foldminlines = 1
        end,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = _buf,
        callback = function()
            local win = vim.api.nvim_get_current_win()
            if not vim.api.nvim_win_is_valid(win) then return end
            -- Reset method/text only; preserve foldlevel so zm/zr state survives.
            vim.wo[win].foldmethod = "manual"
            vim.wo[win].foldtext   = "foldtext()"
        end,
    })

    return _buf
end

local function open_win()
    local cfg = require("envoy.types").config
    if _win and vim.api.nvim_win_is_valid(_win) then return _win end

    local buf     = get_or_create_buf()
    local src_win = vim.api.nvim_get_current_win()

    vim.cmd("vertical botright " .. cfg.result_win_width .. "split")
    _win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(_win, buf)
    vim.wo[_win].wrap       = false
    vim.wo[_win].number     = false
    vim.wo[_win].signcolumn = "no"
    require("envoy.fold").setup_result(_win)

    vim.api.nvim_set_current_win(src_win)
    return _win
end

local function write(lines)
    -- nvim_buf_set_lines rejects any element that contains \n.
    -- This can happen when a JSON string value has embedded newlines.
    -- Flatten: split every line on \n (and strip \r) before handing off.
    local flat = {}
    for _, l in ipairs(lines) do
        l = l:gsub("\r", "")
        for _, part in ipairs(vim.split(l, "\n", { plain = true })) do
            flat[#flat + 1] = part
        end
    end
    lines = flat

    local buf = get_or_create_buf()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_win_set_cursor(_win, { 1, 0 })
        -- Set foldlevel to the actual max nesting depth so zm/zr are
        -- immediately useful rather than counting down from 99.
        local max = 0
        for _, l in ipairs(lines) do
            local d = math.floor(#(l:match("^(%s*)") or "") / 2)
            if d > max then max = d end
        end
        vim.wo[_win].foldlevel = max
    end
end

--- Focus the result window if it's open.
function M.focus_result()
    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_set_current_win(_win)
    end
end

function M.show_loading(name)
    open_win()
    write({ "  ⋯  " .. name, "  Running..." })
end

---@param result HttpResult
---@param req HttpRequest
function M.show_result(result, req)
    open_win()

    local lines = {}
    local function push(s) table.insert(lines, s or "") end

    if result.error then
        push("── Error " .. string.rep("─", 38))
        push(result.error)
        write(lines)
        return
    end

    -- Status
    local icon = result.status >= 200 and result.status < 300 and "✓"
        or result.status >= 400 and "✗" or "~"
    push(string.format("%s  HTTP %d  %s %s", icon, result.status, req.method, req.url))
    push("")

    -- Response headers (skip the status line already shown)
    push("── Headers " .. string.rep("─", 35))
    for _, hl in ipairs(vim.split(result.headers, "\n")) do
        if not hl:match("^HTTP/") and hl ~= "" then push(hl) end
    end
    push("")

    -- Body
    push("── Body " .. string.rep("─", 38))

    local elastic = require("envoy.elastic")
    if elastic.is_elastic_url(req.url) then
        vim.list_extend(lines, elastic.format_response(result.body))
    else
        -- Try pretty JSON, fall back to raw
        local ok, data = pcall(vim.fn.json_decode, result.body)
        if ok and type(data) == "table" then
            vim.list_extend(lines, vim.split(elastic.pretty_json(data), "\n"))
        else
            vim.list_extend(lines, vim.split(result.body, "\n"))
        end
    end

    write(lines)
end

---@param results {result: HttpResult, req: HttpRequest}[]
function M.show_multi_result(results)
    open_win()

    local lines = {}
    local function push(s) table.insert(lines, s or "") end

    local elastic = require("envoy.elastic")

    for i, entry in ipairs(results) do
        local result = entry.result
        local req    = entry.req

        local divider = string.format("── [%d/%d] %s %s %s", i, #results, req.method, req.url, string.rep("─", math.max(0, 44 - #req.method - #req.url)))
        push(divider)

        if result.error then
            push("  Error: " .. result.error)
        else
            local icon = result.status >= 200 and result.status < 300 and "✓"
                or result.status >= 400 and "✗" or "~"
            push(string.format("  %s  HTTP %d", icon, result.status))
            push("")

            if elastic.is_elastic_url(req.url) then
                local body_lines = elastic.format_response(result.body)
                for _, l in ipairs(body_lines) do push("  " .. l) end
            else
                local ok, data = pcall(vim.fn.json_decode, result.body)
                if ok and type(data) == "table" then
                    for _, l in ipairs(vim.split(elastic.pretty_json(data), "\n")) do
                        push("  " .. l)
                    end
                else
                    for _, l in ipairs(vim.split(result.body or "", "\n")) do
                        push("  " .. l)
                    end
                end
            end
        end

        if i < #results then push("") end
    end

    write(lines)
end

return M
