---@class EnvoyKeys
---@field run            string
---@field run_focus      string
---@field run_last       string
---@field pick           string
---@field next_request   string
---@field prev_request   string
---@field format_body    string
---@field help           string

---@class EnvoyElasticConfig
---@field base_url    string|nil
---@field api_key     string|nil
---@field format_hits boolean

---@class EnvoyCompleteConfig
---@field enabled        boolean
---@field fetch_indices  boolean
---@field fetch_mappings boolean

---@class EnvoyConfig
---@field result_win_width number
---@field env_file          string|nil
---@field env_name          string
---@field picker            "auto"|"telescope"|"native"
---@field keys              EnvoyKeys
---@field elastic           EnvoyElasticConfig
---@field complete          EnvoyCompleteConfig

local M = {}

M.defaults = {
    result_win_width   = 80,
    env_file           = nil,
    env_name           = "dev",
    fold_level_on_open = 0,   -- 0 = fold all on open, 99 = start fully expanded
    picker             = "auto",  -- "auto" | "telescope" | "native"
    keys = {
        run            = "<CR>",
        run_focus      = "<C-CR>",
        run_last       = "<leader><CR>",
        pick           = "<leader>R",
        next_request   = "]r",
        prev_request   = "[r",
        format_body    = "<leader>fj",
        help           = "g?",
    },
    elastic = {
        base_url    = nil,
        api_key     = nil,
        format_hits = true,
    },
    complete = {
        enabled        = true,
        fetch_indices  = true,
        fetch_mappings = true,
    },
}

M.config = vim.deepcopy(M.defaults)

---@param opts? EnvoyConfig
function M.setup(opts)
    M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
