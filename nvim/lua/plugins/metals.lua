return {
  "scalameta/nvim-metals",
  config = function()
    local nvim_metals_group = vim.api.nvim_create_augroup("nvim-metals", { clear = true })

    local metals_config = require("metals").bare_config()
    metals_config.init_options.statusBarProvider = "on"
    metals_config.settings = {
      showImplicitArguments = true,
      showInferredType = true,
    }

    vim.api.nvim_create_autocmd("FileType", {
      pattern = { "scala", "sbt" },
      callback = function()
        require("metals").initialize_or_attach(metals_config)
      end,
      group = nvim_metals_group,
    })

    local map = vim.keymap.set
    map("n", "gD", vim.lsp.buf.definition)
    map("n", "K", vim.lsp.buf.hover)
    map("n", "gi", vim.lsp.buf.implementation)
    map("n", "gr", vim.lsp.buf.references)
    map("n", "gds", vim.lsp.buf.document_symbol)
    map("n", "gws", vim.lsp.buf.workspace_symbol)
    map("n", "<leader>cn", vim.lsp.codelens.run)
    map("n", "<leader>sh", vim.lsp.buf.signature_help)
    map("n", "<leader>rn", vim.lsp.buf.rename)
    map("n", "<leader>f", vim.lsp.buf.format)
    map("n", "<leader>ca", vim.lsp.buf.code_action)
  end,
}
