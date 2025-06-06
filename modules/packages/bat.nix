{
  pkgs,
  config,
  ...
}:
{
  programs.bat = {
    enable = true;
    config = {
      theme = "OneHalfDark";
    };
  };
}
