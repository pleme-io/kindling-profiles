# modules/compliance/cm.nix
# NIST 800-53 Configuration Management (CM) convergence layer.
#
# Controls covered:
#   CM-2   Baseline configuration (NixOS atomic rebuild is inherent)
#   CM-6   Configuration settings (restrictive defaults)
#   CM-7   Least functionality (disable unused services, USB, TTY)
#   CM-8   Information system component inventory (NixOS closure)
#
# This layer is a convergence invariant — it must hold at the AMI checkpoint.
# NixOS itself provides CM-2 (immutable system) and CM-8 (closure = inventory).
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.cm;
in {
  options.kindling.compliance.cm = {
    enable = lib.mkEnableOption "NIST 800-53 Configuration Management (CM) compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # CM-7: Least functionality — disable unused I/O and access paths
    blackmatter.security.hardening.tmpfs = {
      enable = true;
      cleanOnBoot = true;
    };
    blackmatter.security.hardening.tty.lockdown = true;
    blackmatter.security.hardening.usb.restrictDevices = true;
  };
}
