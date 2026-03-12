---@type LazySpec
return {
  "AstroNvim/astrocore",
  ---@type AstroCoreOpts
  opts = {
    features = {
      large_buf = { size = 1024 * 256, lines = 10000 },
      autopairs = true,
      cmp = true,
      diagnostics = { virtual_text = true, virtual_lines = false },
      highlighturl = true,
      notifications = true,
    },
    diagnostics = {
      virtual_text = true,
      underline = true,
    },
    options = {
      opt = {
        relativenumber = true,
        number = true,
        spell = false,
        signcolumn = "yes",
        wrap = true,
        linebreak = true, -- wrap at word boundaries, not mid-word
        autoread = true, -- auto-reload files changed on disk
      },
      g = {},
    },
    autocmds = {
      -- auto-reload files when they change on disk
      auto_reload = {
        {
          event = { "FocusGained", "BufEnter", "CursorHold" },
          desc = "Check for file changes and reload",
          callback = function()
            if vim.fn.getcmdwintype() == "" then vim.cmd("checktime") end
          end,
        },
        {
          event = "FileChangedShellPost",
          desc = "Notify on file reload",
          callback = function() vim.notify("File changed on disk. Reloaded.", vim.log.levels.INFO) end,
        },
      },
    },
    mappings = {
      n = {
        -- navigate buffer tabs
        ["]b"] = { function() require("astrocore.buffer").nav(vim.v.count1) end, desc = "Next buffer" },
        ["[b"] = { function() require("astrocore.buffer").nav(-vim.v.count1) end, desc = "Previous buffer" },

        -- arrow key buffer cycling
        ["<Right>"] = { function() require("astrocore.buffer").nav(vim.v.count1) end, desc = "Next buffer" },
        ["<Left>"] = { function() require("astrocore.buffer").nav(-vim.v.count1) end, desc = "Previous buffer" },

        -- close buffer from tabline
        ["<Leader>bd"] = {
          function()
            require("astroui.status.heirline").buffer_picker(
              function(bufnr) require("astrocore.buffer").close(bufnr) end
            )
          end,
          desc = "Close buffer from tabline",
        },
      },
    },
  },
}
