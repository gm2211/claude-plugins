return {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    event = "VeryLazy",
    config = function()
        local function worktree_component()
            local ok, wt = pcall(require, "worktrees")
            if not ok then return "" end
            local name = wt.get_current_worktree()
            if name then
                return "[wt:" .. name .. "]"
            end
            return ""
        end

        require("lualine").setup({
            options = {
                theme = "dracula",
                component_separators = { left = "|", right = "|" },
                section_separators = { left = "", right = "" },
                globalstatus = true,
            },
            sections = {
                lualine_a = { "mode" },
                lualine_b = { "branch", "diff", "diagnostics" },
                lualine_c = { worktree_component, { "filename", path = 1 } },
                lualine_x = { "encoding", "fileformat", "filetype" },
                lualine_y = { "progress" },
                lualine_z = { "location" },
            },
        })
    end,
}
