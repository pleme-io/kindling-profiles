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
    amiNodeIdentity = system: {
      kindling.nodeIdentity = {
        profile = "k3s-cloud-server";
        hostname = "ami-builder";
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
          role = "server";
          cluster_cidr = null;
          service_cidr = null;
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
        nodes = [
          { name = "cp"; role = "server"; cluster_init = true; vpn_address = "10.99.0.1/24"; node_index = 0; }
          { name = "system"; role = "server"; vpn_address = "10.99.0.2/24"; node_index = 1; }
          { name = "worker1"; role = "agent"; vpn_address = "10.99.0.3/24"; node_index = 2; }
          { name = "worker2"; role = "agent"; vpn_address = "10.99.0.4/24"; node_index = 3; }
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
          "nixos-rebuild switch --flake $FLAKE_REF --option access-tokens github.com=$GITHUB_TOKEN"
          "export PATH=/run/current-system/sw/bin:$PATH"
          "kindling ami-build --flake-ref $FLAKE_REF --skip-rebuild"
        ];
      };

      # Test template: boot from built AMI with test userdata.
      # kindling-init bootstraps VPN + K3s, then kindling ami-integration-test validates.
      # t3.large: K3s needs 4GB+ RAM for single-node cluster.
      test-template = amiBuild.mkTestTemplate {
        testUserData = testClusterConfig;
        instanceType = "t3.large";
      };

      # ── Attic Server Packer Templates ──────────────────────────
      # Build template: base NixOS → nixos-rebuild → kindling ami-build → snapshot
      attic-build-template = amiBuild.mkBuildTemplate {
        amiName = "nixos-attic-server";
        flakeRef = "github:pleme-io/kindling-profiles#attic-builder";
        provisionerScript = [
          "nixos-rebuild switch --flake $FLAKE_REF --option access-tokens github.com=$GITHUB_TOKEN"
          "export PATH=/run/current-system/sw/bin:$PATH"
          "kindling ami-build --flake-ref $FLAKE_REF --skip-rebuild --skip-validation"
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
        ./profiles/k3s-cloud-server
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
        ./profiles/attic-server
        (atticNodeIdentity "x86_64-linux")
        {
          # Make kindling CLI available for ami-build validation
          environment.systemPackages = [ inputs.kindling.packages.x86_64-linux.default ];
        }
      ];
    };

    # NixOS VM tests — validate WireGuard tunnel connectivity
    checks.x86_64-linux.vpn-test = import ./checks/vpn-test.nix {
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      lib = nixpkgs.lib;
    };

    # AMI pipeline apps — Packer orchestrates, ami-forge is a tool
    apps.aarch64-darwin = let
      pkgs = import nixpkgs { system = "aarch64-darwin"; };
      amiBuild = import "${inputs.substrate}/lib/infra/ami-build.nix" { inherit pkgs; };

      # K3s AMI pipeline (with 5-node cluster test)
      k3sPipeline = amiBuild.mkAmiBuildPipeline {
        forgePackage = inputs.ami-forge.packages.aarch64-darwin.default;
        buildTemplate = self.packages.aarch64-darwin.build-template;
        testTemplate = self.packages.aarch64-darwin.test-template;
        ssmParameter = "/pangea/akeyless-dev/nixos-ami-id";
        amiName = "nixos-k3s-cloud-server";
        awsProfile = "akeyless-development";
        clusterTestConfig = self.packages.aarch64-darwin.cluster-test-config;
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
    in k3sPipeline // {
      attic-ami-build = atticPipeline.ami-build;
      attic-ami-test = atticPipeline.ami-test;
      attic-ami-status = atticPipeline.ami-status;
    };

    # Profile library — used by kindling's generated flake
    lib.profiles = {
      macos-developer = ./profiles/macos-developer;
      k3s-server = ./profiles/k3s-server;
      k3s-agent = ./profiles/k3s-agent;
      k3s-cloud-server = ./profiles/k3s-cloud-server;
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
      attic-server = {
        description = "NixOS Attic binary cache server for storing Nix build artifacts with PostgreSQL and local storage";
        platform = "linux";
        components = ["attic-server" "postgresql" "firewall"];
      };
    };
  };
}
