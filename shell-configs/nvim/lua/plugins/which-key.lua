return {
    "folke/which-key.nvim",
    event = "VeryLazy",
    config = function()
        local wk = require("which-key")
        wk.setup({
            delay = 300,
        })
        wk.add({
            { "<leader>?", desc = "Keybinding cheatsheet" },
            { "<leader>f", group = "Find" },
            { "<leader>g", group = "Git" },
            { "<leader>w", group = "Worktrees" },
            { "<leader>ww", desc = "Dashboard" },
            { "<leader>b", group = "Buffer" },
        })
    end,
}
