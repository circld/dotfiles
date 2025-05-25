{
  pkgs,
  config,
  ...
}:
{
  programs.ripgrep = {
    enable = true;
    arguments = [
      "--max-columns=200"
      "--max-columns-preview"
      "--smart-case"
    ];
  };
}
