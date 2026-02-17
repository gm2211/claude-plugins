-- Worktree Dashboard — Public API
-- Thin wrapper over state/ui/git modules, preserves backward compat for lualine

local M = {}

local git = require("worktrees.git")

--- Open the worktree dashboard
function M.open()
    local main_root = git.find_main_root()
    if not main_root then
        vim.notify("Not in a git repository with worktrees", vim.log.levels.WARN)
        return
    end
    local state = require("worktrees.state")
    if state.s.open then
        -- Already open — just focus it
        if state.s.tab and vim.api.nvim_tabpage_is_valid(state.s.tab) then
            vim.api.nvim_set_current_tabpage(state.s.tab)
        end
        return
    end
    state.open(main_root)
end

--- Close the worktree dashboard
function M.close()
    require("worktrees.state").close()
end

--- Get the name of the current worktree (for lualine)
---@return string|nil
function M.get_current_worktree()
    local cwd = vim.fn.getcwd()
    return cwd:match("/.worktrees/([^/]+)")
end

--- List worktrees (backward compat)
---@return table[]
function M.list_worktrees()
    return git.list_worktrees_raw()
end

--- Telescope picker — quick switch (preserved as shortcut)
function M.pick_worktree()
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local worktrees = M.list_worktrees()
    if #worktrees == 0 then
        vim.notify("No worktrees found", vim.log.levels.WARN)
        return
    end

    pickers.new({}, {
        prompt_title = "Worktrees",
        finder = finders.new_table({
            results = worktrees,
            entry_maker = function(entry)
                local display = entry.branch
                if entry.is_current then
                    display = display .. " (current)"
                end
                return { value = entry, display = display, ordinal = entry.branch }
            end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    local wt = selection.value
                    vim.cmd("cd " .. vim.fn.fnameescape(wt.path))
                    vim.notify("Switched to worktree: " .. wt.branch)
                end
            end)
            return true
        end,
    }):find()
end

--- Telescope picker — quick diff
function M.pick_worktree_diff()
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local worktrees = M.list_worktrees()
    if #worktrees == 0 then
        vim.notify("No worktrees found", vim.log.levels.WARN)
        return
    end

    pickers.new({}, {
        prompt_title = "Diff Worktree",
        finder = finders.new_table({
            results = worktrees,
            entry_maker = function(entry)
                return {
                    value = entry,
                    display = entry.branch .. " (" .. entry.path .. ")",
                    ordinal = entry.branch,
                }
            end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    local path = selection.value.path
                    local base = git.merge_base(path)
                    if base then
                        vim.cmd("DiffviewOpen " .. base .. "..HEAD")
                    else
                        vim.cmd("DiffviewOpen")
                    end
                end
            end)
            return true
        end,
    }):find()
end

--- Telescope picker — quick status
function M.pick_worktree_status()
    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")

    local worktrees = M.list_worktrees()
    if #worktrees == 0 then
        vim.notify("No worktrees found", vim.log.levels.WARN)
        return
    end

    pickers.new({}, {
        prompt_title = "Worktree Status",
        finder = finders.new_table({
            results = worktrees,
            entry_maker = function(entry)
                return {
                    value = entry,
                    display = entry.branch .. " (" .. entry.path .. ")",
                    ordinal = entry.branch,
                }
            end,
        }),
        sorter = conf.generic_sorter({}),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = action_state.get_selected_entry()
                if selection then
                    vim.cmd("cd " .. vim.fn.fnameescape(selection.value.path))
                    vim.cmd("Neogit")
                end
            end)
            return true
        end,
    }):find()
end

--- Setup keymaps
function M.setup_keymaps()
    vim.keymap.set("n", "<leader>ww", M.open, { desc = "Worktree dashboard" })
    vim.keymap.set("n", "<leader>wl", M.pick_worktree, { desc = "List worktrees (telescope)" })
    vim.keymap.set("n", "<leader>wd", M.pick_worktree_diff, { desc = "Diff a worktree" })
    vim.keymap.set("n", "<leader>ws", M.pick_worktree_status, { desc = "Worktree status" })
end

return M
