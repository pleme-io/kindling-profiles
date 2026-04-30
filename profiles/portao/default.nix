# profiles/portao/default.nix
#
# Portao — JIT WireGuard concentrator AMI profile.
#
# Baked into a NixOS AMI by `ami-forge packer build --profile portao`,
# deployed by `Pangea::Architectures::Portao` into a target environment's
# AWS account. Operator workstations (declared as `spokes` on the matching
# `vpn-links.nix` link) connect via WireGuard; the wg-quick PreUp hook on
# each spoke calls `cordel portao-wake` if the hub is asleep, so the JIT
# bring-up cycle from connect → handshake completes in ~60-90s.
#
# Cloud-init contract (written by the launch template's user_data shim):
#   /etc/portao/env  →  PORTAO_ENV, PORTAO_REGION, PORTAO_EIP_TAG,
#                       PORTAO_PEERS_PARAM, PORTAO_HUBKEY_PARAM,
#                       PORTAO_WG_PORT
#
# First-boot flow (portao-init.service):
#   1. Generate /etc/wireguard/portao0.key if missing (private key)
#   2. Derive public key, ssm:PutParameter to PORTAO_HUBKEY_PARAM
#   3. ec2:AssociateAddress to claim the persistent EIP by tag
#   4. Render /etc/wireguard/portao0.conf from PORTAO_PEERS_PARAM
#   5. Bring up wg-quick@portao0
#
# Steady state (portao-peer-refresh.timer, every 60s):
#   - Re-fetch PORTAO_PEERS_PARAM, diff vs current, hot-reload via `wg syncconf`
#
# Teardown (portao-watchdog.timer, every 5min):
#   - `wg show portao0 latest-handshakes`; if all peers idle > IDLE_THRESHOLD,
#     `aws autoscaling set-desired-capacity --desired-capacity 0`
{
  config,
  lib,
  pkgs,
  ...
}: let
  ni = config.kindling.nodeIdentity;

  wgInterface = "portao0";

  # Idle threshold: 15 min of no handshake → scale to 0.
  # The AWS-side CloudWatch alarm (created by Pangea::Architectures::Portao)
  # is a separate backstop with a different (typically larger) window.
  idleThresholdSecs = 900;

  # Scripts compiled into the AMI — live in /run/current-system/sw/bin
  # so systemd units don't have to know nix store paths.
  portaoInit = pkgs.writeShellApplication {
    name = "portao-init";
    runtimeInputs = with pkgs; [awscli2 wireguard-tools jq coreutils];
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      . /etc/portao/env

      KEY_FILE=/etc/wireguard/${wgInterface}.key
      PUB_FILE=/etc/wireguard/${wgInterface}.pub
      CONF_FILE=/etc/wireguard/${wgInterface}.conf

      # 1) Private key — fetch from SSM (SecureString), seeded by
      # `portao-secrets-bootstrap` on the operator workstation. Kept
      # in SOPS canonically; SSM is the AMI's read-only delivery
      # channel. /etc/wireguard is mode 700 on the persistent root
      # volume so the key survives instance refresh.
      HUB_PRIV_PARAM="''${PORTAO_HUB_PRIV_PARAM:-/portao/$PORTAO_ENV/hub-private-key}"
      mkdir -p /etc/wireguard
      chmod 700 /etc/wireguard
      umask 077
      aws ssm get-parameter \
        --region "$PORTAO_REGION" \
        --name "$HUB_PRIV_PARAM" \
        --with-decryption \
        --query 'Parameter.Value' --output text > "$KEY_FILE"
      wg pubkey < "$KEY_FILE" > "$PUB_FILE"

      # 2) Publish the hub public key to SSM so the operator's
      #    `kindling vpn lock-hub-key` (and any future drift detector)
      #    can verify the deployed AMI is using the expected key.
      #    Spokes do NOT read this — they have the hub pubkey baked
      #    into vpn-links.nix at nix-eval time. Drift here is a
      #    diagnostic, not a runtime concern.
      aws ssm put-parameter \
        --region "$PORTAO_REGION" \
        --name "$PORTAO_HUBKEY_PARAM" \
        --type String \
        --overwrite \
        --value "$(cat "$PUB_FILE")"

      # 3) Claim the persistent EIP by Name tag — same EIP across cycles
      #    so vpn.<env>.quero.lol always resolves to the same address.
      INSTANCE_ID=$(curl -fsSL http://169.254.169.254/latest/meta-data/instance-id)
      ALLOC_ID=$(aws ec2 describe-addresses \
        --region "$PORTAO_REGION" \
        --filters "Name=tag:Name,Values=$PORTAO_EIP_TAG" \
        --query 'Addresses[0].AllocationId' --output text)
      if [ -z "$ALLOC_ID" ] || [ "$ALLOC_ID" = "None" ]; then
        echo "portao-init: no EIP found tagged Name=$PORTAO_EIP_TAG — aborting" >&2
        exit 1
      fi
      aws ec2 associate-address \
        --region "$PORTAO_REGION" \
        --instance-id "$INSTANCE_ID" \
        --allocation-id "$ALLOC_ID" \
        --allow-reassociation

      # 4) Render config from peer list. Hub address derives from the
      #    spoke subnet's .254 by convention (matches vpn-links.nix).
      PEERS_JSON=$(aws ssm get-parameter \
        --region "$PORTAO_REGION" \
        --name "$PORTAO_PEERS_PARAM" \
        --with-decryption --query 'Parameter.Value' --output text)
      HUB_ADDRESS=$(echo "$PEERS_JSON" | jq -r '.hub_address // "10.100.30.254/24"')
      LISTEN_PORT="''${PORTAO_WG_PORT:-51822}"

      {
        echo "[Interface]"
        echo "PrivateKey = $(cat "$KEY_FILE")"
        echo "Address = $HUB_ADDRESS"
        echo "ListenPort = $LISTEN_PORT"
        echo "MTU = 1380"
        echo "Table = off  # portao routes are managed by sysctl IPv4 forwarding + per-spoke AllowedIPs"
        echo
        # Iterate spokes from JSON ({ peers: [{ name, public_key, psk, address }] })
        echo "$PEERS_JSON" | jq -r '
          .peers[] |
          "[Peer]\n# spoke: " + .name + "\n" +
          "PublicKey = " + .public_key + "\n" +
          (if .psk then ("PresharedKey = " + .psk + "\n") else "" end) +
          "AllowedIPs = " + .address + "\n"
        '
      } > "$CONF_FILE"
      chmod 600 "$CONF_FILE"

      # 5) Bring up the interface — systemd will systemctl restart this
      #    on subsequent peer-refresh cycles via wg-syncconf.
      if ! ip link show ${wgInterface} >/dev/null 2>&1; then
        wg-quick up ${wgInterface}
      fi
    '';
  };

  portaoPeerRefresh = pkgs.writeShellApplication {
    name = "portao-peer-refresh";
    runtimeInputs = with pkgs; [awscli2 wireguard-tools jq coreutils];
    text = ''
      set -euo pipefail
      . /etc/portao/env

      CONF_FILE=/etc/wireguard/${wgInterface}.conf
      KEY_FILE=/etc/wireguard/${wgInterface}.key

      PEERS_JSON=$(aws ssm get-parameter \
        --region "$PORTAO_REGION" \
        --name "$PORTAO_PEERS_PARAM" \
        --with-decryption --query 'Parameter.Value' --output text)
      HUB_ADDRESS=$(echo "$PEERS_JSON" | jq -r '.hub_address // "10.100.30.254/24"')
      LISTEN_PORT="''${PORTAO_WG_PORT:-51822}"

      TMP=$(mktemp)
      {
        echo "[Interface]"
        echo "PrivateKey = $(cat "$KEY_FILE")"
        echo "Address = $HUB_ADDRESS"
        echo "ListenPort = $LISTEN_PORT"
        echo "MTU = 1380"
        echo
        echo "$PEERS_JSON" | jq -r '
          .peers[] |
          "[Peer]\n# spoke: " + .name + "\n" +
          "PublicKey = " + .public_key + "\n" +
          (if .psk then ("PresharedKey = " + .psk + "\n") else "" end) +
          "AllowedIPs = " + .address + "\n"
        '
      } > "$TMP"

      # Hot-reload only if changed.
      if ! diff -q "$TMP" "$CONF_FILE" >/dev/null 2>&1; then
        install -m 600 "$TMP" "$CONF_FILE"
        # `wg syncconf` reloads peers without dropping the interface.
        wg syncconf ${wgInterface} <(wg-quick strip "$CONF_FILE")
      fi
      rm -f "$TMP"
    '';
  };

  portaoWatchdog = pkgs.writeShellApplication {
    name = "portao-watchdog";
    runtimeInputs = with pkgs; [awscli2 wireguard-tools coreutils];
    text = ''
      set -euo pipefail
      . /etc/portao/env

      ASG_NAME="''${PORTAO_ASG_NAME:-portao-$PORTAO_ENV-asg}"
      NOW=$(date +%s)
      MAX_AGE=${toString idleThresholdSecs}

      # No peers configured yet → not idle, just bootstrapping.
      if ! wg show ${wgInterface} latest-handshakes 2>/dev/null | grep -q .; then
        exit 0
      fi

      OLDEST=0
      while read -r _pubkey ts; do
        # ts=0 means "never handshaken" — treat as max age (older than threshold).
        if [ "$ts" = "0" ]; then
          AGE=$((MAX_AGE + 1))
        else
          AGE=$((NOW - ts))
        fi
        # We want to keep alive if ANY peer is fresh — so track the MIN age.
        if [ "$OLDEST" = "0" ] || [ "$AGE" -lt "$OLDEST" ]; then
          OLDEST=$AGE
        fi
      done < <(wg show ${wgInterface} latest-handshakes)

      if [ "$OLDEST" -gt "$MAX_AGE" ]; then
        echo "portao-watchdog: all peers idle > $MAX_AGE seconds (oldest=$OLDEST), scaling $ASG_NAME to 0"
        aws autoscaling set-desired-capacity \
          --region "$PORTAO_REGION" \
          --auto-scaling-group-name "$ASG_NAME" \
          --desired-capacity 0 \
          --honor-cooldown
        # Also publish a metric so the operator dashboard sees it.
        aws cloudwatch put-metric-data \
          --region "$PORTAO_REGION" \
          --namespace Pleme/Portao \
          --metric-name SelfTeardown \
          --dimensions "Env=$PORTAO_ENV" \
          --value 1
      fi
    '';
  };

in {
  # ── Blizzard server profile ─────────────────────────────────────────
  blackmatter.profiles.blizzard = {
    enable = true;
    variant = "server";
  };

  # ── Networking + WireGuard ──────────────────────────────────────────
  blackmatter.profiles.blizzard.networkingExtended = {
    hostName = ni.hostname or "portao";
    useNetworkTopology = false;
    firewall = {
      enable = true;
      allowPing = true;
      allowedTCPPorts = [22];
      allowedUDPPorts = [51822];
      trustedInterfaces = [wgInterface];
    };
  };

  # IPv4 forwarding required for the hub to route between spokes.
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # WireGuard tooling baked into the AMI.
  environment.systemPackages = with pkgs; [
    wireguard-tools
    awscli2
    jq
    portaoInit
    portaoPeerRefresh
    portaoWatchdog
  ];

  # ── Hardware ────────────────────────────────────────────────────────
  blackmatter.profiles.blizzard.hardware = {
    cpu.type = ni.hardware.cpu.vendor or "amd";
    kernel.modules = ni.hardware.kernel.modules or [];
    platform = ni.hardware.platform or "x86_64-linux";
  };

  # ── SSH (break-glass via SSM Session Manager preferred) ─────────────
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # ── System tuning (lighter than k3s — VPN concentrator only) ────────
  blackmatter.profiles.blizzard.optimizations = {
    enable = true;
    cpuGovernor = "performance";
    nvme.optimize = false;
  };

  blackmatter.components.baseSystemTuning = {
    enable = true;
    boot = {
      timeout = 1; # JIT — minimise cold-boot latency
      configurationLimit = 5;
      initrdCompress = "lz4";
    };
    journald = {
      storage = "volatile";
      systemMaxUse = "100M";
    };
    systemd = {
      defaultTimeoutStartSec = "30s";
      defaultTimeoutStopSec = "20s";
      waitOnline = false;
    };
    nix = {
      gcAutomatic = false; # AMI is built once; no GC needed
      optimiseAutomatic = false;
    };
  };

  blackmatter.components.systemTime = {
    enable = true;
    timeZone = "UTC";
  };
  blackmatter.components.systemLocale = {
    enable = true;
    defaultLocale = "en_US.UTF-8";
  };

  # ── portao-init: one-shot at boot ───────────────────────────────────
  systemd.services.portao-init = {
    description = "Portao first-boot init: generate keys, claim EIP, render wg conf";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "amazon-init.service"];
    wants = ["network-online.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${portaoInit}/bin/portao-init";
      StandardOutput = "journal";
      StandardError = "journal";
    };
  };

  # ── portao-peer-refresh: 60s timer, hot-reloads peers from SSM ─────
  systemd.services.portao-peer-refresh = {
    description = "Portao spoke registry refresh (SSM → wg syncconf)";
    after = ["portao-init.service"];
    requires = ["portao-init.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${portaoPeerRefresh}/bin/portao-peer-refresh";
    };
  };
  systemd.timers.portao-peer-refresh = {
    description = "Portao spoke registry refresh — every 60s";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "60s";
      AccuracySec = "5s";
    };
  };

  # ── portao-watchdog: 5min timer, scales ASG to 0 when idle ─────────
  systemd.services.portao-watchdog = {
    description = "Portao idle watchdog — scale ASG to 0 if no fresh handshakes";
    after = ["portao-init.service"];
    requires = ["portao-init.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${portaoWatchdog}/bin/portao-watchdog";
    };
  };
  systemd.timers.portao-watchdog = {
    description = "Portao idle watchdog — every 5 min";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
      AccuracySec = "30s";
    };
  };
}
