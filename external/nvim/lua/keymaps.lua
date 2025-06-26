-- [[ Keymaps ]]
local function map_conditional_diff(key, alt_action)
  return function()
    if vim.o.diff then
      -- Pass the original key through to preserve default behavior
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'n', false)
    else
      if type(alt_action) == "string" then
        vim.cmd(alt_action)
      elseif type(alt_action) == "function" then
        alt_action()
      else
        error("Unsupported alt_action type: must be string or function")
      end
    end
  end
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
vim.keymap.set(
  'x', 'S', [[:<C-u>lua MiniSurround.add('visual')<CR>]],
  { desc = "Surround highlighted text with input", silent = true }
)

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

-- copy filepath of file open in focused buffer
vim.keymap.set(
  "n", "<leader>uc", function() vim.fn.setreg("*", vim.fn.expand("%:t")) end,
  { desc = "Copy filepath of focused buffer" }
)
vim.keymap.set(
  "n", "<leader>uC", function() vim.fn.setreg("*", vim.api.nvim_buf_get_name(0)) end,
  { desc = "Copy filepath of focused buffer" }
)

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

vim.keymap.set("n", "<leader><space>", function() Snacks.picker.smart() end, { desc = "Smart Find Files" })
vim.keymap.set("n", "<leader>,", function() Snacks.picker.buffers({ focus = "list" }) end, { desc = "Buffers" })
vim.keymap.set("n", "<leader>/", function() Snacks.picker.grep() end, { desc = "Grep" })
vim.keymap.set("n", "<leader>:", function() Snacks.picker.command_history() end, { desc = "Command History" })
vim.keymap.set("n", "<leader>n", function() Snacks.picker.notifications() end, { desc = "Notification History" })
vim.keymap.set("n", "<leader>e", function() Snacks.explorer() end, { desc = "File Explorer" })
-- find
vim.keymap.set("n", "<leader>fb", function() Snacks.picker.buffers({ focus = "list" }) end, { desc = "Buffers" })
vim.keymap.set(
  "n", "<leader>fc", function() Snacks.picker.files({ cwd = vim.fn.stdpath("config") }) end,
  { desc = "Find Config File" }
)
vim.keymap.set("n", "<leader>ff", function() Snacks.picker.files() end, { desc = "Find Files" })
vim.keymap.set("n", "<leader>fd", pick_files_under, { desc = "Find Files in Directory" })
vim.keymap.set("n", "<leader>fg", function() Snacks.picker.git_files() end, { desc = "Find Git Files" })
vim.keymap.set("n", "<leader>fp", function() Snacks.picker.projects() end, { desc = "Projects" })
vim.keymap.set("n", "<leader>fr", function() Snacks.picker.recent() end, { desc = "Recent" })
-- git
vim.keymap.set("n", "<leader>gb", function() Snacks.picker.git_branches() end, { desc = "Git Branches" })
vim.keymap.set("n", "<leader>gl", function() Snacks.picker.git_log() end, { desc = "Git Log" })
vim.keymap.set("n", "<leader>gL", function() Snacks.picker.git_log_line() end, { desc = "Git Log Line" })
vim.keymap.set("n", "<leader>gs", function() Snacks.picker.git_status() end, { desc = "Git Status" })
vim.keymap.set("n", "<leader>gS", function() Snacks.picker.git_stash() end, { desc = "Git Stash" })
vim.keymap.set("n", "<leader>gd", diffview_toggle, { desc = "Git Diff View Toggle" })
vim.keymap.set("n", "<leader>gf", function() Snacks.picker.git_log_file() end, { desc = "Git Log File" })
-- use default action in diff view, otherwise use gitsigns hunk navigation
vim.keymap.set("n", "]c", map_conditional_diff("]c", "Gitsigns nav_hunk next"), { desc = "Next hunk" })
vim.keymap.set("n", "]C", map_conditional_diff("]C", "Gitsigns nav_hunk last"), { desc = "Last hunk" })
vim.keymap.set("n", "[c", map_conditional_diff("[c", "Gitsigns nav_hunk prev"), { desc = "Prev hunk" })
vim.keymap.set("n", "[C", map_conditional_diff("[C", "Gitsigns nav_hunk first"), { desc = "First hunk" })
-- Grep
-- search
vim.keymap.set("n", '<leader>s"', function() Snacks.picker.registers() end, { desc = "Registers" })
vim.keymap.set("n", '<leader>s/', function() Snacks.picker.search_history() end, { desc = "Search History" })
vim.keymap.set("n", "<leader>sa", function() Snacks.picker.autocmds() end, { desc = "Autocmds" })
vim.keymap.set("n", "<leader>sb", function() Snacks.picker.lines() end, { desc = "Buffer Lines" })
vim.keymap.set("n", "<leader>sB", function() Snacks.picker.grep_buffers() end, { desc = "Grep Open Buffers" })
vim.keymap.set("n", "<leader>sc", function() Snacks.picker.command_history() end, { desc = "Command History" })
vim.keymap.set("n", "<leader>sC", function() Snacks.picker.commands() end, { desc = "Commands" })
vim.keymap.set("n", "<leader>sd", function() Snacks.picker.diagnostics() end, { desc = "Diagnostics" })
vim.keymap.set("n", "<leader>sD", function() Snacks.picker.diagnostics_buffer() end, { desc = "Buffer Diagnostics" })
vim.keymap.set("n", "<leader>sg", function() Snacks.picker.grep() end, { desc = "Grep" })
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
vim.keymap.set(
  { "n", "x" }, "<leader>sw", function() Snacks.picker.grep_word() end, { desc = "Visual selection or word" }
)
vim.keymap.set("n", "<leader>uz", function() Snacks.picker.colorschemes() end, { desc = "Colorschemes" })
-- LSP
vim.keymap.set("n", "gd", function() Snacks.picker.lsp_definitions() end, { desc = "Goto Definition" })
vim.keymap.set("n", "gD", function() Snacks.picker.lsp_declarations() end, { desc = "Goto Declaration" })
vim.keymap.set("n", "gr", function() Snacks.picker.lsp_references() end, { desc = "References" })
vim.keymap.set("n", "gI", function() Snacks.picker.lsp_implementations() end, { desc = "Goto Implementation" })
vim.keymap.set("n", "gy", function() Snacks.picker.lsp_type_definitions() end, { desc = "Goto T[y]pe Definition" })
vim.keymap.set("n", "<leader>ss", function() Snacks.picker.lsp_symbols() end, { desc = "LSP Symbols" })
vim.keymap.set(
  "n", "<leader>sS", function() Snacks.picker.lsp_workspace_symbols() end, { desc = "LSP Workspace Symbols" }
)
