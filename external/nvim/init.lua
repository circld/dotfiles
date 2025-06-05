-- Set <space> as the leader key
-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- configure everything else
require("opts")
require("plugins")
require("functions")
require("keymaps")
require("autocommands")
require("aesthetics")
