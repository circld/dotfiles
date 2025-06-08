{
  pkgs,
  config,
  ...
}:
{
  programs.starship = {
    enable = true;
    settings = {
      character = {
        success_symbol = "[❯](bright-purple)";
        error_symbol = "[❯](bright-red)";
        vimcmd_symbol = "[❮](purple)";
      };
      cmd_duration = {
        style = "bright-yellow";
      };
      directory = {
        fish_style_pwd_dir_length = 1;
        format = "[$path](bright-cyan)[$read_only]($read_only_style) ";
        home_symbol = "💻";
      };
    };
  };
}
