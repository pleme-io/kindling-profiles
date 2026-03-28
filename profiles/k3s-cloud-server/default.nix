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
    disable = ["traefik"];
    clusterCIDR = if ni.kubernetes.cluster_cidr != null then ni.kubernetes.cluster_cidr else k3sDefaults.defaultClusterCIDR;
    serviceCIDR = if ni.kubernetes.service_cidr != null then ni.kubernetes.service_cidr else k3sDefaults.defaultServiceCIDR;
    clusterDNS = k3sDefaults.defaultClusterDNS;
    waitForDNS.enable = true;
    extraFlags = k3sDefaults.allServerFlags k3sDefaults;
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
  blackmatter.security.hardening.enable = lib.mkForce false;
}
