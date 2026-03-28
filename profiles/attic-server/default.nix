# profiles/attic-server/default.nix
# NixOS Attic binary cache server for cloud hosts (AWS).
#
# Self-contained profile using direct NixOS settings — no blizzard dependency.
# This avoids merge conflicts with amazon-image.nix and other cloud modules.
# All node-specific values come from kindling.nodeIdentity (ni).
#
# Attic stores Nix build artifacts (NARs) so EC2 instances skip rebuilds.
# Runs atticd + PostgreSQL locally; S3 backend added later via IAM roles.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  ni = config.kindling.nodeIdentity;

  # Environment file for atticd JWT secret — generated at boot if absent.
  # On a real deployment this file is provisioned via SOPS/secrets manager.
  # For AMI builds this is a placeholder so the NixOS module assertion passes.
  atticEnvFile = "/var/lib/atticd/env";
in {
  # -- Amazon AMI base (fileSystems, boot loader, EC2 tools) --
  imports = ["${modulesPath}/virtualisation/amazon-image.nix"];

  # -- Attic Server (services.atticd NixOS module) --
  services.atticd = {
    enable = true;
    environmentFile = atticEnvFile;
    settings = {
      listen = "[::]:8080";

      database.url = "postgresql:///atticd?host=/run/postgresql";

      storage = {
        type = "local";
        path = "/var/lib/atticd/storage";
      };

      chunking = {
        nar-size-threshold = 65536;
        min-size = 16384;
        avg-size = 65536;
        max-size = 262144;
      };
    };
  };

  # -- PostgreSQL (local metadata store) --
  # Database name must match the user name for ensureDBOwnership to work.
  # The atticd NixOS module runs as user "atticd" by default.
  services.postgresql = {
    enable = true;
    ensureDatabases = ["atticd"];
    ensureUsers = [{
      name = "atticd";
      ensureDBOwnership = true;
    }];
  };

  # Generate JWT secret env file at boot if it does not exist.
  # Real deployments replace this with a SOPS-managed secret.
  systemd.services.atticd-keygen = {
    description = "Generate Attic JWT secret if absent";
    wantedBy = ["multi-user.target"];
    before = ["atticd.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "atticd";
    };
    path = [pkgs.openssl pkgs.coreutils];
    script = ''
      if [ ! -f ${atticEnvFile} ]; then
        KEY=$(openssl genrsa -traditional 4096 2>/dev/null | base64 -w0)
        echo "ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=$KEY" > ${atticEnvFile}
        chmod 600 ${atticEnvFile}
      fi
    '';
  };

  # -- Kernel --
  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme" "usbhid" "sd_mod"];
  boot.kernelParams = [
    "transparent_hugepage=never"
    "nmi_watchdog=0"
    "nowatchdog"
  ] ++ ni.hardware.kernel.params;
  boot.blacklistedKernelModules = ["pcspkr"];
  boot.kernelModules = ni.hardware.kernel.modules;

  # -- Networking & Firewall --
  networking.hostName = ni.hostname;
  networking.firewall = {
    enable = true;
    allowPing = true;
    allowedTCPPorts = [22 8080] ++ ni.network.firewall.allowed_tcp_ports;
    allowedUDPPorts = ni.network.firewall.allowed_udp_ports;
  };

  # -- Boot & System Tuning --
  boot.loader.timeout = lib.mkDefault 3;
  boot.loader.grub.configurationLimit = lib.mkDefault 20;
  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

  services.journald.extraConfig = ''
    Storage=volatile
    SystemMaxUse=200M
  '';

  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "30s";
    DefaultTimeoutStopSec = "30s";
  };
  systemd.network.wait-online.enable = lib.mkDefault false;

  system.stateVersion = lib.mkDefault "25.11";

  # -- SSH --
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # -- Locale & Time --
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # -- Packages --
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    attic-server
    htop nvme-cli ethtool iotop
    smartmontools lsof tcpdump
  ];

  # -- Nix --
  nix.settings = {
    trusted-users = ni.nix.trusted_users;
    accept-flake-config = true;
    experimental-features = ["nix-command" "flakes"];
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # -- NVMe Optimization --
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="nvme[0-9]n1", ATTR{queue/scheduler}="none"
    ACTION=="add|change", KERNEL=="nvme[0-9]n1", ATTR{queue/nr_requests}="1024"
    ACTION=="add|change", KERNEL=="nvme[0-9]n1", ATTR{queue/read_ahead_kb}="512"
  '';

  # -- Monitoring & Maintenance --
  services.smartd.enable = true;
  services.logrotate.enable = true;
  services.fstrim.enable = true;

  # -- Disable unnecessary services from blackmatter aggregator --
  services.tor.enable = lib.mkForce false;
  virtualisation.docker.enable = lib.mkForce false;
  blackmatter.security.tools = {
    network.enable = lib.mkForce false;
    web.enable = lib.mkForce false;
    osint.enable = lib.mkForce false;
    passwords.enable = lib.mkForce false;
    privacy.enable = lib.mkForce false;
  };
  blackmatter.security.hardening.enable = lib.mkForce false;
}
