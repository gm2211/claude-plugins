return {
    "nvim-neo-tree/neo-tree.nvim",
    branch = "v3.x",
    dependencies = {
        "nvim-lua/plenary.nvim",
        "nvim-tree/nvim-web-devicons",
        "MunifTanjim/nui.nvim",
    },
    keys = {
        { "<leader>e", "<cmd>Neotree toggle<CR>", desc = "Toggle file explorer" },
        { "<leader>E", "<cmd>Neotree focus<CR>", desc = "Focus file explorer" },
    },
    opts = {
        close_if_last_window = true,
        filesystem = {
            follow_current_file = {
                enabled = true,
            },
            filtered_items = {
                visible = true,
                hide_dotfiles = false,
                hide_gitignored = false,
            },
        },
        default_component_configs = {
            git_status = {
                symbols = {
                    added = "+",
                    modified = "~",
                    deleted = "x",
                    renamed = "r",
                    untracked = "?",
                    ignored = "!",
                    unstaged = "U",
                    staged = "S",
                    conflict = "C",
                },
            },
        },
        window = {
            position = "left",
            width = 35,
        },
    },
}
