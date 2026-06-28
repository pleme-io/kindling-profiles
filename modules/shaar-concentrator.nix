# modules/shaar-concentrator.nix
#
# pleme.nixos.shaarConcentrator — the typed node-OS surface for the Shaar
# (akeyless-vpn) WireGuard concentrator: the SERVER end of a Shaar link that
# operator workstations dial. Sibling of the portao concentrator, but built as
# a clean, reusable, enable-gated typed module rather than an always-on profile
# body, so a future cluster/AMI can compose it the same way `pleme.aws-node`
# composes.
#
# What this module owns (the node-OS half — "the binary owns the logic"):
#   * IPv4 forwarding (the hub routes pool → target networks).
#   * The `tun` kernel module (gotatun opens a real OS TUN device).
#   * A declarative nftables ruleset:
#       - a srcnat/POSTROUTING MASQUERADE so the client pool (10.99.0.0/24)
#         reaches the target network (10.0.0.0/16) via the EC2's egress iface
#         — the hub rewrites src to its own VPC IP, so no VPC route-table entry
#         for the pool CIDR is needed;
#       - a DEFAULT-DENY forward filter scaffold (the data-plane half of M4):
#         only the pool may reach the granted target CIDRs; everything else
#         forwarded is dropped. The MVP installs ONE coarse allow
#         (pool → target); per-/32 client grants (only a client's /32 may reach
#         the CIDRs its lease granted) are written by the concentrator binary
#         later — see the design note on `forward` below.
#   * A root systemd service running the `shaar-concentrator` binary from the
#     akeyless-vpn flake (`--config <store-path>`), with the persisted identity
#     dir, network ordering, and RequiresMountsFor on the state dir.
#   * Host firewall openings: the WireGuard UDP listen port + the /sync webhook
#     TCP port.
#
# What this module does NOT own (out of scope — the cloud-init / Pangea layer):
#   * Per-instance `public_endpoint` resolution. The lease embeds the hub's
#     public `ip:port`, which is not known at AMI bake time and which the
#     binary's `validate()` requires to be an `ip:port` SocketAddr (NOT a
#     hostname). Set `publicEndpoint` to the allocated EIP `ip:port` when it is
#     known at eval time, or point `configFile` at a path a first-boot resolver
#     (a portao-userdata sibling owned by the cloud-init layer) renders. When
#     neither is set, the static config is still rendered and the service
#     fail-fasts on the missing field — surfaced via `config.warnings`, never
#     silently wrong.
#
# TYPED EMISSION: the YAML config is emitted by `pkgs.formats.yaml` from a typed
# Nix attrset (no `format!()`, no hand-written YAML). The nftables ruleset is
# composed from typed option values via `lib.concatMapStringsSep` into
# `networking.nftables.tables.<name>.content` — the nixpkgs nftables idiom (there
# is no typed nftables AST in nixpkgs; this is the substrate idiom for nft, not a
# shell script and not a `format!()` of foreign syntax).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.pleme.nixos.shaarConcentrator;

  # Typed YAML serializer — the config border the binary parses
  # (deny_unknown_fields, fail-fast). One key per ConcentratorConfig field.
  settingsFormat = pkgs.formats.yaml {};

  webhookBind = "${cfg.webhookListenAddress}:${toString cfg.webhookPort}";

  renderedConfig =
    {
      pool_cidr = cfg.poolCidr;
      listen_port = cfg.listenPort;
      target_cidrs = cfg.targetCidrs;
      state_dir = cfg.stateDir;
      webhook_bind = webhookBind;
      # MVP: the shared bearer the akeyless gateway sends, read from an env var
      # the systemd `EnvironmentFile` provides (never inline — TYPED EMISSION /
      # zero-plaintext). Real per-request producer-credential validation is M4.
      webhook_creds = {
        kind = "env";
        var = cfg.webhookCredsVar;
      };
      lease_ttl_secs = cfg.leaseTtlSecs;
      gc_interval_secs = cfg.gcIntervalSecs;
      tunnel_name = cfg.tunnelName;
    }
    // lib.optionalAttrs (cfg.publicEndpoint != null) {public_endpoint = cfg.publicEndpoint;}
    // lib.optionalAttrs (cfg.presharedKey != null) {preshared_key = cfg.presharedKey;}
    // lib.optionalAttrs (cfg.keepalive != null) {keepalive = cfg.keepalive;}
    // cfg.extraConfig;

  renderedConfigFile = settingsFormat.generate "shaar-concentrator.yaml" renderedConfig;

  # The config the service actually loads: a first-boot-rendered file if
  # `configFile` is set, otherwise the Nix-rendered static config.
  effectiveConfig =
    if cfg.configFile != null
    then cfg.configFile
    else renderedConfigFile;

  # ── nftables ruleset (family ip — pool + target are IPv4) ──────────────
  # MASQUERADE: rewrite pool-sourced packets bound for a target CIDR to the
  # hub's egress IP. `oifname` is added only when `targetInterface` is set;
  # otherwise the match is purely saddr/daddr and routing picks the egress
  # (robust across EC2 `eth0` / `ens5` naming).
  oifMatch = lib.optionalString (cfg.targetInterface != null) ''oifname "${cfg.targetInterface}" '';

  masqueradeRules =
    lib.concatMapStringsSep "\n"
    (t: "    ip saddr ${cfg.poolCidr} ip daddr ${t} ${oifMatch}masquerade")
    cfg.targetCidrs;

  # DEFAULT-DENY forward filter (the data-plane reach scaffold). policy drop;
  # established/related return traffic always allowed; the pool may open new
  # flows only to the granted target CIDRs. Per-/32 client grants land here
  # later as `ip saddr <client/32> ip daddr <granted> accept` rules emitted by
  # the concentrator — for the MVP this coarse pool → target allow is the whole
  # grant the binary advertises.
  forwardAllowRules =
    lib.concatMapStringsSep "\n"
    (t: "    ip saddr ${cfg.poolCidr} ip daddr ${t} accept")
    cfg.targetCidrs;

  nftablesContent = ''
    chain postrouting {
      type nat hook postrouting priority srcnat; policy accept;
    ${masqueradeRules}
    }

    chain forward {
      type filter hook forward priority filter; policy drop;
      ct state established,related accept
    ${forwardAllowRules}
    }
  '';
in {
  options.pleme.nixos.shaarConcentrator = {
    enable = lib.mkEnableOption "the Shaar (akeyless-vpn) WireGuard concentrator node-OS";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      # `pkgs.shaar-concentrator or null` — safe access: evaluates to null when
      # the akeyless-vpn overlay/package isn't applied (e.g. a bare parse-check),
      # so this module evaluates standalone. The AMI builder sets it from
      # `inputs.akeyless-vpn.packages.<system>.shaar-concentrator` (or via the
      # akeyless-vpn overlay that defines `pkgs.shaar-concentrator`).
      default = pkgs.shaar-concentrator or null;
      defaultText = lib.literalExpression "pkgs.shaar-concentrator or null";
      description = ''
        The `shaar-concentrator` package from the akeyless-vpn flake. Must be
        non-null when the module is enabled (asserted).
      '';
    };

    poolCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.99.0.0/24";
      description = ''
        The `/32` client address pool. The first usable host (`.1`) becomes the
        concentrator's own interface address.
      '';
    };

    targetCidrs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["10.0.0.0/16"];
      description = ''
        The networks the concentrator routes the pool to (the server-owned
        grant). One MASQUERADE + one forward-allow rule is emitted per entry.
        At least one entry required.
      '';
    };

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51822;
      description = "The server-mode WireGuard UDP port clients dial (opened on the host firewall).";
    };

    webhookPort = lib.mkOption {
      type = lib.types.port;
      default = 8200;
      description = "The TCP port the /sync webhook binds (opened on the host firewall).";
    };

    webhookListenAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      example = "10.0.1.20";
      description = ''
        The address the /sync webhook binds. Defaults to all interfaces; the host
        firewall restricts who can reach `webhookPort`. Set to the node's private
        VPC address to bind the webhook to the private addr explicitly.
      '';
    };

    publicEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "203.0.113.10:51822";
      description = ''
        The public `ip:port` embedded in every lease (clients dial it). MUST be an
        `ip:port` SocketAddr — the binary's `validate()` rejects a hostname. This
        is a per-instance value usually unknown at AMI bake time; set it when the
        EIP is known at eval time, or leave null and have a first-boot resolver
        render `configFile` (see the module header). When null and `configFile` is
        null, the service fail-fasts on the missing field (surfaced via warnings).
      '';
    };

    targetInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "eth0";
      description = ''
        The target-facing egress interface for the MASQUERADE rule. When set, adds
        an `oifname` match; when null (default), the rule matches purely on
        saddr/daddr and routing selects the egress (robust across EC2 `eth0` /
        `ens5` naming).
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/shaar-concentrator";
      description = ''
        The persisted identity dir (home of `identity.key`, kept `0700`). The
        concentrator's public key rides every lease, so it must survive restarts.
      '';
    };

    tunnelName = lib.mkOption {
      type = lib.types.str;
      default = "shaar";
      description = "The base WireGuard tunnel name (logical engine iface = `wg-<name[..12]>`).";
    };

    leaseTtlSecs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3600;
      description = "The lease TTL admitted clients get (drives the pool deadline + GC).";
    };

    gcIntervalSecs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "The GC sweep interval that revokes stale clients (>= 1s).";
    };

    presharedKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "An optional pre-shared key issued on every lease (defense in depth).";
    };

    keepalive = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "An optional persistent-keepalive interval (seconds) issued on every lease.";
    };

    webhookCredsVar = lib.mkOption {
      type = lib.types.str;
      default = "SHAAR_CONCENTRATOR_CREDS";
      description = ''
        The env var the binary reads the shared webhook bearer from. Provide its
        value via `credentialsFile` (a systemd EnvironmentFile). Never inline.
      '';
    };

    credentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/shaar-concentrator-creds";
      description = ''
        A systemd `EnvironmentFile` defining `<webhookCredsVar>=<bearer>` (e.g. a
        sops-nix-decrypted path). Loaded into the service environment so the bearer
        never lands in the Nix store.
      '';
    };

    configFile = lib.mkOption {
      # A path ON THE TARGET (e.g. a `/run/...` file a first-boot resolver
      # renders), not a build input — `str`, not `path`, so eval never tries to
      # copy a runtime path into the store.
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/shaar-concentrator/config.yaml";
      description = ''
        Override the Nix-rendered config with an explicit target path (e.g. one a
        first-boot resolver renders with the per-instance `public_endpoint`). When
        null, the module renders the config from the typed options above.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the WireGuard UDP listen port + the /sync webhook TCP port on the host firewall.";
    };

    extraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Extra keys merged into the rendered concentrator config (escape hatch).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = ''
          pleme.nixos.shaarConcentrator.package is null. Provide the
          shaar-concentrator package — apply the akeyless-vpn overlay (so
          `pkgs.shaar-concentrator` exists) or set the option to
          `inputs.akeyless-vpn.packages.<system>.shaar-concentrator`.
        '';
      }
      {
        assertion = cfg.targetCidrs != [];
        message = "pleme.nixos.shaarConcentrator.targetCidrs must have at least one CIDR (the server-owned grant).";
      }
    ];

    # The public_endpoint hole is named, never silent: warn (don't hard-fail
    # eval) when no endpoint is available so the profile stays importable but the
    # operator sees the gap.
    warnings = lib.optional (cfg.configFile == null && cfg.publicEndpoint == null) ''
      pleme.nixos.shaarConcentrator: neither `publicEndpoint` nor `configFile` is
      set, so the rendered config omits the required `public_endpoint` field. The
      shaar-concentrator service will fail-fast at startup until a first-boot
      resolver renders `configFile` with the instance's EIP ip:port.
    '';

    # ── Forwarding + tun device ─────────────────────────────────────────
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv4.conf.all.forwarding" = 1;
    };
    boot.kernelModules = ["tun"];

    # ── nftables: MASQUERADE + DEFAULT-DENY forward reach filter ─────────
    networking.nftables.enable = true;
    networking.nftables.tables.shaar = {
      family = "ip";
      content = nftablesContent;
    };

    # ── Host firewall ───────────────────────────────────────────────────
    # `filterForward = false` (default): no competing firewall forward chain, so
    # this module's policy-drop `forward` chain is the sole forward gate.
    # `openFirewall`: append the WireGuard UDP listen port + the /sync webhook TCP
    # port (allowedUDPPorts / allowedTCPPorts merge across modules).
    networking.firewall =
      {
        filterForward = lib.mkDefault false;
      }
      // lib.optionalAttrs cfg.openFirewall {
        allowedUDPPorts = [cfg.listenPort];
        allowedTCPPorts = [cfg.webhookPort];
      };

    # ── The concentrator service (root: opens tun, sets routes via `ip`) ─
    systemd.services.shaar-concentrator = {
      description = "Shaar (akeyless-vpn) WireGuard concentrator — server tunnel + /sync webhook";
      wantedBy = ["multi-user.target"];
      # After network + the nft rules so NAT/forward are in place before serving.
      after = ["network-online.target" "nftables.service"];
      wants = ["network-online.target"];
      # gotatun's engine drives the OS TUN device via `ip addr/link/route`
      # (iproute2). Pinned here so a missing binary fails at NixOS evaluation,
      # not silently at runtime.
      path = with pkgs; [iproute2];
      unitConfig.RequiresMountsFor = [cfg.stateDir];
      serviceConfig =
        {
          Type = "exec";
          ExecStart = "${cfg.package}/bin/shaar-concentrator --config ${effectiveConfig}";
          # Root: create_tunnel opens a utun and configures addressing/routes.
          User = "root";
          Restart = "on-failure";
          RestartSec = "5s";
          StandardOutput = "journal";
          StandardError = "journal";
        }
        // lib.optionalAttrs (cfg.credentialsFile != null) {
          EnvironmentFile = cfg.credentialsFile;
        };
    };

    # The persisted identity dir, 0700 (the identity loader rejects unsafe perms).
    systemd.tmpfiles.rules = ["d ${cfg.stateDir} 0700 root root -"];
  };
}
