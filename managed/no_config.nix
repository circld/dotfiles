{
  pkgs,
  config,
  ...
}:
{
  programs.bash = {
    enable = true;
  };
  programs.fd = {
    enable = true;
  };
  programs.fzf = {
    enable = true;
  };
  programs.jq = {
    enable = true;
  };
}
