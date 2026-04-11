# modules/compliance/pci.nix
# PCI DSS 4.0 convergence layer.
#
# Requirements covered:
#   1.2.1  Restrict inbound/outbound traffic (firewall)
#   1.2.5  Deny all by default
#   2.2.1  Change vendor-supplied defaults
#   4.2.1  Strong cryptography for transmission
#   5.2    Anti-malware mechanisms (file integrity)
#   8.2.1  Unique identification
#   8.3.6  Password complexity (N/A — key-only SSH)
#   10.2   Audit trail for all system components
#   10.3   Audit trail protected from modification
#
# PCI DSS has significant overlap with FedRAMP. This module adds
# PCI-SPECIFIC controls not already covered by NIST modules.
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.pci;
in {
  options.kindling.compliance.pci = {
    enable = lib.mkEnableOption "PCI DSS 4.0 compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # 1.2.1, 1.2.5: Firewall + deny-all default
    kindling.compliance.sc.enable = true;

    # 2.2.1: Change defaults (SSH hardening, no default passwords)
    kindling.compliance.ac.enable = true;

    # 4.2.1: Strong crypto for transmission
    # Enforced by ac.nix SSH modernCryptoOnly + sc.nix sysctl

    # 5.2: File integrity monitoring
    kindling.compliance.si.enable = true;

    # 8.2.1: Unique identification (SSH key-only, no shared accounts)
    # 8.3.6: Password complexity (N/A — passwords disabled)

    # 10.2, 10.3: Audit trail
    kindling.compliance.au.enable = true;

    # PCI-specific: log all network connections for cardholder data environments
    blackmatter.security.hardening.auditd.extraRules = [
      "-a always,exit -F arch=b64 -S connect -k pci_network_connections"
    ];
  };
}
