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
  programs.direnv = {
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
  programs.starship = {
    enable = true;
  };
  programs.tmux = {
    enable = true;
  };
  programs.zsh = {
    enable = true;
  };
}
