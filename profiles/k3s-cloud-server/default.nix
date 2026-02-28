# profiles/k3s-cloud-server/default.nix
# NixOS K3s server for cloud hosts (Hetzner/AWS/GCP).
#
# Extracted pattern from nix/nodes/orion — cloud-specific K3s server settings.
# All node-specific values come from kindling.nodeIdentity (ni).
#
# Components: K3s server, WireGuard mesh, public firewall, NVMe tuning.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  ni = config.kindling.nodeIdentity;
  k3sDefaults = import ../../lib/k3s-defaults.nix {inherit lib;};
in {
  imports = [
    inputs.self.nixosModules.blackmatter
  ];

  # Enable blizzard profile — server variant
  blackmatter.profiles.blizzard = {
    enable = true;
    variant = "server";
  };

  # ── K3s Server ──────────────────────────────────────────────
  services.blackmatter.k3s = {
    enable = true;
    role = "server";

    disableComponents = ["traefik"];

    clusterCIDR = ni.kubernetes.cluster_cidr or k3sDefaults.defaultClusterCIDR;
    serviceCIDR = ni.kubernetes.service_cidr or k3sDefaults.defaultServiceCIDR;
    clusterDNS = k3sDefaults.defaultClusterDNS;

    waitForDNS = true;

    extraFlags = k3sDefaults.allServerFlags k3sDefaults;
  };

  # ── Hardware ────────────────────────────────────────────────
  blackmatter.profiles.blizzard.hardware = {
    cpu.type = ni.hardware.cpu;
    kernel = {
      modules = k3sDefaults.k3sKernelModules ++ ni.hardware.kernel.modules;
      initrdModules = ["xhci_pci" "ahci" "nvme" "usbhid" "sd_mod"];
      blacklist = ["pcspkr"];
    };
    platform = ni.hardware.platform;
  };

  # ── Networking ──────────────────────────────────────────────
  # Cloud hosts use DHCP and need public firewall rules
  blackmatter.profiles.blizzard.networkingExtended = {
    hostName = ni.hostname;
    useNetworkTopology = false; # No local topology in cloud

    firewall = {
      enable = true;
      allowPing = true;
      allowedTCPPorts = [22 6443 80 443 10250] ++ ni.network.firewall.allowed_tcp_ports;
      allowedUDPPorts = [8472] ++ ni.network.firewall.allowed_udp_ports;
      trustedInterfaces = ["cni0" "flannel.1"];
    };
  };

  # ── System Tuning ───────────────────────────────────────────
  blackmatter.profiles.blizzard.optimizations = {
    enable = true;
    cpuGovernor = "performance";

    kernelParams = [
      "transparent_hugepage=never"
      "skew_tick=1"
      "nmi_watchdog=0"
      "nowatchdog"
    ] ++ ni.hardware.kernel.params;

    nvme.optimize = true;
  };

  blackmatter.components.baseSystemTuning = {
    enable = true;
    boot = {
      timeout = 3;
      configurationLimit = 20;
      initrdCompress = "lz4";
    };
    journald = {
      storage = "volatile";
      systemMaxUse = "200M";
    };
    systemd = {
      defaultTimeoutStartSec = "30s";
      defaultTimeoutStopSec = "30s";
      waitOnline = false;
    };
    nix = {
      gcAutomatic = true;
      gcDates = "weekly";
      gcOptions = "--delete-older-than 14d";
      optimiseAutomatic = true;
    };
  };

  # ── SSH ─────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # ── Locale & Time ───────────────────────────────────────────
  blackmatter.components.systemTime = {
    enable = true;
    timeZone = "UTC";
  };
  blackmatter.components.systemLocale = {
    enable = true;
    defaultLocale = "en_US.UTF-8";
  };

  # ── Packages ────────────────────────────────────────────────
  blackmatter.profiles.blizzard.usersPackages = {
    systemPackages = with pkgs; [
      kubectl
      k9s
      fluxcd
      htop
      nvme-cli
      ethtool
      iotop
    ];
    allowUnfree = true;
  };

  # ── Nix ─────────────────────────────────────────────────────
  blackmatter.profiles.blizzard.nix.performance = {
    enable = true;
    trustedUsers = ni.nix.trusted_users;
    acceptFlakeConfig = true;
    atticCache = {
      enable = ni.nix.attic.token_file != null;
      enablePush = ni.nix.attic.token_file != null;
    };
  };

  # ── NVMe Optimization Rules ─────────────────────────────────
  services.udev.extraRules = ''
    # NVMe optimization for all drives
    ACTION=="add|change", KERNEL=="nvme[0-9]n1", ATTR{queue/scheduler}="none"
    ACTION=="add|change", KERNEL=="nvme[0-9]n1", ATTR{queue/nr_requests}="1024"
    ACTION=="add|change", KERNEL=="nvme[0-9]n1", ATTR{queue/read_ahead_kb}="512"
  '';

  # ── Monitoring ──────────────────────────────────────────────
  blackmatter.profiles.blizzard.serverMonitoring = {
    enable = true;
    smartd.enable = true;
    logrotate.enable = true;
    tools = true;
  };

  # ── Data Persistence ────────────────────────────────────────
  blackmatter.profiles.blizzard.dataPersistence = {
    enable = true;
    fstrim.enable = true;
    backupTools = true;
  };
}
