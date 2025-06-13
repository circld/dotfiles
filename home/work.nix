{ config, pkgs, ... }:
let
  importModules = import ../modules/utils.nix { inherit config pkgs; };
  managedModules = importModules ../modules/packages;
  exclusiveModules = importModules ../modules/work/packages;
  common = import ../modules/common.nix { inherit config pkgs; };
  workConfig = import ../modules/work/untracked.nix;
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
    NIX_SSL_CERT_FILE = "$HOME/octane/global-bundle-with-zscaler.pem";
    SSL_CERT_FILE = "$HOME/octane/global-bundle-with-zscaler.pem";
    AWS_CA_BUNDLE = "$HOME/octane/global-bundle-with-zscaler.pem";
  };

  home.packages = common.home.packages ++ [
    pkgs.awscli2
    pkgs.saml2aws
  ];

  programs.fish.shellAbbrs.ecr = "aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin ${workConfig.awsAccountNumber}.dkr.ecr.us-west-2.amazonaws.com";

  # https://confusedalex.dev/blog/git-conditional-config/
  programs.git.includes = [
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
}
