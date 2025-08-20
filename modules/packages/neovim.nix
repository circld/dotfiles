{
  pkgs,
  config,
  lib,
  ...
}:

let
  fromGitHub =
    {
      repo,
      rev,
      sha256,
    }:

    let
      # note that builtins.split interleaves non-matches w/lists of matched characters
      # so we remove non-captured matches
      parts = builtins.filter (val: val != [ ]) (builtins.split "/" repo);
      owner = builtins.elemAt parts 0;
      name = builtins.elemAt parts 1;

      src = pkgs.fetchFromGitHub {
        inherit owner rev sha256;
        repo = name;
      };
    in

    pkgs.vimUtils.buildVimPlugin {
      inherit src;
      pname = lib.strings.sanitizeDerivationName repo;
      version = rev;
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
      diffview-nvim
      flash-nvim
      gitsigns-nvim
      lazydev-nvim
      mini-nvim
      noice-nvim
      nvim-colorizer-lua
      nvim-lspconfig
      nvim-treesitter.withAllGrammars
      nvim-web-devicons
      snacks-nvim
      tabular
      todo-comments-nvim
      unimpaired-nvim
      vim-sleuth
      which-key-nvim
      # merged into vim but not yet on 0.11.2
      (fromGitHub {
        repo = "gleam-lang/gleam.vim";
        rev = "ad6c328d6460763ca6a338183f7f1bd54137ce80";
        sha256 = "sha256-Yi1M9EbY/Iv55KzqQcqnfvIDfQgN3JhwapskQ8P7+6o=";
      })
      (fromGitHub {
        repo = "liuchengxu/space-vim-dark";
        rev = "0ab698bd2a3959e3bed7691ac55ba4d8abefd143";
        sha256 = "sha256-GafPnqc5WjsxaPCBi6w6/VL9gnJtB/5fhXZamKZsKkA=";
      })
    ];
  };
}
