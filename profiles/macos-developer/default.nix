# profiles/macos-developer/default.nix
# macOS developer workstation profile.
#
# Extracted from nix/nodes/cid — generic settings only.
# All user-specific values come from kindling.nodeIdentity (ni).
#
# Components: blackmatter shell + nvim, zoekt, codesearch, tend, ghostty,
# claude-code, kubectl, SSH config, git, hammerspoon.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  ni = config.kindling.nodeIdentity;
  blzsh = inputs.blackmatter-shell.packages.${pkgs.system}.blzsh;
  homeDir = "/Users/${ni.user.name}";
in {
  imports = [
    ./home.nix
  ];

  # ── macOS blackmatter profile ───────────────────────────────
  blackmatter.profiles.macos = {
    enable = true;

    system = {
      enable = true;
      primaryUser = ni.user.name;
      stateVersion = 4;
      keyboard = {
        enableKeyMapping = true;
        remapCapsLockToEscape = true;
      };
      keyRepeat = 2;
      initialKeyRepeat = 20;
      disableDocumentation = true;
    };

    nix = {
      enable = true;
      binary.variant = "nixpkgs-latest";
      performance = {
        enable = true;
        atticCache = {
          enable = ni.nix.attic.token_file != null;
          enablePush = ni.nix.attic.token_file != null;
          tokenFile = lib.mkIf (ni.nix.attic.token_file != null) ni.nix.attic.token_file;
          netrcFile = lib.mkIf (ni.nix.attic.netrc_file != null) ni.nix.attic.netrc_file;
        };
      };
      trustedUsers = ni.nix.trusted_users;
      dockerCleanup.enable = true;
    };

    maintenance = {
      enable = true;
      rustCleanup.paths = ["${homeDir}/code"];
    };

    dns = {
      enable = true;
      useNetworkTopology = true;
      bind = "127.0.0.1";
      port = 53;
      cacheSize = 1000;
      upstreamServers = ["1.1.1.1" "8.8.8.8"];
      localDomains = ["local" "test"];
      resolverDomains = ["local" "test" "quero.local"];
      enableAliases = true;
      addresses = {
        "app.test" = "127.0.0.1";
        "api.test" = "127.0.0.1";
      };
    };

    kubectl.enable = false;

    packages = {
      enable = true;
      homeManagerUser = ni.user.name;
    };

    vms.enable = true;
  };

  # ── Node identity ───────────────────────────────────────────
  networking.hostName = ni.hostname;

  # Install blzsh and register as login shell
  environment.systemPackages = [blzsh];
  environment.shells = [blzsh];

  # User account
  users.users.${ni.user.name} = {
    uid = ni.user.uid;
    home = homeDir;
    shell = blzsh;
  };

  # Home-manager setup
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";
  home-manager.extraSpecialArgs = {inherit pkgs;};
}
