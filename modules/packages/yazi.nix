{
  pkgs,
  config,
  ...
}:
{
  programs.yazi = {
    enable = true;
    enableFishIntegration = false;
  };
}
