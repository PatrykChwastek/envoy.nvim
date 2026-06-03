local M = {}

local function build_lines(keys)
    -- { key_display, description }  |  nil = divider
    local sections = {
        {
            { keys.run,                                  "Run request under cursor"             },
            { keys.run_focus,                            "Run + jump to result split"           },
            { keys.run_last,                             "Re-run last request(s)"               },
            { keys.pick,                                 "Pick request and run"                 },
            { keys.next_request .. "  /  " .. keys.prev_request, "Next / previous request"    },
            { keys.format_body,                          "Format JSON body (jq or built-in)"   },
            { keys.help,                                 "Show this help"                       },
        },
        {
            { "za",          "Toggle fold at cursor"            },
            { "zO  /  zC",   "Open / close fold recursively"   },
            { "zm  /  zr",   "Fold one more / less level"       },
            { "zM  /  zR",   "Fold all / open all"              },
        },
        {
            { "q / <Esc>",   "Close result window / this help"  },
        },
    }

    -- Find the widest key string
    local key_w = 0
    for _, sec in ipairs(sections) do
        for _, e in ipairs(sec) do
            if #e[1] > key_w then key_w = #e[1] end
        end
    end
    key_w = key_w + 1

    local lines  = { "" }
    local ncols  = key_w + 2 + 38  -- key + gap + desc

    for i, sec in ipairs(sections) do
        for _, e in ipairs(sec) do
            lines[#lines + 1] = string.format(
                "  %-" .. key_w .. "s  %s", e[1], e[2])
        end
        if i < #sections then
            lines[#lines + 1] = "  " .. string.rep("·", ncols - 2)
        end
    end

    lines[#lines + 1] = ""
    return lines, ncols + 4  -- +4 for 2-char padding both sides
end

function M.show()
    local keys  = require("envoy.types").config.keys
    local lines, width = build_lines(keys)
    width = math.max(width, 48)

    local height = #lines
    local row    = math.floor((vim.o.lines   - height - 2) / 2)
    local col    = math.floor((vim.o.columns - width)  / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].buftype    = "nofile"

    local win = vim.api.nvim_open_win(buf, true, {
        relative  = "editor",
        width     = width,
        height    = height,
        row       = row,
        col       = col,
        style     = "minimal",
        border    = "rounded",
        title     = " envoy ",
        title_pos = "center",
    })

    vim.wo[win].cursorline = false
    vim.wo[win].wrap       = false

    local close = function()
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end

    vim.keymap.set("n", "q",     close, { buffer = buf, silent = true, nowait = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true, nowait = true })
end

return M
