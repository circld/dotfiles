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
    '';
    shellAbbrs = {
      l = "ls -al";
      c = "clear";
    };
  };
}
