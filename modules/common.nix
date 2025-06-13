{ config, pkgs, ... }:
let
  dotfiles = "${config.home.homeDirectory}/dotfiles";
  ln = file: config.lib.file.mkOutOfStoreSymlink "${dotfiles}/${file}";
in
{
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.05";

  # Install Nix-managed packages into your environment.
  # https://search.nixos.org/packages
  home.packages = [
    pkgs.aerospace
    pkgs.entr
    pkgs.htop
    pkgs.nerd-fonts.hasklug
    pkgs.nil
    pkgs.nixfmt-rfc-style
    pkgs.tldr
    pkgs.tree
  ];

  # Manage plain config files (moved into /nix/store)
  home.file = { };

  # Environment variables
  home.sessionVariables = {
    NIX_PATH = "nixpkgs=https://github.com/NixOS/nixpkgs/archive/release-25.05.tar.gz";
    XDG_CONFIG_HOME = "${config.home.homeDirectory}/.config";
    EDITOR = "nvim";
    MANPAGER = "nvim +Man!";
  };

  # Configure HM-managed programs & configuration
  programs.home-manager.enable = true;

  # Link to externally managed configuration from XDG_CONFIG_HOME
  xdg.configFile = {
    "fish/functions".source = ln "external/fish/functions";
    "fish/themes".source = ln "external/fish/themes";
    # ghostty must be manually installed & managed until derivation is no longer marked as broken
    "ghostty".source = ln "external/ghostty";
    "nvim".source = ln "external/nvim";
    "zellij/themes".source = ln "external/zellij/themes";
  };
}
