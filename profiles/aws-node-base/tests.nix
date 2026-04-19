# profiles/aws-node-base/tests.nix
# Pure-evaluation tests for the blackmatter-aws-node base profile.
#
# Run with:
#   nix eval --impure --expr 'import ./profiles/aws-node-base/tests.nix { pkgs = import <nixpkgs> {}; }'
# or via the flake check: `nix flake check` (picks up `checks.*.aws-node-base-eval`).
#
# These are pure module-system evaluations -- no derivations, no builds. They
# assert that:
#   * role="builder"  => pleme.metrics.publishers.builderActiveSsh.namespace == "Pleme/Builder"
#   * role="attic"    => pleme.metrics.publishers.atticWriteCount.namespace  == "Pleme/Attic"
#   * role="eks-node" => no auto-derived publisher; user can add their own
#   * role="custom"   => no auto-derived publisher; user can add their own
#   * Expected tags include ManagedBy=pangea + Platform + Role
#   * SSM agent + awscli + nightly maintenance all default to enabled
#   * Hostname-from-tag is opt-out via the option
{pkgs ? import <nixpkgs> {}}: let
  inherit (pkgs) lib;

  # Load the cloudwatch-metric-publisher module as a dependency -- we use
  # the path relative to nixos-25.11's nixpkgs because that's what all
  # consumers pin. The option namespace is the same as substrate's module.
  cloudwatchModule = ../../../substrate/lib/infra/cloudwatch-metric-publisher.nix;

  # The cloudwatch module may not be on-disk during `nix flake check`.
  # Build a minimal in-tree stub defining just the option schema, so the
  # aws-node-base module has something to consume. Tests run against the
  # derived values, not against the actual systemd unit rendering.
  cloudwatchStub = {
    lib,
    config,
    ...
  }: {
    options.pleme.metrics = {
      enable = lib.mkEnableOption "cloudwatch metrics";
      useCordel = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      publishers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            namespace = lib.mkOption {type = lib.types.str;};
            metricName = lib.mkOption {type = lib.types.str;};
            intervalSecs = lib.mkOption {
              type = lib.types.ints.positive;
              default = 10;
            };
            command = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            typedSource = lib.mkOption {
              type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
              default = null;
            };
            region = lib.mkOption {
              type = lib.types.str;
              default = "us-east-1";
            };
            unit = lib.mkOption {
              type = lib.types.str;
              default = "Count";
            };
            dimensions = lib.mkOption {
              type = lib.types.attrsOf lib.types.str;
              default = {};
            };
          };
        });
        default = {};
      };
    };
  };

  # Evaluate a minimal nixosSystem-shaped module tree using lib.evalModules.
  # We only need the option surface the aws-node-base module touches; we do
  # NOT evaluate systemd units or services.openssh (those require the full
  # nixos module set). We stub those with freeform attrs.
  evalAwsNode = {
    role,
    extraConfig ? {},
  }: let
    result = lib.evalModules {
      modules = [
        cloudwatchStub
        ./default.nix
        # Stub out the nixos-level options the base profile touches so they
        # don't require the full nixos evaluator.
        ({
          lib,
          config,
          ...
        }: {
          options = {
            assertions = lib.mkOption {
              type = lib.types.listOf lib.types.unspecified;
              default = [];
            };
            environment.systemPackages = lib.mkOption {
              type = lib.types.listOf lib.types.unspecified;
              default = [];
            };
            services.amazon-ssm-agent.enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            services.openssh.settings = lib.mkOption {
              type = lib.types.attrsOf lib.types.unspecified;
              default = {};
            };
            systemd.services = lib.mkOption {
              type = lib.types.attrsOf lib.types.unspecified;
              default = {};
            };
            systemd.timers = lib.mkOption {
              type = lib.types.attrsOf lib.types.unspecified;
              default = {};
            };
          };
          # Provide pkgs to the module via _module.args.
          config._module.args = {inherit pkgs;};
        })
        {
          pleme.aws-node = {
            enable = true;
            inherit role;
            platform = "quero";
          };
        }
        extraConfig
      ];
    };
  in
    result.config;

  builder = evalAwsNode {role = "builder";};
  attic = evalAwsNode {role = "attic";};
  eksNode = evalAwsNode {role = "eks-node";};
  custom = evalAwsNode {
    role = "custom";
    extraConfig = {
      pleme.metrics.publishers.myCustom = {
        namespace = "Pleme/Custom";
        metricName = "Whatever";
        command = "echo 1";
      };
    };
  };

  # Build a list of { name, pass } entries, then fold into a single attrset
  # reporting the outcome. Any failure prints the offending test.
  checks = [
    {
      name = "builder-role-namespace";
      pass = builder.pleme.metrics.publishers.builderActiveSsh.namespace == "Pleme/Builder";
    }
    {
      name = "builder-role-metric-name";
      pass = builder.pleme.metrics.publishers.builderActiveSsh.metricName == "ActiveSshSessions";
    }
    {
      name = "builder-role-interval-10s";
      pass = builder.pleme.metrics.publishers.builderActiveSsh.intervalSecs == 10;
    }
    {
      name = "builder-role-command-ss-port-22";
      pass =
        builder.pleme.metrics.publishers.builderActiveSsh.command
        == "ss -tHn state established '( sport = :22 )' | wc -l | tr -d ' '";
    }
    {
      name = "builder-role-region-default";
      pass = builder.pleme.metrics.publishers.builderActiveSsh.region == "us-east-1";
    }
    {
      name = "attic-role-namespace";
      pass = attic.pleme.metrics.publishers.atticWriteCount.namespace == "Pleme/Attic";
    }
    {
      name = "attic-role-metric-name";
      pass = attic.pleme.metrics.publishers.atticWriteCount.metricName == "WriteCount";
    }
    {
      name = "attic-role-command-ss-ports-8080-443";
      pass =
        attic.pleme.metrics.publishers.atticWriteCount.command
        == "ss -tHn state established '( sport = :8080 or sport = :443 )' | wc -l | tr -d ' '";
    }
    {
      name = "eks-node-has-no-auto-publisher";
      pass = eksNode.pleme.metrics.publishers == {};
    }
    {
      name = "custom-role-preserves-user-publisher";
      pass = custom.pleme.metrics.publishers.myCustom.namespace == "Pleme/Custom";
    }
    {
      name = "custom-role-no-auto-publishers";
      # Only the user-provided one should be present.
      pass = builtins.attrNames custom.pleme.metrics.publishers == ["myCustom"];
    }
    {
      name = "expected-tags-managed-by-pangea";
      pass = builder.pleme.aws-node.expectedTags.ManagedBy == "pangea";
    }
    {
      name = "expected-tags-platform-quero";
      pass = builder.pleme.aws-node.expectedTags.Platform == "quero";
    }
    {
      name = "expected-tags-role-builder";
      pass = builder.pleme.aws-node.expectedTags.Role == "builder";
    }
    {
      name = "expected-tags-role-attic-seed";
      pass = attic.pleme.aws-node.expectedTags.Role == "attic-seed";
    }
    {
      name = "expected-tags-role-eks-node";
      pass = eksNode.pleme.aws-node.expectedTags.Role == "eks-node";
    }
    {
      name = "ssm-agent-enabled-by-default";
      pass = builder.services.amazon-ssm-agent.enable == true;
    }
    {
      name = "awscli-in-system-packages";
      pass =
        builtins.any
        (p: p == pkgs.awscli2)
        builder.environment.systemPackages;
    }
    {
      name = "ssm-session-manager-plugin-in-system-packages";
      pass =
        builtins.any
        (p: p == pkgs.ssm-session-manager-plugin)
        builder.environment.systemPackages;
    }
    {
      name = "nightly-maintenance-timer-exists";
      pass = builder.systemd.timers ? pleme-aws-nightly;
    }
    {
      name = "hostname-service-exists-when-enabled";
      pass = builder.systemd.services ? pleme-aws-hostname;
    }
    {
      name = "hostname-service-absent-when-disabled";
      pass = let
        disabled = evalAwsNode {
          role = "builder";
          extraConfig = {pleme.aws-node.hostnameFromInstanceTag = false;};
        };
      in
        !(disabled.systemd.services ? pleme-aws-hostname);
    }
    {
      name = "ssh-kbd-interactive-off";
      pass = builder.services.openssh.settings.KbdInteractiveAuthentication == false;
    }
    {
      name = "ssh-x11-forwarding-off";
      pass = builder.services.openssh.settings.X11Forwarding == false;
    }
    {
      name = "ssh-max-auth-tries-3";
      pass = builder.services.openssh.settings.MaxAuthTries == 3;
    }
  ];

  failures = builtins.filter (c: !c.pass) checks;

  summary = {
    total = builtins.length checks;
    passed = builtins.length checks - builtins.length failures;
    failed = builtins.length failures;
    failing = map (c: c.name) failures;
  };
in
  # If any check failed, throw so `nix eval` returns non-zero and the output
  # makes the failure list visible. Success prints the summary.
  if failures == []
  then summary
  else
    throw ''
      aws-node-base tests failed: ${toString summary.failed}/${toString summary.total}
      Failing: ${lib.concatStringsSep ", " summary.failing}
    ''
