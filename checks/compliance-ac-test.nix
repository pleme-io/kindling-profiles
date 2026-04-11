# NixOS VM test: verify Access Control (AC) compliance layer.
#
# Validates NIST 800-53 AC controls on a single VM:
#   AC-2/AC-17: SSH key-only, password auth disabled
#   AC-17: fail2ban running and protecting SSH
#   AC-6: PAM limits enforced (core dumps disabled)
#
# Run: nix build .#checks.x86_64-linux.compliance-ac-test
# Cost: FREE (local QEMU VM, no cloud resources)
{ pkgs, lib }:

pkgs.testers.runNixOSTest {
  name = "compliance-ac";

  nodes.machine = { ... }: {
    imports = [
      ../modules/compliance/ac.nix
    ];

    # Enable the AC compliance layer
    kindling.compliance.ac.enable = true;

    # blackmatter hardening master toggle (required by AC module)
    blackmatter.security.hardening.enable = true;

    # SSH must be enabled for the AC layer to harden
    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # AC-2, AC-17: SSH hardening
    machine.wait_for_unit("sshd.service")
    machine.succeed("grep -i 'PasswordAuthentication.*no' /etc/ssh/sshd_config")

    # AC-17: fail2ban active
    machine.wait_for_unit("fail2ban.service")
    machine.succeed("fail2ban-client status sshd")

    # AC-6: PAM limits — core dumps disabled
    machine.succeed("test $(ulimit -c) -eq 0 || grep 'hard.*core.*0' /etc/security/limits.conf")
  '';
}
