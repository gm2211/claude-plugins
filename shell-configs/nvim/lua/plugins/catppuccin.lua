---@type LazySpec
return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    opts = {
      flavour = "mocha",
    },
  },
  {
    "mason-org/mason-lspconfig.nvim",
    version = false, -- follow HEAD; AstroNvim v6 needs v2+ (mappings module)
  },
  {
    "AstroNvim/astrolsp",
    ---@type AstroLSPOpts
    opts = {
      native_lsp_config = true, -- use vim.lsp.config/enable instead of deprecated lspconfig framework
    },
  },
}
