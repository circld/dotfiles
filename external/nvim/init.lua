local flash = require("flash").setup {
  modes = { char = { enabled = false } }
}
vim.keymap.set("n", "f", function() require("flash").jump() end)
