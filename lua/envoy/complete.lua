local M = {}

-- ── Static ES query DSL keywords ──────────────────────────────────────
M.KEYWORDS = {
    -- Query DSL
    "query", "bool", "must", "must_not", "should", "filter", "minimum_should_match",
    "match", "match_phrase", "match_phrase_prefix", "match_all", "match_none",
    "term", "terms", "range", "exists", "prefix", "wildcard", "regexp", "fuzzy",
    "ids", "constant_score", "function_score", "boosting", "dis_max", "nested",
    "multi_match", "query_string", "simple_query_string", "more_like_this",
    -- Range operators
    "gt", "gte", "lt", "lte", "from", "to",
    -- Aggregations
    "aggs", "aggregations", "date_histogram", "histogram", "filters",
    "sum", "avg", "min", "max", "value_count", "cardinality", "stats",
    "extended_stats", "percentiles", "percentile_ranks", "top_hits",
    -- Sort / search options
    "sort", "order", "asc", "desc", "_score", "_doc",
    "size", "_source", "_source_includes", "_source_excludes",
    "track_total_hits", "track_scores", "highlight", "explain", "version",
    "fields", "stored_fields", "script_fields", "docvalue_fields", "runtime_mappings",
    -- Highlight options
    "pre_tags", "post_tags", "fragment_size", "number_of_fragments",
    -- Mapping / index settings
    "settings", "mappings", "aliases", "properties", "type", "format",
    "number_of_shards", "number_of_replicas",
    -- Bulk action keywords
    "index", "create", "update", "delete", "doc", "doc_as_upsert", "upsert",
}

-- Suggested after /<index>/ on a URL line
M.ENDPOINTS = {
    "_search", "_count", "_mapping", "_settings", "_aliases",
    "_doc", "_bulk", "_msearch", "_update", "_update_by_query",
    "_delete_by_query", "_refresh", "_flush", "_cache/clear",
    "_recovery", "_segments", "_stats",
}

-- Cache: indexes list + mapping fields per index name
M._indices  = {}
M._mappings = {}

-- ── Networking ────────────────────────────────────────────────────────
local function get_base_url()
    local cfg = require("envoy.types").config
    return (cfg.elastic.base_url or ""):gsub("/$", "")
end

M._last_error = nil   -- visible via :EnvoyDebug

local function curl_get(url, callback)
    local cfg  = require("envoy.types").config
    local args = { "curl", "-s", "--max-time", "5" }
    if cfg.elastic.api_key then
        table.insert(args, "-H")
        table.insert(args, "Authorization: ApiKey " .. cfg.elastic.api_key)
    end
    table.insert(args, url)
    vim.system(args, { text = true }, function(out)
        if out.code ~= 0 or not out.stdout or out.stdout == "" then
            M._last_error = ("curl %s: exit=%d stderr=%s")
                :format(url, out.code or -1, (out.stderr or ""):gsub("\n", " "))
            vim.schedule(function() callback(nil) end)
            return
        end
        local ok, data = pcall(vim.json.decode, out.stdout)
        if not ok then
            M._last_error = ("decode %s: %s"):format(url, tostring(data):sub(1, 200))
        end
        vim.schedule(function() callback(ok and data or nil) end)
    end)
end

-- ── Index list ────────────────────────────────────────────────────────
function M.refresh_indices()
    local base = get_base_url()
    if base == "" then return end
    curl_get(base .. "/_cat/indices?format=json", function(data)
        if type(data) ~= "table" then return end
        -- _cat/indices?format=json returns an array; an error response is an
        -- object. Detect and remember the error so :EnvoyDebug can show it.
        if not vim.islist(data) then
            M._last_error = "_cat/indices returned object (likely an error): "
                .. vim.inspect(data):sub(1, 200)
            return
        end
        local indices = {}
        for _, item in ipairs(data) do
            if type(item) == "table" and item.index then
                table.insert(indices, item.index)
            end
        end
        table.sort(indices)
        M._indices = indices
    end)
end

-- ── Mapping fields ────────────────────────────────────────────────────
local function extract_fields(node, out, seen)
    if type(node) ~= "table" then return end
    local props = node.properties
    if type(props) ~= "table" then return end
    for name, def in pairs(props) do
        local kind = (type(def) == "table" and def.type) or "object"
        if not seen[name] then
            seen[name] = true
            table.insert(out, { name = name, type = kind })
        end
        if type(def) == "table" and def.properties then
            extract_fields(def, out, seen)
        end
    end
end

function M.refresh_mapping(index)
    if not index or index == "" then return end
    -- nil  = never tried     (do fetch)
    -- false = in-flight       (skip, fetch already running)
    -- table = result (possibly empty after a failed fetch — also skip,
    --          user can call :EnvoyRefresh to retry)
    if M._mappings[index] ~= nil then return end
    local base = get_base_url()
    if base == "" then return end
    M._mappings[index] = false   -- in-flight sentinel
    curl_get(base .. "/" .. index .. "/_mapping", function(data)
        if type(data) ~= "table" then
            M._mappings[index] = nil   -- clear in-flight so retries work
            return
        end
        local fields = {}
        local seen   = {}
        for _, idx_data in pairs(data) do
            if type(idx_data) == "table" and idx_data.mappings then
                extract_fields(idx_data.mappings, fields, seen)
            end
        end
        table.sort(fields, function(a, b) return a.name < b.name end)
        M._mappings[index] = fields
    end)
end

--- Extract a concrete index name from a (possibly templated) request URL.
--- Resolves variables so {{baseUrl}}/myidx/_search → "myidx".
local function index_from_request(req, file_vars, bufnr)
    local ok, envoy = pcall(require, "envoy")
    local url = req.url
    if ok and envoy and envoy._resolve_req_pub then
        local r_ok, resolved = pcall(envoy._resolve_req_pub, req, file_vars, bufnr)
        if r_ok and resolved and resolved.url then url = resolved.url end
    end
    url = url:gsub("^https?://[^/]+", ""):gsub("^/", "")
    local idx = url:match("^([^/?]+)")
    if not idx or idx:match("^_") or idx:match("^{{") or idx == "" then return nil end
    return idx
end

--- Pre-fetch mappings for every index referenced in the buffer
function M.prefetch(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local lines    = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local parser   = require("envoy.parser")
    local requests, file_vars = parser.parse(lines)
    local seen     = {}
    for _, req in ipairs(requests) do
        local idx = index_from_request(req, file_vars, bufnr)
        if idx and not seen[idx] and not idx:find(",", 1, true) then
            seen[idx] = true
            M.refresh_mapping(idx)
        end
    end
end

-- ── Context detection ─────────────────────────────────────────────────
local METHODS_SET = {
    GET = true, POST = true, PUT = true, DELETE = true, PATCH = true,
    HEAD = true, OPTIONS = true,
}

local function detect_context(line, col)
    local before = line:sub(1, col)
    -- URL line: starts with a METHOD then space
    local method = before:match("^(%u+)%s+")
    if method and METHODS_SET[method] then
        local after_method = before:match("^%u+%s+(.*)$") or ""
        -- Strip protocol+host if present
        local path = after_method:gsub("^https?://[^/]*", "")
        -- How many path segments are we in?
        local slashes = 0
        for _ in path:gmatch("/") do slashes = slashes + 1 end
        if slashes == 0 then
            return "index"      -- typing the first path segment (the index)
        else
            return "endpoint"   -- after the first /, suggest _search etc.
        end
    end
    return nil
end

local function in_json_body(bufnr, lnum)
    -- Scan back for the closest method line; if a `{` or `[` line lies between
    -- it and the cursor, we're inside a JSON body.
    local opened = false
    for i = lnum - 1, math.max(1, lnum - 500), -1 do
        local prev = vim.api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1] or ""
        if prev:match("^%u+%s+%S") then
            return opened
        end
        if prev:match("^[{%[]") then opened = true end
    end
    return false
end

local function find_enclosing_index(bufnr, lnum)
    local lines    = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local parser   = require("envoy.parser")
    local requests, file_vars = parser.parse(lines)
    local req      = parser.request_at_line(requests, lnum)
    if not req then return nil end
    return index_from_request(req, file_vars, bufnr)
end

-- ── omnifunc ──────────────────────────────────────────────────────────
function M.omnifunc(findstart, base)
    local cfg = require("envoy.types").config
    if not cfg.complete or not cfg.complete.enabled then
        return findstart == 1 and -1 or {}
    end

    local line = vim.api.nvim_get_current_line()
    local col  = vim.fn.col(".") - 1  -- 0-based byte index of cursor

    if findstart == 1 then
        local start = col
        while start > 0 do
            local c = line:sub(start, start)
            if not c:match("[%w_%./]") then break end
            start = start - 1
        end
        return start
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local ctx   = detect_context(line, col)
    local items = {}

    local function add(word, kind, menu)
        if base == "" or word:lower():find(base:lower(), 1, true) == 1 then
            table.insert(items, { word = word, kind = kind, menu = menu })
        end
    end

    if ctx == "index" then
        for _, idx in ipairs(M._indices) do add(idx, "I", "[index]") end
    elseif ctx == "endpoint" then
        for _, ep in ipairs(M.ENDPOINTS) do add(ep, "E", "[endpoint]") end
    elseif in_json_body(bufnr, vim.fn.line(".")) then
        for _, kw in ipairs(M.KEYWORDS) do add(kw, "K", "[dsl]") end
        if cfg.complete.fetch_mappings then
            local idx = find_enclosing_index(bufnr, vim.fn.line("."))
            if idx then
                local fields = M._mappings[idx]
                if type(fields) == "table" and #fields > 0 then
                    for _, f in ipairs(fields) do
                        add(f.name, "F", "[" .. (f.type or "field") .. "]")
                    end
                elseif fields == nil then
                    M.refresh_mapping(idx)   -- not yet tried; kick off async
                end
            end
        end
    end

    return items
end

-- ── Buffer setup ──────────────────────────────────────────────────────
function M.setup_buffer(bufnr)
    local cfg = require("envoy.types").config
    if not cfg.complete or not cfg.complete.enabled then return end
    vim.bo[bufnr].omnifunc = "v:lua.require'envoy.complete'.omnifunc"
    if cfg.complete.fetch_indices  then M.refresh_indices() end
    if cfg.complete.fetch_mappings then M.prefetch(bufnr)   end
end

--- Force refresh: indices + clear mapping cache
function M.refresh_all()
    M._mappings  = {}
    M._last_error = nil
    M.refresh_indices()
    M.prefetch(vim.api.nvim_get_current_buf())
end

--- Diagnostic dump — surfaces what the cache thinks and what last failed.
function M.debug()
    local cfg = require("envoy.types").config
    local lines = {
        "[envoy.complete]",
        "  base_url:        " .. (cfg.elastic.base_url or "<nil>"),
        "  enabled:         " .. tostring(cfg.complete and cfg.complete.enabled),
        "  indices cached:  " .. #M._indices,
    }
    if #M._indices > 0 then
        local sample = {}
        for i = 1, math.min(5, #M._indices) do sample[i] = M._indices[i] end
        table.insert(lines, "    sample: " .. table.concat(sample, ", "))
    end
    table.insert(lines, "  mappings cached:")
    local count = 0
    for idx, fields in pairs(M._mappings) do
        count = count + 1
        local state
        if fields == false then
            state = "in-flight"
        elseif type(fields) == "table" then
            state = tostring(#fields) .. " fields"
            if #fields > 0 then
                local sample = {}
                for i = 1, math.min(5, #fields) do
                    sample[i] = fields[i].name .. "(" .. (fields[i].type or "?") .. ")"
                end
                state = state .. "  eg: " .. table.concat(sample, ", ")
                if #fields > 5 then state = state .. ", …" end
            end
        else
            state = tostring(fields)
        end
        table.insert(lines, ("    %s → %s"):format(idx, state))
    end
    if count == 0 then table.insert(lines, "    (none)") end
    if M._last_error then
        table.insert(lines, "  last error:")
        table.insert(lines, "    " .. M._last_error)
    end

    -- Parser snapshot for the current buffer + which request the cursor maps to
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].filetype == "http" then
        local parser   = require("envoy.parser")
        local buf_lns  = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local requests = parser.parse(buf_lns)
        local cur_lnum = vim.fn.line(".")
        local picked   = parser.request_at_line(requests, cur_lnum)
        table.insert(lines, ("  parsed requests (%d), cursor line %d:"):format(#requests, cur_lnum))
        for i, r in ipairs(requests) do
            local marker = (picked == r) and " <- cursor picks" or ""
            table.insert(lines, ("    [%d] L%d-%d  %s %s%s")
                :format(i, r.line_start, r.line_end, r.method, r.url, marker))
        end
    end

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "envoy" })
end

return M
