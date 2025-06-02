-- [[ Setting options ]]
-- See `:help vim.opt`
-- For more options, you can see `:help option-list`

-- Set <space> as the leader key
-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = true

-- Make line numbers default
vim.opt.number = true
-- You can also add relative line numbers, to help with jumping.
--  Experiment for yourself to see if you like it!
-- vim.opt.relativenumber = true

-- Enable mouse mode, can be useful for resizing splits for example!
vim.opt.mouse = 'a'

-- Don't show the mode, since it's already in the status line
vim.opt.showmode = false

-- Blinking cursor
vim.o.guicursor = table.concat({
  'n-v-c:block-Cursor/lCursor-blinkwait100-blinkon100-blinkoff100',
  'i-ci:ver25-Cursor/lCursor-blinkwait100-blinkon100-blinkoff100',
  'r:hor50-Cursor/lCursor-blinkwait100-blinkon100-blinkoff100',
}, ',')

-- Enable break indent
vim.opt.breakindent = true

-- Save undo history
vim.opt.undofile = true

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Keep signcolumn on by default
vim.opt.signcolumn = 'yes'

-- Decrease update time
vim.opt.updatetime = 250

-- Decrease mapped sequence wait time
vim.opt.timeoutlen = 300

-- Configure how new splits should be opened
vim.opt.splitright = true
vim.opt.splitbelow = true

-- Sets how neovim will display certain whitespace characters in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live, as you type!
vim.opt.inccommand = 'split'

-- Show which line your cursor is on
vim.opt.cursorline = true

-- Minimal number of screen lines to keep above and below the cursor.
vim.opt.scrolloff = 10

-- if performing an operation that would fail due to unsaved changes in the buffer (like `:q`),
-- instead raise a dialog asking if you wish to save the current file(s)
-- See `:help 'confirm'`
vim.opt.confirm = true

-- added for diagnostic hover window
vim.o.updatetime = 250

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
vim.lsp.enable({
  'pyright',
})

-- https://github.com/echasnovski/mini.surround?tab=readme-ov-file#default-config
-- sa (add)
-- sd (delete)
-- sr (replace)
require("mini.surround").setup {}

-- https://github.com/nvim-telescope/telescope.nvim?tab=readme-ov-file#customization
require("telescope").setup {
  defaults = {
    file_ignore_patterns = { ".git/[^h]" },
  },
  extensions = {
    ['ui-select'] = {
      require('telescope.themes').get_dropdown(),
    },
  },
  pickers = {
    find_files = {
      hidden = true;
    }
  },
}
pcall(require('telescope').load_extension, 'fzf')
pcall(require('telescope').load_extension, 'ui-select')

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

-- [[ Utility functions ]]

function FollowRoutePath()
  local target_path = vim.fn.expand("<cfile>")
  local ext = vim.fn.expand("<cfile>:e")

  -- check if in a project-local context
  local is_project_file = vim.startswith(target_path, "/") and vim.fn.empty(vim.fn.glob(target_path)) == 1
  local is_image = vim.tbl_contains({ "jpeg", "jpg", "png" }, ext)

  if is_project_file then
    -- remove leading /
    target_path = string.sub(target_path, 2)
  end

  if is_image then
    -- Use netrw to browse images
    vim.fn["netrw#BrowseX"](target_path, 0)
  else
    vim.cmd("edit " .. target_path)
  end
end

function OpenGithub()
  local file = vim.fn.expand("%:p")
  local line = vim.fn.getcurpos()[2]

  local function last_line_of_cmd(cmd)
    local output = vim.fn.systemlist(cmd)
    return output[#output] or ""
  end

  local repo_full_path = last_line_of_cmd("git rev-parse --show-toplevel")
  local branch = last_line_of_cmd("git rev-parse --abbrev-ref HEAD")

  -- Extract remote URL and parse it
  local remotes = vim.fn.systemlist("git remote -v")
  local remote_line = remotes[2] or remotes[1] or ""
  local remote = string.gsub(remote_line, "%.git", "")
  local remote = string.match(remote_line, "github.com[:/](.-)%s")

  if not remote then
    vim.notify("Could not find a valid GitHub remote", vim.log.levels.ERROR)
    return
  end

  -- Get file path relative to repo root
  local file_repo_path = file:gsub(repo_full_path, "")
  local github_url = string.format(
    "https://github.com/%s/tree/%s%s#L%d",
    remote,
    branch,
    file_repo_path,
    line
  )

  -- Open in default browser (macOS)
  vim.fn.system({ "open", github_url })
end

-- More intuitive behaviors
vim.keymap.set("n", "Y", "v$hy")
vim.keymap.set("n", "vv", "vV")
vim.keymap.set("n", "V", "v$h")

-- Use Enter for EX commands
vim.keymap.set('n', '<CR>', ':')

-- Preferred navigation shortcuts
vim.keymap.set("n", "<BS>", "<C-O>")
vim.keymap.set("n", "<Esc>", "<C-I>")

-- remap S to something more useful
vim.keymap.set('x', 'S', [[:<C-u>lua MiniSurround.add('visual')<CR>]], { desc = "Surround highlighted text with input", silent = true })

-- simple diffing of buffers
vim.keymap.set("n", "]d", "<cmd>windo diffthis<CR>")
vim.keymap.set("n", "[d", "<cmd>windo diffoff<CR>")

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set('n', '<Tab>', '<cmd>nohlsearch<CR><Tab>')

-- open images
vim.keymap.set("n", "gf", FollowRoutePath, { desc = "Open file or image" })

-- open github in browser
vim.keymap.set("n", "go", OpenGithub, { desc = "Open current line in Github" })

-- Diagnostic keymaps
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Exit terminal mode in the builtin terminal with a shortcut that is a bit easier
-- for people to discover. Otherwise, you normally need to press <C-\><C-n>, which
-- is not what someone will guess without a bit more experience.
--
-- NOTE: This won't work in all terminal emulators/tmux/etc. Try your own mapping
-- or just use <C-\><C-n> to exit terminal mode
vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

-- Disable arrow keys in normal mode
vim.keymap.set('n', '<left>', '<cmd>3wincmd <<CR>')
vim.keymap.set('n', '<right>', '<cmd>3wincmd ><CR>')
vim.keymap.set('n', '<up>', '<cmd>3wincmd +<CR>')
vim.keymap.set('n', '<down>', '<cmd>3wincmd -<CR>')

-- Keybinds to make split navigation easier.
--  See `:help wincmd` for a list of all window commands
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

-- replace default f behavior with flash jump
vim.keymap.set("n", "f", function() require("flash").jump() end)

-- lsp
-- https://stackoverflow.com/a/79435977/3726041
vim.api.nvim_create_autocmd({ "CursorHold", "CursorHoldI" }, {
   callback = function()
     if vim.fn.mode() == "n" then
       vim.diagnostic.open_float(nil, { focus = false })
     end
   end
})

-- telescope
-- See `:help telescope.builtin`
local builtin = require 'telescope.builtin'
vim.keymap.set('n', '<leader>sh', builtin.help_tags, { desc = '[S]earch [H]elp' })
vim.keymap.set('n', '<leader>sk', builtin.keymaps, { desc = '[S]earch [K]eymaps' })
vim.keymap.set('n', '<leader>sf', builtin.find_files, { desc = '[S]earch [F]iles' })
vim.keymap.set('n', '<leader>ss', builtin.builtin, { desc = '[S]earch [S]elect Telescope' })
vim.keymap.set('n', '<leader>sw', builtin.grep_string, { desc = '[S]earch current [W]ord' })
vim.keymap.set('n', '<leader>sg', builtin.live_grep, { desc = '[S]earch by [G]rep' })
vim.keymap.set('n', '<leader>sd', builtin.diagnostics, { desc = '[S]earch [D]iagnostics' })
vim.keymap.set('n', '<leader>sr', builtin.resume, { desc = '[S]earch [R]esume' })
vim.keymap.set('n', '<leader>s.', builtin.oldfiles, { desc = '[S]earch Recent Files ("." for repeat)' })
vim.keymap.set('n', '<leader><leader>', builtin.buffers, { desc = '[ ] Find existing buffers' })

-- Slightly advanced example of overriding default behavior and theme
vim.keymap.set('n', '<leader>/', function()
  -- You can pass additional configuration to Telescope to change the theme, layout, etc.
  builtin.current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
    winblend = 10,
    previewer = false,
  })
end, { desc = '[/] Fuzzily search in current buffer' })

-- It's also possible to pass additional configuration options.
--  See `:help telescope.builtin.live_grep()` for information about particular keys
vim.keymap.set('n', '<leader>s/', function()
  builtin.live_grep {
    grep_open_files = true,
    prompt_title = 'Live Grep in Open Files',
  }
end, { desc = '[S]earch [/] in Open Files' })

-- Shortcut for searching your Neovim configuration files
vim.keymap.set('n', '<leader>sn', function()
  builtin.find_files { cwd = vim.fn.stdpath 'config' }
end, { desc = '[S]earch [N]eovim files' })

-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- conform-nvim: Format on save
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*",
  callback = function(args)
    require("conform").format({ bufnr = args.buf })
  end,
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

-- [[ Theming ]]

-- colors
vim.cmd.colorscheme "space-vim-dark"

vim.cmd([[
  " improved aesthetics
  hi LineNr ctermbg=NONE ctermfg=243 guibg=NONE guifg=#767676
  hi SpecialComment ctermfg=38 guifg=#0087d7
  hi Error      gui=None guifg=#ff5e86
  hi ErrorMsg   gui=bold guifg=#ff5e86
  hi Warning    gui=NONE guifg=#fabd2f
  hi WarningMsg gui=bold guifg=#fabd2f
  hi Todo       gui=bold guifg=#d697e6
  hi DiffAdd    gui=NONE guifg=#a4e93e guibg=#3a3a3a
  hi DiffChange gui=NONE guifg=#fabd2f guibg=#3a3a3a
  hi DiffDelete gui=NONE guifg=#ff5e86 guibg=#3a3a3a
  hi DiffText   gui=NONE guifg=#fabd2f guibg=#827400
  hi! link diffAdded DiffAdd
  hi! link diffChanged DiffChange
  hi! link diffRemoved DiffDelete
  hi CurrentWordTwins cterm=bold,underline ctermfg=40 ctermbg=234 gui=bold,underline guifg=#00ff00
  " flash labels
  hi! FlashBackdrop guifg=#5C6370 ctermfg=59
  hi FlashMatch guifg=#8a6716 guibg=#292b2e
  hi FlashCurrent guifg=#292b2e guibg=#8a6716 
  hi FlashLabel gui=bold guifg=#fabd2f
  " gitsigns gutter colors
  hi! link GitSignsAdd DiffAdd
  hi! link GitSignsChange DiffChange
  hi! link GitSignsDelete DiffDelete
]])

-- lsp display configuration
-- https://www.nerdfonts.com/cheat-sheet
vim.diagnostic.config({
  float = true,
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = " ",
      [vim.diagnostic.severity.WARN] = " ",
      [vim.diagnostic.severity.INFO] = "󰋼 ",
      [vim.diagnostic.severity.HINT] = "󰌵 ",
    },
    numhl = {
      [vim.diagnostic.severity.ERROR] = "",
      [vim.diagnostic.severity.WARN] = "",
      [vim.diagnostic.severity.HINT] = "",
      [vim.diagnostic.severity.INFO] = "",
    },
  },
})
