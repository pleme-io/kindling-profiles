# profiles/portao/default.nix
#
# Portao — JIT WireGuard concentrator AMI profile.
#
# Baked into a NixOS AMI by `ami-forge packer build --profile portao`,
# deployed by `Pangea::Architectures::Portao` into a target environment's
# AWS account. Operator workstations (declared as `spokes` on the matching
# `vpn-links.nix` link) connect via WireGuard; the wg-quick PreUp hook on
# each spoke calls `cordel portao-wake` if the hub is asleep, so the JIT
# bring-up cycle from connect → handshake completes in ~60-90s.
#
# Cloud-init contract (written by the launch template's user_data shim):
#   /etc/portao/env  →  PORTAO_ENV, PORTAO_REGION,
#                       PORTAO_HUB_PRIV_PARAM, PORTAO_HUBKEY_PARAM,
#                       PORTAO_PEERS_PARAM, PORTAO_HOSTED_ZONE_ID,
#                       PORTAO_DNS_NAME, PORTAO_WG_PORT
#
# All in-instance lifecycle scripts are tatara-lisp:
#   portao-userdata.tlisp   — IMDSv2 + user_data → /etc/portao/env
#   portao-init.tlisp       — first-boot bring-up (keys, DNS, wg-quick)
#   portao-peer-refresh.tlisp — 60s SSM-driven peer hot-reload
#   portao-nat.tlisp        — iptables MASQUERADE for advertised CIDRs
#   portao-metric.tlisp     — publish HandshakeAge metric to CloudWatch
#
# The control loop ("scale ASG to 0 when handshake idle") used to live
# on the instance as a shell watchdog. It now lives in AWS as a
# CloudWatch alarm + ASG SimpleScaling policy declared by
# `Pangea::Architectures::Portao`. The instance only emits the metric;
# the alarm decides when to drain. This means the instance can't stop
# itself from being drained — the 17-hour silent drift bug we hit with
# the awk-not-found shell watchdog is impossible by construction.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  ni = config.kindling.nodeIdentity;

  wgInterface = "portao0";

  # ── Lifecycle scripts — all tatara-lisp ─────────────────────────────
  # The previous shell `portao-init` / `portao-peer-refresh` /
  # `portao-watchdog` were brittle: writeShellApplication strips PATH
  # to runtimeInputs, so any forgotten binary fails silently at exec
  # time. The watchdog hit this exact bug (awk:command-not-found,
  # silent drift for 17h). Tatara-script ships one cohesive runtime;
  # the only externally-resolved binaries are the ones we explicitly
  # hand to `exec-capture`, and those are pinned via the systemd
  # unit's `path =` so missing-binary failures are caught at NixOS
  # evaluation, not at runtime.
  portaoInitScript        = ./portao-init.tlisp;
  portaoPeerRefreshScript = ./portao-peer-refresh.tlisp;
  portaoMetricScript      = ./portao-metric.tlisp;
  portaoUserdataScript    = ./portao-userdata.tlisp;
  portaoNatScript         = ./portao-nat.tlisp;

in {
  # ── Amazon AMI base ─────────────────────────────────────────────────
  # Self-contained profile pattern (mirrors attic-server) — direct
  # NixOS settings, no blizzard dependency. blizzard's hardware module
  # declares `swapDevices` + `fileSystems` that don't match the bare EC2
  # builder's actual disks, breaking `check-mountpoints` during
  # nixos-rebuild switch. amazon-image.nix already configures the right
  # filesystems for AWS.
  imports = ["${modulesPath}/virtualisation/amazon-image.nix"];

  # ── Networking + Firewall ───────────────────────────────────────────
  networking.hostName = ni.hostname or "portao";
  networking.firewall = {
    enable = true;
    allowPing = true;
    allowedTCPPorts = [22];
    allowedUDPPorts = [51822];
    trustedInterfaces = [wgInterface];
  };

  # IPv4 forwarding required for the hub to route between spokes.
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # ── Boot tuning ─────────────────────────────────────────────────────
  boot.loader.timeout = lib.mkDefault 1; # JIT — minimise cold-boot latency
  boot.loader.grub.configurationLimit = lib.mkDefault 5;
  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme" "usbhid" "sd_mod"];
  boot.kernelParams = [
    "transparent_hugepage=never"
    "nmi_watchdog=0"
    "nowatchdog"
  ] ++ (ni.hardware.kernel.params or []);
  boot.blacklistedKernelModules = ["pcspkr"];
  boot.kernelModules = ni.hardware.kernel.modules or [];

  # ── Packages ────────────────────────────────────────────────────────
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    wireguard-tools
    awscli2
    jq
    tatara-script
    htop
    tcpdump
    iotop
  ];

  # ── SSH (break-glass via SSM Session Manager preferred) ─────────────
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # ── Locale & Time ───────────────────────────────────────────────────
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── System tuning ───────────────────────────────────────────────────
  services.journald.extraConfig = ''
    Storage=volatile
    SystemMaxUse=100M
  '';
  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "30s";
    DefaultTimeoutStopSec = "20s";
  };
  systemd.network.wait-online.enable = lib.mkDefault false;

  # ── Nix ─────────────────────────────────────────────────────────────
  nix.settings = {
    trusted-users = ni.nix.trusted_users or ["root"];
    accept-flake-config = true;
    experimental-features = ["nix-command" "flakes"];
    auto-optimise-store = true;
  };

  # ── Maintenance ─────────────────────────────────────────────────────
  services.fstrim.enable = true;
  services.logrotate.enable = true;

  system.stateVersion = lib.mkDefault "25.11";

  # ── Disable services pulled in by the blackmatter aggregator ────────
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

  # ── portao-userdata: fetch + execute EC2 user_data on first boot ────
  systemd.services.portao-userdata = {
    description = "Portao userdata: fetch EC2 user_data via IMDSv2 and seed /etc/portao/env";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    unitConfig.ConditionPathExists = "!/etc/portao/env";
    path = with pkgs; [tatara-script curl bash coreutils];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${pkgs.tatara-script}/bin/tatara-script ${portaoUserdataScript}";
    };
  };

  # ── portao-init: one-shot at boot — keys + DNS + wg conf + bring-up ─
  systemd.services.portao-init = {
    description = "Portao first-boot init: SSM keys, Route53 UPSERT, wg conf, wg-quick up";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "portao-userdata.service"];
    requires = ["portao-userdata.service"];
    wants = ["network-online.target"];
    unitConfig.ConditionPathExists = "/etc/portao/env";
    # tatara-script invokes these via `exec-capture`. Pinned here so a
    # missing binary fails at NixOS evaluation rather than at runtime.
    path = with pkgs; [tatara-script awscli2 wireguard-tools jq curl bash coreutils iproute2];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${pkgs.tatara-script}/bin/tatara-script ${portaoInitScript}";
    };
  };

  # ── portao-peer-refresh: 60s SSM → wg syncconf hot-reload ───────────
  systemd.services.portao-peer-refresh = {
    description = "Portao spoke registry refresh (SSM → wg syncconf)";
    after = ["portao-init.service"];
    requires = ["portao-init.service"];
    unitConfig.ConditionPathExists = "/etc/portao/env";
    path = with pkgs; [tatara-script awscli2 wireguard-tools jq bash coreutils];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${pkgs.tatara-script}/bin/tatara-script ${portaoPeerRefreshScript}";
    };
  };
  systemd.timers.portao-peer-refresh = {
    description = "Portao spoke registry refresh — every 60s";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "60s";
      AccuracySec = "5s";
    };
  };

  # ── portao-nat: install MASQUERADE rules from PORTAO_ADVERTISE_CIDRS ──
  systemd.services.portao-nat = {
    description = "Portao NAT: install iptables MASQUERADE for advertised internal CIDRs";
    wantedBy = ["multi-user.target"];
    after = ["portao-init.service" "network-online.target"];
    requires = ["portao-init.service"];
    wants = ["network-online.target"];
    unitConfig.ConditionPathExists = "/etc/portao/env";
    path = with pkgs; [tatara-script iptables iproute2 coreutils];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${pkgs.tatara-script}/bin/tatara-script ${portaoNatScript}";
    };
  };

  # ── portao-metric: 60s CloudWatch metric publisher ──────────────────
  # Replaces the in-instance shell watchdog. The instance only emits
  # the HandshakeAge metric; the AWS-side CloudWatch alarm + ASG
  # SimpleScaling policy (declared by Pangea::Architectures::Portao)
  # owns the scale-to-zero decision. TreatMissingData=breaching on
  # the alarm means: if this publisher ever stops emitting (instance
  # OOM, IAM failure, kernel panic, kill -9), the ASG drains anyway —
  # fail-safe to $0.
  systemd.services.portao-metric = {
    description = "Portao metric: publish HandshakeAge to CloudWatch";
    after = ["portao-init.service"];
    requires = ["portao-init.service"];
    unitConfig.ConditionPathExists = "/etc/portao/env";
    path = with pkgs; [tatara-script awscli2 wireguard-tools coreutils];
    serviceConfig = {
      Type = "oneshot";
      StandardOutput = "journal";
      StandardError = "journal";
      ExecStart = "${pkgs.tatara-script}/bin/tatara-script ${portaoMetricScript}";
    };
  };
  systemd.timers.portao-metric = {
    description = "Portao HandshakeAge metric — every 60s";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "60s";
      OnUnitActiveSec = "60s";
      AccuracySec = "5s";
    };
  };
}
