{
  pkgs,
  config,
  lib,
  ...
}:

let
  fromGitHub = { repo, ref ? null, rev ? null }:

  let
    gitArgs = lib.filterAttrs (name: value: value != null) {
      url = "https://github.com/${repo}.git";
      inherit ref;
      inherit rev;
    };
    src = builtins.fetchGit gitArgs;
  in
    pkgs.vimUtils.buildVimPlugin {
      inherit src;
      pname = "${lib.strings.sanitizeDerivationName repo}";
      version = if rev != null then rev else ref;
    };

in
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
      (fromGitHub { repo = "liuchengxu/space-vim-dark"; rev = "0ab698bd2a3959e3bed7691ac55ba4d8abefd143"; })
    ];
  };
}
