local M = {}

--- Foldtext for both .http and result buffers.
function M.json_foldtext()
    local line  = vim.fn.getline(vim.v.foldstart)
    local total = vim.v.foldend - vim.v.foldstart + 1
    return string.format("%s  ···  %d lines", vim.trim(line), total)
end

local function fold_reset(win)
    if not vim.api.nvim_win_is_valid(win) then return end
    vim.wo[win].foldmethod   = "manual"
    vim.wo[win].foldtext     = "foldtext()"
    vim.wo[win].foldlevel    = 0
    vim.wo[win].foldminlines = 0
end

M.reset_win = fold_reset

-- Reassert only the window-local options that can leak/get clobbered when
-- another buffer is shown in the same window. Crucially, NOT foldlevel —
-- touching foldlevel here would re-collapse user-expanded folds every time
-- the .http buffer is re-entered (which happens implicitly each time we
-- briefly switch windows to create/open the result split).
local function reassert_http(win)
    if not vim.api.nvim_win_is_valid(win) then return end
    vim.wo[win].foldmethod   = "syntax"
    vim.wo[win].foldtext     = "v:lua.require('envoy.fold').json_foldtext()"
    vim.wo[win].foldminlines = 1
end

--- Set up folding for an .http buffer.
--- Uses foldmethod=syntax so the httpBody region (defined in syntax.lua)
--- drives fold boundaries — no foldexpr Lua calls, no event-loop blocking.
function M.setup_http(winnr)
    winnr = winnr or vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(winnr)
    local cfg   = require("envoy.types").config

    reassert_http(winnr)
    -- Set the initial foldlevel exactly once per buffer. After this, user
    -- zm/zr/zo operations are the source of truth for foldlevel.
    if not vim.b[bufnr].envoy_fold_initialized then
        vim.wo[winnr].foldlevel = cfg.fold_level_on_open
        vim.b[bufnr].envoy_fold_initialized = true
    end

    local ag = vim.api.nvim_create_augroup("EnvoyFold_" .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = bufnr, group = ag,
        callback = function() reassert_http(vim.api.nvim_get_current_win()) end,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = bufnr, group = ag,
        callback = function() fold_reset(vim.api.nvim_get_current_win()) end,
    })
end

--- Set up folding for the result window (indent-based, starts fully open).
function M.setup_result(winnr)
    winnr = winnr or vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(winnr)
    vim.bo[bufnr].shiftwidth   = 2
    vim.bo[bufnr].tabstop      = 2
    vim.wo[winnr].foldmethod   = "indent"
    vim.wo[winnr].foldtext     = "v:lua.require('envoy.fold').json_foldtext()"
    vim.wo[winnr].foldlevel    = 99
    vim.wo[winnr].foldminlines = 1
end

return M
