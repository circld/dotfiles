-- [[ Plugin configuration ]]

-- https://cmp.saghen.dev/configuration/reference.html
require("blink-cmp").setup {
  completion = {
    -- TODO figure out how to avoid documentation from getting cut off near bottom of window
    documentation = {
      auto_show = true,
      window = {
        max_height = 50,
        direction_priority = {
          menu_north = { 'e', 'w', 'n', 's' },
          menu_south = { 'e', 'w', 's', 'n' },
        },
      },
    },
  },
  keymap = {
    preset = 'default',
    ['<S-Tab>'] = { 'select_prev', 'fallback' },
    ['<Tab>'] = { 'select_next', 'fallback' },
    ['<Enter>'] = { 'accept', 'fallback' },
  },
  signature = {
    enabled = true,
    window = {
      max_height = 50,
    },
  },
}

-- https://github.com/stevearc/conform.nvim
require("conform").setup({
  formatters_by_ft = {
    python = { "ruff_organize_imports", "ruff_format", "ruff_fix" },
    nix = { "nixfmt" },
  },
})

-- https://github.com/folke/flash.nvim?tab=readme-ov-file#%EF%B8%8F-configuration
local flash = require("flash").setup {
  modes = { char = { enabled = false } },
}

-- https://github.com/lewis6991/gitsigns.nvim
require("gitsigns").setup {}

-- https://github.com/neovim/nvim-lspconfig
-- nvim-lspconfig setup for Pyright
local lspconfig = require('lspconfig')

-- Configure Pyright as the LSP server for Python
lspconfig.pyright.setup{
  on_attach = function(client, bufnr)
    -- Enable signature help if supported by the LSP server
    if client.server_capabilities.signatureHelp then
      vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(vim.lsp.handlers.signature_help, {
        border = "rounded",  -- Optional: Adds a rounded border to signature help popups
      })
    end
  end,
  settings = {
    python = {
      analysis = {
        typeCheckingMode = "basic",  -- Can adjust this to "strict" or "off"
      },
    },
  },
}
require('lspconfig').nil_ls.setup {
  autostart = true,
  capabilities = caps,
  cmd = { "nil" },
  settings = {
    ['nil'] = {
      formatting = {
        command = { "nixfmt" },
      },
    },
  },
}
vim.lsp.enable({
  'pyright',
  'nil_ls'
})

-- https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-indentscope.md
-- TODO figure out how to change color to gray
require("mini.indentscope").setup {
  symbol = "",
  mappings = {
    -- Textobjects
    object_scope = 'ii',
    object_scope_with_border = 'ai',

    -- Motions (jump to respective border line; if not present - body line)
    goto_top = '[i',
    goto_bottom = ']i',
  },
}

-- https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-pairs.md
require("mini.pairs").setup {}

-- https://github.com/echasnovski/mini.nvim/blob/main/readmes/mini-statusline.md
require("mini.statusline").setup {}

-- https://github.com/echasnovski/mini.surround?tab=readme-ov-file#default-config
-- sa (add)
-- sd (delete)
-- sr (replace)
require("mini.surround").setup {}

-- https://github.com/catgoose/nvim-colorizer.lua
require("colorizer").setup {
  user_default_options = {
    names = false,
  },
}

-- https://github.com/Tummetott/unimpaired.nvim
require("unimpaired").setup {}

-- https://github.com/folke/which-key.nvim?tab=readme-ov-file#%EF%B8%8F-configuration
require("which-key").setup {
  -- delay between pressing a key and opening which-key (milliseconds)
  -- this setting is independent of vim.opt.timeoutlen
  delay = 0,
  icons = {
    -- set icon mappings to true if you have a Nerd Font
    mappings = vim.g.have_nerd_font,
    -- If you are using a Nerd Font: set icons.keys to an empty table which will use the
    -- default which-key.nvim defined Nerd Font icons, otherwise define a string table
    keys = vim.g.have_nerd_font and {} or {
      Up = '<Up> ',
      Down = '<Down> ',
      Left = '<Left> ',
      Right = '<Right> ',
      C = '<C-…> ',
      M = '<M-…> ',
      D = '<D-…> ',
      S = '<S-…> ',
      CR = '<CR> ',
      Esc = '<Esc> ',
      ScrollWheelDown = '<ScrollWheelDown> ',
      ScrollWheelUp = '<ScrollWheelUp> ',
      NL = '<NL> ',
      BS = '<BS> ',
      Space = '<Space> ',
      Tab = '<Tab> ',
      F1 = '<F1>',
      F2 = '<F2>',
      F3 = '<F3>',
      F4 = '<F4>',
      F5 = '<F5>',
      F6 = '<F6>',
      F7 = '<F7>',
      F8 = '<F8>',
      F9 = '<F9>',
      F10 = '<F10>',
      F11 = '<F11>',
      F12 = '<F12>',
    },
  },
  -- Document existing key chains
  spec = {
    { '<leader>s', group = '[S]earch' },
    -- TODO too add once other plugins are configured
    -- { '<leader>t', group = '[T]oggle' },
    -- { '<leader>h', group = 'Git [H]unk', mode = { 'n', 'v' } },
  },
}

-- https://github.com/folke/snacks.nvim
snacks = require("snacks").setup {
  -- https://github.com/folke/snacks.nvim/blob/main/docs/picker.md
  picker = {
    enabled = true,
    matcher = {
      frecency = true,
    },
    win = {
      input = {
        keys = {
          ["<up>"] = { "preview_scroll_up", mode = { "i", "n" } },
          ["<down>"] = { "preview_scroll_down", mode = { "i", "n" } },
        },
      },
    },
  },
}
