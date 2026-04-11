# modules/compliance/hipaa.nix
# HIPAA Security Rule convergence layer.
#
# Safeguards covered:
#   164.312(a)(1)  Access control (unique user ID, emergency access)
#   164.312(a)(2)  Audit controls (record and examine activity)
#   164.312(c)(1)  Integrity (protect ePHI from alteration/destruction)
#   164.312(d)     Person/entity authentication
#   164.312(e)(1)  Transmission security (encryption in transit)
#   164.312(e)(2)  Integrity controls for transmitted ePHI
#
# HIPAA maps to NIST modules + additional PHI-specific controls.
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.hipaa;
in {
  options.kindling.compliance.hipaa = {
    enable = lib.mkEnableOption "HIPAA Security Rule compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # 164.312(a): Access control → ac.nix
    kindling.compliance.ac.enable = true;
    # 164.312(a)(2): Audit controls → au.nix
    kindling.compliance.au.enable = true;
    # 164.312(c)(1): Integrity → si.nix (file integrity)
    kindling.compliance.si.enable = true;
    # 164.312(e): Transmission security → sc.nix (crypto, firewall)
    kindling.compliance.sc.enable = true;
    # 164.312(d): Authentication → ac.nix (SSH key-only)

    # HIPAA-specific: audit all access to /var/lib (potential ePHI storage)
    blackmatter.security.hardening.auditd.extraRules = [
      "-w /var/lib -p rwa -k hipaa_phi_access"
    ];

    # HIPAA requires persistent audit logs (not volatile)
    kindling.observability.logging.journalPersistent = true;
    kindling.observability.logging.maxRetentionDays = 365;
  };
}
