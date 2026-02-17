-- Central state object for worktree dashboard
-- Manages data, cursor positions, pane coordination

local git = require("worktrees.git")

local M = {}

--- The global dashboard state
---@class WtState
M.s = {
    open = false,
    main_root = nil,
    -- Data
    worktrees = {},   -- {path, branch, is_current, dirty, ci_status, ahead, behind}[]
    files = {},       -- {path, status, staged, x, y}[]
    log = {},         -- {hash, subject, author, date, refs}[]
    -- Cursors (1-indexed)
    wt_cursor = 1,
    file_cursor = 1,
    log_cursor = 1,
    -- Active pane: 1=left, 2=middle, 3=right
    active_pane = 1,
    -- Filter
    filter_text = "",
    -- Window/buffer IDs
    tab = nil,
    wins = {},   -- {left, middle, right}
    bufs = {},   -- {left, middle, right}
    -- Async generation counter to discard stale callbacks
    generation = 0,
}

--- Get the currently selected worktree
---@return table|nil
function M.selected_wt()
    return M.s.worktrees[M.s.wt_cursor]
end

--- Initialize dashboard state and populate data
---@param main_root string
function M.open(main_root)
    local ui = require("worktrees.ui")
    M.s.main_root = main_root
    M.s.open = true
    M.s.generation = 0
    M.s.wt_cursor = 1
    M.s.file_cursor = 1
    M.s.log_cursor = 1
    M.s.active_pane = 1
    M.s.filter_text = ""

    -- Create layout
    ui.create_layout()

    -- Load worktrees (sync — fast local operation)
    M.refresh_worktrees()

    -- Async-load files + log for the first selected worktree
    M.refresh_secondary()
end

--- Close the dashboard
function M.close()
    if not M.s.open then return end
    M.s.open = false
    M.s.generation = M.s.generation + 1
    local ui = require("worktrees.ui")
    ui.close_layout()
end

--- Refresh the worktree list (sync)
function M.refresh_worktrees()
    M.s.worktrees = git.list_worktrees_raw(M.s.main_root)
    -- Clamp cursor
    if M.s.wt_cursor > #M.s.worktrees then
        M.s.wt_cursor = math.max(1, #M.s.worktrees)
    end
    local ui = require("worktrees.ui")
    if M.s.open then
        ui.render_left()
    end
end

--- Refresh files + log for the selected worktree (async)
function M.refresh_secondary()
    local wt = M.selected_wt()
    if not wt then return end

    M.s.generation = M.s.generation + 1
    local gen = M.s.generation

    -- Load changed files
    git.changed_files(wt.path, function(files)
        if gen ~= M.s.generation then return end
        M.s.files = files
        M.s.file_cursor = math.min(M.s.file_cursor, math.max(1, #files))
        local ui = require("worktrees.ui")
        if M.s.open then ui.render_middle() end
    end)

    -- Load git log
    git.log(wt.path, 50, function(entries)
        if gen ~= M.s.generation then return end
        M.s.log = entries
        M.s.log_cursor = math.min(M.s.log_cursor, math.max(1, #entries))
        local ui = require("worktrees.ui")
        if M.s.open then ui.render_right() end
    end)
end

--- Refresh everything
function M.refresh_all()
    M.refresh_worktrees()
    M.refresh_secondary()
    -- Also refresh CI and dirty status in the background
    M.refresh_wt_metadata()
end

--- Refresh dirty/CI/ahead-behind metadata for all worktrees
function M.refresh_wt_metadata()
    for i, wt in ipairs(M.s.worktrees) do
        git.is_dirty(wt.path, function(dirty)
            if M.s.worktrees[i] then
                M.s.worktrees[i].dirty = dirty
                local ui = require("worktrees.ui")
                if M.s.open then ui.render_left() end
            end
        end)
        git.ahead_behind(wt.path, function(ahead, behind)
            if M.s.worktrees[i] then
                M.s.worktrees[i].ahead = ahead
                M.s.worktrees[i].behind = behind
                local ui = require("worktrees.ui")
                if M.s.open then ui.render_left() end
            end
        end)
    end
end

--- Move worktree cursor by delta, refresh secondary panes
---@param delta number
function M.move_wt_cursor(delta)
    local count = #M.s.worktrees
    if count == 0 then return end
    M.s.wt_cursor = ((M.s.wt_cursor - 1 + delta) % count) + 1
    M.s.file_cursor = 1
    M.s.log_cursor = 1
    local ui = require("worktrees.ui")
    ui.render_left()
    M.refresh_secondary()
end

--- Move file cursor by delta
---@param delta number
function M.move_file_cursor(delta)
    local count = #M.s.files
    if count == 0 then return end
    M.s.file_cursor = ((M.s.file_cursor - 1 + delta) % count) + 1
    local ui = require("worktrees.ui")
    ui.render_middle()
end

--- Move log cursor by delta
---@param delta number
function M.move_log_cursor(delta)
    local count = #M.s.log
    if count == 0 then return end
    M.s.log_cursor = ((M.s.log_cursor - 1 + delta) % count) + 1
    local ui = require("worktrees.ui")
    ui.render_right()
end

--- Switch to the selected worktree (cd + update panes)
function M.switch_to_worktree()
    local wt = M.selected_wt()
    if not wt then return end
    vim.cmd("cd " .. vim.fn.fnameescape(wt.path))
    vim.notify("Switched to: " .. wt.branch)
    M.refresh_worktrees()
    M.refresh_secondary()
end

--- Toggle stage/unstage for the selected file
function M.toggle_stage()
    local file = M.s.files[M.s.file_cursor]
    if not file then return end
    local wt = M.selected_wt()
    if not wt then return end

    local cb = function()
        M.refresh_secondary()
    end

    if file.staged then
        git.unstage_file(wt.path, file.path, function() cb() end)
    else
        git.stage_file(wt.path, file.path, function() cb() end)
    end
end

--- Stage all files
function M.stage_all()
    local wt = M.selected_wt()
    if not wt then return end
    git.stage_all(wt.path, function()
        M.refresh_secondary()
    end)
end

--- Unstage all files
function M.unstage_all()
    local wt = M.selected_wt()
    if not wt then return end
    git.unstage_all(wt.path, function()
        M.refresh_secondary()
    end)
end

--- Discard changes to the selected file (requires confirmation from caller)
function M.discard_file()
    local file = M.s.files[M.s.file_cursor]
    if not file then return end
    local wt = M.selected_wt()
    if not wt then return end
    local is_untracked = file.x == "?" and file.y == "?"
    git.discard_file(wt.path, file.path, is_untracked, function(ok)
        if ok then
            M.refresh_secondary()
        else
            vim.notify("Failed to discard: " .. file.path, vim.log.levels.ERROR)
        end
    end)
end

--- Open the commit message editor (floating window)
function M.start_commit()
    local wt = M.selected_wt()
    if not wt then return end

    -- Check for staged files
    local has_staged = false
    for _, f in ipairs(M.s.files) do
        if f.staged then has_staged = true; break end
    end
    if not has_staged then
        vim.notify("No staged files to commit", vim.log.levels.WARN)
        return
    end

    local ui_mod = require("worktrees.ui")
    ui_mod.open_commit_editor(function(message)
        if not message or message == "" then return end
        git.commit(wt.path, message, function(ok, output)
            if ok then
                vim.notify("Committed!")
                M.refresh_secondary()
                M.refresh_worktrees()
            else
                vim.notify("Commit failed: " .. output, vim.log.levels.ERROR)
            end
        end)
    end)
end

--- Create a new worktree (prompts for branch name)
function M.create_worktree()
    vim.ui.input({ prompt = "New branch name: " }, function(branch)
        if not branch or branch == "" then return end
        git.create_worktree(M.s.main_root, branch, function(ok, output)
            if ok then
                vim.notify("Created worktree: " .. branch)
                M.refresh_worktrees()
                M.refresh_wt_metadata()
            else
                vim.notify("Failed: " .. output, vim.log.levels.ERROR)
            end
        end)
    end)
end

--- Create worktree from PR or issue number
function M.create_from_pr_or_issue()
    vim.ui.input({ prompt = "PR or issue # (prefix with i for issue, e.g. i42): " }, function(input)
        if not input or input == "" then return end
        local is_issue = input:match("^i(%d+)$")
        local num = is_issue or input:match("^(%d+)$")
        if not num then
            vim.notify("Invalid input. Use a number or i<number> for issues.", vim.log.levels.WARN)
            return
        end
        local cb = function(ok, output)
            if ok then
                vim.notify("Created worktree from " .. (is_issue and "issue" or "PR") .. " #" .. num)
                M.refresh_worktrees()
                M.refresh_wt_metadata()
            else
                vim.notify("Failed: " .. output, vim.log.levels.ERROR)
            end
        end
        if is_issue then
            git.create_from_issue(M.s.main_root, num, cb)
        else
            git.create_from_pr(M.s.main_root, num, cb)
        end
    end)
end

--- Delete the selected worktree (with confirmation)
function M.delete_worktree()
    local wt = M.selected_wt()
    if not wt then return end
    vim.ui.input({ prompt = "Delete worktree '" .. wt.branch .. "'? (y/N): " }, function(answer)
        if answer ~= "y" and answer ~= "Y" then return end
        git.delete_worktree(M.s.main_root, wt.path, function(ok, output)
            if ok then
                vim.notify("Deleted: " .. wt.branch)
                M.refresh_worktrees()
                M.refresh_secondary()
            else
                vim.notify("Failed: " .. output, vim.log.levels.ERROR)
            end
        end)
    end)
end

--- Fetch for selected worktree
function M.fetch_selected()
    local wt = M.selected_wt()
    if not wt then return end
    vim.notify("Fetching...")
    git.fetch(wt.path, function(ok)
        if ok then
            vim.notify("Fetch complete")
            M.refresh_all()
        else
            vim.notify("Fetch failed", vim.log.levels.ERROR)
        end
    end)
end

--- Fetch all remotes
function M.fetch_all()
    local wt = M.selected_wt()
    if not wt then return end
    vim.notify("Fetching all remotes...")
    git.fetch_all(wt.path, function(ok)
        if ok then
            vim.notify("Fetch all complete")
            M.refresh_all()
        else
            vim.notify("Fetch all failed", vim.log.levels.ERROR)
        end
    end)
end

--- Open PR in browser for selected worktree
function M.open_pr()
    local wt = M.selected_wt()
    if not wt then return end
    git.open_pr_url(wt.branch)
end

--- Refresh CI status for selected worktree
function M.refresh_ci()
    local wt = M.selected_wt()
    if not wt then return end
    local idx = M.s.wt_cursor
    git.ci_status(wt.branch, function(status)
        if M.s.worktrees[idx] then
            M.s.worktrees[idx].ci_status = status
            local ui = require("worktrees.ui")
            if M.s.open then ui.render_left() end
        end
    end)
end

--- Open diffview for selected worktree
function M.open_diffview()
    local wt = M.selected_wt()
    if not wt then return end
    local base = git.merge_base(wt.path)
    if base then
        vim.cmd("DiffviewOpen " .. base .. "..HEAD")
    else
        vim.cmd("DiffviewOpen")
    end
end

--- Open Neogit
function M.open_neogit()
    local wt = M.selected_wt()
    if not wt then return end
    vim.cmd("cd " .. vim.fn.fnameescape(wt.path))
    vim.cmd("Neogit")
end

--- Open selected file in a split
function M.open_file()
    local file = M.s.files[M.s.file_cursor]
    if not file then return end
    local wt = M.selected_wt()
    if not wt then return end
    M.close()
    vim.cmd("edit " .. vim.fn.fnameescape(wt.path .. "/" .. file.path))
end

--- Diff selected file
function M.diff_file()
    local file = M.s.files[M.s.file_cursor]
    if not file then return end
    local wt = M.selected_wt()
    if not wt then return end
    M.close()
    vim.cmd("cd " .. vim.fn.fnameescape(wt.path))
    vim.cmd("DiffviewOpen -- " .. vim.fn.fnameescape(file.path))
end

--- Show commit diff in diffview
function M.show_commit()
    local entry = M.s.log[M.s.log_cursor]
    if not entry then return end
    M.close()
    vim.cmd("DiffviewOpen " .. entry.hash .. "^.." .. entry.hash)
end

--- Yank commit hash
function M.yank_hash()
    local entry = M.s.log[M.s.log_cursor]
    if not entry then return end
    vim.fn.setreg("+", entry.hash)
    vim.notify("Yanked: " .. entry.hash)
end

return M
