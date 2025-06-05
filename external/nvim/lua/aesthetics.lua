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
  " flash labels
  hi! FlashBackdrop guifg=#5C6370 ctermfg=59
  hi FlashMatch guifg=#8a6716 guibg=#292b2e
  hi FlashCurrent guifg=#292b2e guibg=#8a6716
  hi FlashLabel gui=bold guifg=#fabd2f
  " gitsigns gutter colors
  hi! GitSignsAdd guifg=#a4e93e guibg=#292b2e
  hi! GitSignsChange guifg=#fabd2f guibg=#292b2e
  hi! GitSignsDelete guifg=#ff5e86 guibg=#292b2e
  " mini.indentscope
  hi! MiniIndentscopeSymbol guifg=#555f69
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
