# TODO
# [x] move programs statements to `managed/`
# [ ] add fish config
# [ ] add neovim config (circld/kickstart.nvim)
#     see https://discourse.nixos.org/t/how-to-manage-dotfiles-with-home-manager/30576/3
#     and https://github.com/supermarin/dotfiles/blob/7b7910717b4c63031e29f94988181c215cfec075/neovim.nix
# [ ] figure out how best to separate personal & work configurations while sharing core
{ config, pkgs, ... }:
let
  dotfiles = "${config.home.homeDirectory}/dotfiles";
  ln = file: config.lib.file.mkOutOfStoreSymlink "${dotfiles}/${file}";
in
{
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "paul.grow";
  home.homeDirectory = "/Users/paul.grow";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.05"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = [
    pkgs.entr
    pkgs.tldr
    pkgs.tree
    # TODO python3.withPackages supported?

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # ".config/.gitignore"
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/paul.grow/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    XDG_CONFIG_HOME = "${config.home.homeDirectory}/.config";
    EDITOR = "nvim";
  };

  # Configure HM-managed programs & configuration
  programs.home-manager.enable = true;
  imports = [
    ./managed/programs.nix
    ./managed/atuin.nix
    ./managed/fish.nix
    ./managed/git.nix
    ./managed/neovim.nix
    ./managed/ripgrep.nix
  ];

  # Link to externally managed configuration from XDG_CONFIG_HOME
  xdg.configFile = {
    # ghostty must be manually installed & managed until derivation is no longer marked as broken
    "ghostty".source = ln "external/ghostty";
    "nvim".source = ln "external/nvim";
  };
}
