{
  pkgs,
  config,
  ...
}:
{
  programs.bash = {
    enable = true;
  };
  programs.eza = {
    enable = true;
  };
  programs.fd = {
    enable = true;
  };
  programs.jq = {
    enable = true;
  };
}
