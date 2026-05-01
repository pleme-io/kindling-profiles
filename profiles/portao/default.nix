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
  modulesPath,
  ...
}: let
  ni = config.kindling.nodeIdentity;

  wgInterface = "portao0";

  # Idle threshold: 15 min of no handshake → scale to 0.
  # The AWS-side CloudWatch alarm (created by Pangea::Architectures::Portao)
  # is a separate backstop with a different (typically larger) window.
  idleThresholdSecs = 900;

  # Cold-start grace period: when the instance has just woken, no spoke
  # has had time to handshake yet. Without this grace, the watchdog fires
  # at OnBootSec=5min and scales the ASG back to 0 BEFORE the spoke that
  # triggered the wake even completes its first handshake — kicking off
  # an instance churn loop. The cordel portao-wake op typically takes
  # 60-120s end-to-end (ASG scale + EC2 boot + portao-init), so 15 min
  # of grace gives the operator's wg-quick PreUp + handshake comfortable
  # margin even on a slow link or tight SSO refresh path. The watchdog
  # uses /proc/uptime to gate this — no external timer state.
  coldStartGraceSecs = 900;

  # Scripts compiled into the AMI — live in /run/current-system/sw/bin
  # so systemd units don't have to know nix store paths.
  portaoInit = pkgs.writeShellApplication {
    name = "portao-init";
    runtimeInputs = with pkgs; [awscli2 wireguard-tools jq coreutils curl];
    text = ''
      set -euo pipefail
      # shellcheck source=/dev/null
      . /etc/portao/env

      KEY_FILE=/etc/wireguard/${wgInterface}.key
      PUB_FILE=/etc/wireguard/${wgInterface}.pub
      CONF_FILE=/etc/wireguard/${wgInterface}.conf

      # 1) Private key — fetch from SSM (SecureString), seeded by
      # `kindling vpn portao-bootstrap` on the operator workstation.
      # Kept in SOPS canonically; SSM is the AMI's read-only delivery
      # channel. Re-fetched on every boot — instance disks are
      # ephemeral now (no EIP-stable identity), so we don't try to
      # cache the key locally.
      mkdir -p /etc/wireguard
      chmod 700 /etc/wireguard
      umask 077
      aws ssm get-parameter \
        --region "$PORTAO_REGION" \
        --name "$PORTAO_HUB_PRIV_PARAM" \
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

      # 3) Publish DNS — read this instance's auto-assigned public IP
      #    via IMDSv2 + UPSERT the A record at PORTAO_DNS_NAME so spokes
      #    resolve us at handshake time. No EIP — idle cost is $0; the
      #    operator-facing DNS name is the stable contract instead.
      IMDS_TOKEN=$(curl -fsS -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
        http://169.254.169.254/latest/api/token)
      PUBLIC_IP=$(curl -fsS -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        http://169.254.169.254/latest/meta-data/public-ipv4)
      if [ -z "$PUBLIC_IP" ]; then
        echo "portao-init: no public IPv4 on this instance — aborting" >&2
        exit 1
      fi
      CHANGE_BATCH=$(jq -nc \
        --arg name "$PORTAO_DNS_NAME" \
        --arg ip "$PUBLIC_IP" \
        '{Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$name,Type:"A",TTL:60,ResourceRecords:[{Value:$ip}]}}]}')
      aws route53 change-resource-record-sets \
        --hosted-zone-id "$PORTAO_HOSTED_ZONE_ID" \
        --change-batch "$CHANGE_BATCH" >/dev/null
      echo "portao-init: upserted $PORTAO_DNS_NAME → $PUBLIC_IP"

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
      # shellcheck source=/dev/null
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
      # shellcheck source=/dev/null
      . /etc/portao/env

      ASG_NAME="''${PORTAO_ASG_NAME:-portao-$PORTAO_ENV-asg}"
      NOW=$(date +%s)
      MAX_AGE=${toString idleThresholdSecs}
      GRACE=${toString coldStartGraceSecs}

      # Cold-start grace: when the instance has just been woken by a
      # spoke's `cordel portao-wake`, the spoke's handshake hasn't had
      # time to land yet. Honoring scaledown inside the grace window
      # would terminate the instance the spoke is actively trying to
      # reach, kicking off a churn loop. /proc/uptime is monotonic and
      # local — no external state needed.
      UPTIME=$(awk '{print int($1)}' /proc/uptime)
      if [ "$UPTIME" -lt "$GRACE" ]; then
        echo "portao-watchdog: cold-start grace ($UPTIME < $GRACE) — skipping scaledown"
        exit 0
      fi

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
  # ── Amazon AMI base ─────────────────────────────────────────────────
  # Self-contained profile pattern (mirrors attic-server) — direct
  # NixOS settings, no blizzard dependency. blizzard's hardware module
  # declares `swapDevices` + `fileSystems` that don't match the bare EC2
  # builder's actual disks, breaking `check-mountpoints` during
  # nixos-rebuild switch. amazon-image.nix already configures the right
  # filesystems for AWS.
  imports = ["${modulesPath}/virtualisation/amazon-image.nix"];

  # ── Networking + Firewall ───────────────────────────────────────────
  networking.hostName = ni.hostname or "portao";
  networking.firewall = {
    enable = true;
    allowPing = true;
    allowedTCPPorts = [22];
    allowedUDPPorts = [51822];
    trustedInterfaces = [wgInterface];
  };

  # IPv4 forwarding required for the hub to route between spokes.
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv4.conf.all.forwarding" = 1;
  };

  # ── Boot tuning ─────────────────────────────────────────────────────
  boot.loader.timeout = lib.mkDefault 1; # JIT — minimise cold-boot latency
  boot.loader.grub.configurationLimit = lib.mkDefault 5;
  boot.initrd.availableKernelModules = ["xhci_pci" "ahci" "nvme" "usbhid" "sd_mod"];
  boot.kernelParams = [
    "transparent_hugepage=never"
    "nmi_watchdog=0"
    "nowatchdog"
  ] ++ (ni.hardware.kernel.params or []);
  boot.blacklistedKernelModules = ["pcspkr"];
  boot.kernelModules = ni.hardware.kernel.modules or [];

  # ── Packages ────────────────────────────────────────────────────────
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    wireguard-tools
    awscli2
    jq
    portaoInit
    portaoPeerRefresh
    portaoWatchdog
    htop
    tcpdump
    iotop
  ];

  # ── SSH (break-glass via SSM Session Manager preferred) ─────────────
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # ── Locale & Time ───────────────────────────────────────────────────
  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # ── System tuning ───────────────────────────────────────────────────
  services.journald.extraConfig = ''
    Storage=volatile
    SystemMaxUse=100M
  '';
  systemd.settings.Manager = {
    DefaultTimeoutStartSec = "30s";
    DefaultTimeoutStopSec = "20s";
  };
  systemd.network.wait-online.enable = lib.mkDefault false;

  # ── Nix ─────────────────────────────────────────────────────────────
  nix.settings = {
    trusted-users = ni.nix.trusted_users or ["root"];
    accept-flake-config = true;
    experimental-features = ["nix-command" "flakes"];
    auto-optimise-store = true;
  };

  # ── Maintenance ─────────────────────────────────────────────────────
  services.fstrim.enable = true;
  services.logrotate.enable = true;

  system.stateVersion = lib.mkDefault "25.11";

  # ── Disable services pulled in by the blackmatter aggregator ────────
  # (mirrors attic-server pattern — these aren't relevant to a single-
  # purpose VPN concentrator and add closure weight).
  services.tor.enable = lib.mkForce false;
  virtualisation.docker.enable = lib.mkForce false;
  blackmatter.security.tools = {
    network.enable = lib.mkForce false;
    web.enable = lib.mkForce false;
    osint.enable = lib.mkForce false;
    passwords.enable = lib.mkForce false;
    privacy.enable = lib.mkForce false;
  };
  blackmatter.security.hardening.enable = lib.mkForce false;

  # ── portao-userdata: fetch + execute EC2 user_data on first boot ────
  # The NixOS amazon-image module ships an `amazon-init.service` that's
  # supposed to fetch user_data from IMDSv2 and execute it, but its
  # current upstream wiring (`After=multi-user.target`) makes it a no-op
  # in practice — the unit reaches "ready" without firing the script,
  # so /etc/portao/env never gets written.
  #
  # Owning the contract directly avoids that dependency: this unit
  # explicitly fetches user_data via IMDSv2 and runs it before
  # portao-init. ConditionPathExists guards against re-running on
  # subsequent boots (user_data already executed) and during AMI bake
  # (no IMDSv2 endpoint).
  systemd.services.portao-userdata = {
    description = "Portao userdata: fetch EC2 user_data via IMDSv2 and seed /etc/portao/env";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];
    # Don't re-run on subsequent boots — portao-init's env file is the
    # marker that this unit already fired successfully. (RemainAfterExit
    # alone isn't enough: a boot-after-stop would trigger the unit again
    # and overwrite a possibly-edited env file.)
    unitConfig.ConditionPathExists = "!/etc/portao/env";
    path = [pkgs.curl pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StandardOutput = "journal";
      StandardError = "journal";
    };
    script = ''
      set -euo pipefail
      mkdir -p /etc/portao

      # IMDSv2 token (60s TTL is plenty — we only need one call).
      TOKEN=$(curl -sf -X PUT \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
        http://169.254.169.254/latest/api/token)

      # Fetch user_data (404 = no userdata attached, which is fatal —
      # there's no fallback shape; an unconfigured portao instance is
      # useless).
      USERDATA=$(curl -sf \
        -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/user-data)

      # Execute under sh — the launch_template user_data is a shell
      # script that writes /etc/portao/env. Trust comes from IMDSv2
      # being instance-local + IAM-gated (the LT user_data is set by
      # pangea, not user-controllable).
      printf '%s\n' "$USERDATA" | sh
    '';
  };

  # ── portao-init: one-shot at boot ───────────────────────────────────
  # Depends on portao-userdata so /etc/portao/env exists before this
  # unit reads it. ConditionPathExists is a defensive belt-and-suspenders
  # in case portao-userdata is masked / skipped / fails open.
  systemd.services.portao-init = {
    description = "Portao first-boot init: generate keys, claim EIP, render wg conf";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target" "portao-userdata.service"];
    requires = ["portao-userdata.service"];
    wants = ["network-online.target"];
    unitConfig.ConditionPathExists = "/etc/portao/env";
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
    unitConfig.ConditionPathExists = "/etc/portao/env";
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
    unitConfig.ConditionPathExists = "/etc/portao/env";
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
