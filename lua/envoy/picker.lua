local M = {}

local function use_telescope()
    local mode = require("envoy.types").config.picker
    if mode == "native" then return false end
    if mode == "telescope" then return true end
    -- auto: use telescope if it's installed
    local ok = pcall(require, "telescope")
    return ok
end

local function format_native(r)
    if r.comment then
        return string.format("%-8s %-45s  # %s", r.method, r.url, r.comment)
    end
    return string.format("%-8s %s", r.method, r.url)
end

local function telescope_pick(requests, on_choice)
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf    = require("telescope.config").values
    local actions = require("telescope.actions")
    local state   = require("telescope.actions.state")
    local entry_display = require("telescope.pickers.entry_display")

    local displayer = entry_display.create({
        separator = "  ",
        items = {
            { width = 8 },
            { remaining = true },
        },
    })

    pickers.new({}, {
        prompt_title = "Run HTTP Request",
        finder = finders.new_table({
            results = requests,
            entry_maker = function(req)
                local comment_str = req.comment and ("  # " .. req.comment) or ""
                return {
                    value   = req,
                    display = function()
                        return displayer({
                            { req.method, "TelescopeResultsIdentifier" },
                            req.url .. comment_str,
                        })
                    end,
                    -- ordinal includes comment + name so fuzzy search finds them
                    ordinal = req.method .. " " .. req.url
                        .. " " .. (req.comment or "")
                        .. " " .. (req.name ~= (req.method .. " " .. req.url) and req.name or ""),
                }
            end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                local multi = state.get_current_picker(prompt_bufnr):get_multi_selection()
                actions.close(prompt_bufnr)
                if #multi > 0 then
                    local chosen = {}
                    for _, entry in ipairs(multi) do chosen[#chosen + 1] = entry.value end
                    on_choice(chosen)
                else
                    local sel = state.get_selected_entry()
                    if sel then on_choice({ sel.value }) end
                end
            end)
            return true
        end,
    }):find()
end

local function native_pick(requests, on_choice)
    vim.ui.select(requests, {
        prompt      = "Run request:",
        format_item = format_native,
    }, function(choice)
        if choice then on_choice({ choice }) end
    end)
end

---@param requests HttpRequest[]
---@param on_choice fun(reqs: HttpRequest[])
function M.pick(requests, on_choice)
    if #requests == 0 then
        vim.notify("[envoy] No requests found", vim.log.levels.WARN)
        return
    end
    if use_telescope() then
        telescope_pick(requests, on_choice)
    else
        native_pick(requests, on_choice)
    end
end

return M
