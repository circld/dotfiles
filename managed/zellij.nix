{
  pkgs,
  config,
  ...
}:
{
  programs.zellij = {
    enable = true;
    # https://zellij.dev/documentation/configuration.html
    settings = {
      default_shell = "fish";
      theme = "space-vim-dark";
    };
    themes = {
      "space-vim-dark" = ''
        themes {
          space-vim-dark {
            bg "#262626"
            fg "#d358d5"
            red "#262626"
            green "#af87d7"
            blue "#4083cd"
            yellow "#e89e0f"
            magenta "#4083cd"
            orange "#d358d5"
            cyan "#22abbb"
            black "#262626"
            white "#b2b2b2"
          }
        }
        '';
    };
  };
}
