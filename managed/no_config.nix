{
  pkgs,
  config,
  ...
}:
{
  programs.bash = {
    enable = true;
  };
  programs.bat = {
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
  programs.tmux = {
    enable = true;
  };
}
