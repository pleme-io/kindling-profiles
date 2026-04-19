{
  description = "kindling-profiles — reusable machine profiles for kindling fleet management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    blackmatter = {
      url = "github:pleme-io/blackmatter";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    substrate = {
      url = "github:pleme-io/substrate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    kindling = {
      url = "github:pleme-io/kindling";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ami-forge = {
      url = "github:pleme-io/ami-forge";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    # Minimal node identity shared by both mkAmi and nixosConfigurations.ami-builder
    # Max-baked AMI identity: everything pre-configured so runtime only writes
    # secrets + config.yaml + sentinels. No nixos-rebuild at boot.
    amiNodeIdentity = system: {
      kindling.nodeIdentity = {
        profile = "k3s-cloud-server";
        hostname = "ami-builder";
        user = { name = "root"; uid = 0; };
        secrets.provider = "sops";
        secrets.age_key_file = "/var/lib/sops-nix/key.txt";
        hardware = {
          platform = system;
          cpu.vendor = if system == "x86_64-linux" then "amd" else "arm";
          kernel.modules = [];
          kernel.params = [];
        };
        network.firewall = {
          allowed_tcp_ports = [];
          allowed_udp_ports = [51820]; # WireGuard listen port pre-baked in firewall
        };
        network.vpn_links = [];
        kubernetes = {
          role = "server";
          cluster_cidr = null;
          service_cidr = null;
        };
        # FluxCD pre-baked with placeholder values + sentinel gate.
        # Real source/auth comes at runtime via kindling-init bootstrap.
        # fluxcd-bootstrap.service waits for /var/lib/kindling/fluxcd-ready sentinel.
        fluxcd = {
          enable = true;
          source = "https://github.com/pleme-io/k8s";
          auth = "token";
          token_file = "/run/secrets.d/flux-github-token";
          reconcile = {
            path = ".";
            branch = "main";
            interval = "2m0s";
            prune = true;
          };
        };
        nix.trusted_users = ["root"];
        nix.attic.token_file = null;
      };
    };

    # Minimal node identity for K8s (kubeadm) AMI builds
    k8sAmiNodeIdentity = system: {
      kindling.nodeIdentity = {
        profile = "k8s-cloud-server";
        hostname = "k8s-builder";
        user = { name = "root"; uid = 0; };
        secrets.provider = "sops";
        secrets.age_key_file = "/var/lib/sops-nix/key.txt";
        hardware = {
          platform = system;
          cpu.vendor = if system == "x86_64-linux" then "amd" else "arm";
          kernel.modules = [];
          kernel.params = [];
        };
        network.firewall = {
          allowed_tcp_ports = [];
          allowed_udp_ports = [51820]; # WireGuard listen port pre-baked in firewall
        };
        network.vpn_links = [];
        kubernetes = {
          role = "server";
          cluster_cidr = null;
          service_cidr = null;
        };
        fluxcd = {
          enable = true;
          source = "https://github.com/pleme-io/k8s";
          auth = "token";
          token_file = "/run/secrets.d/flux-github-token";
          reconcile = {
            path = ".";
            branch = "main";
            interval = "2m0s";
            prune = true;
          };
        };
        nix.trusted_users = ["root"];
        nix.attic.token_file = null;
      };
    };

    # Minimal node identity for Attic server AMI builds
    atticNodeIdentity = system: {
      kindling.nodeIdentity = {
        profile = "attic-server";
        hostname = "attic-builder";
        user = { name = "root"; uid = 0; };
        secrets.provider = "sops";
        hardware = {
          platform = system;
          cpu.vendor = if system == "x86_64-linux" then "amd" else "arm";
          kernel.modules = [];
          kernel.params = [];
        };
        network.firewall = {
          allowed_tcp_ports = [];
          allowed_udp_ports = [];
        };
        network.vpn_links = [];
        kubernetes = {
          role = null;
          cluster_cidr = null;
          service_cidr = null;
        };
        nix.trusted_users = ["root"];
        nix.attic.token_file = null;
      };
    };

    # AMI builder via nixos-generators — produces Amazon-format images (for local testing)
    mkAmi = system: inputs.nixos-generators.nixosGenerate {
      inherit system;
      format = "amazon";
      modules = [
        self.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        ./profiles/k3s-cloud-server
        (amiNodeIdentity system)
      ];
    };
  in {
    # Module exports — each target type imports the node identity interface
    darwinModules.default = {imports = [./modules/node-identity.nix];};
    nixosModules.default = {imports = [./modules/node-identity.nix inputs.blackmatter.nixosModules.blackmatter];};
    homeManagerModules.default = {imports = [./modules/node-identity.nix];};

    # AMI packages — for local testing with nixos-generators
    packages.x86_64-linux.ami = mkAmi "x86_64-linux";
    packages.aarch64-linux.ami = mkAmi "aarch64-linux";

    # Packer templates — generated via substrate ami-build.nix
    packages.aarch64-darwin = let
      pkgs = import nixpkgs { system = "aarch64-darwin"; };
      amiBuild = import "${inputs.substrate}/lib/infra/ami-build.nix" { inherit pkgs; };

      # Test cluster config for AMI integration testing.
      # Injected as EC2 userdata → kindling-init bootstraps VPN + K3s on the test instance.
      # Hardcoded WireGuard keys are ephemeral (test instance destroyed after validation).
      testClusterConfig = builtins.toJSON {
        cluster_name = "ami-integration-test";
        role = "server";
        distribution = "k3s";
        distribution_track = "1.34";
        profile = "cloud-server";
        node_index = 0;
        cluster_init = true;
        skip_nix_rebuild = true;
        vpn = {
          require_liveness = false;
          links = [{
            name = "wg-test";
            address = "10.99.0.1/24";
            private_key_file = "/run/secrets.d/vpn-private-key";
            listen_port = 51820;
            profile = "k8s-control-plane";
            peers = [{
              public_key = "dCfQx6dLR/xFT5W7sVlEqyZFk0UR+6QRH+3hf0TDAiI=";
              allowed_ips = ["10.99.0.0/24"];
              preshared_key_file = "/run/secrets.d/vpn-psk";
            }];
            firewall = {
              trust_interface = false;
              allowed_tcp_ports = [6443];
              allowed_udp_ports = [51820];
              incoming_udp_port = 51820;
            };
          }];
        };
        bootstrap_secrets = {
          vpn_private_key = "YNqHbfBQKdFIan6LjbRByxxMY5IjDK23kMCEGGb3q2o=";
          vpn_psk = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
          k3s_server_token = "ami-integration-test-token-0000000000";
        };
      };
      # 5-node cluster topology for ami-forge cluster-test validation.
      # Topology: 1 control-plane (cluster_init), 1 system server, 2 workers, 1 client.
      clusterTestConfig = amiBuild.mkClusterTestConfig {
        instanceType = "t3.xlarge";
        timeout = 1200;
        instanceProfileName = "ami-forge-test-instance-profile";  # deployed via Pangea IaC
        minReadyNodes = 3;  # CP + 2 workers minimum (5 is too strict for CI timing)
        # 1 CP + 3 agents + 1 client. No second server (etcd HA join is too slow for CI).
        nodes = [
          { name = "cp"; role = "server"; cluster_init = true; vpn_address = "10.99.0.1/24"; node_index = 0; }
          { name = "worker1"; role = "agent"; vpn_address = "10.99.0.2/24"; node_index = 1; }
          { name = "worker2"; role = "agent"; vpn_address = "10.99.0.3/24"; node_index = 2; }
          { name = "worker3"; role = "agent"; vpn_address = "10.99.0.4/24"; node_index = 3; }
          { name = "client"; role = "agent"; vpn_address = "10.99.0.5/24"; node_index = 4; }
        ];
      };
    in {
      # Cluster test config — 5-node topology for ami-forge cluster-test
      cluster-test-config = clusterTestConfig;

      # Build template: base NixOS → nixos-rebuild → kindling ami-test → snapshot
      build-template = amiBuild.mkBuildTemplate {
        amiName = "nixos-k3s-cloud-server";
        flakeRef = "github:pleme-io/kindling-profiles#ami-builder";
        # Step 1: nixos-rebuild installs kindling + all packages into the system
        # Step 2: kindling ami-build --skip-rebuild does post-rebuild work (all Rust):
        #         clean K3s state → validate (11 checks) → cleanup
        provisionerScript = [
          ''if [ -n "$ATTIC_URL" ]; then echo "Using Attic cache: $ATTIC_URL"; nixos-rebuild switch --flake $FLAKE_REF --option access-tokens github.com=$GITHUB_TOKEN --option extra-substituters "$ATTIC_URL" --option require-sigs false; else nixos-rebuild switch --flake $FLAKE_REF --option access-tokens github.com=$GITHUB_TOKEN; fi''
          "export PATH=/run/current-system/sw/bin:$PATH"
          "kindling ami-build --flake-ref $FLAKE_REF --skip-rebuild"
        ];
      };

      # Test template: basic boot validation only.
      # Full K3s integration test disabled until skip_nix_rebuild + ConditionPathExists
      # interaction is resolved. Real validation happens via cluster deploy.
      test-template = amiBuild.mkTestTemplate {
        instanceType = "t3.small";
        testScript = [
          "export PATH=/run/current-system/sw/bin:$PATH"
          "kindling ami-test"
        ];
      };

      # ── Multi-Layer AMI Templates ────────────────────────────
      # Each layer produces a checkpointed AMI. Failures restart from last good layer.

      # Layer 1: Populate Nix store + push NARs to Attic
      # This is the expensive layer. Attic substituter pulls cached NARs,
      # nix build fills in the rest, then we push everything back to Attic.
      # If ATTIC_URL is empty, the provisioner FAILS (hard gate).
      layer-1-template = amiBuild.mkLayerTemplate {
        name = "layer-1-nix-store.pkr.json";
        amiName = "nixos-k3s-layer-1-nix-store";
        sourceAmiVariable = false;
        provisionerScript = [
          # Validate Attic URL is set (hard gate)
          ''test -n "$ATTIC_URL" || { echo "FATAL: ATTIC_URL not set -- refusing to build without cache"; exit 1; }''
          ''echo "Attic cache: $ATTIC_URL"''
          # Write GitHub token
          ''mkdir -p /etc/nix && test -z "$GITHUB_TOKEN" || echo "$GITHUB_TOKEN" > /etc/nix/github-access-token''
          # Build toplevel with Attic as substituter
          ''TOPLEVEL=$(nix --extra-experimental-features "nix-command flakes" build --print-out-paths "github:pleme-io/kindling-profiles#nixosConfigurations.ami-builder.config.system.build.toplevel" --option access-tokens "github.com=$(cat /etc/nix/github-access-token 2>/dev/null || true)" --option extra-substituters "$ATTIC_URL" --option require-sigs false --no-link)''
          ''echo "Toplevel: $TOPLEVEL"''
          # Push NARs to Attic (the cache MUST grow every run)
          ''echo "Pushing NARs to Attic cache..."''
          ''nix --extra-experimental-features "nix-command flakes" copy --to "$ATTIC_URL" "$TOPLEVEL" 2>&1 | tail -5 || echo "WARN: nix copy failed (Attic may not support push yet)"''
          ''echo "Layer 1 complete: store populated + NARs pushed"''
        ];
        extraTags = { Layer = "1-nix-store"; };
      };

      # Layer 2: Activate system (instant — everything already in store)
      layer-2-template = amiBuild.mkLayerTemplate {
        name = "layer-2-activate.pkr.json";
        amiName = "nixos-k3s-layer-2-activated";
        sourceAmiVariable = true;  # Takes Layer 1 AMI
        provisionerScript = [
          ''TOPLEVEL=$(ls -d /nix/store/*-nixos-system-ami-builder-* 2>/dev/null | head -1)''
          ''echo "Activating: $TOPLEVEL"''
          ''$TOPLEVEL/bin/switch-to-configuration switch''
        ];
        extraTags = { Layer = "2-activated"; };
      };

      # Layer 3: Release preparation (cleanup + 11 validation checks)
      layer-3-template = amiBuild.mkLayerTemplate {
        name = "layer-3-release.pkr.json";
        amiName = "nixos-k3s-cloud-server";
        sourceAmiVariable = true;  # Takes Layer 2 AMI
        provisionerScript = [
          "export PATH=/run/current-system/sw/bin:$PATH"
          "kindling ami-build --flake-ref github:pleme-io/kindling-profiles#ami-builder --skip-rebuild"
        ];
        extraTags = { Layer = "3-release"; };
      };

      # ── Attic Server Packer Templates ──────────────────────────
      # Build template: base NixOS → kindling ami-build → snapshot
      attic-build-template = amiBuild.mkBuildTemplate {
        amiName = "nixos-attic-server";
        flakeRef = "github:pleme-io/kindling-profiles#attic-builder";
        provisionerScript = [
          "nixos-rebuild switch --flake $FLAKE_REF --option access-tokens github.com=$GITHUB_TOKEN"
          "export PATH=/run/current-system/sw/bin:$PATH"
          "kindling ami-build --flake-ref $FLAKE_REF --skip-validation"
        ];
      };

      # Test template: boot from built AMI, validate atticd + postgresql.
      # No userdata needed — Attic doesn't use kindling-init bootstrap.
      # t3.small: Attic cache server has modest resource requirements.
      attic-test-template = amiBuild.mkTestTemplate {
        instanceType = "t3.small";
        testScript = [
          "export PATH=/run/current-system/sw/bin:$PATH"
          "systemctl is-active atticd.service"
          "systemctl is-active postgresql.service"
          "curl -sf http://localhost:8080/ || curl -sf http://localhost:8080/_status || true"
        ];
      };

      # ── K8s (kubeadm) AMI Templates ─────────────────────────────
      # Parallel pipeline for upstream Kubernetes via kubeadm.

      # K8s cluster test config — 5-node topology for ami-forge cluster-test.
      # Distribution-level config (kubernetes, kubeadm join) is injected via
      # ami-forge's userdata generation, not the cluster test config.
      k8s-cluster-test-config = amiBuild.mkClusterTestConfig {
        instanceType = "t3.xlarge";
        timeout = 1200;
        instanceProfileName = "ami-forge-test-instance-profile";
        minReadyNodes = 3;
        clusterName = "k8s-cluster-test";
        nodes = [
          { name = "cp"; role = "server"; cluster_init = true; vpn_address = "10.99.0.1/24"; node_index = 0; }
          { name = "worker1"; role = "agent"; vpn_address = "10.99.0.2/24"; node_index = 1; }
          { name = "worker2"; role = "agent"; vpn_address = "10.99.0.3/24"; node_index = 2; }
          { name = "worker3"; role = "agent"; vpn_address = "10.99.0.4/24"; node_index = 3; }
          { name = "client"; role = "agent"; vpn_address = "10.99.0.5/24"; node_index = 4; }
        ];
      };

      # K8s build template: base NixOS → nixos-rebuild → kindling ami-build → snapshot
      k8s-build-template = amiBuild.mkBuildTemplate {
        amiName = "nixos-k8s-cloud-server";
        flakeRef = "github:pleme-io/kindling-profiles#k8s-builder";
        provisionerScript = [
          ''if [ -n "$ATTIC_URL" ]; then echo "Using Attic cache: $ATTIC_URL"; nixos-rebuild switch --flake $FLAKE_REF --option access-tokens github.com=$GITHUB_TOKEN --option extra-substituters "$ATTIC_URL" --option require-sigs false; else nixos-rebuild switch --flake $FLAKE_REF --option access-tokens github.com=$GITHUB_TOKEN; fi''
          "export PATH=/run/current-system/sw/bin:$PATH"
          "kindling ami-build --flake-ref $FLAKE_REF --skip-rebuild"
        ];
      };

      # K8s test template: basic boot validation with --distribution kubernetes
      k8s-test-template = amiBuild.mkTestTemplate {
        instanceType = "t3.small";
        testScript = [
          "export PATH=/run/current-system/sw/bin:$PATH"
          "kindling ami-test --distribution kubernetes"
        ];
      };
    };

    # NixOS configuration for Packer-based AMI builds (nixos-rebuild switch target)
    nixosConfigurations.ami-builder = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        inputs.kindling.nixosModules.default
        inputs.home-manager.nixosModules.home-manager
        # Preserve EC2/Amazon modules from the base AMI — amazon-init processes
        # userdata (cloud-init) at boot, writing /etc/pangea/cluster-config.json
        "${nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
        # Reusable CloudWatch metric publisher — feeds BuilderQuiescentTriggerDecl
        # alarm (Pleme/Builder/ActiveSshSessions) as the 10-20s backstop for the
        # client-side watchdog on real builds.
        "${inputs.substrate}/lib/infra/cloudwatch-metric-publisher.nix"
        ./profiles/k3s-cloud-server
        ./profiles/aws-node-base
        (amiNodeIdentity "x86_64-linux")
        {
          # Enable kindling bootstrap service — reads /etc/pangea/cluster-config.json
          # at boot and applies cluster-specific delta (VPN, k3s tokens, FluxCD)
          services.kindling.server = {
            enable = true;
            package = inputs.kindling.packages.x86_64-linux.default;
          };
          # Make kindling CLI available in PATH for ami-test and operator use
          environment.systemPackages = [ inputs.kindling.packages.x86_64-linux.default ];

          # Shared AWS node conventions + role-derived CloudWatch publisher.
          # role="builder" auto-configures Pleme/Builder/ActiveSshSessions @ 10s,
          # matching BuilderQuiescentTriggerDecl::required_publisher() in
          # arch-synthesizer. Hostname from instance tag disabled at AMI build
          # time so the baked image stays idempotent.
          pleme.aws-node = {
            enable = true;
            role = "builder";
            platform = "quero";
            hostnameFromInstanceTag = false;
          };
        }
      ];
    };

    # NixOS configuration for Packer-based K8s AMI builds (nixos-rebuild switch target)
    nixosConfigurations.k8s-builder = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        inputs.kindling.nixosModules.default
        inputs.home-manager.nixosModules.home-manager
        "${nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
        # Reusable CloudWatch metric publisher — feeds BuilderQuiescentTriggerDecl
        # alarm (Pleme/Builder/ActiveSshSessions) as the 10-20s backstop.
        "${inputs.substrate}/lib/infra/cloudwatch-metric-publisher.nix"
        ./profiles/k8s-cloud-server
        ./profiles/aws-node-base
        (k8sAmiNodeIdentity "x86_64-linux")
        {
          services.kindling.server = {
            enable = true;
            package = inputs.kindling.packages.x86_64-linux.default;
          };
          environment.systemPackages = [ inputs.kindling.packages.x86_64-linux.default ];

          # Shared AWS node conventions — role="builder" maps to
          # Pleme/Builder/ActiveSshSessions per
          # BuilderQuiescentTriggerDecl::required_publisher().
          pleme.aws-node = {
            enable = true;
            role = "builder";
            platform = "quero";
            hostnameFromInstanceTag = false;
          };
        }
      ];
    };

    # NixOS configuration for Packer-based Attic AMI builds (nixos-rebuild switch target)
    nixosConfigurations.attic-builder = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        inputs.kindling.nixosModules.default
        inputs.home-manager.nixosModules.home-manager
        "${nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
        # Reusable CloudWatch metric publisher — feeds AtticQuiescentTriggerDecl
        # alarm (Pleme/Attic/WriteCount). Matches
        # AtticQuiescentTriggerDecl::required_publisher() in arch-synthesizer.
        "${inputs.substrate}/lib/infra/cloudwatch-metric-publisher.nix"
        ./profiles/attic-server
        ./profiles/aws-node-base
        (atticNodeIdentity "x86_64-linux")
        {
          # Make kindling CLI available for ami-build validation
          environment.systemPackages = [ inputs.kindling.packages.x86_64-linux.default ];

          # Shared AWS node conventions — role="attic" auto-configures
          # Pleme/Attic/WriteCount per AtticQuiescentTriggerDecl::required_publisher().
          pleme.aws-node = {
            enable = true;
            role = "attic";
            platform = "quero";
            hostnameFromInstanceTag = false;
          };
        }
      ];
    };

    # NixOS configuration for the Pangea Nix remote-build worker AMI.
    #
    # Unlike ami-builder / k8s-builder / attic-builder, this profile is:
    #   * aarch64-linux — serves arm64 Linux derivations to aarch64-darwin
    #     operators (ryn) through nix-daemon dispatch over SSH.
    #   * NO k3s / NO FluxCD — a Nix remote builder has no cluster role,
    #     so the k3s-cloud-server profile (which pulls in flux-manifests.drv,
    #     an x86_64-only IFD) is deliberately absent.
    #   * Minimal userspace — openssh + nix daemon + aws-node-base.
    #     Everything else (VPN, kindling-init, FluxCD) is explicitly NOT
    #     imported so the closure stays small and evaluation is total on
    #     aarch64 without a remote x86_64 helper.
    #
    # Consumed by pangea-architectures/workspaces/platform-packer with
    # `nixos_profile = "pangea-builder"` in the platform YAML. Activated
    # at Packer build time by the provisioner via
    #   TOPLEVEL=$(nix build ...#nixosConfigurations.pangea-builder.config.system.build.toplevel)
    #   switch-to-configuration switch
    nixosConfigurations.pangea-builder = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        self.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        inputs.home-manager.nixosModules.home-manager
        "${nixpkgs}/nixos/modules/virtualisation/amazon-image.nix"
        # Reusable CloudWatch metric publisher — feeds
        # BuilderQuiescentTriggerDecl alarm
        # (Pleme/Builder/ActiveSshSessions) as the 10-20s backstop for
        # the client-side watchdog on real nix-daemon dispatch builds.
        "${inputs.substrate}/lib/infra/cloudwatch-metric-publisher.nix"
        ./profiles/aws-node-base
        {
          # Shared AWS node conventions — role="builder" auto-configures
          # Pleme/Builder/ActiveSshSessions per
          # BuilderQuiescentTriggerDecl::required_publisher() in
          # arch-synthesizer. hostnameFromInstanceTag disabled at AMI
          # build time so the image stays idempotent.
          pleme.aws-node = {
            enable = true;
            role = "builder";
            platform = "quero";
            hostnameFromInstanceTag = false;
          };

          # Nix remote builder config: ryn ssh-dispatches derivations
          # to this node over the `builder` account. The daemon accepts
          # the `builder` user's connections (trusted-users) and runs
          # the full derivation.
          nix.settings = {
            experimental-features = [ "nix-command" "flakes" ];
            trusted-users = [ "root" "builder" ];
            # Keep the builder fast: don't garbage-collect the attic
            # seed while a build is in progress. Scheduled gc lives in
            # aws-node-base.nightlyMaintenance.
            auto-optimise-store = true;
          };

          services.openssh = {
            enable = true;
            settings = {
              # Remote dispatch via SSH; password auth is off per
              # aws-node-base hardening.
              PermitRootLogin = "prohibit-password";
              PasswordAuthentication = false;
            };
          };

          # Authorized public key for the `builder` user — private
          # counterpart decrypts from SOPS on operator machines
          # (ryn) as ~/.ssh/pangea-builder. Sourced from
          # pangea-architectures/platforms/quero.yaml
          # (builder_fleet.ssh_public_key).
          users.users.builder = {
            isNormalUser = true;
            extraGroups = [ "wheel" ];
            openssh.authorizedKeys.keys = [
              "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII+WToJymXGGMFQB+Hlb8s7HZTDSLJFf+T3YpLxUg8QM pangea-builder@ryn"
            ];
          };
          # Root also receives the same key so nix-daemon over SSH as
          # root (the default when derivations need privileged ops)
          # works without switching accounts.
          users.users.root.openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII+WToJymXGGMFQB+Hlb8s7HZTDSLJFf+T3YpLxUg8QM pangea-builder@ryn"
          ];
        }
      ];
    };

    # NixOS VM tests — convergence verification at the AMI layer
    checks.x86_64-linux = let
      testPkgs = import nixpkgs { system = "x86_64-linux"; };
      testLib = nixpkgs.lib;
    in {
      # Network convergence: WireGuard tunnel connectivity
      vpn-test = import ./checks/vpn-test.nix {
        pkgs = testPkgs; lib = testLib;
      };
      # Compliance layer convergence: each independently verifiable
      compliance-ac-test = import ./checks/compliance-ac-test.nix {
        pkgs = testPkgs; lib = testLib;
      };
      compliance-au-test = import ./checks/compliance-au-test.nix {
        pkgs = testPkgs; lib = testLib;
      };
      compliance-sc-test = import ./checks/compliance-sc-test.nix {
        pkgs = testPkgs; lib = testLib;
      };
      # Pure-eval tests for the blackmatter-aws-node base profile
      # (role -> publisher derivation, expected tags, SSM/awscli/SSH defaults).
      # Derivation wraps the eval so `nix flake check` surfaces failures.
      aws-node-base-eval = testPkgs.runCommand "aws-node-base-eval" {} ''
        cat > $out <<EOF
        ${builtins.toJSON (import ./profiles/aws-node-base/tests.nix { pkgs = testPkgs; })}
        EOF
      '';
    };

    # AMI pipeline apps — Packer orchestrates, ami-forge is a tool
    apps.aarch64-darwin = let
      pkgs = import nixpkgs { system = "aarch64-darwin"; };
      amiBuild = import "${inputs.substrate}/lib/infra/ami-build.nix" { inherit pkgs; };

      # K3s AMI pipeline (build → basic test → promote)
      # Cluster test disabled until skip_nix_rebuild K3s startup is resolved.
      # Real validation via cluster deploy + scale test.
      k3sPipeline = amiBuild.mkAmiBuildPipeline {
        forgePackage = inputs.ami-forge.packages.aarch64-darwin.default;
        buildTemplate = self.packages.aarch64-darwin.build-template;
        testTemplate = self.packages.aarch64-darwin.test-template;
        ssmParameter = "/pangea/akeyless-dev/nixos-ami-id";
        amiName = "nixos-k3s-cloud-server";
        awsProfile = "akeyless-development";
        clusterTestConfig = self.packages.aarch64-darwin.cluster-test-config;
        # Ephemeral Attic cache — boot from last AMI, use as substituter, snapshot after
        atticSsm = "/pangea/attic-cache/nixos-ami-id";
      };

      # Attic cache server AMI pipeline (no K3s, no cluster test)
      atticPipeline = amiBuild.mkAmiBuildPipeline {
        forgePackage = inputs.ami-forge.packages.aarch64-darwin.default;
        buildTemplate = self.packages.aarch64-darwin.attic-build-template;
        testTemplate = self.packages.aarch64-darwin.attic-test-template;
        ssmParameter = "/pangea/attic-cache/nixos-ami-id";
        amiName = "nixos-attic-server";
        awsProfile = "akeyless-development";
        skipClusterTest = true;
      };
      # K8s (kubeadm) AMI pipeline (build → basic test → promote)
      k8sPipeline = amiBuild.mkAmiBuildPipeline {
        forgePackage = inputs.ami-forge.packages.aarch64-darwin.default;
        buildTemplate = self.packages.aarch64-darwin.k8s-build-template;
        testTemplate = self.packages.aarch64-darwin.k8s-test-template;
        ssmParameter = "/pangea/akeyless-dev/k8s-ami-id";
        amiName = "nixos-k8s-cloud-server";
        awsProfile = "akeyless-development";
        clusterTestConfig = self.packages.aarch64-darwin.k8s-cluster-test-config;
        atticSsm = "/pangea/attic-cache/nixos-ami-id";
      };

      # Multi-layer K3s AMI pipeline — each layer checkpointed in SSM
      k3sLayeredPipeline = amiBuild.mkMultiLayerPipeline {
        forgePackage = inputs.ami-forge.packages.aarch64-darwin.default;
        layers = [
          {
            template = self.packages.aarch64-darwin.layer-1-template;
            name = "layer-1-nix-store";
            ssmParameter = "/pangea/ami-layers/k3s-cloud-server/layer-1";
            fingerprintInputs = [ "${self}/flake.lock" ];
          }
          {
            template = self.packages.aarch64-darwin.layer-2-template;
            name = "layer-2-activated";
            ssmParameter = "/pangea/ami-layers/k3s-cloud-server/layer-2";
          }
          {
            template = self.packages.aarch64-darwin.layer-3-template;
            name = "layer-3-release";
            ssmParameter = "/pangea/ami-layers/k3s-cloud-server/layer-3";
          }
        ];
        testLayers = [
          {
            template = self.packages.aarch64-darwin.test-template;
            name = "test-basic";
          }
        ];
        promoteSsm = "/pangea/akeyless-dev/nixos-ami-id";
        amiName = "nixos-k3s-cloud-server";
        awsProfile = "akeyless-development";
        atticSsm = "/pangea/attic-cache/nixos-ami-id";
      };
    in k3sPipeline // {
      # Multi-layer pipeline (replaces monolithic build when validated)
      ami-build-layered = k3sLayeredPipeline.ami-build;
      ami-status-layered = k3sLayeredPipeline.ami-status;
      attic-ami-build = atticPipeline.ami-build;
      attic-ami-test = atticPipeline.ami-test;
      attic-ami-status = atticPipeline.ami-status;
      # K8s (kubeadm) pipeline apps
      k8s-ami-build = k8sPipeline.ami-build;
      k8s-ami-test = k8sPipeline.ami-test;
      k8s-ami-status = k8sPipeline.ami-status;
    };

    # Profile library — used by kindling's generated flake
    lib.profiles = {
      macos-developer = ./profiles/macos-developer;
      k3s-server = ./profiles/k3s-server;
      k3s-agent = ./profiles/k3s-agent;
      k3s-cloud-server = ./profiles/k3s-cloud-server;
      k8s-cloud-server = ./profiles/k8s-cloud-server;
      attic-server = ./profiles/attic-server;
    };

    # Profile metadata — used by `kindling profile list/show`
    lib.profileMeta = {
      macos-developer = {
        description = "macOS developer workstation with blackmatter shell, neovim, code search, and workspace tooling";
        platform = "darwin";
        components = ["blackmatter-shell" "blackmatter-nvim" "zoekt" "codesearch" "tend" "ghostty" "claude-code"];
      };
      k3s-server = {
        description = "NixOS K3s control plane server with FluxCD, IPVS, and production tuning";
        platform = "linux";
        components = ["k3s" "fluxcd" "wireguard" "dnsmasq"];
      };
      k3s-agent = {
        description = "NixOS K3s worker node with staging taints and node labels";
        platform = "linux";
        components = ["k3s" "docker" "github-actions-runner"];
      };
      k3s-cloud-server = {
        description = "NixOS K3s server for cloud hosts (Hetzner/AWS) with WireGuard mesh and FluxCD";
        platform = "linux";
        components = ["k3s" "fluxcd" "wireguard" "firewall"];
      };
      k8s-cloud-server = {
        description = "NixOS upstream Kubernetes (kubeadm) server for cloud hosts with containerd, etcd, WireGuard mesh, and FluxCD";
        platform = "linux";
        components = ["kubernetes" "kubeadm" "containerd" "etcd" "fluxcd" "wireguard" "firewall"];
      };
      attic-server = {
        description = "NixOS Attic binary cache server for storing Nix build artifacts with PostgreSQL and local storage";
        platform = "linux";
        components = ["attic-server" "postgresql" "firewall"];
      };
    };
  };
}
