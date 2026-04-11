# modules/compliance/soc2.nix
# SOC 2 Type II convergence layer.
#
# Trust Service Criteria covered:
#   CC6.1  Logical and physical access controls
#   CC6.6  System boundary protection
#   CC6.7  Restrict data transmission/movement
#   CC7.1  Detection of malicious/unauthorized activities
#   CC7.2  Monitoring for anomalies
#   CC8.1  Change management controls
#
# SOC 2 overlaps heavily with FedRAMP — this module adds SOC2-SPECIFIC
# controls that aren't already in ac/au/cm/sc/si. Enable alongside
# the NIST modules for full SOC 2 coverage.
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.soc2;
in {
  options.kindling.compliance.soc2 = {
    enable = lib.mkEnableOption "SOC 2 Type II compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # CC6.1, CC6.6: Access controls + boundary protection
    # Covered by ac.nix (SSH, fail2ban, PAM) + sc.nix (firewall, sysctl)
    # Force-enable those layers for SOC 2
    kindling.compliance.ac.enable = true;
    kindling.compliance.sc.enable = true;

    # CC7.1, CC7.2: Detection + monitoring
    # Covered by au.nix (auditd) — force-enable
    kindling.compliance.au.enable = true;

    # CC8.1: Change management
    # NixOS immutable store IS change management. Additional: log all
    # package changes via auditd rule on /nix/store
    blackmatter.security.hardening.auditd.extraRules = [
      "-w /nix/store -p wa -k nix_store_changes"
    ];
  };
}
