{
  pkgs,
  config,
  ...
}:
{
  programs.zsh = {
    enable = true;
    initContent = "exec fish --interactive";
  };
}
