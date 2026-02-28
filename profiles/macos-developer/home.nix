# profiles/macos-developer/home.nix
# Home-manager portion of the macOS developer profile.
#
# Configures: zoekt, codesearch, tend, git, SSH, ghostty, kubectl,
# env vars, claude-code skills, and workspace layout.
#
# All user-specific values come from kindling.nodeIdentity (ni).
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  ni = config.kindling.nodeIdentity;
  homeDir = "/Users/${ni.user.name}";

  # Build kubectl cluster config from node identity
  kubectlClusters = map (c: c.name) ni.kubernetes.clusters;
  kubeconfigYaml = let
    clusterEntries = lib.concatMapStringsSep "\n" (c: ''
      - cluster:
          insecure-skip-tls-verify: true
          server: ${c.server}
        name: ${c.name}'') ni.kubernetes.clusters;
    contextEntries = lib.concatMapStringsSep "\n" (c: ''
      - context:
          cluster: ${c.name}
          user: ${c.name}
        name: ${c.name}'') ni.kubernetes.clusters;
    defaultContext = if ni.kubernetes.clusters != [] then (builtins.head ni.kubernetes.clusters).name else "default";
  in ''
    apiVersion: v1
    clusters:
    ${clusterEntries}
    contexts:
    ${contextEntries}
    current-context: ${defaultContext}
    kind: Config
    preferences: {}
  '';

  # Build tend workspace config from node identity orgs
  tendConfig = let
    orgEntries = lib.concatMapStringsSep "\n" (org: ''
        - name: ${org.name}
          provider: github
          base_dir: ${org.base_dir}
          clone_method: ssh
          discover: true
          org: ${org.name}
          exclude:
            - ".github"
          extra_repos: []'') ni.workspace.orgs;
  in ''
    workspaces:
    ${orgEntries}
  '';
in {
  home-manager.users.${ni.user.name} = {hmConfig, ...}: {
    home.stateVersion = "23.11";

    # Stylix overlays applied at darwin level — disable in HM
    stylix.overlays.enable = false;

    # Chrome dev launcher for curupira debugging
    blackmatter.components.desktop.chrome-dev.enable = true;

    # Kubectl — managed by blackmatter-kubernetes HM module
    blackmatter.components.kubernetes.kubectl = lib.mkIf (ni.kubernetes.clusters != []) {
      enable = true;
      clusters = kubectlClusters;
      enableAliases = true;
      enableCompletion = true;
      editor = "blnvim";
      kubeconfig = kubeconfigYaml;
    };

    home.packages = [pkgs.sops pkgs.blnvim pkgs.skopeo pkgs.tend];

    # Centralized environment variables
    blackmatter.components.env = {
      enable = true;
      variables = {
        EDITOR = "blnvim";
        VISUAL = "blnvim";
        SOPS_AGE_KEY_FILE = lib.mkIf (ni.secrets.age_key_file != null) ni.secrets.age_key_file;
        KUBECONFIG = "$HOME/.kube/config:$HOME/.kube/credentials";
        LIBRARY_PATH = "${pkgs.libiconv}/lib";
        C_INCLUDE_PATH = "${pkgs.libiconv}/include";
      };
      secretFiles = lib.mkMerge [
        (lib.mkIf (ni.workspace.orgs != []) {
          GITHUB_TOKEN = "$HOME/.config/github/token";
        })
        {
          ATTIC_TOKEN = "$HOME/.config/attic/token";
        }
      ];
    };

    programs.home-manager.enable = true;
    blackmatter.profiles.frost.enable = true;

    # Tend workspace config
    home.file.".config/tend/config.yaml".text = tendConfig;

    manual.manpages.enable = false;

    # Git configuration
    blackmatter.components.gitconfig = {
      enable = true;
      user = {
        name = if ni.git.user.name != "" then ni.git.user.name else ni.user.name;
        email = if ni.git.user.email != "" then ni.git.user.email else ni.user.email;
      };
      core.editor = "blnvim";
      core.pager = "delta --dark --line-numbers";
      delta = {
        enable = true;
        sideBySide = true;
      };
    };

    # SSH client configuration
    blackmatter.components.ssh = {
      enable = true;

      performance = {
        enableCompression = true;
        enableControlMaster = true;
        controlPersist = "10m";
      };

      nixBuilder = lib.mkIf (ni.network.ssh ? builder && ni.network.ssh.builder != null) {
        enable = true;
        hostname = ni.network.ssh.builder.hostname;
        fqdn = ni.network.ssh.builder.fqdn;
        port = 22;
        user = "root";
        identityFile = lib.mkIf (ni.network.ssh.builder ? identity_file && ni.network.ssh.builder.identity_file != null) ni.network.ssh.builder.identity_file;
      };

      cloudflareTunnel = lib.mkIf (ni.network.ssh ? cloudflare_tunnel && ni.network.ssh.cloudflare_tunnel != null) {
        enable = true;
        user = ni.network.ssh.cloudflare_tunnel.user;
        domainSuffix = ni.network.ssh.cloudflare_tunnel.domain_suffix;
        hosts = ni.network.ssh.cloudflare_tunnel.hosts;
      };
    };

    # Attic cache netrc — disabled (managed by SOPS in node-specific config)
    blackmatter.components.atticNetrc.enable = false;

    # Hammerspoon macOS automation
    blackmatter.components.hammerspoon.enable = true;

    # Zoekt — trigram-indexed code search daemon
    services.zoekt.daemon = lib.mkIf (ni.workspace.zoekt_repos != []) {
      enable = true;
      repos = ni.workspace.zoekt_repos;
    };

    # Codesearch — semantic code search daemon
    services.codesearch.daemon = lib.mkIf (ni.workspace.orgs != []) {
      enable = true;
      github = {
        enable = true;
        tokenFile = "~/.config/github/token";
        sources = map (org: {
          owner = org.name;
          kind = "org";
          cloneBase = org.base_dir;
          skipArchived = true;
          skipForks = false;
        }) ni.workspace.orgs;
      };
    };

    # Tend daemon — persistent workspace sync + fetch
    services.tend.daemon = {
      enable = true;
      package = pkgs.tend;
      interval = 300;
      fetch = true;
      quiet = true;
      githubTokenFile = "${hmConfig.home.homeDirectory}/.config/github/token";
    };

    # Ghostty terminal — barebones, performant, Nord theme
    blackmatter.components.ghostty = {
      enable = true;

      font = {
        family = "JetBrains Mono";
        size = 13;
        thicken = false;
        adjustCellHeight = 25;
      };

      window = {
        paddingX = 4;
        paddingY = 4;
        decoration = true;
      };

      appearance = {
        backgroundOpacity = 1.0;
        backgroundBlurRadius = 0;
        unfocusedSplitOpacity = 1.0;
        windowColorspace = "display-p3";
      };

      theme = {
        nordTheme = true;
        useBuiltinNord = false;
      };

      cursor = {
        style = "block";
        blink = false;
      };

      performance = {
        vsync = false;
        minimumContrast = 1.0;
      };

      behavior = {
        confirmClose = false;
        copyOnSelect = false;
        mouseHideWhileTyping = false;
        scrollbackLimit = 5000;
        gtkSingleInstance = false;
      };

      shellIntegration = {
        enable = true;
        features = ["cursor" "title"];
      };

      extraSettings = {
        "macos-option-as-alt" = true;
        "macos-titlebar-style" = "tabs";
        "window-inherit-working-directory" = true;
        "window-inherit-font-size" = true;
      };
    };
  };
}
