---@class HttpRequest
---@field name        string
---@field method      string
---@field url         string   -- raw, before variable substitution
---@field headers     table<string, string>
---@field body        string|nil
---@field comment     string|nil  -- # comment lines immediately before the request
---@field line_start  number   -- 1-indexed: ### line or method line
---@field line_end    number
---@field body_line_start number|nil
---@field body_line_end   number|nil

local M = {}

-- Lua patterns have no | alternation, so use a lookup table instead
local METHODS_SET = {
    GET = true, POST = true, PUT = true, DELETE = true, PATCH = true,
    HEAD = true, OPTIONS = true, CONNECT = true, TRACE = true,
}

--- Extract the HTTP method from a line, or return nil.
local function get_method(line)
    local m = line:match("^(%u+)%s+")
    return (m and METHODS_SET[m]) and m or nil
end

--- Parse a full .http buffer into requests and file-level variables.
---@param lines string[]
---@return HttpRequest[], table<string, string>
function M.parse(lines)
    -- File-level @var = value (anywhere in file, first-pass)
    local file_vars = {}
    for _, line in ipairs(lines) do
        local k, v = line:match("^@([%w_]+)%s*=%s*(.+)$")
        if k then file_vars[k] = vim.trim(v) end
    end

    -- Split into sections on ### markers OR on a new method line when the
    -- current section already contains one (implicit separator, Kibana style)
    local sections = {}
    local cur = { name = "", start_lnum = 1, items = {} }
    local cur_has_method = false

    for i, line in ipairs(lines) do
        local sep = line:match("^###%s*(.*)")
        if sep ~= nil then
            if #cur.items > 0 then table.insert(sections, cur) end
            cur = { name = vim.trim(sep), start_lnum = i, items = {} }
            cur_has_method = false
        elseif get_method(line) and cur_has_method then
            -- new request without explicit ### separator
            -- pull trailing blank + comment lines out of cur and give them to the new section
            local leading = {}
            while #cur.items > 0 and cur.items[#cur.items].text:match("^%s*$") do
                table.remove(cur.items)
            end
            while #cur.items > 0 and cur.items[#cur.items].text:match("^#") do
                table.insert(leading, 1, table.remove(cur.items))
            end
            while #cur.items > 0 and cur.items[#cur.items].text:match("^%s*$") do
                table.remove(cur.items)
            end
            table.insert(sections, cur)
            local new_items = {}
            for _, item in ipairs(leading) do new_items[#new_items + 1] = item end
            new_items[#new_items + 1] = { text = line, lnum = i }
            local new_start = leading[1] and leading[1].lnum or i
            cur = { name = "", start_lnum = new_start, items = new_items }
            -- cur_has_method stays true
        else
            if get_method(line) then cur_has_method = true end
            table.insert(cur.items, { text = line, lnum = i })
        end
    end
    if #cur.items > 0 then table.insert(sections, cur) end

    local requests = {}
    for _, sec in ipairs(sections) do
        local req = M._parse_section(sec)
        if req then table.insert(requests, req) end
    end

    return requests, file_vars
end

---@param sec {name: string, start_lnum: number, items: {text: string, lnum: number}[]}
---@return HttpRequest|nil
function M._parse_section(sec)
    -- Find first method line
    local method_idx
    for i, item in ipairs(sec.items) do
        if get_method(item.text) then
            method_idx = i
            break
        end
    end
    if not method_idx then return nil end

    -- Collect # comment lines before the method line
    local comment_parts = {}
    for i = 1, method_idx - 1 do
        local c = sec.items[i].text:match("^#%s*(.*)")
        if c and vim.trim(c) ~= "" then
            comment_parts[#comment_parts + 1] = vim.trim(c)
        end
    end
    local comment = #comment_parts > 0 and table.concat(comment_parts, " ") or nil

    local method_item = sec.items[method_idx]
    local method = get_method(method_item.text)
    local url = method_item.text:match("^%u+%s+(.-)%s*$")
    -- strip trailing HTTP/1.x
    url = url:match("^(.-)%s+HTTP/%S+$") or url

    -- Headers: lines after method until blank line OR start of JSON body
    -- Kibana style has no blank line between method and body
    local headers = {}
    local body_idx  -- index in sec.items where body begins
    for i = method_idx + 1, #sec.items do
        local text = sec.items[i].text
        if text:match("^%s*$") then
            -- blank line: body starts on the next non-blank line
            for j = i + 1, #sec.items do
                if not sec.items[j].text:match("^%s*$") then
                    body_idx = j
                    break
                end
            end
            break
        elseif text:match("^[%[{]") then
            -- JSON body starts immediately (no blank line required)
            body_idx = i
            break
        else
            local hname, hval = text:match("^([^:]+):%s*(.*)$")
            if hname then headers[vim.trim(hname)] = vim.trim(hval) end
        end
    end

    -- Body: lines from body_idx to end of section.
    -- Stop at comment (#) or variable (@) lines — they cannot be inside JSON
    -- and signal that the body has already ended.
    local body_lines = {}
    local body_start, body_end
    if body_idx then
        for i = body_idx, #sec.items do
            local item = sec.items[i]
            if item.text:match("^#") or item.text:match("^@") then break end
            table.insert(body_lines, item.text)
            if not body_start then body_start = item.lnum end
            body_end = item.lnum
        end
    end

    local last = sec.items[#sec.items]
    return {
        name           = sec.name ~= "" and sec.name or (method .. " " .. url),
        comment        = comment,
        method         = method,
        url            = url,
        headers        = headers,
        body           = #body_lines > 0 and table.concat(body_lines, "\n") or nil,
        line_start     = sec.start_lnum,
        line_end       = last.lnum,
        body_line_start = body_start,
        body_line_end   = body_end,
    }
end

--- Return the request that contains lnum, or the closest one above.
---@param requests HttpRequest[]
---@param lnum number
---@return HttpRequest|nil
function M.request_at_line(requests, lnum)
    local best
    for _, req in ipairs(requests) do
        if lnum >= req.line_start then
            best = req
        end
    end
    return best
end

return M
