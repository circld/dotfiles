{
  pkgs,
  config,
  ...
}:
{
  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
  };
}
