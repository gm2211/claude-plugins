return {
    "NeogitOrg/neogit",
    dependencies = {
        "nvim-lua/plenary.nvim",
        "sindrets/diffview.nvim",
        "nvim-telescope/telescope.nvim",
    },
    cmd = "Neogit",
    keys = {
        { "<leader>gs", "<cmd>Neogit<CR>", desc = "Git status (Neogit)" },
        { "<leader>gl", "<cmd>Neogit log<CR>", desc = "Git log" },
    },
    opts = {
        integrations = {
            diffview = true,
            telescope = true,
        },
        signs = {
            section = { ">", "v" },
            item = { ">", "v" },
        },
    },
}
