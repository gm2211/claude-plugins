-- Core Neovim options (migrated from .vimrc / amix vimrc)

local opt = vim.opt

-- Leader key
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- History and undo
opt.history = 500

-- Auto-read when a file is changed from the outside
opt.autoread = true

-- UI
opt.scrolloff = 7
opt.wildmenu = true
opt.wildignore = { "*.o", "*~", "*.pyc", "*/.git/*", "*/.hg/*", "*/.svn/*", "*/.DS_Store" }
opt.ruler = true
opt.cmdheight = 1
opt.hidden = true
opt.backspace = { "eol", "start", "indent" }
opt.lazyredraw = true
opt.showmatch = true
opt.matchtime = 2
opt.foldcolumn = "1"
opt.number = true
opt.relativenumber = true
opt.signcolumn = "yes"
opt.termguicolors = true
opt.cursorline = true

-- No annoying sounds
opt.errorbells = false
opt.visualbell = false
vim.cmd("set t_vb=")

-- Search
opt.ignorecase = true
opt.smartcase = true
opt.hlsearch = true
opt.incsearch = true

-- No backup/swap
opt.backup = false
opt.swapfile = false
opt.writebackup = false

-- Tabs and indentation
opt.expandtab = true
opt.shiftwidth = 4
opt.tabstop = 4
opt.smarttab = true
opt.autoindent = true
opt.smartindent = true
opt.wrap = true

-- Encoding
opt.encoding = "utf-8"
opt.fileformats = { "unix", "dos", "mac" }

-- Split behavior
opt.splitbelow = true
opt.splitright = true

-- Faster update time (for gitsigns etc.)
opt.updatetime = 250
opt.timeoutlen = 400

-- Clipboard
opt.clipboard = "unnamedplus"

-- Mouse support
opt.mouse = "a"
