# modules/compliance/si.nix
# NIST 800-53 System & Information Integrity (SI) convergence layer.
#
# Controls covered:
#   SI-2   Flaw remediation (lynis vulnerability scanning)
#   SI-4   Information system monitoring (aide file integrity)
#   SI-7   Software/firmware integrity (aide baseline, NixOS immutability)
#
# This layer installs security audit and integrity monitoring tools.
# NixOS inherently provides SI-7 (immutable store, content-addressed paths).
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.si;
in {
  options.kindling.compliance.si = {
    enable = lib.mkEnableOption "NIST 800-53 System & Information Integrity (SI) compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # SI-2, SI-4, SI-7: Security audit and integrity tools
    blackmatter.security.hardening.tools.enable = true;
  };
}
