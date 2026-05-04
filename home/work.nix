{ config, pkgs, ... }:
let
  utils = import ../modules/utils.nix { inherit config pkgs; };
  importModules = utils.collectModules;
  ln = utils.ln;
  managedModules = importModules ../modules/packages;
  exclusiveModules = importModules ../modules/work/packages;
  common = import ../modules/common.nix { inherit config pkgs; };
  workConfig = import ../modules/work/untracked.nix;
  workCredentialHelper = pkgs.writeShellScript "git-credential-work" ''
    case "$1" in
      get)
        while IFS= read -r line && [ -n "$line" ]; do
          case "$line" in
            host=*) host=''${line#host=} ;;
          esac
        done
        if [ "$host" = "github.com" ]; then
          token=$(${pkgs.gh}/bin/gh auth token -u ${workConfig.gitUser} 2>/dev/null)
          if [ -n "$token" ]; then
            echo "username=${workConfig.gitUser}"
            echo "password=$token"
          fi
        fi
        ;;
    esac
  '';
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
        credential = {
          helper = [
            ""
            "!${workCredentialHelper}"
          ];
        };
      };
    }
  ];
}
