return {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose" },
    keys = {
        { "<leader>gd", "<cmd>DiffviewOpen<CR>", desc = "Diff current worktree" },
        { "<leader>gh", "<cmd>DiffviewFileHistory %<CR>", desc = "File history (current file)" },
        { "<leader>gH", "<cmd>DiffviewFileHistory<CR>", desc = "File history (repo)" },
        { "<leader>gc", "<cmd>DiffviewClose<CR>", desc = "Close diffview" },
    },
    opts = {
        enhanced_diff_hl = true,
        view = {
            default = {
                layout = "diff2_horizontal",
            },
            merge_tool = {
                layout = "diff3_horizontal",
            },
            file_history = {
                layout = "diff2_horizontal",
            },
        },
        file_panel = {
            listing_style = "tree",
            win_config = {
                position = "left",
                width = 35,
            },
        },
    },
}
