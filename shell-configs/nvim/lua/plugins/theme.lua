return {
    "Mofiqul/dracula.nvim",
    lazy = false,
    priority = 1000,
    config = function()
        require("dracula").setup({
            transparent_bg = false,
            italic_comment = true,
        })
        vim.cmd.colorscheme("dracula")
    end,
}
