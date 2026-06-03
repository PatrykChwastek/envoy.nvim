local M = {}

-- Vim regex matching any HTTP method at start of line
local PAT = [[^\(GET\|POST\|PUT\|DELETE\|PATCH\|HEAD\|OPTIONS\|CONNECT\|TRACE\)\s]]

function M.next()
    vim.fn.search(PAT, "W")
end

function M.prev()
    vim.fn.search(PAT, "bW")
end

return M
