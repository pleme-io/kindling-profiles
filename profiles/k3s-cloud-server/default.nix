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
  modulesPath,
  ...
}: let
  ni = config.kindling.nodeIdentity;
  k3sDefaults = import ../../lib/k3s-defaults.nix {inherit lib;};
in {
  # Import the Amazon AMI base module for EC2 hardware, fileSystems, boot loader
  imports = [ "${modulesPath}/virtualisation/amazon-image.nix" ];

  # NOTE: blackmatter NixOS modules must be loaded by the host repo.
  # This profile only SETS blackmatter options — it does not import modules.

  # Enable blizzard profile — server variant
  blackmatter.profiles.blizzard = {
    enable = true;
    variant = "server";
  };

  # ── K3s Server ──────────────────────────────────────────────
  services.blackmatter.k3s = {
    enable = true;
    role = "server";

    disable = ["traefik"];

    clusterCIDR = if ni.kubernetes.cluster_cidr != null then ni.kubernetes.cluster_cidr else k3sDefaults.defaultClusterCIDR;
    serviceCIDR = if ni.kubernetes.service_cidr != null then ni.kubernetes.service_cidr else k3sDefaults.defaultServiceCIDR;
    clusterDNS = k3sDefaults.defaultClusterDNS;

    waitForDNS.enable = true;

    extraFlags = k3sDefaults.allServerFlags k3sDefaults;
  };

  # ── Hardware ────────────────────────────────────────────────
  # Cloud instances default to intel/x86_64 when node.json has empty values
  blackmatter.profiles.blizzard.hardware = {
    cpu.type = if ni.hardware.cpu.vendor != "" then ni.hardware.cpu.vendor else "intel";
    kernel = {
      modules = k3sDefaults.k3sKernelModules ++ ni.hardware.kernel.modules;
      initrdModules = ["xhci_pci" "ahci" "nvme" "usbhid" "sd_mod"];
      blacklist = ["pcspkr"];
    };
    platform = if ni.hardware.platform != "" then ni.hardware.platform else "x86_64-linux";
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

  # ── VPN ────────────────────────────────────────────────────
  # Wire kindling vpn_links to blackmatter-vpn module
  services.blackmatter.vpn = lib.mkIf (ni.network.vpn_links != []) {
    enable = true;
    links = builtins.listToAttrs (map (link: {
      name = link.name;
      value = {
        privateKeyFile = link.private_key_file;
        listenPort = link.listen_port or 0;
        address = link.address;
        mtu = link.mtu or 1420;
        profile = link.profile;
        persistentKeepalive = link.persistent_keepalive;
        peers = map (peer: {
          publicKey = peer.public_key;
          endpoint = peer.endpoint;
          allowedIPs = peer.allowed_ips;
          persistentKeepalive = peer.persistent_keepalive;
          presharedKeyFile = peer.preshared_key_file;
        }) link.peers;
        firewall = {
          trustInterface = link.firewall.trust_interface;
          allowedTCPPorts = link.firewall.allowed_tcp_ports;
          allowedUDPPorts = link.firewall.allowed_udp_ports;
          incomingUDPPort = link.firewall.incoming_udp_port;
        };
      };
    }) ni.network.vpn_links);
  };

  # ── System Tuning (direct, not via blizzard optimizations to avoid sysctl conflicts) ──
  boot.kernelParams = [
    "transparent_hugepage=never"
    "skew_tick=1"
    "nmi_watchdog=0"
    "nowatchdog"
  ] ++ ni.hardware.kernel.params;

  powerManagement.cpuFreqGovernor = lib.mkDefault "performance";

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
