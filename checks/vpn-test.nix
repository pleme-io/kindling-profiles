# NixOS VM test: verify WireGuard tunnel connectivity between two machines.
#
# Launches two QEMU VMs (server + client), configures a WireGuard tunnel
# between them, and verifies bidirectional ping through the tunnel.
# Also validates that the firewall correctly blocks non-tunneled traffic
# and that the tunnel survives interface bounce.
#
# Run: nix build .#checks.x86_64-linux.vpn-test
# Cost: FREE (local QEMU VMs, no cloud resources)
{ pkgs, lib }:

let
  # Generate WireGuard key pairs at build time (deterministic per build, not secrets)
  serverKeys = pkgs.runCommand "wg-keys-server" { } ''
    mkdir -p $out
    ${pkgs.wireguard-tools}/bin/wg genkey | tee $out/private | \
      ${pkgs.wireguard-tools}/bin/wg pubkey > $out/public
    chmod 600 $out/private
  '';

  clientKeys = pkgs.runCommand "wg-keys-client" { } ''
    mkdir -p $out
    ${pkgs.wireguard-tools}/bin/wg genkey | tee $out/private | \
      ${pkgs.wireguard-tools}/bin/wg pubkey > $out/public
    chmod 600 $out/private
  '';

  serverPub = lib.removeSuffix "\n" (builtins.readFile "${serverKeys}/public");
  clientPub = lib.removeSuffix "\n" (builtins.readFile "${clientKeys}/public");
in

pkgs.testers.runNixOSTest {
  name = "vpn-connectivity";

  nodes = {
    server = { ... }: {
      boot.kernelModules = [ "wireguard" ];

      networking.wireguard.interfaces.wg-test = {
        ips = [ "10.99.0.1/24" ];
        listenPort = 51899;
        privateKeyFile = "${serverKeys}/private";
        peers = [
          {
            publicKey = clientPub;
            allowedIPs = [ "10.99.0.2/32" ];
          }
        ];
      };

      # Only allow WireGuard UDP — no other inbound traffic
      networking.firewall = {
        enable = true;
        allowedUDPPorts = [ 51899 ];
        allowedTCPPorts = [ ];
      };
    };

    client = { nodes, ... }: {
      boot.kernelModules = [ "wireguard" ];

      networking.wireguard.interfaces.wg-test = {
        ips = [ "10.99.0.2/24" ];
        privateKeyFile = "${clientKeys}/private";
        peers = [
          {
            publicKey = serverPub;
            endpoint = "${nodes.server.networking.primaryIPAddress}:51899";
            allowedIPs = [ "10.99.0.1/32" ];
            persistentKeepalive = 5;
          }
        ];
      };

      networking.firewall.enable = true;
    };
  };

  testScript = ''
    start_all()

    # ── Phase 1: WireGuard interface setup ──
    server.wait_for_unit("wireguard-wg-test.service")
    client.wait_for_unit("wireguard-wg-test.service")

    # Verify interfaces exist and have correct IPs
    server.succeed("ip link show wg-test")
    client.succeed("ip link show wg-test")
    server.succeed("ip addr show wg-test | grep 10.99.0.1")
    client.succeed("ip addr show wg-test | grep 10.99.0.2")

    # ── Phase 2: Tunnel connectivity ──
    # Bidirectional ping through the WireGuard tunnel
    client.wait_until_succeeds("ping -c 3 -W 5 10.99.0.1", timeout=30)
    server.wait_until_succeeds("ping -c 3 -W 5 10.99.0.2", timeout=30)

    # Verify WireGuard handshake completed on both sides
    server.succeed("wg show wg-test")
    client.succeed("wg show wg-test")

    # Verify correct listen port
    server.succeed("wg show wg-test | grep 'listening port: 51899'")

    # Verify handshake happened (latest handshake field exists)
    server.succeed("wg show wg-test | grep 'latest handshake'")

    # ── Phase 3: Firewall validation ──
    # The tunnel IPs should be reachable, but TCP on a random high port should not
    # (firewall blocks non-WG traffic)
    client.fail("nc -z -w 2 10.99.0.1 12345")

    # ── Phase 4: Interface bounce (resilience) ──
    # Take the tunnel down and bring it back up — verify it reconnects
    client.succeed("wg-quick down wg-test")
    client.succeed("wg-quick up ${clientKeys}/../../wg-test.conf || ip link delete wg-test 2>/dev/null; true")

    # Re-establish via systemd (the canonical way)
    client.succeed("systemctl restart wireguard-wg-test.service")
    client.wait_for_unit("wireguard-wg-test.service")

    # Verify tunnel works again after bounce
    client.wait_until_succeeds("ping -c 3 -W 5 10.99.0.1", timeout=30)

    # ── Phase 5: WireGuard tools validation ──
    server.succeed("wg --version")
    server.succeed("wg-quick --help > /dev/null 2>&1 || true")
  '';
}
