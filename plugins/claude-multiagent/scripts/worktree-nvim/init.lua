-- Worktree Nvim — self-contained config for claude-multiagent dashboard
-- Launch: nvim -u /path/to/init.lua --clean -c "cd /project"

-- Isolated data/state directories
local data_dir = vim.fn.expand("~/.local/share/claude-worktree-nvim")
local state_dir = vim.fn.expand("~/.local/state/claude-worktree-nvim")
vim.opt.runtimepath:prepend(data_dir)
vim.opt.packpath:prepend(data_dir)
vim.fn.mkdir(data_dir, "p")
vim.fn.mkdir(state_dir, "p")
vim.fn.mkdir(state_dir .. "/swap", "p")
vim.fn.mkdir(state_dir .. "/undo", "p")

-- Basic settings
vim.g.mapleader = " "
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.signcolumn = "yes"
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.undofile = true
vim.opt.undodir = state_dir .. "/undo"
vim.opt.shadafile = state_dir .. "/shada"
vim.cmd("filetype plugin indent on")
vim.cmd("syntax enable")
vim.cmd("colorscheme habamax")

-- Bootstrap lazy.nvim
local lazypath = data_dir .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", lazypath,
  })
end
vim.opt.runtimepath:prepend(lazypath)

-- Plugins
require("lazy").setup({
  {
    "sindrets/diffview.nvim",
    dependencies = { "nvim-lua/plenary.nvim", "nvim-tree/nvim-web-devicons" },
  },
}, {
  root = data_dir .. "/lazy",
  lockfile = data_dir .. "/lazy-lock.json",
  state = state_dir .. "/lazy/state.json",
  readme = { enabled = false },
})

-- Helper: detect default branch
local function default_branch()
  local result = vim.fn.system("git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null")
  local branch = result:match("refs/remotes/origin/(.+)")
  if branch then return vim.trim(branch) end
  -- fallback: check if main or master exists
  if vim.fn.system("git rev-parse --verify main 2>/dev/null") ~= "" then return "main" end
  return "master"
end

-- Helper: worktree picker
local function worktree_picker()
  local output = vim.fn.system("git worktree list --porcelain")
  local worktrees = {}
  local current_path = nil
  for line in output:gmatch("[^\n]+") do
    local path = line:match("^worktree (.+)")
    if path then current_path = path end
    local branch = line:match("^branch refs/heads/(.+)")
    if branch and current_path then
      table.insert(worktrees, { path = current_path, branch = branch })
      current_path = nil
    end
  end
  if #worktrees == 0 then
    vim.notify("No worktrees found", vim.log.levels.WARN)
    return
  end
  vim.ui.select(worktrees, {
    prompt = "Select worktree:",
    format_item = function(item) return item.branch .. "  " .. item.path end,
  }, function(choice)
    if choice then
      vim.cmd("cd " .. vim.fn.fnameescape(choice.path))
      vim.cmd("DiffviewOpen")
      vim.notify("Switched to: " .. choice.branch)
    end
  end)
end

-- Keymaps
vim.keymap.set("n", "<leader>d", "<cmd>DiffviewOpen<cr>", { desc = "Diff uncommitted" })
vim.keymap.set("n", "<leader>m", function()
  vim.cmd("DiffviewOpen " .. default_branch())
end, { desc = "Diff vs main" })
vim.keymap.set("n", "<leader>w", worktree_picker, { desc = "Worktree picker" })
vim.keymap.set("n", "<leader>h", "<cmd>DiffviewFileHistory<cr>", { desc = "File history" })
vim.keymap.set("n", "<leader>c", "<cmd>DiffviewClose<cr>", { desc = "Close diffview" })
vim.keymap.set("n", "q", function()
  -- Only quit if not in a diffview buffer
  if vim.bo.filetype:match("^Diffview") then
    vim.cmd("DiffviewClose")
  else
    vim.cmd("quit")
  end
end, { desc = "Quit / close diffview" })

-- Auto-open DiffviewOpen on startup (with retry for slow plugin loads)
vim.api.nvim_create_autocmd("VimEnter", {
  callback = function()
    local attempts = 0
    local max_attempts = 3
    local function try_open()
      attempts = attempts + 1
      if vim.fn.exists(":DiffviewOpen") == 2 then
        pcall(vim.cmd, "DiffviewOpen")
      elseif attempts < max_attempts then
        vim.defer_fn(try_open, 1000)
      else
        vim.notify("Diffview not ready — press <Space>d to open manually", vim.log.levels.INFO)
      end
    end
    vim.defer_fn(try_open, 1000)
  end,
})
