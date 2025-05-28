{
  pkgs,
  config,
  ...
}:
{
  programs.zellij = {
    enable = true;
    settings = {
      default_shell = "fish";
    };
  };
}
