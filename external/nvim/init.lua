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
          ["<c-t>"] = { "preview_scroll_up", mode = { "i", "n" } },
          ["<c-g>"] = { "preview_scroll_down", mode = { "i", "n" } },
        },
      },
    },
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

-- TODO replace w/https://github.com/folke/snacks.nvim/blob/main/docs/gitbrowse.md?
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
vim.keymap.set({ 'n', 'v' }, '<CR>', ':')

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

vim.keymap.set("n", "<leader><space>", function() Snacks.picker.smart() end, { desc = "Smart Find Files" })
vim.keymap.set("n", "<leader>,", function() Snacks.picker.buffers({ focus = "list" }) end, { desc = "Buffers" })
vim.keymap.set("n", "<leader>/", function() Snacks.picker.grep() end, { desc = "Grep" })
vim.keymap.set("n", "<leader>:", function() Snacks.picker.command_history() end, { desc = "Command History" })
vim.keymap.set("n", "<leader>n", function() Snacks.picker.notifications() end, { desc = "Notification History" })
vim.keymap.set("n", "<leader>e", function() Snacks.explorer() end, { desc = "File Explorer" })
-- find
vim.keymap.set("n", "<leader>fb", function() Snacks.picker.buffers({ focus = "list" }) end, { desc = "Buffers" })
vim.keymap.set("n", "<leader>fc", function() Snacks.picker.files({ cwd = vim.fn.stdpath("config") }) end, { desc = "Find Config File" })
vim.keymap.set("n", "<leader>ff", function() Snacks.picker.files() end, { desc = "Find Files" })
vim.keymap.set("n", "<leader>fg", function() Snacks.picker.git_files() end, { desc = "Find Git Files" })
vim.keymap.set("n", "<leader>fp", function() Snacks.picker.projects() end, { desc = "Projects" })
vim.keymap.set("n", "<leader>fr", function() Snacks.picker.recent() end, { desc = "Recent" })
-- git
vim.keymap.set("n", "<leader>gb", function() Snacks.picker.git_branches() end, { desc = "Git Branches" })
vim.keymap.set("n", "<leader>gl", function() Snacks.picker.git_log() end, { desc = "Git Log" })
vim.keymap.set("n", "<leader>gL", function() Snacks.picker.git_log_line() end, { desc = "Git Log Line" })
vim.keymap.set("n", "<leader>gs", function() Snacks.picker.git_status() end, { desc = "Git Status" })
vim.keymap.set("n", "<leader>gS", function() Snacks.picker.git_stash() end, { desc = "Git Stash" })
vim.keymap.set("n", "<leader>gd", function() Snacks.picker.git_diff() end, { desc = "Git Diff (Hunks)" })
vim.keymap.set("n", "<leader>gf", function() Snacks.picker.git_log_file() end, { desc = "Git Log File" })
-- Grep
vim.keymap.set("n", "<leader>sb", function() Snacks.picker.lines() end, { desc = "Buffer Lines" })
vim.keymap.set("n", "<leader>sB", function() Snacks.picker.grep_buffers() end, { desc = "Grep Open Buffers" })
vim.keymap.set("n", "<leader>sg", function() Snacks.picker.grep() end, { desc = "Grep" })
vim.keymap.set({ "n", "x" }, "<leader>sw", function() Snacks.picker.grep_word() end, { desc = "Visual selection or word" })
-- search
vim.keymap.set("n", '<leader>s"', function() Snacks.picker.registers() end, { desc = "Registers" })
vim.keymap.set("n", '<leader>s/', function() Snacks.picker.search_history() end, { desc = "Search History" })
vim.keymap.set("n", "<leader>sa", function() Snacks.picker.autocmds() end, { desc = "Autocmds" })
vim.keymap.set("n", "<leader>sb", function() Snacks.picker.lines() end, { desc = "Buffer Lines" })
vim.keymap.set("n", "<leader>sc", function() Snacks.picker.command_history() end, { desc = "Command History" })
vim.keymap.set("n", "<leader>sC", function() Snacks.picker.commands() end, { desc = "Commands" })
vim.keymap.set("n", "<leader>sd", function() Snacks.picker.diagnostics() end, { desc = "Diagnostics" })
vim.keymap.set("n", "<leader>sD", function() Snacks.picker.diagnostics_buffer() end, { desc = "Buffer Diagnostics" })
vim.keymap.set("n", "<leader>sh", function() Snacks.picker.help() end, { desc = "Help Pages" })
vim.keymap.set("n", "<leader>sH", function() Snacks.picker.highlights() end, { desc = "Highlights" })
vim.keymap.set("n", "<leader>si", function() Snacks.picker.icons() end, { desc = "Icons" })
vim.keymap.set("n", "<leader>sj", function() Snacks.picker.jumps() end, { desc = "Jumps" })
vim.keymap.set("n", "<leader>sk", function() Snacks.picker.keymaps() end, { desc = "Keymaps" })
vim.keymap.set("n", "<leader>sl", function() Snacks.picker.loclist() end, { desc = "Location List" })
vim.keymap.set("n", "<leader>sm", function() Snacks.picker.marks() end, { desc = "Marks" })
vim.keymap.set("n", "<leader>sM", function() Snacks.picker.man() end, { desc = "Man Pages" })
vim.keymap.set("n", "<leader>sp", function() Snacks.picker.lazy() end, { desc = "Search for Plugin Spec" })
vim.keymap.set("n", "<leader>sq", function() Snacks.picker.qflist() end, { desc = "Quickfix List" })
vim.keymap.set("n", "<leader>sR", function() Snacks.picker.resume() end, { desc = "Resume" })
vim.keymap.set("n", "<leader>su", function() Snacks.picker.undo() end, { desc = "Undo History" })
vim.keymap.set("n", "<leader>uC", function() Snacks.picker.colorschemes() end, { desc = "Colorschemes" })
-- LSP
vim.keymap.set("n", "gd", function() Snacks.picker.lsp_definitions() end, { desc = "Goto Definition" })
vim.keymap.set("n", "gD", function() Snacks.picker.lsp_declarations() end, { desc = "Goto Declaration" })
vim.keymap.set("n", "gr", function() Snacks.picker.lsp_references() end, { desc = "References" })
vim.keymap.set("n", "gI", function() Snacks.picker.lsp_implementations() end, { desc = "Goto Implementation" })
vim.keymap.set("n", "gy", function() Snacks.picker.lsp_type_definitions() end, { desc = "Goto T[y]pe Definition" })
vim.keymap.set("n", "<leader>ss", function() Snacks.picker.lsp_symbols() end, { desc = "LSP Symbols" })
vim.keymap.set("n", "<leader>sS", function() Snacks.picker.lsp_workspace_symbols() end, { desc = "LSP Workspace Symbols" })

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
  hi! GitSignsAdd guifg=#a4e93e guibg=#292b2e
  hi! GitSignsChange guifg=#fabd2f guibg=#292b2e
  hi! GitSignsDelete guifg=#ff5e86 guibg=#292b2e
  " snacks theming
  hi! link NormalFloat Normal
  hi SnacksPickerBorder guifg=#af87d7
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
