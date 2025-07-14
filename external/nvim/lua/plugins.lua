-- [[ Plugin configuration ]]
-- https://cmp.saghen.dev/configuration/reference.html
require("blink-cmp").setup {
  cmdline = {
    keymap = { preset = 'inherit' },
    completion = { ghost_text = { enabled = true }, menu = { auto_show = true } },
  },
  completion = {
    -- TODO figure out how to avoid documentation from getting cut off near bottom of window
    documentation = {
      auto_show = true,
      window = {
        max_height = 50,
        direction_priority = { menu_north = { 'e', 'w', 'n', 's' }, menu_south = { 'e', 'w', 's', 'n' } },
      },
    },
  },
  keymap = {
    preset = 'default',
    ['<S-Tab>'] = { 'select_prev', 'fallback' },
    ['<Tab>'] = { 'select_next', 'fallback' },
    ['<S-Enter>'] = { 'accept', 'fallback' },
    ['<C-C>'] = { 'cancel', 'fallback' },
  },
  signature = { enabled = true, window = { max_height = 50 } },
  sources = {
    providers = {
      path = {
        opts = {
          -- ./* relative to repo root
          get_cwd = function(_) return vim.fn.getcwd() end,
          show_hidden_files_by_default = true,
        },
      },
    },
  },
}

-- https://github.com/stevearc/conform.nvim
require("conform").setup(
  {
    formatters_by_ft = {
      sh = { "shellcheck", "shfmt" },
      lua = { "lua-format" },
      gleam = { "gleam" },
      python = { "ruff_organize_imports", "ruff_format", "ruff_fix", "black" },
      nix = { "nixfmt" },
      rust = { "rustfmt" },
      ["*"] = { "trim_newlines", "trim_whitespace" },
    },
  }
)

-- https://github.com/folke/flash.nvim?tab=readme-ov-file#%EF%B8%8F-configuration
local flash = require("flash").setup { modes = { char = { enabled = false } } }

-- https://github.com/lewis6991/gitsigns.nvim
require("gitsigns").setup {
  current_line_blame = true,
  current_line_blame_opts = { virt_text_pos = 'right_align' },
  signs = { delete = { show_count = true }, topdelete = { show_count = true } },
}

-- https://github.com/neovim/nvim-lspconfig
-- nvim-lspconfig setup for Pyright
local lspconfig = require('lspconfig')

-- https://github.com/bash-lsp/bash-language-server

-- Configure Pyright as the LSP server for Python
-- https://github.com/microsoft/pyright
lspconfig.pyright.setup {
  on_attach = function(client, bufnr)
    -- Enable signature help if supported by the LSP server
    if client.server_capabilities.signatureHelp then
      vim.lsp.handlers["textDocument/signatureHelp"] = vim.lsp.with(
        vim.lsp.handlers.signature_help, {
          border = "rounded", -- Optional: Adds a rounded border to signature help popups
        }
      )
    end
  end,
  settings = {
    python = {
      analysis = {
        typeCheckingMode = "basic", -- Can adjust this to "strict" or "off"
      },
    },
  },
}
-- https://github.com/oxalica/nil
require('lspconfig').nil_ls.setup {
  autostart = true,
  capabilities = caps,
  cmd = { "nil" },
  settings = { ['nil'] = { formatting = { command = { "nixfmt" } } } },
}

vim.lsp.config('rust_analyzer', { settings = { ['rust-analyzer'] = { diagnostics = { enable = false } } } })

vim.lsp.enable({ 'bashls', 'gleam', 'pyright', 'nil_ls', 'rust_analyzer' })

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
require("mini.statusline").setup {
  content = {
    -- remove git branch info as it crowds out more important information
    active = function()
      local mode, mode_hl = MiniStatusline.section_mode({ trunc_width = 120 })
      local diff = MiniStatusline.section_diff({ trunc_width = 75 })
      local diagnostics = MiniStatusline.section_diagnostics({ trunc_width = 75 })
      local lsp = MiniStatusline.section_lsp({ trunc_width = 75 })
      local filename = MiniStatusline.section_filename({ trunc_width = 140 })
      local fileinfo = MiniStatusline.section_fileinfo({ trunc_width = 120 })
      local location = MiniStatusline.section_location({ trunc_width = 75 })
      local search = MiniStatusline.section_searchcount({ trunc_width = 75 })
      ---
      return MiniStatusline.combine_groups(
        {
          { hl = mode_hl, strings = { mode } }, { hl = 'MiniStatuslineDevinfo', strings = { diff, diagnostics, lsp } },
          '%<', -- Mark general truncate point
          { hl = 'MiniStatuslineFilename', strings = { filename } }, '%=', -- End left alignment
          { hl = 'MiniStatuslineFileinfo', strings = { fileinfo } }, { hl = mode_hl, strings = { search, location } },
        }
      )
    end,
  },
}

-- https://github.com/echasnovski/mini.surround?tab=readme-ov-file#default-config
-- sa (add)
-- sd (delete)
-- sr (replace)
require("mini.surround").setup {}

-- https://github.com/folke/noice.nvim
require("noice").setup {
  presets = {
    bottom_search = true, -- use a classic bottom cmdline for search
    command_palette = true, -- position the cmdline and popupmenu together
    long_message_to_split = true, -- long messages will be sent to a split
    inc_rename = false, -- enables an input dialog for inc-rename.nvim
    lsp_doc_border = false, -- add a border to hover docs and signature help
  },
}

-- https://github.com/catgoose/nvim-colorizer.lua
require("colorizer").setup { user_default_options = { names = false } }

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
  spec = { { '<leader>s', group = '[S]earch' }, { '<leader>u', group = '[U]tility' } },
}

-- https://github.com/folke/snacks.nvim
snacks = require("snacks").setup {
  -- https://github.com/folke/snacks.nvim/blob/main/docs/picker.md
  picker = {
    enabled = true,
    matcher = { frecency = true },
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
