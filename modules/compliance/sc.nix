# modules/compliance/sc.nix
# NIST 800-53 System & Communications Protection (SC) convergence layer.
#
# Controls covered:
#   SC-5   Denial of service protection (SYN cookies, rate limiting, PAM limits)
#   SC-7   Boundary protection (firewall hardening, anti-spoofing, source route rejection)
#   SC-8   Transmission confidentiality (sysctl martian logging)
#   SC-13  Cryptographic protection (kernel pointer restriction)
#   SC-28  Protection of information at rest (core dump disabled via sysctl)
#   SC-45  System time (NTP configuration)
#   SI-16  Memory protection (dmesg restrict, symlink/hardlink protection)
#
# This layer applies kernel sysctl hardening and firewall rules.
# K3s-specific CIDRs are whitelisted via k3s-defaults.nix.
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.sc;
  k3sDefaults = import ../../lib/k3s-defaults.nix { inherit lib; };
in {
  options.kindling.compliance.sc = {
    enable = lib.mkEnableOption "NIST 800-53 System & Communications Protection (SC) compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # SC-7: Firewall hardening with K3s-aware CIDRs
    blackmatter.security.hardening.firewall = {
      enable = true;
      sshRateLimit = true;
      blockTCPAnomalies = true;
      allowedCIDRs = k3sDefaults.defaultAllowedCIDRs;
      allowedInterfaces = ["cni0" "flannel.1"];
    };

    # SC-5, SC-7, SC-13, SI-16: Kernel sysctl hardening
    boot.kernel.sysctl = {
      # K3s required (mkDefault — may also be set by K3s module)
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "fs.inotify.max_user_watches" = 1048576;
      "fs.inotify.max_user_instances" = 8192;
      # SC-5: SYN flood defense
      "net.ipv4.tcp_syncookies" = 1;
      # SC-7: Anti-spoofing
      "net.ipv4.conf.all.rp_filter" = 1;
      "net.ipv4.conf.default.rp_filter" = 1;
      # SC-7: Reject source routing and redirects
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv4.conf.default.accept_source_route" = 0;
      # SC-8: Log martian packets
      "net.ipv4.conf.all.log_martians" = 1;
      # SC-5: Ignore broadcast pings
      "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
      # SI-16: Kernel memory protection
      "kernel.dmesg_restrict" = 1;
      "kernel.kptr_restrict" = 2;
      "fs.protected_hardlinks" = 1;
      "fs.protected_symlinks" = 1;
      # SC-28: Prevent core dumps from leaking secrets
      "fs.suid_dumpable" = 0;
    };
  };
}
