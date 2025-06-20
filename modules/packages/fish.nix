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
