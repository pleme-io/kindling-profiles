# modules/compliance/cis-l1.nix
# CIS Benchmark Level 1 convergence layer.
#
# CIS Linux Benchmark sections covered:
#   1.1  Filesystem configuration (tmpfs, separate partitions)
#   1.4  Secure boot settings
#   2.1  inetd services (disabled by NixOS design)
#   3.1  Network parameters (sysctl hardening)
#   3.2  Network parameters (host-only, not router)
#   4.1  Audit daemon configuration
#   4.2  Log configuration
#   5.1  SSH server configuration
#   5.2  PAM configuration
#   5.3  User environment (umask, shell timeout)
#   6.1  System file permissions
#   6.2  User and group settings
#
# CIS Level 1 is the baseline. Level 2 adds kernel hardening,
# MAC (AppArmor/SELinux), and more restrictive settings.
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.cis-l1;
in {
  options.kindling.compliance.cis-l1 = {
    enable = lib.mkEnableOption "CIS Linux Benchmark Level 1 compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # CIS maps directly to our NIST modules:
    # 1.1 + 1.4: Filesystem + boot → cm.nix
    kindling.compliance.cm.enable = true;
    # 3.x: Network params → sc.nix
    kindling.compliance.sc.enable = true;
    # 4.x: Audit → au.nix
    kindling.compliance.au.enable = true;
    # 5.x: SSH + PAM → ac.nix
    kindling.compliance.ac.enable = true;
    # 6.x: File integrity → si.nix
    kindling.compliance.si.enable = true;

    # CIS-specific: shell timeout (TMOUT)
    environment.variables.TMOUT = "900";

    # CIS-specific: restrictive umask
    environment.variables.UMASK = "027";

    # CIS 1.1.21: Ensure sticky bit on world-writable directories
    # NixOS handles this via tmpfs configuration (cm.nix)

    # CIS 5.3.1: Password requirements (N/A — key-only SSH, no passwords)
    # CIS 5.3.2: Lockout policy → fail2ban (ac.nix)
  };
}
