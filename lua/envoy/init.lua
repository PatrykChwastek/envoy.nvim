local types = require("envoy.types")

local M = {}
M.config = types.config
M._last  = nil   -- last resolved request(s): always a list

---@param opts? EnvoyConfig
function M.setup(opts)
    types.setup(opts)
    M.config = types.config

    -- Teach Neovim about .http / .rest filetypes
    vim.filetype.add({ extension = { http = "http", rest = "http" } })

    local ag = vim.api.nvim_create_augroup("Envoy", { clear = true })

    vim.api.nvim_create_user_command("EnvoyRefresh",
        function() require("envoy.complete").refresh_all() end,
        { desc = "envoy: refresh ES index/mapping completion cache" })

    vim.api.nvim_create_user_command("EnvoyDebug",
        function() require("envoy.complete").debug() end,
        { desc = "envoy: show completion cache state" })

    vim.api.nvim_create_autocmd("FileType", {
        group   = ag,
        pattern = "http",
        callback = function(ev)
            local bufnr = ev.buf
            local winnr = vim.api.nvim_get_current_win()
            -- schedule so we run after Neovim's built-in syntax/http.vim loads;
            -- capture bufnr/winnr here so they stay correct even if the user
            -- switches buffers before the scheduled tick fires (e.g. Telescope).
            vim.schedule(function()
                require("envoy.syntax").apply(bufnr)
                require("envoy.fold").setup_http(winnr)
                vim.bo[bufnr].formatexpr = "v:lua.require('envoy.format').formatexpr()"
                require("envoy.complete").setup_buffer(bufnr)
                M._set_keymaps(bufnr)
            end)
        end,
    })

end

function M._set_keymaps(bufnr)
    local o    = { buffer = bufnr or true, silent = true }
    local k    = vim.keymap.set
    local keys = types.config.keys

    local function map(key, fn, desc)
        if key and key ~= "" then
            k("n", key, fn, vim.tbl_extend("force", o, { desc = desc }))
        end
    end

    map(keys.run,           M.run_request,                                       "envoy: run request")
    if keys.run and keys.run ~= "" then
        k("v", keys.run, function() M.run_selected() end, vim.tbl_extend("force", o, { desc = "envoy: run selected" }))
    end
    if keys.run_focus and keys.run_focus ~= "" then
        local function run_and_focus(fn)
            return function()
                fn()
                require("envoy.ui").focus_result()
            end
        end
        k("n", keys.run_focus, run_and_focus(M.run_request),
            vim.tbl_extend("force", o, { desc = "envoy: run + focus result" }))
        k("v", keys.run_focus, run_and_focus(M.run_selected),
            vim.tbl_extend("force", o, { desc = "envoy: run selected + focus result" }))
    end
    map(keys.pick,          M.pick_and_run,                                      "envoy: pick & run")
    map(keys.run_last,      M.run_last,                                          "envoy: run last")
    map(keys.next_request,  function() require("envoy.nav").next() end,     "envoy: next request")
    map(keys.prev_request,  function() require("envoy.nav").prev() end,     "envoy: prev request")
    map(keys.format_body,   function() require("envoy.format").format_body() end, "envoy: format JSON body")
    map(keys.help,          function() require("envoy.help").show() end,    "envoy: keymaps help")
end

-- Build the merged variable table for the current buffer.
local function build_vars(file_vars)
    local cfg      = types.config
    local variables = require("envoy.variables")
    local env_vars = {}
    local env_path = cfg.env_file
    if not env_path then
        local dir       = vim.fn.expand("%:p:h")
        local candidate = dir .. "/http-client.env.json"
        if vim.fn.filereadable(candidate) == 1 then env_path = candidate end
    end
    if env_path then
        env_vars = variables.load_env_file(env_path, cfg.env_name)
    end
    local all_vars = vim.tbl_extend("force", file_vars, env_vars)
    if cfg.elastic.base_url then
        all_vars["es_url"]  = all_vars["es_url"]  or cfg.elastic.base_url
        all_vars["baseUrl"] = all_vars["baseUrl"] or cfg.elastic.base_url
    end
    return all_vars
end

-- Replace invisible/unicode whitespace that breaks ES's JSON parser.
-- Most common offender: U+00A0 non-breaking space from copy-paste.
local function sanitize_body(body)
    if not body then return nil end
    body = body
        :gsub("\194\160", " ")        -- U+00A0  no-break space
        :gsub("\226\128\175", " ")    -- U+202F  narrow no-break space
        :gsub("\226\128\168", "\n")   -- U+2028  line separator
        :gsub("\226\128\169", "\n")   -- U+2029  paragraph separator
        :gsub("\226\128\139", "")     -- U+200B  zero-width space
        :gsub("\239\187\191", "")     -- U+FEFF  BOM / zero-width no-break space
    -- U+2000–U+200A: en/em/thin/hair spaces, etc. (UTF-8: E2 80 80–E2 80 8A)
    body = body:gsub("\226\128[\128-\138]", " ")
    return body
end

-- Resolve variables + inject auth into a parsed request.
local function resolve_req(req, all_vars)
    local cfg       = types.config
    local variables = require("envoy.variables")
    local resolved  = vim.deepcopy(req)
    resolved.url    = variables.resolve(req.url, all_vars)
    resolved.body   = req.body and sanitize_body(variables.resolve(req.body, all_vars)) or nil
    local rh = {}
    for k, v in pairs(req.headers) do
        rh[variables.resolve(k, all_vars)] = variables.resolve(v, all_vars)
    end
    resolved.headers = rh
    if not resolved.url:match("^https?://") then
        local base = (cfg.elastic.base_url or ""):gsub("/$", "")
        if base ~= "" then
            resolved.url = base .. (resolved.url:match("^/") and "" or "/") .. resolved.url
        end
    end
    if cfg.elastic.api_key and not rh["Authorization"] then
        resolved.headers["Authorization"] = "ApiKey " .. cfg.elastic.api_key
    end
    -- Bulk API: compact body to NDJSON and set the right Content-Type
    if resolved.body and resolved.url:find("/_bulk", 1, true) then
        local elastic = require("envoy.elastic")
        resolved.body = elastic.prepare_bulk_body(resolved.body)
        local ct = resolved.headers["Content-Type"] or resolved.headers["content-type"]
        if not ct then
            resolved.headers["Content-Type"] = "application/x-ndjson"
        end
    end
    return resolved
end

--- Public helper: resolve a request given file_vars and an optional http bufnr for env lookup.
function M._resolve_req_pub(req, file_vars, http_buf)
    local all_vars
    if http_buf and vim.api.nvim_buf_is_valid(http_buf) then
        vim.api.nvim_buf_call(http_buf, function()
            all_vars = build_vars(file_vars)
        end)
    else
        all_vars = build_vars(file_vars)
    end
    return resolve_req(req, all_vars)
end

--- Run the request the cursor is on (or closest one above).
function M.run_request()
    local bufnr = vim.api.nvim_get_current_buf()
    local lnum  = vim.fn.line(".")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    local parser   = require("envoy.parser")
    local executor = require("envoy.executor")
    local ui       = require("envoy.ui")

    local requests, file_vars = parser.parse(lines)
    local all_vars = build_vars(file_vars)

    local req = parser.request_at_line(requests, lnum)
    if not req then
        vim.notify("[envoy] No request found at cursor", vim.log.levels.WARN)
        return
    end

    local resolved = resolve_req(req, all_vars)
    M._last = { resolved }
    ui.show_loading(resolved.name)
    executor.run(resolved, function(result)
        ui.show_result(result, resolved)
    end)
end

--- Run all requests that overlap the visual selection, results in one window.
function M.run_selected()
    local bufnr = vim.api.nvim_get_current_buf()
    -- Exit visual mode first so '< '> marks are set
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
    local line1 = vim.fn.line("'<")
    local line2 = vim.fn.line("'>")
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    local parser   = require("envoy.parser")
    local executor = require("envoy.executor")
    local ui       = require("envoy.ui")

    local requests, file_vars = parser.parse(lines)
    local all_vars = build_vars(file_vars)

    local selected = {}
    for _, req in ipairs(requests) do
        if req.line_start <= line2 and req.line_end >= line1 then
            table.insert(selected, resolve_req(req, all_vars))
        end
    end

    if #selected == 0 then
        vim.notify("[envoy] No requests in selection", vim.log.levels.WARN)
        return
    end

    M._last = selected
    ui.show_loading(string.format("Running %d requests…", #selected))

    -- Run all concurrently; collect into ordered results table then display.
    local results = {}
    local pending = #selected
    for i, resolved in ipairs(selected) do
        local idx = i
        executor.run(resolved, function(result)
            results[idx] = { result = result, req = resolved }
            pending = pending - 1
            if pending == 0 then
                vim.schedule(function() ui.show_multi_result(results) end)
            end
        end)
    end
end

--- Pick a request from the file with the configured picker, then run it.
function M.pick_and_run()
    local lines    = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local requests, file_vars = require("envoy.parser").parse(lines)

    require("envoy.picker").pick(requests, function(choices)
        local all_vars = build_vars(file_vars)
        local resolved_list = {}
        for _, choice in ipairs(choices) do
            resolved_list[#resolved_list + 1] = resolve_req(choice, all_vars)
        end
        M._last = resolved_list

        local ui       = require("envoy.ui")
        local executor = require("envoy.executor")
        if #resolved_list == 1 then
            local resolved = resolved_list[1]
            ui.show_loading(resolved.name)
            executor.run(resolved, function(result)
                ui.show_result(result, resolved)
            end)
        else
            ui.show_loading(string.format("Running %d requests…", #resolved_list))
            local results = {}
            local pending = #resolved_list
            for i, resolved in ipairs(resolved_list) do
                local idx = i
                executor.run(resolved, function(result)
                    results[idx] = { result = result, req = resolved }
                    pending = pending - 1
                    if pending == 0 then
                        vim.schedule(function() ui.show_multi_result(results) end)
                    end
                end)
            end
        end
    end)
end

--- Re-run the last executed request(s).
function M.run_last()
    if not M._last or #M._last == 0 then
        vim.notify("[envoy] No previous request", vim.log.levels.WARN)
        return
    end

    local ui       = require("envoy.ui")
    local executor = require("envoy.executor")
    local last     = M._last

    if #last == 1 then
        local resolved = last[1]
        ui.show_loading(resolved.name)
        executor.run(resolved, function(result)
            ui.show_result(result, resolved)
        end)
    else
        ui.show_loading(string.format("Re-running %d requests…", #last))
        local results = {}
        local pending = #last
        for i, resolved in ipairs(last) do
            local idx = i
            executor.run(resolved, function(result)
                results[idx] = { result = result, req = resolved }
                pending = pending - 1
                if pending == 0 then
                    vim.schedule(function() ui.show_multi_result(results) end)
                end
            end)
        end
    end
end

--- Paste Kibana Dev Tools query from clipboard, converting to .http format.
---@param base_url? string  override; falls back to config.elastic.base_url or {{es_url}}
function M.import_kibana(base_url)
    local cfg     = types.config
    local elastic = require("envoy.elastic")
    base_url = base_url or cfg.elastic.base_url or "{{es_url}}"

    local clip = vim.fn.getreg("+")
    if clip == "" then clip = vim.fn.getreg('"') end
    if clip == "" then
        vim.notify("[envoy] Clipboard is empty", vim.log.levels.WARN)
        return
    end

    local converted = elastic.from_kibana(clip, base_url)
    if converted == "" then
        vim.notify("[envoy] No Kibana requests detected in clipboard", vim.log.levels.WARN)
        return
    end

    local insert_lines = vim.split(converted, "\n")
    local lnum = vim.fn.line(".")
    vim.api.nvim_buf_set_lines(0, lnum, lnum, false, insert_lines)
    vim.notify(string.format("[envoy] Inserted %d lines from Kibana format", #insert_lines))
end

return M
