# TODO
# [ ] move programs statements to `managed/`
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
    # ghostty must be manually installed until derivation is no longer marked as broken
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
  xdg.configFile = {
    "ghostty".source = ln "external/ghostty";
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

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;

  # Configure HM-managed programs & configuration
  programs.atuin = {
    enable = true;
    enableFishIntegration = true;
    flags = [ "--disable-up-arrow" ];
  };
  programs.bash = {
    enable = true;
  };
  programs.bat = {
    enable = true;
  };
  programs.direnv = {
    enable = true;
  };
  programs.fd = {
    enable = true;
  };
  programs.fzf = {
    enable = true;
  };
  programs.fish = {
    enable = true;
    generateCompletions = true;
  };
  programs.git = {
    enable = true;
    aliases = {
      st = "status";
      ci = "commit";
      co = "checkout";
      rco = "!f(){ git fetch origin \"$1\" && git checkout \"$1\"; };f";
      hist = "log --pretty=format:'%h %ad | %s%d [%an]' --graph --date=short";
      type = "cat-file -t";
      dump = "cat-file -p";
      br = "!f(){ export count=$1; git for-each-ref --sort=-committerdate refs/heads --format='%(HEAD)%(color:yellow)%(refname:short)|%(color:bold green)%(committerdate:relative)|%(color:blue)%(subject)|%(color:magenta)%(authorname)%(color:reset)' --color=always --count=\"\${count:=10}\" | column -ts'|'; };f";
      nbr = "!f(){ git checkout -b \"$1\" && git push --set-upstream origin \"$1\"; };f";
      root = "rev-parse --show-toplevel";
    };
    delta.enable = true;
    delta.options = {
      features = "villsau";
      navigate = true;
      side-by-side = true;
      # villsau from https://github.com/dandavison/delta/blob/main/themes.gitconfig
      dark = true;
      file-style = "omit";
      hunk-header-decoration-style = "omit";
      hunk-header-file-style = "magenta";
      hunk-header-line-number-style = "dim magenta";
      hunk-header-style = "file line-number syntax";
      line-numbers = false;
      minus-emph-style = "bold red 52";
      minus-empty-line-marker-style = "normal \"#3f0001\"";
      minus-non-emph-style = "dim red";
      minus-style = "bold red";
      plus-emph-style = "bold green 22";
      plus-empty-line-marker-style = "normal \"#002800\"";
      plus-non-emph-style = "dim green";
      plus-style = "bold green";
      syntax-theme = "OneHalfDark";
      whitespace-error-style = "reverse red";
      zero-style = "dim syntax";
    };
    extraConfig = {
      core = {
	# TODO add this to home.file
        # excludesfile = "${config.home.homeDirectory}/.gitignore_global";
        editor = "nvim";
      };
      color = {
        ui = true;
	pager = true;
      };
      init = { defaultBranc = "main"; };
    };
    userEmail = "circld1@gmail.com";
    userName = "circld";
  };
  programs.jq = {
    enable = true;
  };
  programs.neovim = {
    enable = true;
    vimAlias = true;
    viAlias = true;
    vimdiffAlias = true;
    plugins = with pkgs.vimPlugins; [

    ];
  };
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/dotfiles/nvim";
  programs.ripgrep = {
    enable = true;
    arguments = [
      "--max-columns=200"
      "--max-columns-preview"
      "--smart-case"
    ];
  };
  programs.starship = {
    enable = true;
  };
  programs.tmux = {
    enable = true;
  };
  programs.zsh = {
    enable = true;
  };
}
