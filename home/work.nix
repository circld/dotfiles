{ config, pkgs, ... }:
let
  utils = import ../modules/utils.nix { inherit config pkgs; };
  importModules = utils.collectModules;
  ln = utils.ln;
  managedModules = importModules ../modules/packages;
  exclusiveModules = importModules ../modules/work/packages;
  common = import ../modules/common.nix { inherit config pkgs; };
  unstablePkgs = import ../modules/unstable-pkgs.nix { inherit pkgs; };
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

  home.file = common.home.file // {
    ".codex/AGENTS.md".source = ln "external/opencode/AGENTS.md";
  };

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
    OPENAI_API_KEY = workConfig.openAiApiKey;
    CLAUDE_CODE_USE_BEDROCK = 1;
    AWS_BEARER_TOKEN_BEDROCK = workConfig.bedrockApiKey;
  };

  home.packages = common.home.packages ++ [
    pkgs.awscli2
    pkgs.dive
    pkgs.saml2aws
    unstablePkgs.codex
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
