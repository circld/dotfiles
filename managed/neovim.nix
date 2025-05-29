# Adding space-vim-dark: https://gist.github.com/nat-418/d76586da7a5d113ab90578ed56069509
{
  pkgs,
  config,
  ...
}:
{
  programs.neovim = {
    enable = true;
    vimAlias = true;
    viAlias = true;
    vimdiffAlias = true;
    plugins = with pkgs.vimPlugins; [
      blink-cmp
      conform-nvim
      flash-nvim
      gitsigns-nvim
      lazydev-nvim
      mini-nvim
      nvim-lspconfig
      nvim-treesitter
      telescope-nvim
      todo-comments-nvim
      vim-sleuth
      which-key-nvim
    ];
  };
}
