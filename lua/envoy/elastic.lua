-- Elasticsearch/Kibana integration: response formatting + query import

local M = {}

local ES_PATTERNS = {
    "/_search", "/_msearch", "/_count", "/_bulk",
    "/_mapping", "/_settings", "/_index_template",
    "/_cat/", "/_cluster/", "/_nodes", "/_aliases",
    "/_doc", "/_create", "/_update",
}

---@param url string
---@return boolean
function M.is_elastic_url(url)
    for _, pat in ipairs(ES_PATTERNS) do
        if url:find(pat, 1, true) then return true end
    end
    return false
end

--- Recursive Lua-table → pretty JSON string.
---@param val any
---@param depth number
---@return string
function M.pretty_json(val, depth)
    depth = depth or 0
    local pad  = string.rep("  ", depth)
    local pad1 = string.rep("  ", depth + 1)
    local t    = type(val)

    if t == "table" then
        local is_arr = (vim.islist or vim.tbl_islist)(val)
        if is_arr then
            if #val == 0 then return "[]" end
            local items = {}
            for _, v in ipairs(val) do
                table.insert(items, pad1 .. M.pretty_json(v, depth + 1))
            end
            return "[\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "]"
        else
            local keys = vim.tbl_keys(val)
            table.sort(keys)
            if #keys == 0 then return "{}" end
            local items = {}
            for _, k in ipairs(keys) do
                local kstr = '"' .. tostring(k):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
                table.insert(items, pad1 .. kstr .. ": " .. M.pretty_json(val[k], depth + 1))
            end
            return "{\n" .. table.concat(items, ",\n") .. "\n" .. pad .. "}"
        end
    elseif t == "string" then
        return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\t', '\\t') .. '"'
    elseif t == "number" then
        if val == math.floor(val) and math.abs(val) < 2 ^ 53 then
            return string.format("%d", val)
        end
        return string.format("%g", val)
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif val == nil or val == vim.NIL then
        return "null"
    else
        return tostring(val)
    end
end

--- Format a raw ES JSON response body into display lines.
---@param body string
---@return string[]
function M.format_response(body)
    local ok, data = pcall(vim.fn.json_decode, body)
    if not ok or type(data) ~= "table" then
        return vim.split(body, "\n")
    end

    local lines = {}
    local function push(s) table.insert(lines, s) end
    local function divider(label)
        push(string.format("── %s %s", label, string.rep("─", math.max(0, 44 - #label))))
    end

    -- Error
    if data.error then
        divider("ES Error")
        local err = data.error
        if type(err) == "table" then
            push("  type:   " .. (err.type   or "?"))
            push("  reason: " .. (err.reason or "?"))
            if err.root_cause and err.root_cause[1] then
                push("  root:   " .. (err.root_cause[1].reason or ""))
            end
        else
            push("  " .. tostring(err))
        end
        return lines
    end

    -- Bulk response
    if data.items then
        local took = data.took or 0
        local has_errors = data.errors
        divider(string.format("Bulk  took:%dms  errors:%s", took, has_errors and "YES" or "no"))
        push("")
        local ok_count, err_count = 0, 0
        for i, item in ipairs(data.items) do
            for action, doc in pairs(item) do
                local status = doc.status or 0
                if doc.error then
                    err_count = err_count + 1
                    local etype  = type(doc.error) == "table" and (doc.error.type   or "error") or tostring(doc.error)
                    local reason = type(doc.error) == "table" and (doc.error.reason or "") or ""
                    push(string.format("  [%d] ✗  %-8s  %-36s  %s: %s", i, action, doc._id or "?", etype, reason))
                else
                    ok_count = ok_count + 1
                    local icon = status >= 200 and status < 300 and "✓" or "~"
                    push(string.format("  [%d] %s  %-8s  %-36s  → %s", i, icon, action, doc._id or "?", doc.result or "?"))
                end
            end
        end
        if has_errors then
            push("")
            push(string.format("  %d succeeded, %d failed", ok_count, err_count))
        end
        return lines
    end

    -- Search response
    if data.hits then
        local total     = data.hits.total
        local total_val = type(total) == "table" and total.value or (total or 0)
        local relation  = type(total) == "table" and total.relation or "eq"
        local took      = data.took or 0
        local shards    = data._shards or {}

        divider(string.format("Hits: %s%d  took:%dms  shards:%s/%s",
            relation == "gte" and ">=" or "",
            total_val, took,
            shards.successful or "?", shards.total or "?"))
        push("")

        for i, hit in ipairs(data.hits.hits or {}) do
            push(string.format("  [%d]  _index: %s  _id: %s", i, hit._index or "?", hit._id or "?"))
            if hit._source then
                local src_lines = vim.split(M.pretty_json(hit._source, 0), "\n")
                for _, sl in ipairs(src_lines) do push("  " .. sl) end
            end
            push("")
        end

        -- Aggregations
        if data.aggregations then
            divider("Aggregations")
            for agg_name, agg in pairs(data.aggregations) do
                push("  " .. agg_name .. ":")
                if agg.buckets then
                    for _, bucket in ipairs(agg.buckets) do
                        local key = tostring(bucket.key_as_string or bucket.key or "?")
                        push(string.format("    %-30s  %d", key, bucket.doc_count or 0))
                    end
                elseif agg.value ~= nil then
                    push("    value: " .. tostring(agg.value))
                end
            end
        end

        return lines
    end

    -- Fallback: pretty print
    return vim.split(M.pretty_json(data), "\n")
end

--- Convert Kibana triple-quoted strings """...""" to standard JSON strings.
local function fix_triple_quotes(s)
    return s:gsub('"""(.-)"""', function(content)
        content = content:gsub('\\', '\\\\'):gsub('"', '\\"')
        return '"' .. content .. '"'
    end)
end

--- Compact body to NDJSON: each top-level JSON object/array on its own line.
--- Parses each block with json_decode/encode for correctness, falls back to
--- line-joining if parsing fails (e.g. already single-line action rows).
local function compact_ndjson(body)
    local lines   = vim.split(body, "\n", { plain = true })
    local blocks  = {}
    local cur     = {}
    local depth   = 0
    local in_str  = false
    local esc     = false

    local function flush()
        if #cur == 0 then return end
        local joined = table.concat(cur, "\n")
        local ok, parsed = pcall(vim.fn.json_decode, joined)
        if ok then
            blocks[#blocks + 1] = vim.fn.json_encode(parsed)
        else
            local parts = {}
            for _, l in ipairs(cur) do
                l = vim.trim(l)
                if l ~= "" then parts[#parts + 1] = l end
            end
            blocks[#blocks + 1] = table.concat(parts, " ")
        end
        cur    = {}
        depth  = 0
        in_str = false
        esc    = false
    end

    for _, line in ipairs(lines) do
        if vim.trim(line) == "" then
            if depth == 0 then flush() end
        else
            cur[#cur + 1] = line
            for i = 1, #line do
                local c = line:sub(i, i)
                if esc then esc = false
                elseif in_str then
                    if c == "\\" then esc = true elseif c == '"' then in_str = false end
                else
                    if     c == '"'             then in_str = true
                    elseif c == "{" or c == "[" then depth = depth + 1
                    elseif c == "}" or c == "]" then depth = depth - 1 end
                end
            end
            if depth == 0 then flush() end
        end
    end
    flush()

    if #blocks == 0 then return body end
    return table.concat(blocks, "\n") .. "\n"   -- _bulk requires trailing newline
end

--- Prepare a body for the _bulk API: convert triple-quotes + compact to NDJSON.
function M.prepare_bulk_body(body)
    return compact_ndjson(fix_triple_quotes(body))
end

--- Convert Kibana Dev Tools text (clipboard) to .http format.
--- Kibana: GET /index/_search\n{...}\n\nGET ...
---@param kibana_text string
---@param base_url string
---@return string
function M.from_kibana(kibana_text, base_url)
    local out = {}
    local raw_lines = vim.split(kibana_text, "\n")
    local i = 1

    while i <= #raw_lines do
        local line = vim.trim(raw_lines[i])

        if line == "" or line:match("^#") then
            i = i + 1
        else
            local method, path = line:match("^(%u+)%s+(/[^ ]*)")
            if method then
                local section = { "", "###", method .. " " .. base_url .. path }
                if method == "POST" or method == "PUT" or method == "PATCH" then
                    table.insert(section, "Content-Type: application/json")
                end
                i = i + 1

                -- Collect body until blank-then-method or EOF
                local body = {}
                while i <= #raw_lines do
                    local bl = raw_lines[i]
                    if vim.trim(bl) == "" then
                        -- peek: is the next non-blank a method line?
                        local j = i + 1
                        while j <= #raw_lines and vim.trim(raw_lines[j]) == "" do
                            j = j + 1
                        end
                        if j > #raw_lines or vim.trim(raw_lines[j]):match("^%u+%s+/") then
                            break
                        end
                    end
                    table.insert(body, bl)
                    i = i + 1
                end

                -- Trim trailing blank lines from body
                while #body > 0 and vim.trim(body[#body]) == "" do
                    table.remove(body)
                end

                if #body > 0 then
                    table.insert(section, "")
                    vim.list_extend(section, body)
                end

                vim.list_extend(out, section)
            else
                i = i + 1
            end
        end
    end

    return table.concat(out, "\n")
end

return M
