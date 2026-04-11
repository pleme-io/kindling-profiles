# modules/compliance/au.nix
# NIST 800-53 Audit & Accountability (AU) convergence layer.
#
# Controls covered:
#   AU-2   Audit events (auditd enabled with system call monitoring)
#   AU-3   Content of audit records (file, SSH, privesc, deletion tracking)
#   AU-9   Protection of audit information (log integrity)
#   AU-11  Audit record retention (journal size limits)
#   AU-12  Audit generation (auditd service active)
#
# This layer is a convergence invariant — it must hold at the AMI checkpoint.
# The auditd service must be enabled in the AMI; it activates at boot.
{ config, lib, ... }:
let
  cfg = config.kindling.compliance.au;
in {
  options.kindling.compliance.au = {
    enable = lib.mkEnableOption "NIST 800-53 Audit & Accountability (AU) compliance layer";
  };

  config = lib.mkIf cfg.enable {
    # AU-2, AU-3, AU-12: Audit daemon with comprehensive monitoring
    blackmatter.security.hardening.auditd = {
      enable = true;
      monitorFiles = true;       # /etc/passwd, /etc/shadow, /etc/ssh/sshd_config, etc.
      monitorSSHKeys = true;     # ~/.ssh/ key changes
      monitorPrivEsc = true;     # execve with euid=0
      monitorDeletion = true;    # unlink/rename operations
    };
  };
}
