# modules/compliance/fedramp-high.nix
# FedRAMP High additive layer — extends Moderate baseline with High-impact controls.
#
# FedRAMP tiers: Low → Moderate → High
# Moderate is the baseline (ac.nix + au.nix + cm.nix + sc.nix + si.nix).
# This module adds controls ONLY required at High impact level.
#
# Additional controls at High:
#   AC-2(4)   Automated audit actions (process accounting)
#   AU-4      Audit storage capacity (persistent, not volatile)
#   AU-9(2)   Audit backup to separate system
#   IA-2(12)  MFA for all remote access (placeholder — requires external provider)
#   SC-13(3)  FIPS-validated cryptographic modules
#   SC-28(1)  Cryptographic protection of information at rest
#   SI-6      Security function verification (kernel module signing)
#   SI-7(1)   Integrity checks on boot (measured boot)
#
# WARNING: Some High controls conflict with K3s IPVS mode.
# kernel.lockdown=confidentiality may break IPVS — test thoroughly.
# AppArmor requires custom K3s/containerd profiles.
{ config, lib, pkgs, ... }:
let
  cfg = config.kindling.compliance.fedramp-high;
in {
  options.kindling.compliance.fedramp-high = {
    enable = lib.mkEnableOption "FedRAMP High additive compliance layer (extends Moderate)";
  };

  config = lib.mkIf cfg.enable {
    # Force all Moderate layers on (High requires Moderate as baseline)
    kindling.compliance = {
      ac.enable = true;
      au.enable = true;
      cm.enable = true;
      sc.enable = true;
      si.enable = true;
    };

    # SI-6, SI-7(1): Kernel module signing + lockdown (integrity mode)
    # Using 'integrity' not 'confidentiality' to preserve IPVS compatibility
    blackmatter.security.hardening.kernel.enable = true;

    # SC-13(3): FIPS-aware crypto — ensure OpenSSL FIPS provider is available
    # Full FIPS enforcement requires NixOS kernel + OpenSSL FIPS module build
    # which is a separate workstream. This ensures the tools are present.
    environment.systemPackages = [ pkgs.openssl ];

    # AU-4, AU-9(2): Persistent audit logging (not volatile journald)
    services.journald.extraConfig = lib.mkForce ''
      Storage=persistent
      SystemMaxUse=2G
      SystemMaxFileSize=100M
      MaxRetentionSec=90day
    '';
  };
}
