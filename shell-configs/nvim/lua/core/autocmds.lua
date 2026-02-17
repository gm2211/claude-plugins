-- Autocommands

local augroup = vim.api.nvim_create_augroup
local autocmd = vim.api.nvim_create_autocmd

-- Highlight on yank
augroup("YankHighlight", { clear = true })
autocmd("TextYankPost", {
    group = "YankHighlight",
    callback = function()
        vim.highlight.on_yank({ higroup = "IncSearch", timeout = 200 })
    end,
})

-- Auto-reload files changed outside vim
augroup("AutoRead", { clear = true })
autocmd({ "FocusGained", "BufEnter", "CursorHold" }, {
    group = "AutoRead",
    command = "silent! checktime",
})

-- Remove trailing whitespace on save
augroup("TrimWhitespace", { clear = true })
autocmd("BufWritePre", {
    group = "TrimWhitespace",
    pattern = "*",
    command = "%s/\\s\\+$//e",
})

-- Return to last edit position when opening files
augroup("LastPosition", { clear = true })
autocmd("BufReadPost", {
    group = "LastPosition",
    callback = function()
        local mark = vim.api.nvim_buf_get_mark(0, '"')
        local lcount = vim.api.nvim_buf_line_count(0)
        if mark[1] > 0 and mark[1] <= lcount then
            pcall(vim.api.nvim_win_set_cursor, 0, mark)
        end
    end,
})

-- Resize splits when window is resized
augroup("ResizeSplits", { clear = true })
autocmd("VimResized", {
    group = "ResizeSplits",
    command = "tabdo wincmd =",
})
