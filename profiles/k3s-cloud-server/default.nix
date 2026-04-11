# profiles/k3s-cloud-server/default.nix
# NixOS K3s server for cloud hosts (AWS/GCP/Hetzner).
#
# Self-contained profile using direct NixOS settings — no blizzard dependency.
# This avoids merge conflicts with amazon-image.nix and other cloud modules.
# All node-specific values come from kindling.nodeIdentity (ni).
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
  # ── Amazon AMI base + composable compliance layers ─────────
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
    # Compliance layers — each is an independent convergence invariant.
    # Toggleable per profile. All enabled here for FedRAMP Moderate baseline.
    ../../modules/compliance/ac.nix   # Access Control (SSH, fail2ban, PAM)
    ../../modules/compliance/au.nix   # Audit & Accountability (auditd)
    ../../modules/compliance/cm.nix   # Configuration Management (tmpfs, TTY, USB)
    ../../modules/compliance/sc.nix   # System & Communications Protection (sysctl, firewall)
    ../../modules/compliance/si.nix   # System & Information Integrity (lynis, aide)
    ../../modules/compliance/fedramp-high.nix  # FedRAMP High additive (disabled by default)
    # Additional compliance frameworks (disabled by default, enable per cluster)
    ../../modules/compliance/soc2.nix    # SOC 2 Type II (CC6/CC7/CC8)
    ../../modules/compliance/pci.nix     # PCI DSS 4.0 (Req 1-10)
    ../../modules/compliance/cis-l1.nix  # CIS Linux Benchmark Level 1
    # Domain control surfaces — typed interfaces for each convergence domain
    ../../modules/networking.nix      # VPN, firewall, CIDRs
    ../../modules/orchestration.nix   # K3s/kubeadm, FluxCD, profiles
    ../../modules/identity.nix        # Secrets provider, bootstrap method
    ../../modules/observability.nix   # Logging, metrics, tracing
    ../../modules/fleet.nix           # Reverse-access fleet control
  ];

  # Enable all compliance layers — FedRAMP Moderate requires all five.
  # Individual clusters can disable specific layers via mkForce if needed.
  kindling.compliance = {
    ac.enable = lib.mkDefault true;
    au.enable = lib.mkDefault true;
    cm.enable = lib.mkDefault true;
    sc.enable = lib.mkDefault true;
    si.enable = lib.mkDefault true;
  };

  # ── K3s Server ──────────────────────────────────────────────
  services.blackmatter.k3s = {
    enable = true;
    role = "server";
    configPath = "/etc/rancher/k3s/config.yaml";
    agent.enable = true;
    # Dual-sentinel role selection: systemd ConditionPathExists gates which
    # K3s service starts. kindling-init writes exactly one sentinel.
    # Both services in wantedBy=multi-user.target. No race conditions.
    roleConditionPath = {
      server = "/var/lib/kindling/server-mode";
      agent = "/var/lib/kindling/agent-mode";
    };
    disable = ["traefik"];
    clusterCIDR = if ni.kubernetes.cluster_cidr != null then ni.kubernetes.cluster_cidr else k3sDefaults.defaultClusterCIDR;
    serviceCIDR = if ni.kubernetes.service_cidr != null then ni.kubernetes.service_cidr else k3sDefaults.defaultServiceCIDR;
    clusterDNS = k3sDefaults.defaultClusterDNS;
    waitForDNS.enable = true;
    extraFlags = k3sDefaults.allServerFlags k3sDefaults
      # Add VPN addresses as tls-san so K3s server cert covers VPN IPs
      ++ (map (link: "--tls-san=${builtins.head (lib.splitString "/" link.address)}")
             (builtins.filter (link: link.address or null != null) ni.network.vpn_links));
  };

  # ── Kernel ────────────────────────────────────────────────
  boot.kernelModules = k3sDefaults.k3sKernelModules ++ ni.hardware.kernel.modules;
  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme" "usbhid" "sd_mod"];
  boot.kernelParams = [
    "transparent_hugepage=never"
    "skew_tick=1"
    "nmi_watchdog=0"
    "nowatchdog"
  ] ++ ni.hardware.kernel.params;
  boot.blacklistedKernelModules = ["pcspkr"];

  # ── Networking ───────────────────────────────────────────
  # Firewall is managed by kindling.networking module (typed control surface).
  # Additional ports from nodeIdentity are merged here.
  networking.hostName = ni.hostname;
  networking.firewall.allowedTCPPorts = ni.network.firewall.allowed_tcp_ports;
  networking.firewall.allowedUDPPorts = ni.network.firewall.allowed_udp_ports;

  # ── VPN ────────────────────────────────────────────────────
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

  # ── FluxCD (GitOps Bootstrap) ─────────────────────────────
  services.blackmatter.fluxcd = lib.mkIf ni.fluxcd.enable {
    enable = true;
    conditionPath = "/var/lib/kindling/fluxcd-ready"; # sentinel written by kindling-init
    source = {
      url = ni.fluxcd.source;
      branch = ni.fluxcd.reconcile.branch or "main";
      interval = ni.fluxcd.reconcile.interval or "1m0s";
      auth = ni.fluxcd.auth;
      tokenFile = lib.mkIf (ni.fluxcd.auth == "token") ni.fluxcd.token_file;
      sshKeyFile = lib.mkIf (ni.fluxcd.auth == "ssh") ni.fluxcd.ssh_key_file;
    };
    reconcile = {
      path = ni.fluxcd.reconcile.path or ".";
      interval = ni.fluxcd.reconcile.interval or "2m0s";
      prune = ni.fluxcd.reconcile.prune or true;
    };
    sops = lib.mkIf (ni.secrets.provider == "sops") {
      enable = true;
      ageKeyFile = if ni.secrets.age_key_file != null
        then ni.secrets.age_key_file
        else "/var/lib/sops-nix/key.txt";
    };
  };

  # ── Boot & System Tuning ──────────────────────────────────
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

  # ── SSH ─────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # ── Locale & Time ──────────────────────────────────────────
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── Packages ────────────────────────────────────────────────
  # Minimal closure: only what's needed for convergence + operation.
  # Diagnostic tools (htop, iotop, tcpdump) are available via nix-shell
  # when needed — not baked into every AMI.
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    # Convergence primitives (required for bootstrap + operation)
    k3s
    kubectl
    fluxcd
    wireguard-tools
    # Diagnostics (minimal — operators use nix-shell for heavy tools)
    htop
    lsof
    ethtool
  ];

  # ── Nix ─────────────────────────────────────────────────────
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

  # ── NVMe Optimization ─────────────────────────────────────
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="nvme[0-9]n1", ATTR{queue/scheduler}="none"
    ACTION=="add|change", KERNEL=="nvme[0-9]n1", ATTR{queue/nr_requests}="1024"
    ACTION=="add|change", KERNEL=="nvme[0-9]n1", ATTR{queue/read_ahead_kb}="512"
  '';

  # ── Monitoring & Maintenance ───────────────────────────────
  # smartd disabled — EC2 NVMe doesn't support SMART (and saves smartmontools from closure)
  services.smartd.enable = false;
  services.logrotate.enable = true;
  services.fstrim.enable = true;

  # ── Disable unnecessary services from blackmatter aggregator ─
  # The blackmatter NixOS module includes security, android, services
  # modules that enable things we don't need on a K3s cloud server.
  services.tor.enable = lib.mkForce false;
  services.postgresql.enable = lib.mkForce false;
  virtualisation.docker.enable = lib.mkForce false;
  blackmatter.security.tools = {
    network.enable = lib.mkForce false;
    web.enable = lib.mkForce false;
    osint.enable = lib.mkForce false;
    passwords.enable = lib.mkForce false;
    privacy.enable = lib.mkForce false;
  };

  # ── Hardening ────────────────────────────────────────────
  # The compliance modules (ac/au/cm/sc/si) set individual hardening options.
  # The master toggle enables the blackmatter hardening module that implements them.
  # K3s-incompatible options are gated via the compliance interface — NOT mkForce.
  blackmatter.security.hardening.enable = true;

  # K3s-incompatible hardening stays off (these default to false with
  # researcher profile no longer auto-imported). The fedramp-high module
  # can re-enable kernel with integrity mode when explicitly opted in.
  # No overrides needed — proper lattice boundaries.

}
