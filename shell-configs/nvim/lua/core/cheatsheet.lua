-- Floating cheatsheet for custom keybindings

local M = {}

local lines = {
    "    Neovim Cheatsheet",
    "    ═══════════════════════════════",
    "",
    "    GENERAL",
    "    Space s           Save file",
    "    Space e           Toggle file explorer",
    "    Space E           Focus file explorer",
    "    Space ?           This cheatsheet",
    "    Space Enter       Clear search highlight",
    "    jk                Exit insert mode",
    "    Ctrl+h/j/k/l     Navigate windows",
    "    0                 First non-blank char",
    "    Ctrl+d/u          Scroll down/up (centered)",
    "",
    "    BUFFER",
    "    Space l            Next buffer",
    "    Space h            Previous buffer",
    "    Space b d          Close buffer",
    "",
    "    GIT",
    "    Space g d          Open diff view",
    "    Space g h          File history (current)",
    "    Space g H          File history (repo)",
    "    Space g c          Close diff view",
    "    Space g s          Git status (Neogit)",
    "    Space g l          Git log",
    "    Space g b          Blame line (popup)",
    "    Space g B          Toggle inline blame",
    "    Space g p          Preview hunk",
    "    Space g S          Stage hunk",
    "    Space g r          Reset hunk",
    "    Space g u          Undo stage hunk",
    "",
    "    WORKTREES",
    "    Space w w          Worktree dashboard",
    "    Space w l          List worktrees (telescope)",
    "    Space w d          Diff worktree",
    "    Space w s          Worktree status",
    "    Space w 0          Go home (close views, cd root)",
    "",
    "    DASHBOARD (when open)",
    "    1 / 2 / 3          Focus pane",
    "    Tab / S-Tab         Cycle panes",
    "    h / l               Prev/next pane",
    "    j / k               Navigate items",
    "    q                   Close dashboard",
    "    R                   Refresh all",
    "    ?                   Help overlay",
    "    a / A               Create worktree / from PR",
    "    d                   Delete worktree",
    "    s / S / u            Stage/all/unstage",
    "    c                   Commit staged",
    "",
    "    FIND (Telescope)",
    "    Space f f          Find files",
    "    Space f g          Live grep",
    "    Space f b          Buffers",
    "    Space f h          Help tags",
    "    Space f r          Recent files",
    "    Space f c          Git commits",
    "    Space f s          Git status files",
    "",
    "    Press q or <Esc> to close",
}

function M.open()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- Size the window to fit content
    local width = 0
    for _, line in ipairs(lines) do
        if #line > width then
            width = #line
        end
    end
    width = math.max(width + 4, 50)
    local height = #lines

    -- Center in editor
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
        title = " Keybindings ",
        title_pos = "center",
    })

    -- Buffer settings
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].modifiable = false

    -- Highlight the title and section headers
    local ns = vim.api.nvim_create_namespace("cheatsheet")
    for i, line in ipairs(lines) do
        if line:match("Neovim Cheatsheet") then
            vim.api.nvim_buf_add_highlight(buf, ns, "Title", i - 1, 0, -1)
        elseif line:match("═") then
            vim.api.nvim_buf_add_highlight(buf, ns, "FloatBorder", i - 1, 0, -1)
        elseif line:match("^    %u%u") then
            vim.api.nvim_buf_add_highlight(buf, ns, "Keyword", i - 1, 0, -1)
        end
    end

    -- Close mappings
    local close_opts = { buffer = buf, silent = true }
    vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, close_opts)
    vim.keymap.set("n", "<Esc>", function() vim.api.nvim_win_close(win, true) end, close_opts)
end

return M
