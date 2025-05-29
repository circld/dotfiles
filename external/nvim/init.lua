-- TODO clean up once everything is configured
local flash = require("flash").setup {
  modes = { char = { enabled = false } }
}
vim.keymap.set("n", "f", function() require("flash").jump() end)

vim.cmd.colorscheme "space-vim-dark"
