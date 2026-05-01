{ config, pkgs, ... }:
let
  utils = import ../modules/utils.nix { inherit config pkgs; };
  importModules = utils.collectModules;
  ln = utils.ln;
  managedModules = importModules ../modules/packages;
  exclusiveModules = importModules ../modules/work/packages;
  common = import ../modules/common.nix { inherit config pkgs; };
  workConfig = import ../modules/work/untracked.nix;
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

  xdg.configFile = common.xdg.configFile // {
    "opencode/opencode.json".source = ln "external/opencode/work-opencode.json";
  };

  home.sessionVariables = common.home.sessionVariables // {
    AWS_CA_BUNDLE = workConfig.customCaCertFile;
    NIX_SSL_CERT_FILE = workConfig.customCaCertFile;
    PIP_CERT = workConfig.customCaCertFile;
    REQUESTS_CA_BUNDLE = workConfig.customCaCertFile;
    SSL_CERT_FILE = workConfig.customCaCertFile;
    OCTANE_API_KEY = workConfig.octaneApiKey;
    OCTANE_MCP_BASE_URL = workConfig.octaneMcpBaseUrl;
    OCTANE_LLM_PROXY_URL = workConfig.octaneLlmProxyUrl;
    SONARQUBE_TOKEN = workConfig.octaneSonarCloudToken;
  };

  home.packages = common.home.packages ++ [
    pkgs.awscli2
    pkgs.dive
    pkgs.saml2aws

  ];

  programs.fish.shellAbbrs.ecr = workConfig.ecrCommand;

  # Global git config for SSL (applies everywhere, including pre-commit cache)
  programs.git.extraConfig = {
    http = {
      sslCAInfo = workConfig.customCaCertFile;
      proactiveAuth = "basic";
    };
  };

  # https://confusedalex.dev/blog/git-conditional-config/
  programs.git.includes = [
    {
      condition = "gitdir:~/work/";
      contents = {
        user = {
          name = workConfig.gitUser;
          email = workConfig.gitEmail;
        };
      };
    }
  ];
}
