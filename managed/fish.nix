{
  pkgs,
  config,
  ...
}:
{
  programs.fish = {
    enable = true;
    generateCompletions = true;
  };
}
