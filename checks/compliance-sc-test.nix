# NixOS VM test: verify System & Communications Protection (SC) compliance layer.
#
# Validates NIST 800-53 SC controls on a single VM:
#   SC-5: SYN cookies enabled (DoS protection)
#   SC-7: Anti-spoofing (rp_filter), source route rejection, redirect rejection
#   SC-13: Kernel pointer restriction (kptr_restrict)
#   SI-16: Symlink/hardlink protection, dmesg restriction
#
# Run: nix build .#checks.x86_64-linux.compliance-sc-test
# Cost: FREE (local QEMU VM, no cloud resources)
{ pkgs, lib }:

pkgs.testers.runNixOSTest {
  name = "compliance-sc";

  nodes.machine = { ... }: {
    imports = [
      ../modules/compliance/sc.nix
    ];

    # Enable the SC compliance layer
    kindling.compliance.sc.enable = true;

    # blackmatter hardening master toggle (required by SC module for firewall)
    blackmatter.security.hardening.enable = true;

    # Firewall must be enabled (SC module adds hardening rules)
    networking.firewall.enable = true;
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # SC-5: SYN cookies enabled
    machine.succeed("test $(sysctl -n net.ipv4.tcp_syncookies) -eq 1")

    # SC-7: Anti-spoofing
    machine.succeed("test $(sysctl -n net.ipv4.conf.all.rp_filter) -eq 1")

    # SC-7: Source route rejection
    machine.succeed("test $(sysctl -n net.ipv4.conf.all.accept_source_route) -eq 0")

    # SC-7: ICMP redirect rejection
    machine.succeed("test $(sysctl -n net.ipv4.conf.all.accept_redirects) -eq 0")
    machine.succeed("test $(sysctl -n net.ipv4.conf.all.send_redirects) -eq 0")

    # SI-16: Kernel pointer restriction
    machine.succeed("test $(sysctl -n kernel.dmesg_restrict) -eq 1")
    machine.succeed("test $(sysctl -n kernel.kptr_restrict) -eq 2")

    # SI-16: Symlink/hardlink protection
    machine.succeed("test $(sysctl -n fs.protected_symlinks) -eq 1")
    machine.succeed("test $(sysctl -n fs.protected_hardlinks) -eq 1")

    # SC-28: Core dump prevention
    machine.succeed("test $(sysctl -n fs.suid_dumpable) -eq 0")

    # SC-7: Firewall has rules (not empty default)
    machine.succeed("iptables -L -n | wc -l | xargs test 6 -lt")
  '';
}
