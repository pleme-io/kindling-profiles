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
  # ── Amazon AMI base (fileSystems, boot loader, EC2 tools) ──
  imports = ["${modulesPath}/virtualisation/amazon-image.nix"];

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

  # ── Kernel Sysctl Hardening ───────────────────────────────
  # K3s-required + FedRAMP hardening in one block.
  # These are convergence invariants — they must hold in the AMI checkpoint.
  boot.kernel.sysctl = {
    # K3s required (mkDefault — may also be set by blackmatter K3s module)
    "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
    "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
    "net.ipv4.ip_forward" = lib.mkDefault 1;
    "fs.inotify.max_user_watches" = 1048576;
    "fs.inotify.max_user_instances" = 8192;
    # FedRAMP hardening — SC-5 (SYN flood), SC-7 (anti-spoofing)
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.default.rp_filter" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv4.conf.default.accept_redirects" = 0;
    "net.ipv4.conf.all.send_redirects" = 0;
    "net.ipv4.conf.default.send_redirects" = 0;
    "net.ipv4.conf.all.accept_source_route" = 0;
    "net.ipv4.conf.default.accept_source_route" = 0;
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
    # Kernel hardening — SI-16
    "kernel.dmesg_restrict" = 1;
    "kernel.kptr_restrict" = 2;
    "fs.protected_hardlinks" = 1;
    "fs.protected_symlinks" = 1;
    "fs.suid_dumpable" = 0;
  };

  # ── Networking & Firewall ─────────────────────────────────
  networking.hostName = ni.hostname;
  networking.firewall = {
    enable = true;
    allowPing = true;
    allowedTCPPorts = [22 6443 80 443 10250] ++ ni.network.firewall.allowed_tcp_ports;
    allowedUDPPorts = [8472] ++ ni.network.firewall.allowed_udp_ports;
    trustedInterfaces = ["cni0" "flannel.1"];
  };

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
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    k3s kubectl k9s fluxcd
    wireguard-tools
    htop nvme-cli ethtool iotop
    smartmontools lsof tcpdump
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
  services.smartd.enable = true;
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

  # ── FedRAMP Moderate Hardening (convergence invariants) ─────
  # These are compliance invariants that must hold at the AMI convergence
  # checkpoint. Enabled selectively to avoid K3s-incompatible settings
  # (AppArmor custom profiles, kernel lockdown=confidentiality breaks IPVS).
  blackmatter.security.hardening = {
    enable = true;

    # SSH hardening — IA-2(1), AC-17
    ssh = {
      enable = true;
      maxAuthTries = 3;
      disableForwarding = true;
      modernCryptoOnly = true;
      clientAliveInterval = 300;
      clientAliveCountMax = 2;
    };

    # Brute-force protection — SC-5, SI-4
    fail2ban = {
      enable = true;
      maxretry = 3;
      bantime = "24h";
      sshJail = { enable = true; maxretry = 3; bantime = "1h"; };
    };

    # Audit logging — AU-2, AU-3, AU-9, AU-12 (FedRAMP critical)
    auditd = {
      enable = true;
      monitorFiles = true;
      monitorSSHKeys = true;
      monitorPrivEsc = true;
      monitorDeletion = true;
    };

    # PAM resource limits — SC-5, SC-6
    pam = {
      enable = true;
      disableCoreDumps = true;
      maxOpenFiles = 65536;
      maxProcesses = 32768;
    };

    # Firewall hardening with K3s-aware CIDRs — SC-7, AC-4
    firewall = {
      enable = true;
      sshRateLimit = true;
      blockTCPAnomalies = true;
      allowedCIDRs = k3sDefaults.defaultAllowedCIDRs;
      allowedInterfaces = ["cni0" "flannel.1"];
    };

    # Host hygiene — CM-7, SI-7
    tmpfs = { enable = true; cleanOnBoot = true; };
    tty.lockdown = true;
    usb.restrictDevices = true;

    # Security audit tools (lynis, aide) — CA-2, RA-5
    tools.enable = true;

    # NOT enabled (K3s incompatible):
    # - apparmor: needs custom profiles for container runtime
    # - kernel: lockdown=confidentiality breaks IPVS proxy mode
    # - autoUpgrade: reboot on CP node causes cluster downtime
  };

}
