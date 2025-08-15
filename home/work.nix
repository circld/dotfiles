{ config, pkgs, ... }:
let
  importModules = import ../modules/utils.nix { inherit config pkgs; };
  managedModules = importModules ../modules/packages;
  exclusiveModules = importModules ../modules/work/packages;
  common = import ../modules/common.nix { inherit config pkgs; };
  workConfig = import ../modules/work/untracked.nix;
  dotfiles = "${config.home.homeDirectory}/dotfiles";
  ln = file: config.lib.file.mkOutOfStoreSymlink "${dotfiles}/${file}";
  unstablePkgs =
    import
      (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz";
      })
      {
        system = pkgs.system;
        config.allowUnfree = true;
      };
in
{
  # expects list of module paths
  imports = [
    ../modules/common.nix
  ]
  ++ (builtins.map (mod: import mod) managedModules)
  ++ (builtins.map (mod: import mod) exclusiveModules);

  home.username = workConfig.userName;
  home.homeDirectory = workConfig.homeDirectory;

  home.sessionVariables = common.home.sessionVariables // {
    AWS_CA_BUNDLE = workConfig.customCaCertFile;
    NIX_SSL_CERT_FILE = workConfig.customCaCertFile;
    PIP_CERT = workConfig.customCaCertFile;
    REQUESTS_CA_BUNDLE = workConfig.customCaCertFile;
    SSL_CERT_FILE = workConfig.customCaCertFile;
  };

  home.file = common.home.file // {
    ".claude/commands".source = ln "external/claude/commands";
  };

  home.packages = common.home.packages ++ [
    pkgs.awscli2
    pkgs.dive
    pkgs.saml2aws
    unstablePkgs.claude-code
  ];

  programs.fish.shellAbbrs.ecr = workConfig.ecrCommand;

  # https://confusedalex.dev/blog/git-conditional-config/
  programs.git.includes = [
    {
      condition = "gitdir:~/work/";
      contents = {
        user = {
          name = workConfig.gitUser;
          email = workConfig.gitEmail;
        };
        http = {
          sslCAInfo = workConfig.customCaCertFile;
          proactiveAuth = "basic";
        };
      };
    }
  ];
}
