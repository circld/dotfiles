# TODO
# [x] neovim: configure language servers
# [ ] neovim: configure formatters/linters
# [ ] translate utility functions from vimscript to lua
# [ ] neovim: configure remaining plugins: https://github.com/circld/kickstart.nvim/blob/b3765acc86187b18431f275905e964e71d32be95/init.lua
# [ ] neovim: add undotree replacement
# [ ] attempt to integrate with lazy.nvim: https://nixalted.com/
# [ ] break init.lua sections into separate files
# [ ] figure out how best to separate personal & work configurations while sharing core

# see template & docs:
# - https://github.com/nix-community/home-manager/blob/901f8fef7f349cf8a8e97b3230b22fd592df9160/tests/integration/standalone/alice-home-init.nix#L8
# - https://nix-community.github.io/home-manager/
{ config, pkgs, ... }:
let
  dotfiles = "${config.home.homeDirectory}/dotfiles";
  ln = file: config.lib.file.mkOutOfStoreSymlink "${dotfiles}/${file}";
in
{
  home.username = "paul.grow";
  home.homeDirectory = "/Users/paul.grow";

  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.05";

  # Install Nix-managed packages into your environment.
  home.packages = [
    pkgs.entr
    pkgs.nerd-fonts.hasklug
    pkgs.tldr
    pkgs.tree
  ];

  # Manage plain config files (moved into /nix/store)
  home.file = { };

  # Environment variables
  home.sessionVariables = {
    XDG_CONFIG_HOME = "${config.home.homeDirectory}/.config";
    EDITOR = "nvim";
  };

  # Configure HM-managed programs & configuration
  programs.home-manager.enable = true;
  imports = [
    ./managed/no_config.nix
    ./managed/atuin.nix
    ./managed/bat.nix
    ./managed/direnv.nix
    ./managed/fish.nix
    ./managed/git.nix
    ./managed/neovim.nix
    ./managed/ripgrep.nix
    ./managed/starship.nix
    ./managed/zellij.nix
    ./managed/zsh.nix
  ];

  # Link to externally managed configuration from XDG_CONFIG_HOME
  xdg.configFile = {
    "fish/functions".source = ln "external/fish/functions";
    "fish/themes".source = ln "external/fish/themes";
    # ghostty must be manually installed & managed until derivation is no longer marked as broken
    "ghostty".source = ln "external/ghostty";
    "nvim".source = ln "external/nvim";
  };
}
