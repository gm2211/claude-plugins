-- General keymaps (non-plugin)

local map = vim.keymap.set

-- jk to escape
map("i", "jk", "<Esc>", { desc = "Escape insert mode" })

-- Window navigation with Ctrl+hjkl
map("n", "<C-h>", "<C-w>h", { desc = "Move to left window" })
map("n", "<C-j>", "<C-w>j", { desc = "Move to lower window" })
map("n", "<C-k>", "<C-w>k", { desc = "Move to upper window" })
map("n", "<C-l>", "<C-w>l", { desc = "Move to right window" })

-- Save with leader+s (leader+w is reserved for worktrees)
map("n", "<leader>s", ":w!<CR>", { desc = "Save file", silent = true })

-- 0 goes to first non-blank character
map("n", "0", "^", { desc = "Go to first non-blank" })

-- / is the native search key (no mapping needed)

-- Clear search highlight
map("n", "<leader><CR>", ":nohlsearch<CR>", { desc = "Clear search highlight", silent = true })

-- Buffer navigation
map("n", "<leader>l", ":bnext<CR>", { desc = "Next buffer", silent = true })
map("n", "<leader>h", ":bprevious<CR>", { desc = "Previous buffer", silent = true })
map("n", "<leader>bd", ":bdelete<CR>", { desc = "Close buffer", silent = true })

-- Move lines up/down in visual mode
map("v", "J", ":m '>+1<CR>gv=gv", { desc = "Move selection down", silent = true })
map("v", "K", ":m '<-2<CR>gv=gv", { desc = "Move selection up", silent = true })

-- Keep cursor centered when scrolling
map("n", "<C-d>", "<C-d>zz", { desc = "Scroll down centered" })
map("n", "<C-u>", "<C-u>zz", { desc = "Scroll up centered" })

-- Resize windows with arrows
map("n", "<C-Up>", ":resize -2<CR>", { silent = true })
map("n", "<C-Down>", ":resize +2<CR>", { silent = true })
map("n", "<C-Left>", ":vertical resize -2<CR>", { silent = true })
map("n", "<C-Right>", ":vertical resize +2<CR>", { silent = true })
