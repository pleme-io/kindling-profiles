# profiles/nixos-security-hardened/default.nix
# Security hardening layer for NixOS servers.
# Stackable — import alongside other profiles.
{ lib, ... }: {
  blackmatter.security.hardening = {
    enable = lib.mkDefault true;
    ssh.enable = lib.mkDefault true;
    fail2ban.enable = lib.mkDefault true;
    apparmor.enable = lib.mkDefault true;
    auditd.enable = lib.mkDefault true;
    kernel.enable = lib.mkDefault true;
    pam.enable = lib.mkDefault true;
    firewall = {
      enable = lib.mkDefault true;
      allowedCIDRs = lib.mkDefault ["10.42.0.0/16" "10.43.0.0/16"];
      allowedInterfaces = lib.mkDefault ["cni0" "flannel.1"];
    };
    tty.lockdown = lib.mkDefault true;
    tmpfs.enable = lib.mkDefault true;
    tools.enable = lib.mkDefault true;
  };
}
