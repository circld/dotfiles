-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`
-- conform-nvim: Format on save
vim.api.nvim_create_autocmd(
  "BufWritePre", { pattern = "*", callback = function(args) require("conform").format({ bufnr = args.buf }) end }
)

-- lsp
-- https://stackoverflow.com/a/79435977/3726041
vim.api.nvim_create_autocmd(
  { "CursorHold", "CursorHoldI" },
  { callback = function() if vim.fn.mode() == "n" then vim.diagnostic.open_float(nil, { focus = false }) end end }
)

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.highlight.on_yank()`
vim.api.nvim_create_autocmd(
  'TextYankPost', {
    desc = 'Highlight when yanking (copying) text',
    group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
    callback = function() vim.hl.on_yank() end,
  }
)

-- update pwd to project root
-- https://www.reddit.com/r/neovim/comments/zy5s0l/you_dont_need_vimrooter_usually_or_how_to_set_up/
local root_names = { '.git', 'Makefile', 'pyproject.toml', 'cargo.toml', 'gleam.toml' }

-- Cache to use for speed up (at cost of possibly outdated results)
local root_cache = {}

local set_root = function()
  -- Get directory path to start search from
  local path = vim.api.nvim_buf_get_name(0)
  if path == '' then return end
  path = vim.fs.dirname(path)

  -- Try cache and resort to searching upward for root directory
  local root = root_cache[path]
  if root == nil then
    local root_file = vim.fs.find(root_names, { path = path, upward = true })[1]
    if root_file == nil then return end
    root = vim.fs.dirname(root_file)
    root_cache[path] = root
  end

  -- Set current directory
  vim.fn.chdir(root)
end

local root_augroup = vim.api.nvim_create_augroup('MyAutoRoot', {})
vim.api.nvim_create_autocmd('BufEnter', { group = root_augroup, callback = set_root })
