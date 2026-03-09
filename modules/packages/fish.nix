# https://mynixos.com/home-manager/options/programs.fish
{
  pkgs,
  config,
  ...
}:
{
  programs.fish = {
    enable = true;
    generateCompletions = true;
    interactiveShellInit = ''
      # Always re-source HM session vars to override the __HM_SESS_VARS_SOURCED
      # guard inherited from the zellij server environment
      hm-refresh

      # Detect home-manager generation change; exec fish for full re-init
      set -l current_config (readlink ~/.config/fish/config.fish)
      if set -q __HM_FISH_CONFIG; and test "$__HM_FISH_CONFIG" != "$current_config"
          set -gx __HM_FISH_CONFIG $current_config
          exec fish
      end
      set -gx __HM_FISH_CONFIG $current_config

      set -xg PATH $PATH $HOME/.local/bin

      set fish_greeting

      # vi mode
      function fish_vi_cursor
      end
      fish_vi_key_bindings

      # custom key bindings
      fish_user_key_bindings

      # set theme
      fish_config theme choose custom
    '';
    plugins = [
      {
        name = "exercism-cli-fish-wrapper";
        src = pkgs.fetchFromGitHub {
          owner = "glennj";
          repo = "exercism-cli-fish-wrapper";
          rev = "fc00e992b73adc63596e1406a8554313d642204f";
          sha256 = "sha256-w2aGakB/Kel0TMaZ44/WC6syhetohJzn5kgwgW7Kdqs";
        };
      }
    ];
    shellAbbrs = {
      l = "ls -al";
      c = "clear";
    };
  };
}
