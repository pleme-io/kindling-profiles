# profiles/k3s-agent/default.nix
# NixOS K3s worker node profile.
#
# Extracted pattern from nix/nodes/zek — generic K3s agent settings.
# All node-specific values come from kindling.nodeIdentity (ni).
#
# Components: K3s agent, node labels/taints, Docker.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}: let
  ni = config.kindling.nodeIdentity;
  k3sDefaults = import ../../lib/k3s-defaults.nix {inherit lib;};

  # Build --node-label flags from ni.kubernetes.node_labels
  labelFlags = lib.mapAttrsToList (k: v: "--node-label=${k}=${v}") ni.kubernetes.node_labels;

  # Build --node-taint flags from ni.kubernetes.node_taints
  taintFlags = map (t: "--node-taint=${t}") ni.kubernetes.node_taints;
in {
  imports = [
    inputs.self.nixosModules.blackmatter
  ];

  # Enable blizzard profile — agent variant
  blackmatter.profiles.blizzard = {
    enable = true;
    variant = "agent";
  };

  # ── K3s Agent ───────────────────────────────────────────────
  services.blackmatter.k3s = {
    enable = true;
    role = "agent";
    serverAddr = ni.kubernetes.server_addr;
    waitForDNS = true;

    extraFlags = [
      "--node-name=${ni.hostname}"
    ] ++ labelFlags ++ taintFlags;
  };

  # ── Hardware ────────────────────────────────────────────────
  blackmatter.profiles.blizzard.hardware = {
    cpu.type = ni.hardware.cpu;
    kernel.modules = k3sDefaults.k3sKernelModules ++ ni.hardware.kernel.modules;
    platform = ni.hardware.platform;
  };

  # ── Networking ──────────────────────────────────────────────
  blackmatter.profiles.blizzard.networkingExtended = {
    hostName = ni.hostname;
    useNetworkTopology = true;

    firewall = {
      enable = false;
      allowPing = true;
      trustedInterfaces = ["cni0" "flannel.1"];
    };
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
      domainMappings = [];
    };
    localNameservers = ["127.0.0.1"];
  };

  # ── SSH ─────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = true;
    };
  };

  # ── Locale & Time ───────────────────────────────────────────
  blackmatter.components.systemTime = {
    enable = true;
    timeZone = "America/New_York";
  };
  blackmatter.components.systemLocale = {
    enable = true;
    defaultLocale = "en_US.UTF-8";
  };

  # ── System Tuning ───────────────────────────────────────────
  blackmatter.profiles.blizzard.optimizations = {
    enable = true;
    cpuGovernor = "performance";
    nvme.optimize = true;
  };

  blackmatter.components.baseSystemTuning = {
    enable = true;
    realTimeKernel = false;
    boot = {
      timeout = 5;
      configurationLimit = 50;
      initrdCompress = "gzip";
    };
    journald = {
      storage = "persistent";
      systemMaxUse = "500M";
    };
    systemd = {
      defaultTimeoutStartSec = "30s";
      defaultTimeoutStopSec = "30s";
      waitOnline = false;
    };
  };

  # ── Virtualisation ──────────────────────────────────────────
  blackmatter.profiles.blizzard.virtualisation = {
    docker = {
      enable = true;
      enableOnBoot = true;
    };
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
