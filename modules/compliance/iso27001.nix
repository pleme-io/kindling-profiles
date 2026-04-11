# modules/compliance/iso27001.nix
# ISO 27001:2022 Annex A convergence layer.
#
# Controls covered (selected Annex A controls applicable to compute nodes):
#   A.5.15  Access control (identity management)
#   A.5.23  Information security for cloud services
#   A.5.28  Collection of evidence (audit logging)
#   A.8.5   Secure authentication (MFA, key-only)
#   A.8.8   Management of technical vulnerabilities
#   A.8.9   Configuration management
#   A.8.15  Logging (event logs, admin activity)
#   A.8.16  Monitoring activities
#   A.8.20  Network security
#   A.8.24  Use of cryptography
#   A.8.25  Secure development lifecycle
#
# ISO 27001 is comprehensive — maps to all NIST modules combined.
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.iso27001;
in {
  options.kindling.compliance.iso27001 = {
    enable = lib.mkEnableOption "ISO 27001:2022 Annex A compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # ISO 27001 maps to the complete NIST baseline
    kindling.compliance = {
      ac.enable = true;   # A.5.15, A.8.5
      au.enable = true;   # A.5.28, A.8.15, A.8.16
      cm.enable = true;   # A.8.9
      sc.enable = true;   # A.8.20, A.8.24
      si.enable = true;   # A.8.8, A.8.25
    };
  };
}
