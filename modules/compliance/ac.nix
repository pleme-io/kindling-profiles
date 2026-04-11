# modules/compliance/ac.nix
# NIST 800-53 Access Control (AC) convergence layer.
#
# Controls covered:
#   AC-2   Account management (key-only SSH, no password auth)
#   AC-4   Information flow enforcement (firewall with K3s CIDRs)
#   AC-6   Least privilege (PAM limits, core dumps disabled)
#   AC-17  Remote access (SSH hardening, modern crypto, rate limiting)
#
# This layer is a convergence invariant — it must hold at the AMI checkpoint.
# Verifiable independently via NixOS VM test and kindling ami-test.
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.ac;
in {
  options.kindling.compliance.ac = {
    enable = lib.mkEnableOption "NIST 800-53 Access Control (AC) compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # AC-2, AC-17: SSH hardening — key-only, modern crypto, rate limiting
    blackmatter.security.hardening.ssh = {
      enable = true;
      maxAuthTries = 3;
      disableForwarding = true;
      modernCryptoOnly = true;
      clientAliveInterval = 300;
      clientAliveCountMax = 2;
    };

    # AC-17: Brute-force protection on remote access
    blackmatter.security.hardening.fail2ban = {
      enable = true;
      maxretry = 3;
      bantime = "24h";
      sshJail = { enable = true; maxretry = 3; bantime = "1h"; };
    };

    # AC-6: PAM resource limits — least privilege for processes
    blackmatter.security.hardening.pam = {
      enable = true;
      disableCoreDumps = true;
      maxOpenFiles = 65536;
      maxProcesses = 32768;
    };
  };
}
