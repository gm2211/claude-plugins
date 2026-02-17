-- Layout, rendering, keymaps, and help overlay for worktree dashboard

local M = {}

local ns = vim.api.nvim_create_namespace("worktree_dashboard")

--- Highlight groups (set once)
local function setup_highlights()
    local hi = vim.api.nvim_set_hl
    hi(0, "WtHeader", { bold = true, fg = "#bd93f9" })
    hi(0, "WtCurrent", { fg = "#50fa7b", bold = true })
    hi(0, "WtSelected", { fg = "#f8f8f2", bold = true })
    hi(0, "WtBranch", { fg = "#8be9fd" })
    hi(0, "WtDirty", { fg = "#ffb86c" })
    hi(0, "WtCIPass", { fg = "#50fa7b" })
    hi(0, "WtCIFail", { fg = "#ff5555" })
    hi(0, "WtCIPending", { fg = "#f1fa8c" })
    hi(0, "WtStaged", { fg = "#50fa7b" })
    hi(0, "WtModified", { fg = "#ffb86c" })
    hi(0, "WtUntracked", { fg = "#8be9fd" })
    hi(0, "WtHash", { fg = "#bd93f9" })
    hi(0, "WtDate", { fg = "#6272a4" })
    hi(0, "WtRefs", { fg = "#ff79c6" })
    hi(0, "WtStatusLine", { fg = "#6272a4", italic = true })
end

--- Get the state module (avoids circular require at load time)
local function state()
    return require("worktrees.state")
end

--- Create the three-pane layout in a new tab
function M.create_layout()
    setup_highlights()
    local s = state().s

    -- Save the current tab to return to on close
    s.prev_tab = vim.api.nvim_get_current_tabpage()

    -- New tab
    vim.cmd("tabnew")
    s.tab = vim.api.nvim_get_current_tabpage()

    -- Create 3 scratch buffers
    local function make_buf(name)
        local buf = vim.api.nvim_create_buf(false, true)
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].bufhidden = "wipe"
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = "worktree_dashboard"
        vim.api.nvim_buf_set_name(buf, "worktrees://" .. name)
        return buf
    end

    s.bufs = {
        left = make_buf("worktrees"),
        middle = make_buf("changes"),
        right = make_buf("log"),
    }

    -- Set up the left window (current window in new tab)
    local left_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(left_win, s.bufs.left)

    -- Create middle split
    vim.cmd("vsplit")
    local mid_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(mid_win, s.bufs.middle)

    -- Create right split
    vim.cmd("vsplit")
    local right_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right_win, s.bufs.right)

    s.wins = { left = left_win, middle = mid_win, right = right_win }

    -- Set widths: 25%, 40%, 35%
    local total_width = vim.o.columns
    vim.api.nvim_win_set_width(left_win, math.floor(total_width * 0.25))
    vim.api.nvim_win_set_width(mid_win, math.floor(total_width * 0.40))
    -- right gets the rest

    -- Window options for all panes
    for _, win in pairs(s.wins) do
        vim.wo[win].number = false
        vim.wo[win].relativenumber = false
        vim.wo[win].cursorline = true
        vim.wo[win].signcolumn = "no"
        vim.wo[win].wrap = false
        vim.wo[win].winfixwidth = true
        vim.wo[win].foldcolumn = "0"
    end

    -- Focus left pane
    vim.api.nvim_set_current_win(left_win)

    -- Set keymaps
    M.set_keymaps()
end

--- Close the dashboard layout
function M.close_layout()
    local s = state().s

    -- Close the dashboard tab
    if s.tab and vim.api.nvim_tabpage_is_valid(s.tab) then
        -- Switch to previous tab first, then close the dashboard tab
        if s.prev_tab and vim.api.nvim_tabpage_is_valid(s.prev_tab) then
            vim.api.nvim_set_current_tabpage(s.prev_tab)
        end
        -- Close dashboard tab by closing its windows
        for _, win in pairs(s.wins) do
            if vim.api.nvim_win_is_valid(win) then
                pcall(vim.api.nvim_win_close, win, true)
            end
        end
    end

    s.wins = {}
    s.bufs = {}
    s.tab = nil
end

--- Write lines to a buffer with highlights
---@param buf number
---@param lines string[]
---@param highlights table[] {line, col_start, col_end, group}
local function render_buf(buf, lines, highlights)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, hl in ipairs(highlights) do
        vim.api.nvim_buf_add_highlight(buf, ns, hl.group, hl.line, hl.col_start or 0, hl.col_end or -1)
    end
    vim.bo[buf].modifiable = false
end

--- Set cursor line in a pane's window
---@param win number
---@param line number 1-indexed
local function set_cursor(win, line)
    if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local line_count = vim.api.nvim_buf_line_count(buf)
        line = math.max(1, math.min(line, line_count))
        pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
    end
end

--- Render the left pane (worktree list)
function M.render_left()
    local s = state().s
    if not s.bufs.left then return end

    local lines = {}
    local highlights = {}

    table.insert(lines, "  WORKTREES")
    table.insert(highlights, { line = 0, group = "WtHeader" })
    table.insert(lines, "")

    for i, wt in ipairs(s.worktrees) do
        local prefix = (i == s.wt_cursor) and "> " or "  "
        local suffix = ""
        if wt.is_current then suffix = suffix .. " [*]" end
        if wt.dirty then suffix = suffix .. " ~" end
        if wt.ahead and wt.ahead > 0 then suffix = suffix .. " +" .. wt.ahead end
        if wt.behind and wt.behind > 0 then suffix = suffix .. " -" .. wt.behind end

        local line = prefix .. wt.branch .. suffix
        table.insert(lines, line)

        local line_idx = #lines - 1
        if i == s.wt_cursor then
            table.insert(highlights, { line = line_idx, group = "WtSelected" })
        elseif wt.is_current then
            table.insert(highlights, { line = line_idx, group = "WtCurrent" })
        else
            table.insert(highlights, { line = line_idx, col_start = 2, group = "WtBranch" })
        end

        -- CI badge on same line
        if wt.ci_status then
            local ci_text = "  CI:" .. wt.ci_status
            -- Already included in the line; add highlight for the CI part
            lines[#lines] = lines[#lines] .. ci_text
            local ci_start = #line
            local ci_group = "WtCIPending"
            if wt.ci_status == "success" then ci_group = "WtCIPass"
            elseif wt.ci_status == "failure" then ci_group = "WtCIFail" end
            table.insert(highlights, { line = line_idx, col_start = ci_start, group = ci_group })
        end
    end

    -- Status line at bottom
    table.insert(lines, "")
    local status = "  " .. #s.worktrees .. " worktrees"
    table.insert(lines, status)
    table.insert(highlights, { line = #lines - 1, group = "WtStatusLine" })

    render_buf(s.bufs.left, lines, highlights)
    -- Cursor on the selected worktree (line index = cursor + 1 for header + blank)
    set_cursor(s.wins.left, s.wt_cursor + 2)
end

--- Render the middle pane (changed files)
function M.render_middle()
    local s = state().s
    if not s.bufs.middle then return end

    local wt = state().selected_wt()
    local branch_name = wt and wt.branch or "—"

    local lines = {}
    local highlights = {}

    table.insert(lines, "  CHANGES (" .. branch_name .. ")")
    table.insert(highlights, { line = 0, group = "WtHeader" })
    table.insert(lines, "")

    local staged_count = 0
    local modified_count = 0

    for i, file in ipairs(s.files) do
        local prefix = (i == s.file_cursor) and "> " or "  "
        local status_char = file.status
        local line = prefix .. status_char .. " " .. file.path
        table.insert(lines, line)

        local line_idx = #lines - 1
        local status_group = "WtModified"
        if file.staged then
            status_group = "WtStaged"
            staged_count = staged_count + 1
        elseif file.status == "?" then
            status_group = "WtUntracked"
        else
            modified_count = modified_count + 1
        end
        -- Highlight status character
        table.insert(highlights, { line = line_idx, col_start = #prefix, col_end = #prefix + 1, group = status_group })
        if i == s.file_cursor then
            table.insert(highlights, { line = line_idx, col_start = 0, col_end = 1, group = "WtSelected" })
        end
    end

    if #s.files == 0 then
        table.insert(lines, "  (no changes)")
        table.insert(highlights, { line = #lines - 1, group = "WtStatusLine" })
    end

    -- Status line
    table.insert(lines, "")
    local status = string.format("  %d staged, %d modified", staged_count, modified_count)
    table.insert(lines, status)
    table.insert(highlights, { line = #lines - 1, group = "WtStatusLine" })

    render_buf(s.bufs.middle, lines, highlights)
    if #s.files > 0 then
        set_cursor(s.wins.middle, s.file_cursor + 2)
    end
end

--- Render the right pane (git log)
function M.render_right()
    local s = state().s
    if not s.bufs.right then return end

    local wt = state().selected_wt()
    local branch_name = wt and wt.branch or "—"

    local lines = {}
    local highlights = {}

    table.insert(lines, "  LOG (" .. branch_name .. ")")
    table.insert(highlights, { line = 0, group = "WtHeader" })
    table.insert(lines, "")

    for i, entry in ipairs(s.log) do
        local prefix = (i == s.log_cursor) and "> " or "  "
        local line = prefix .. entry.hash .. " " .. entry.subject
        if entry.date ~= "" then
            line = line .. "  " .. entry.date
        end
        table.insert(lines, line)

        local line_idx = #lines - 1
        -- Hash highlight
        local hash_end = #prefix + #entry.hash
        table.insert(highlights, { line = line_idx, col_start = #prefix, col_end = hash_end, group = "WtHash" })
        -- Date highlight
        if entry.date ~= "" then
            local date_start = #line - #entry.date
            table.insert(highlights, { line = line_idx, col_start = date_start, group = "WtDate" })
        end
        -- Refs highlight
        if entry.refs and entry.refs ~= "" then
            lines[#lines] = lines[#lines] .. " (" .. entry.refs .. ")"
            table.insert(highlights, { line = line_idx, col_start = #line, group = "WtRefs" })
        end
        if i == s.log_cursor then
            table.insert(highlights, { line = line_idx, col_start = 0, col_end = 1, group = "WtSelected" })
        end
    end

    if #s.log == 0 then
        table.insert(lines, "  (no commits)")
        table.insert(highlights, { line = #lines - 1, group = "WtStatusLine" })
    end

    -- Status line
    table.insert(lines, "")
    local status = "  " .. #s.log .. " commits"
    table.insert(lines, status)
    table.insert(highlights, { line = #lines - 1, group = "WtStatusLine" })

    render_buf(s.bufs.right, lines, highlights)
    if #s.log > 0 then
        set_cursor(s.wins.right, s.log_cursor + 2)
    end
end

--- Focus a specific pane (1=left, 2=middle, 3=right)
---@param n number
function M.focus_pane(n)
    local s = state().s
    local wins = { s.wins.left, s.wins.middle, s.wins.right }
    local win = wins[n]
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
        s.active_pane = n
    end
end

--- Determine which pane the current window belongs to
---@return number 1, 2, or 3
local function current_pane()
    local s = state().s
    local win = vim.api.nvim_get_current_win()
    if win == s.wins.left then return 1 end
    if win == s.wins.middle then return 2 end
    if win == s.wins.right then return 3 end
    return s.active_pane
end

--- Cycle to next/prev pane
---@param delta number 1 or -1
local function cycle_pane(delta)
    local cur = current_pane()
    local next = ((cur - 1 + delta) % 3) + 1
    M.focus_pane(next)
end

--- Show help overlay
function M.show_help()
    local help_lines = {
        "  Worktree Dashboard — Help",
        "  ════════════════════════════",
        "",
        "  NAVIGATION",
        "  1 / 2 / 3        Focus pane (left/mid/right)",
        "  Tab / S-Tab       Cycle panes",
        "  h / l             Prev/next pane",
        "  j / k             Navigate items",
        "  q                 Close dashboard",
        "  R                 Refresh all data",
        "  ?                 This help",
        "",
        "  LEFT PANE — Worktrees",
        "  Enter             Switch to worktree (cd)",
        "  a                 Create worktree",
        "  A                 Create from PR/issue #",
        "  d                 Delete worktree",
        "  f                 Fetch remote",
        "  F                 Fetch all remotes",
        "  p                 Open PR in browser",
        "  D                 Open Diffview",
        "  g                 Open Neogit",
        "  v                 Refresh CI status",
        "",
        "  MIDDLE PANE — Changed Files",
        "  Enter             Open file",
        "  s                 Stage/unstage file",
        "  S                 Stage all",
        "  u                 Unstage all",
        "  d                 Diff file",
        "  c                 Commit staged",
        "  x                 Discard changes",
        "",
        "  RIGHT PANE — Git Log",
        "  Enter             Show commit diff",
        "  y                 Yank commit hash",
        "",
        "  Press q or <Esc> to close",
    }

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, help_lines)

    local width = 0
    for _, line in ipairs(help_lines) do
        if #line > width then width = #line end
    end
    width = math.max(width + 4, 50)
    local height = #help_lines

    local ui = vim.api.nvim_list_uis()[1]
    local row = math.floor((ui.height - height) / 2)
    local col = math.floor((ui.width - width) / 2)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Help ",
        title_pos = "center",
    })

    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false

    -- Highlights
    local help_ns = vim.api.nvim_create_namespace("wt_help")
    for i, line in ipairs(help_lines) do
        if line:match("Dashboard") then
            vim.api.nvim_buf_add_highlight(buf, help_ns, "Title", i - 1, 0, -1)
        elseif line:match("═") then
            vim.api.nvim_buf_add_highlight(buf, help_ns, "FloatBorder", i - 1, 0, -1)
        elseif line:match("^  %u%u") then
            vim.api.nvim_buf_add_highlight(buf, help_ns, "Keyword", i - 1, 0, -1)
        end
    end

    local close = function() pcall(vim.api.nvim_win_close, win, true) end
    vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
    vim.keymap.set("n", "?", close, { buffer = buf, silent = true })
end

--- Open floating commit message editor
---@param cb fun(message: string|nil)
function M.open_commit_editor(cb)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].filetype = "gitcommit"

    local width = 60
    local height = 5
    local ui = vim.api.nvim_list_uis()[1]
    local row = math.floor((ui.height - height) / 2)
    local col = math.floor((ui.width - width) / 2)

    local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Commit Message (q=cancel, <C-CR>=commit) ",
        title_pos = "center",
    })

    vim.cmd("startinsert")

    -- Confirm with Ctrl+Enter
    vim.keymap.set({ "n", "i" }, "<C-CR>", function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local message = vim.trim(table.concat(lines, "\n"))
        pcall(vim.api.nvim_win_close, win, true)
        cb(message)
    end, { buffer = buf, silent = true })

    -- Also allow confirm with Enter in normal mode
    vim.keymap.set("n", "<CR>", function()
        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local message = vim.trim(table.concat(lines, "\n"))
        pcall(vim.api.nvim_win_close, win, true)
        cb(message)
    end, { buffer = buf, silent = true })

    -- Cancel
    local cancel = function()
        pcall(vim.api.nvim_win_close, win, true)
        cb(nil)
    end
    vim.keymap.set("n", "q", cancel, { buffer = buf, silent = true })
    vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true })
end

--- Set buffer-local keymaps for all panes
function M.set_keymaps()
    local s = state().s
    local st = state()

    local all_bufs = { s.bufs.left, s.bufs.middle, s.bufs.right }

    -- Global navigation keys on all buffers
    for _, buf in ipairs(all_bufs) do
        local opts = { buffer = buf, silent = true, nowait = true }

        -- Pane focus
        vim.keymap.set("n", "1", function() M.focus_pane(1) end, opts)
        vim.keymap.set("n", "2", function() M.focus_pane(2) end, opts)
        vim.keymap.set("n", "3", function() M.focus_pane(3) end, opts)
        vim.keymap.set("n", "<Tab>", function() cycle_pane(1) end, opts)
        vim.keymap.set("n", "<S-Tab>", function() cycle_pane(-1) end, opts)
        vim.keymap.set("n", "h", function() cycle_pane(-1) end, opts)
        vim.keymap.set("n", "l", function() cycle_pane(1) end, opts)

        -- Close
        vim.keymap.set("n", "q", function() st.close() end, opts)

        -- Refresh
        vim.keymap.set("n", "R", function() st.refresh_all() end, opts)

        -- Help
        vim.keymap.set("n", "?", function() M.show_help() end, opts)
    end

    -- Left pane — Worktrees
    local left_opts = { buffer = s.bufs.left, silent = true, nowait = true }
    vim.keymap.set("n", "j", function() st.move_wt_cursor(1) end, left_opts)
    vim.keymap.set("n", "k", function() st.move_wt_cursor(-1) end, left_opts)
    vim.keymap.set("n", "<CR>", function() st.switch_to_worktree() end, left_opts)
    vim.keymap.set("n", "a", function() st.create_worktree() end, left_opts)
    vim.keymap.set("n", "A", function() st.create_from_pr_or_issue() end, left_opts)
    vim.keymap.set("n", "d", function() st.delete_worktree() end, left_opts)
    vim.keymap.set("n", "f", function() st.fetch_selected() end, left_opts)
    vim.keymap.set("n", "F", function() st.fetch_all() end, left_opts)
    vim.keymap.set("n", "p", function() st.open_pr() end, left_opts)
    vim.keymap.set("n", "D", function() st.open_diffview() end, left_opts)
    vim.keymap.set("n", "g", function() st.open_neogit() end, left_opts)
    vim.keymap.set("n", "v", function() st.refresh_ci() end, left_opts)

    -- Middle pane — Changed files
    local mid_opts = { buffer = s.bufs.middle, silent = true, nowait = true }
    vim.keymap.set("n", "j", function() st.move_file_cursor(1) end, mid_opts)
    vim.keymap.set("n", "k", function() st.move_file_cursor(-1) end, mid_opts)
    vim.keymap.set("n", "<CR>", function() st.open_file() end, mid_opts)
    vim.keymap.set("n", "s", function() st.toggle_stage() end, mid_opts)
    vim.keymap.set("n", "S", function() st.stage_all() end, mid_opts)
    vim.keymap.set("n", "u", function() st.unstage_all() end, mid_opts)
    vim.keymap.set("n", "d", function() st.diff_file() end, mid_opts)
    vim.keymap.set("n", "c", function() st.start_commit() end, mid_opts)
    vim.keymap.set("n", "x", function()
        local file = s.files[s.file_cursor]
        if not file then return end
        vim.ui.input({ prompt = "Discard changes to '" .. file.path .. "'? (y/N): " }, function(ans)
            if ans == "y" or ans == "Y" then
                st.discard_file()
            end
        end)
    end, mid_opts)

    -- Right pane — Git log
    local right_opts = { buffer = s.bufs.right, silent = true, nowait = true }
    vim.keymap.set("n", "j", function() st.move_log_cursor(1) end, right_opts)
    vim.keymap.set("n", "k", function() st.move_log_cursor(-1) end, right_opts)
    vim.keymap.set("n", "<CR>", function() st.show_commit() end, right_opts)
    vim.keymap.set("n", "y", function() st.yank_hash() end, right_opts)

    -- Auto-close if any dashboard window is closed externally
    vim.api.nvim_create_autocmd("WinClosed", {
        callback = function(ev)
            if not s.open then return end
            local closed_win = tonumber(ev.match)
            if closed_win == s.wins.left or closed_win == s.wins.middle or closed_win == s.wins.right then
                vim.schedule(function()
                    st.close()
                end)
            end
        end,
    })
end

return M
