-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- conform-nvim: Format on save
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*",
  callback = function(args)
    require("conform").format({ bufnr = args.buf })
  end,
})

-- lsp
-- https://stackoverflow.com/a/79435977/3726041
vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
   callback = function()
     if vim.fn.mode() == "n" then
       vim.diagnostic.open_float(nil, { focus = false })
     end
   end
})

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})
