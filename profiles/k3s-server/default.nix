# profiles/k3s-server/default.nix
# NixOS K3s control plane server profile.
#
# Extracted pattern from nix/nodes/plo — generic K3s server settings.
# All node-specific values come from kindling.nodeIdentity (ni).
#
# Components: K3s server, FluxCD, IPVS, production tuning, dnsmasq.
{
  config,
  lib,
  pkgs,
  ...
}: let
  ni = config.kindling.nodeIdentity;
  k3sDefaults = import ../../lib/k3s-defaults.nix {inherit lib;};
in {
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

    clusterCIDR = ni.kubernetes.cluster_cidr or k3sDefaults.defaultClusterCIDR;
    serviceCIDR = ni.kubernetes.service_cidr or k3sDefaults.defaultServiceCIDR;
    clusterDNS = k3sDefaults.defaultClusterDNS;

    waitForDNS.enable = true;

    extraFlags = k3sDefaults.allServerFlags k3sDefaults;
  };

  # ── Networking ──────────────────────────────────────────────
  blackmatter.profiles.blizzard.networkingExtended = {
    hostName = ni.hostname;
    useNetworkTopology = true;

    firewall = {
      enable = true;
      allowPing = true;
      allowedTCPPorts = ni.network.firewall.allowed_tcp_ports;
      allowedUDPPorts = ni.network.firewall.allowed_udp_ports;
      trustedInterfaces = ["cni0" "flannel.1"];
    };
  };

  # ── Hardware ────────────────────────────────────────────────
  blackmatter.profiles.blizzard.hardware = {
    cpu.type = ni.hardware.cpu.vendor;
    kernel.modules = k3sDefaults.k3sKernelModules ++ ni.hardware.kernel.modules;
    platform = ni.hardware.platform;
  };

  # ── DNS ─────────────────────────────────────────────────────
  blackmatter.profiles.blizzard.dns = {
    dnsmasq = {
      enable = true;
      useNetworkTopology = true;
      port = 53;
      listenAddresses = ["127.0.0.1"];
      upstreamServers = ["1.1.1.1" "8.8.8.8"];
      cacheSize = 1000;
      logQueries = false;
    };
    localNameservers = ["127.0.0.1"];
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

  # ── System Tuning ───────────────────────────────────────────
  blackmatter.profiles.blizzard.optimizations = {
    enable = true;
    cpuGovernor = "performance";
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
