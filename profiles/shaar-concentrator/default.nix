# profiles/shaar-concentrator/default.nix
#
# Shaar concentrator — the akeyless-vpn JIT WireGuard concentrator AMI profile.
# Sibling of `profiles/portao`: same shape (self-contained AMI baseline, no
# blizzard dependency, internet-facing on a single UDP port), different brain —
# instead of portao's SSM-key + Route53 tatara-lisp first-boot stack, the
# `shaar-concentrator` Rust binary owns ALL the logic (server tunnel, address
# pool, /sync admission webhook, lease GC). This profile is just the node-OS it
# runs on.
#
# Baked into a NixOS AMI and deployed into the akeyless-dev AWS account
# (376129857990, us-east-1). Operator workstations run the cid `shaar-daemon`
# and dial this hub at the WireGuard endpoint; the akeyless gateway calls the
# /sync webhook to admit/revoke clients.
#
# Cloud-init contract (the per-instance `public_endpoint` — the EIP ip:port —
# is the one value not known at bake time): a first-boot resolver (a
# portao-userdata sibling owned by the cloud-init / Pangea layer) renders the
# final config at `/run/shaar-concentrator/config.yaml` and the module is
# pointed at it via `configFile`, OR `publicEndpoint` is set directly when the
# EIP is known at eval time. See modules/shaar-concentrator.nix header.
#
# What clones from portao:
#   * amazon-image.nix base (no blizzard hardware module — its swapDevices /
#     fileSystems don't match the bare EC2 builder's disks).
#   * Internet-facing firewall: SSH + the WireGuard UDP port; ICMP allowed.
#   * IPv4 forwarding for hub → target routing (here via the typed module).
#   * JIT boot tuning, volatile journald, UTC, fstrim/logrotate.
#   * blackmatter aggregator services disabled (tor, docker, security tools).
#
# What's NEW vs portao:
#   * The reach plane is declarative nftables (MASQUERADE + DEFAULT-DENY forward
#     filter) emitted by the typed module — not an imperative iptables tlisp.
#   * One long-running Rust service (`shaar-concentrator`) instead of the
#     init/peer-refresh/metric/fingerprint oneshot+timer fleet.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  ni = config.kindling.nodeIdentity;
  shaar = config.pleme.nixos.shaarConcentrator;
in {
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
    ../../modules/shaar-concentrator.nix
  ];

  # ── The concentrator (the binary owns the logic) ────────────────────
  # Fleet defaults per the akeyless-dev deployment: pool 10.99.0.0/24, target
  # 10.0.0.0/16, WireGuard UDP 51822, /sync webhook on 8200. `publicEndpoint`
  # stays null here — it is the one per-instance value resolved at first boot
  # (see the header). `package` is left to its default (`pkgs.shaar-concentrator`
  # from the akeyless-vpn overlay); the AMI builder wires it explicitly.
  pleme.nixos.shaarConcentrator = {
    enable = true;
    poolCidr = lib.mkDefault "10.99.0.0/24";
    targetCidrs = lib.mkDefault ["10.0.0.0/16"];
    listenPort = lib.mkDefault 51822;
    webhookPort = lib.mkDefault 8200;
    # The cloud-init resolver renders this with the per-instance EIP ip:port.
    configFile = lib.mkDefault "/run/shaar-concentrator/config.yaml";
  };

  # ── Amazon AMI base ─────────────────────────────────────────────────
  networking.hostName = ni.hostname or "shaar-concentrator";
  networking.firewall = {
    enable = true;
    allowPing = true;
    allowedTCPPorts = [22];
    # The module appends the WireGuard UDP listen port + the /sync webhook TCP
    # port (allowedUDPPorts / allowedTCPPorts merge across modules).
  };

  # ── Boot tuning (JIT — minimise cold-boot latency) ──────────────────
  boot.loader.timeout = lib.mkDefault 1;
  boot.loader.grub.configurationLimit = lib.mkDefault 5;
  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme" "usbhid" "sd_mod"];
  boot.kernelParams =
    [
      "transparent_hugepage=never"
      "nmi_watchdog=0"
      "nowatchdog"
    ]
    ++ (ni.hardware.kernel.params or []);
  boot.blacklistedKernelModules = ["pcspkr"];
  # ni-declared modules compose with the `tun` module the concentrator module adds.
  boot.kernelModules = ni.hardware.kernel.modules or [];

  # ── Packages ────────────────────────────────────────────────────────
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs;
    [
      wireguard-tools # break-glass inspection (`wg show`)
      iproute2
      jq
      htop
      tcpdump
      iotop
    ]
    ++ lib.optional (shaar.package != null) shaar.package;

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
}
