{ config, pkgs, ... }:
let
  importModules = import ../modules/utils.nix { inherit config pkgs; };
  managedModules = importModules ../modules/shared;
  exclusiveModules = importModules ../modules/work;
  sharedGit = import ../modules/shared/git.nix { inherit config pkgs; };
  common = import ../modules/common.nix { inherit config pkgs; };
in
{
  # expects list of module paths
  imports =
    [ ../modules/common.nix ]
    ++ (builtins.map (mod: import mod) managedModules)
    ++ (builtins.map (mod: import mod) exclusiveModules);

  home.username = "paul.garaud";
  home.homeDirectory = "/Users/paul.garaud";

  home.sessionVariables = common.home.sessionVariables // {
    NIX_SSL_CERT_FILE="$HOME/octane/global-bundle-with-zscaler.pem";
    SSL_CERT_FILE="$HOME/octane/global-bundle-with-zscaler.pem";
    AWS_CA_BUNDLE="$HOME/octane/global-bundle-with-zscaler.pem";
  };

  programs.git = sharedGit.programs.git // {
    # https://confusedalex.dev/blog/git-conditional-config/
    includes = [
      {
        condition = "gitdir:~/work/";
        contents = {
          user = {
            name = "paulgrow-octane";
            email = "paul.garaud@octanelending.com";
          };
          http = {
            sslCAInfo = "${config.home.homeDirectory}/octane/global-bundle-with-zscaler.pem";
            proactiveAuth = "basic";
          };
        };
      }
    ];
  };
}
