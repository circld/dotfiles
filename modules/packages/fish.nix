# https://mynixos.com/home-manager/options/programs.fish
{
  pkgs,
  config,
  ...
}:
{
  # see this example (but i think i'd rather define/manage my functions outside of HM...)
  # https://codeberg.org/justgivemeaname/.dotfiles/src/branch/main/home-manager/packages/fish/fish.nix
  programs.fish = {
    enable = true;
    generateCompletions = true;
    interactiveShellInit = ''
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
    shellAbbrs = {
      l = "ls -al";
      c = "clear";
    };
  };
}
