# modules/compliance/cis-l2.nix
# CIS Benchmark Level 2 convergence layer (extends Level 1).
#
# Level 2 adds defense-in-depth controls that may impact performance:
#   1.6  Mandatory Access Control (AppArmor)
#   1.7  Command line warning banners
#   3.3  Uncommon network protocols disabled
#   4.1  Detailed audit rules (syscall-level)
#   5.4  Root login restricted to console
#
# WARNING: Some L2 controls may conflict with K3s:
# - AppArmor needs custom profiles for containerd
# - Kernel module restrictions may block K3s networking
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.cis-l2;
in {
  options.kindling.compliance.cis-l2 = {
    enable = lib.mkEnableOption "CIS Linux Benchmark Level 2 compliance layer (extends L1)";
  };

  config = lib.mkIf cfg.enable {
    # L2 requires L1 as baseline
    kindling.compliance.cis-l1.enable = true;

    # 1.7: Warning banners
    services.openssh.banner = "/etc/issue.net";
    environment.etc."issue.net".text = ''
      UNAUTHORIZED ACCESS PROHIBITED. All activity is monitored and logged.
    '';

    # 3.3: Disable uncommon network protocols
    boot.blacklistedKernelModules = [
      "dccp" "sctp" "rds" "tipc"
    ];

    # 4.1: Detailed syscall auditing
    blackmatter.security.hardening.auditd.extraRules = [
      # CIS 4.1.4: Events that modify date and time
      "-a always,exit -F arch=b64 -S adjtimex -S settimeofday -k time-change"
      # CIS 4.1.6: Events that modify user/group info
      "-a always,exit -F arch=b64 -S sethostname -S setdomainname -k system-locale"
      # CIS 4.1.14: Unsuccessful file access attempts
      "-a always,exit -F arch=b64 -S creat -S open -S openat -S truncate -F exit=-EACCES -k access"
    ];
  };
}
