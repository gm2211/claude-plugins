-- Neovim configuration entry point
-- Loads core settings, then plugins via lazy.nvim, then custom modules

-- Core settings (must load before plugins)
require("core.options")
require("core.keymaps")
require("core.autocmds")

-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
    local out = vim.fn.system({
        "git",
        "clone",
        "--filter=blob:none",
        "https://github.com/folke/lazy.nvim.git",
        "--branch=stable",
        lazypath,
    })
    if vim.v.shell_error ~= 0 then
        vim.api.nvim_echo({
            { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
            { out, "WarningMsg" },
        }, true, {})
    end
end
vim.opt.rtp:prepend(lazypath)

-- Load all plugin specs from lua/plugins/*.lua
require("lazy").setup({
    spec = {
        { import = "plugins" },
    },
    defaults = {
        lazy = true,
    },
    install = {
        colorscheme = { "dracula" },
    },
    checker = {
        enabled = false,
    },
    performance = {
        rtp = {
            disabled_plugins = {
                "gzip",
                "matchit",
                "matchparen",
                "netrwPlugin",
                "tarPlugin",
                "tohtml",
                "tutor",
                "zipPlugin",
            },
        },
    },
})

-- Custom worktree navigation (loaded after plugins)
vim.api.nvim_create_autocmd("User", {
    pattern = "VeryLazy",
    callback = function()
        local ok, wt = pcall(require, "worktrees")
        if ok then
            wt.setup_keymaps()
        end
    end,
})

-- :Review command — opens worktree dashboard (use from shell: nvim +Review)
vim.api.nvim_create_user_command("Review", function()
    require("worktrees").open()
end, { desc = "Open worktree dashboard" })

-- :WorktreeDashboard alias
vim.api.nvim_create_user_command("WorktreeDashboard", function()
    require("worktrees").open()
end, { desc = "Open worktree dashboard" })

-- Go home: close review views and cd back to project root
vim.api.nvim_create_user_command("ReviewHome", function()
    -- Close diffview if open
    pcall(vim.cmd, "DiffviewClose")
    -- Close neogit if open
    pcall(vim.cmd, "Neogit close")
    -- cd back to the git toplevel (main repo, not worktree)
    local toplevel = vim.fn.systemlist("git -C " .. vim.fn.getcwd() .. " rev-parse --show-toplevel")[1]
    if toplevel and toplevel ~= "" then
        -- Check if this is a worktree — if so, go to the main repo root
        local common_dir = vim.fn.systemlist("git -C " .. toplevel .. " rev-parse --git-common-dir")[1]
        if common_dir and common_dir:match("%.git/worktrees/") then
            -- We're in a worktree — the main repo is the parent of .git
            local main_root = vim.fn.fnamemodify(common_dir:gsub("/%.git/worktrees/.*$", ""), ":p")
            vim.cmd("cd " .. vim.fn.fnameescape(main_root))
        else
            vim.cmd("cd " .. vim.fn.fnameescape(toplevel))
        end
    end
    vim.notify("Back to project root: " .. vim.fn.getcwd(), vim.log.levels.INFO)
end, { desc = "Close review views and return to project root" })

vim.keymap.set("n", "<leader>w0", "<cmd>ReviewHome<CR>", { desc = "Go home (close views, cd to root)" })

-- :Cheatsheet command — floating keybinding reference
vim.api.nvim_create_user_command("Cheatsheet", function()
    require("core.cheatsheet").open()
end, { desc = "Show keybinding cheatsheet" })

vim.keymap.set("n", "<leader>?", "<cmd>Cheatsheet<CR>", { desc = "Keybinding cheatsheet" })

-- Auto-launch worktree dashboard on startup if worktrees exist
vim.api.nvim_create_autocmd("VimEnter", {
    callback = function()
        -- Skip if opened with a file argument or the +Review command
        if vim.fn.argc() > 0 then
            return
        end
        vim.defer_fn(function()
            local ok, wt = pcall(require, "worktrees")
            if ok then
                local worktrees = wt.list_worktrees()
                if #worktrees > 0 then
                    wt.open()
                end
            end
        end, 100) -- small delay to let plugins finish loading
    end,
})
