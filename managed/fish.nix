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
      set fish_greeting
      fish_vi_key_bindings
      fish_user_key_bindings
    '';
    shellAbbrs = {
      l = "ls -al";
      c = "clear";
    };
  };
}
