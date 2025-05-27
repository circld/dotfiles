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
        error_symbol = "[❯](red)";
        vimcmd_symbol = "[❮](purple)";
      };
      directory = {
        fish_style_pwd_dir_length = 1;
	format = "[$path](bright-blue)[$read_only]($read_only_style) ";
	home_symbol = "💻";
      };
    };
  };
}
