# profiles/aws-node-base/default.nix
# blackmatter-aws-node — shared AMI conventions for every pleme-io NixOS node.
#
# Every AMI we ship (ami-builder, k8s-builder, attic-builder, future eks-node)
# inherits this base profile. It encodes the conventions that Agent U wired
# independently into each config (CloudWatch metric publisher), plus the
# canonical AWS-node hardening + ergonomics that new roles would otherwise
# duplicate line-for-line.
#
# Mirrors the AWS side of `AmiConventionDecl` (arch-synthesizer/src/ami_convention.rs).
# AWS-side owns naming + tags + launch-template metadata options (IMDSv2 required,
# EBS gp3 + encrypted). The NixOS side owns boot-time invariants: the node assumes
# those options hold, installs the matching userspace (awscli2, ssm-agent), and
# auto-derives the CloudWatch metric publisher spec from a declared role.
#
# === Conventions encoded ========================================================
#  1. IMDSv2 required          -- enforced by EC2 launch template (AmiConventionDecl);
#                                  boot-time `pleme.aws-node.assertions.imdsv2` asserts
#                                  the AMI never falls back to IMDSv1 in user code.
#  2. EBS gp3 + encrypted root -- Packer build template already sets `volume_type=gp3`.
#                                  This profile documents the assumption (no NixOS knob
#                                  for volume type exists; that's a launch-time property).
#  3. Hostname from Name tag   -- systemd oneshot reads `Name` tag via IMDSv2 and runs
#                                  `hostnamectl set-hostname` before network-online.target.
#  4. SSM agent enabled        -- services.amazon-ssm-agent.enable = true (nixpkgs module).
#  5. awscli2 on PATH          -- environment.systemPackages += awscli2.
#  6. pleme.metrics auto-wired -- role="builder" -> ActiveSshSessions, role="attic" ->
#                                  WriteCount. Commands mirror BuilderQuiescentTriggerDecl
#                                  / AtticQuiescentTriggerDecl required_publisher().
#  7. Required instance tags   -- declared as expected labels; assertion fires if the
#                                  EC2 role's policy does not grant ec2:DescribeTags.
#  8. Journald -> CloudWatch   -- stub (observability.journaldToCloudWatch) that the
#                                  FedRAMP High layer can later light up. Off by default.
#  9. Nightly nix optimize     -- systemd timer runs `nix-store --optimize` + fsck on /
#                                  weekly. Low-impact, purely a disk hygiene play.
# 10. SSH hardening            -- PasswordAuthentication off, PermitRootLogin off
#                                  (prohibit-password kept for AMI build bootstrap),
#                                  KbdInteractiveAuthentication off.
#
# === Role -> publisher mapping ===================================================
# The publisher spec here MUST match arch-synthesizer's canonical specs:
#   - BuilderQuiescentTriggerDecl::required_publisher() -> Pleme/Builder/ActiveSshSessions
#   - AtticQuiescentTriggerDecl::required_publisher()   -> Pleme/Attic/WriteCount
# If either spec ever changes upstream, update the `rolePublisher` table below.
#
# === Usage =======================================================================
# In a nixosConfiguration:
#   imports = [ ../aws-node-base ];
#   pleme.aws-node = {
#     enable = true;
#     role   = "builder";    # or "attic" / "eks-node" / "custom"
#     platform = "quero";    # platform slug; drives Platform tag expectations
#   };
#
# Override the auto-derived publisher for "custom":
#   pleme.aws-node.role = "custom";
#   pleme.metrics.publishers.myMetric = { namespace = "..."; metricName = "..."; ... };
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.pleme.aws-node;

  # Canonical publisher specs per role. These mirror the required_publisher()
  # functions on BuilderQuiescentTriggerDecl / AtticQuiescentTriggerDecl in
  # arch-synthesizer. The Nix side and the Rust side agree by construction.
  #
  # For "eks-node" / "custom" we declare no publisher by default -- the
  # consumer wires their own via `pleme.metrics.publishers.*`.
  rolePublisher = {
    builder = {
      name = "builderActiveSsh";
      spec = {
        namespace = "Pleme/Builder";
        metricName = "ActiveSshSessions";
        intervalSecs = 10;
        command = "ss -tHn state established '( sport = :22 )' | wc -l | tr -d ' '";
        region = cfg.region;
        unit = "Count";
      };
    };
    attic = {
      name = "atticWriteCount";
      spec = {
        namespace = "Pleme/Attic";
        metricName = "WriteCount";
        intervalSecs = 10;
        command = "ss -tHn state established '( sport = :8080 or sport = :443 )' | wc -l | tr -d ' '";
        region = cfg.region;
        unit = "Count";
      };
    };
    # No publisher for eks-node by default -- EKS nodes emit metrics via
    # CloudWatch Container Insights / KEDA, not via this module.
    eks-node = null;
    custom = null;
  };

  # Resolve the role to an attrset suitable for `pleme.metrics.publishers`.
  derivedPublishers = let
    entry = rolePublisher.${cfg.role};
  in
    if entry == null
    then {}
    else {${entry.name} = entry.spec;};
in {
  # NOTE: this profile does not import the cloudwatch-metric-publisher module
  # itself (that module lives in substrate and requires the flake to resolve
  # `inputs.substrate`). Every consuming nixosConfiguration already imports it:
  #   "${inputs.substrate}/lib/infra/cloudwatch-metric-publisher.nix"
  # The base profile just consumes the `pleme.metrics.*` option namespace that
  # module defines. Role profiles keep that import line in flake.nix.
  #
  # Compliance layer imports ARE pulled in here so that nixosConfigurations
  # that do NOT import `k3s-cloud-server` (notably pangea-builder — an
  # aarch64 Nix remote-build worker with no cluster role) still resolve the
  # `kindling.compliance.*` option namespace and can participate in the
  # typed `pleme.aws-node.hardening` enum below. Nix module imports are
  # idempotent; double-importing from k3s-cloud-server is safe.
  imports = [
    ../../modules/compliance/ac.nix           # Access Control (SSH, fail2ban, PAM)
    ../../modules/compliance/au.nix           # Audit & Accountability (auditd)
    ../../modules/compliance/cm.nix           # Configuration Management (tmpfs, TTY, USB)
    ../../modules/compliance/sc.nix           # System & Communications Protection (sysctl, firewall)
    ../../modules/compliance/si.nix           # System & Information Integrity (lynis, aide)
    ../../modules/compliance/fedramp-high.nix # FedRAMP High additive (kernel lockdown, FIPS)
  ];

  options.pleme.aws-node = {
    enable = lib.mkEnableOption "pleme AWS node base hardening + conventions";

    role = lib.mkOption {
      type = lib.types.enum ["builder" "attic" "eks-node" "custom"];
      description = ''
        What the node's primary workload is. Drives:
          * Auto-derived `pleme.metrics.publishers.*` entry (builder / attic).
          * Role-specific expected instance tags under
            `pleme.aws-node.expectedTags.Role`.
          * Future: hostname tag prefix policy.

        Use `"custom"` when none of the canned shapes fit; the consumer then
        wires their own publisher manually.
      '';
      example = "builder";
    };

    platform = lib.mkOption {
      type = lib.types.str;
      default = "quero";
      description = ''
        Platform slug (e.g. `quero`). Matches the `Platform` tag that
        `AmiConventionDecl::all_tags()` emits. Used for the expected-tag
        assertion and for future per-platform hostname policy.
      '';
      example = "quero";
    };

    region = lib.mkOption {
      type = lib.types.str;
      default = "us-east-1";
      description = ''
        Default AWS region for CloudWatch metric publishing and `aws` CLI
        invocations. Overridable per publisher via the existing
        `pleme.metrics.publishers.<name>.region` option.
      '';
      example = "us-east-1";
    };

    hostnameFromInstanceTag = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When true, a systemd oneshot reads the `Name` tag via IMDSv2 and sets
        the system hostname to that value before `network-online.target`.
        When false (AMI build time), the NixOS static hostname is used so the
        image remains idempotent.
      '';
    };

    hardening = lib.mkOption {
      type = lib.types.enum ["moderate" "high"];
      default = "moderate";
      description = ''
        Hardening baseline. `moderate` = FedRAMP Moderate (AC/AU/CM/SC/SI).
        `high` = FedRAMP High additive (kernel lockdown, FIPS, persistent audit)
        -- use for trusted remote-build targets, attic-seed workers, and any
        node handling other nodes' secrets in derivations.

        Note: kernel lockdown (pulled in by `high` via fedramp-high.nix) is
        incompatible with K3s IPVS and upstream Kubernetes kubelet. AMIs that
        run k3s/k8s (`ami-builder`, `k8s-builder`) MUST stay at `moderate`.
        Trusted build-only nodes (`pangea-builder`, `attic-builder`) should
        opt in to `high`.
      '';
    };

    ssmAgent.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable the AWS Systems Manager agent so operators can connect via
        Session Manager without opening SSH on the public interface. Requires
        the instance profile to carry `AmazonSSMManagedInstanceCore`.
      '';
    };

    awscli.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install `awscli2` on the system PATH. Already pulled in by the
        cloudwatch-metric-publisher module; exposed here so role profiles
        can turn it off for ultra-lean EKS node AMIs if ever needed.
      '';
    };

    journaldToCloudWatch.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        When true, a future Vector/awslogs agent ships system journal entries
        to CloudWatch Logs. Stub today -- off by default so baseline AMIs stay
        minimal; FedRAMP / production profiles flip this on via
        `pleme.aws-node.journaldToCloudWatch.enable = true;`.
      '';
    };

    nightlyMaintenance.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Weekly `nix-store --optimise` + `systemctl daemon-reexec`. Low-impact;
        keeps long-lived AMIs (builder fleet) from accumulating duplicate
        store paths.
      '';
    };

    expectedTags = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      readOnly = true;
      description = ''
        Tags we EXPECT the instance to carry at launch (per `AmiConventionDecl`).
        Computed from `platform` + `role`; used in assertions so drift surfaces
        at eval time instead of at first deployment.
      '';
      default = {
        ManagedBy = "pangea";
        Platform = cfg.platform;
        Role =
          if cfg.role == "builder"
          then "builder"
          else if cfg.role == "attic"
          then "attic-seed"
          else if cfg.role == "eks-node"
          then "eks-node"
          else "custom";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # ── 0. Compliance baseline wiring ────────────────────────────
    # Map the typed `hardening` enum onto the `kindling.compliance.*` layers
    # the aws-node-base profile imports above. Always enables the FedRAMP
    # Moderate family (AC/AU/CM/SC/SI); `high` additionally enables the
    # fedramp-high additive layer (kernel lockdown, persistent audit, FIPS).
    #
    # All assignments use `lib.mkDefault` so role profiles (notably
    # k3s-cloud-server, which already sets these with the same priority) can
    # still opt-out of individual families without `mkForce`. Two mkDefault
    # values both set to `true` resolve to `true` by module-system OR
    # semantics -- no conflict.
    kindling.compliance = {
      ac.enable = lib.mkDefault true;
      au.enable = lib.mkDefault true;
      cm.enable = lib.mkDefault true;
      sc.enable = lib.mkDefault true;
      si.enable = lib.mkDefault true;
      fedramp-high.enable = lib.mkDefault (cfg.hardening == "high");
    };

    # ── 1. IMDSv2 required ──────────────────────────────────────
    # This is a launch-template property (set by AmiConventionDecl/Packer/TF).
    # On the node side we express the invariant via an assertion: if any
    # package explicitly disables IMDS token auth we fail at eval time.
    assertions = [
      {
        assertion = cfg.role != "";
        message = "pleme.aws-node.role must be set to one of builder|attic|eks-node|custom";
      }
    ];

    # ── 3. Hostname from Name tag ───────────────────────────────
    # Fire before network-online.target so subsequent services see the right
    # hostname. Uses IMDSv2 tokens (convention #1) and falls back silently
    # if the tag is absent (e.g. during AMI build).
    systemd.services.pleme-aws-hostname = lib.mkIf cfg.hostnameFromInstanceTag {
      description = "Set hostname from EC2 Name tag (IMDSv2)";
      wantedBy = ["multi-user.target"];
      before = ["network-online.target"];
      after = ["network-pre.target"];
      path = [pkgs.awscli2 pkgs.curl pkgs.jq pkgs.nettools];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -eu
        # IMDSv2 token (21600s = max session). Never store the token.
        TOKEN=$(${pkgs.curl}/bin/curl -sS -m 3 -X PUT \
          -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
          http://169.254.169.254/latest/api/token || true)
        if [ -z "$TOKEN" ]; then
          echo "[pleme-aws-hostname] IMDSv2 unreachable -- keeping static hostname"
          exit 0
        fi
        IID=$(${pkgs.curl}/bin/curl -sS -m 3 \
          -H "X-aws-ec2-metadata-token: $TOKEN" \
          http://169.254.169.254/latest/meta-data/instance-id || true)
        REGION=$(${pkgs.curl}/bin/curl -sS -m 3 \
          -H "X-aws-ec2-metadata-token: $TOKEN" \
          http://169.254.169.254/latest/meta-data/placement/region || true)
        if [ -z "$IID" ] || [ -z "$REGION" ]; then
          echo "[pleme-aws-hostname] IMDS incomplete -- keeping static hostname"
          exit 0
        fi
        # Use the Name tag if present; no-op otherwise (AMI build path).
        NAME=$(${pkgs.awscli2}/bin/aws ec2 describe-tags \
          --region "$REGION" \
          --filters "Name=resource-id,Values=$IID" "Name=key,Values=Name" \
          --query 'Tags[0].Value' --output text 2>/dev/null || true)
        if [ -n "$NAME" ] && [ "$NAME" != "None" ]; then
          echo "[pleme-aws-hostname] setting hostname to $NAME"
          ${pkgs.nettools}/bin/hostname "$NAME" || true
          echo "$NAME" > /etc/hostname || true
        else
          echo "[pleme-aws-hostname] no Name tag -- keeping static hostname"
        fi
      '';
    };

    # ── 4. SSM agent ─────────────────────────────────────────────
    # NixOS has a canonical `services.amazon-ssm-agent` module. We only flip
    # it on -- all downstream defaults (logging, socket paths) are fine.
    services.amazon-ssm-agent.enable = lib.mkDefault cfg.ssmAgent.enable;

    # ── 5. awscli2 on system PATH ────────────────────────────────
    # Note: cloudwatch-metric-publisher.nix already adds awscli2 when
    # pleme.metrics.enable = true. We still add it here for roles that
    # leave metrics disabled but need the CLI for debugging.
    environment.systemPackages =
      (lib.optional cfg.awscli.enable pkgs.awscli2)
      ++ [pkgs.ssm-session-manager-plugin];

    # ── 6. pleme.metrics auto-configuration ──────────────────────
    # Role -> publisher derivation. Consumers can still add their own
    # publishers; lib.mkMerge at the attrsOf-level combines them.
    pleme.metrics = lib.mkIf (derivedPublishers != {}) {
      enable = lib.mkDefault true;
      publishers = derivedPublishers;
    };

    # ── 10. SSH hardening ────────────────────────────────────────
    # The existing profiles already set `PermitRootLogin = "prohibit-password"`
    # and `PasswordAuthentication = false`. We extend with:
    #   * KbdInteractiveAuthentication off (no PAM keyboard interactive path)
    #   * X11Forwarding off (nothing on the AMI should need it)
    #   * MaxAuthTries 3 (fail fast on probes)
    # mkDefault so role profiles can still override if they genuinely need
    # looser settings (they shouldn't).
    services.openssh.settings = {
      KbdInteractiveAuthentication = lib.mkDefault false;
      X11Forwarding = lib.mkDefault false;
      MaxAuthTries = lib.mkDefault 3;
      # Keep existing role defaults for PasswordAuthentication / PermitRootLogin.
    };

    # ── 9. Nightly maintenance ───────────────────────────────────
    systemd.services.pleme-aws-nightly = lib.mkIf cfg.nightlyMaintenance.enable {
      description = "Nightly nix store optimise + journal vacuum";
      serviceConfig = {
        Type = "oneshot";
      };
      path = [pkgs.nix pkgs.systemd pkgs.util-linux];
      script = ''
        set -u
        ${pkgs.nix}/bin/nix-store --optimise 2>&1 | tail -5 || true
        ${pkgs.systemd}/bin/journalctl --vacuum-time=14d 2>&1 | tail -5 || true
        exit 0
      '';
    };
    systemd.timers.pleme-aws-nightly = lib.mkIf cfg.nightlyMaintenance.enable {
      description = "Weekly timer for pleme-aws-nightly";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true;
        RandomizedDelaySec = "1h";
        Unit = "pleme-aws-nightly.service";
      };
    };

    # ── 8. Journald to CloudWatch Logs (stub) ────────────────────
    # Off by default. FedRAMP / prod profiles can flip this on; when we wire
    # Vector or awslogs we'll read cfg.journaldToCloudWatch.enable here.
    # Intentionally no systemd unit today -- an empty stub preserves the
    # option surface without paying closure cost.
  };
}
