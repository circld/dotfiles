{
  pkgs,
  config,
  ...
}:
{
  # https://yazi-rs.github.io/docs/installation
  programs.yazi = {
    enable = true;
    enableFishIntegration = false;
    settings = {
      # https://github.com/sxyazi/yazi/blob/shipped/yazi-config/preset/yazi-default.toml
      mgr = {
        ratio = [
          1
          3
          4
        ];
        show_hidden = true;
      };
      input = {
        cursor_blink = true;
      };
    };
  };
}
