# profiles/k8s-cloud-server/default.nix
# NixOS upstream Kubernetes (kubeadm) server for cloud hosts (AWS/GCP/Hetzner).
#
# Self-contained profile using direct NixOS settings -- no blizzard dependency.
# This mirrors the k3s-cloud-server profile but uses kubeadm + containerd + etcd
# from nixpkgs instead of K3s. All node-specific values come from
# kindling.nodeIdentity (ni).
#
# The dual-sentinel pattern is reused: kindling-init writes a role sentinel,
# and kubelet.service uses ConditionPathExists to determine whether to start.
# kubeadm init/join is handled by kindling-init, NOT by this NixOS module.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  ni = config.kindling.nodeIdentity;
in {
  # -- Amazon AMI base (fileSystems, boot loader, EC2 tools) --
  imports = ["${modulesPath}/virtualisation/amazon-image.nix"];

  # -- Container Runtime: containerd --
  virtualisation.containerd = {
    enable = true;
    settings = {
      version = 2;
      plugins."io.containerd.grpc.v1.cri" = {
        sandbox_image = "registry.k8s.io/pause:3.10";
        containerd.runtimes.runc = {
          runtime_type = "io.containerd.runc.v2";
          options.SystemdCgroup = true;
        };
      };
    };
  };

  # -- Kubelet systemd service with dual-sentinel role selection --
  # We do NOT use services.kubernetes.* from NixOS because kubeadm manages
  # the kubelet lifecycle and config directly. Instead, we create a minimal
  # kubelet.service that kubeadm expects to find.
  systemd.services.kubelet = {
    description = "Kubernetes Kubelet";
    documentation = ["https://kubernetes.io/docs/reference/command-line-tools-reference/kubelet/"];
    after = [
      "containerd.service"
      "kindling-init.service"
      "network-online.target"
    ];
    wants = ["containerd.service" "network-online.target"];
    wantedBy = ["multi-user.target"];

    # Dual-sentinel: kubelet only starts if kindling-init has written a sentinel.
    # Either server-mode or agent-mode must exist. If neither exists (AMI build),
    # kubelet does not start.
    unitConfig = {
      ConditionPathExists = [
        "|/var/lib/kindling/server-mode"
        "|/var/lib/kindling/agent-mode"
      ];
    };

    serviceConfig = {
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.kubernetes}/bin/kubelet"
        "--config=/var/lib/kubelet/config.yaml"
        "--kubeconfig=/etc/kubernetes/kubelet.conf"
        "--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
        "--node-name=${ni.hostname}"
      ];
      Restart = "always";
      RestartSec = "10s";
      # kubelet needs elevated privileges
      Delegate = true;
      KillMode = "process";
      OOMScoreAdjust = -999;
    };

    # kubeadm writes the actual kubelet config, but we pre-create the dir
    preStart = ''
      mkdir -p /var/lib/kubelet
      mkdir -p /etc/kubernetes/manifests
    '';
  };

  # -- Kernel --
  boot.kernelModules = [
    "br_netfilter"
    "overlay"
    "ip_vs"
    "ip_vs_rr"
    "ip_vs_wrr"
    "ip_vs_sh"
    "nf_conntrack"
  ] ++ ni.hardware.kernel.modules;
  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme" "usbhid" "sd_mod"];
  boot.kernelParams = [
    "transparent_hugepage=never"
    "skew_tick=1"
    "nmi_watchdog=0"
    "nowatchdog"
  ] ++ ni.hardware.kernel.params;
  boot.blacklistedKernelModules = ["pcspkr"];

  # Required sysctl for Kubernetes networking
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.bridge.bridge-nf-call-ip6tables" = 1;
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "fs.inotify.max_user_watches" = 1048576;
    "fs.inotify.max_user_instances" = 8192;
  };

  # -- Networking & Firewall --
  networking.hostName = ni.hostname;
  networking.firewall = {
    enable = true;
    allowPing = true;
    # 6443: API server, 2379-2380: etcd, 10250: kubelet, 10257: controller-manager,
    # 10259: scheduler, 30000-32767: NodePort range
    allowedTCPPorts = [22 6443 2379 2380 10250 10257 10259 80 443]
      ++ ni.network.firewall.allowed_tcp_ports;
    allowedUDPPorts = [8472] ++ ni.network.firewall.allowed_udp_ports;
    # Allow all traffic on the CNI bridge and VXLAN interfaces
    trustedInterfaces = ["cni0" "flannel.1" "vxlan.calico" "cali+"];
  };

  # -- VPN --
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

  # -- FluxCD (GitOps Bootstrap) --
  services.blackmatter.fluxcd = lib.mkIf ni.fluxcd.enable {
    enable = true;
    conditionPath = "/var/lib/kindling/fluxcd-ready";
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
    # Kubernetes core
    kubernetes  # provides kubeadm, kubelet, kubectl
    etcd        # etcd for CP nodes
    containerd  # container runtime
    cni-plugins # CNI networking
    # Tools
    kubectl k9s fluxcd
    wireguard-tools
    htop nvme-cli ethtool iotop
    smartmontools lsof tcpdump
    # Required by kubeadm
    conntrack-tools socat iproute2 iptables
    cri-tools  # CRI debugging (crictl)
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
