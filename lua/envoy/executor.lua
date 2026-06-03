local M = {}

---@class HttpResult
---@field status  number
---@field headers string   -- raw header block
---@field body    string
---@field error   string|nil

--- Execute req using curl via vim.system (nvim 0.10+).
--- callback is always called on the main thread.
---@param req HttpRequest
---@param callback fun(result: HttpResult)
function M.run(req, callback)
    local args = { "curl", "-s", "-i", "--max-time", "30" }

    table.insert(args, "-X")
    table.insert(args, req.method)

    for name, value in pairs(req.headers) do
        table.insert(args, "-H")
        table.insert(args, name .. ": " .. value)
    end

    if req.body and req.body ~= "" then
        table.insert(args, "--data-raw")
        table.insert(args, req.body)
        if not req.headers["Content-Type"] and not req.headers["content-type"] then
            table.insert(args, "-H")
            table.insert(args, "Content-Type: application/json")
        end
    end

    table.insert(args, req.url)

    vim.system(args, { text = true }, function(out)
        vim.schedule(function()
            if out.code ~= 0 then
                local msg = (out.stderr ~= "" and out.stderr)
                    or ("curl exited with code " .. out.code)
                callback({ status = 0, headers = "", body = "", error = msg })
                return
            end

            local raw = out.stdout or ""
            -- curl -i separates headers and body with \r\n\r\n
            local hdr, body = raw:match("^(.-)\r?\n\r?\n(.*)$")
            if not hdr then
                hdr  = ""
                body = raw
            end

            -- Follow redirects: curl may emit multiple header blocks
            while body:match("^HTTP/") do
                local h2, b2 = body:match("^(.-)\r?\n\r?\n(.*)$")
                if h2 then hdr, body = h2, b2 else break end
            end

            local status = tonumber(hdr:match("HTTP/%S+%s+(%d+)")) or 0
            callback({ status = status, headers = hdr, body = body, error = nil })
        end)
    end)
end

return M
