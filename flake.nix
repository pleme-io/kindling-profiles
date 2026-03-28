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

    # Packer template — Nix-generated JSON for HashiCorp Packer AMI builds
    # Available on all systems (it's just a JSON text file)
    packages.aarch64-darwin.packer-template = let
      pkgs = import nixpkgs { system = "aarch64-darwin"; };
      template = {
        variable = {
          ami_name = { type = "string"; default = "nixos-k3s-cloud-server"; };
          region = { type = "string"; default = "us-east-1"; };
          instance_type = { type = "string"; default = "c7i.4xlarge"; };
          volume_size = { type = "number"; default = 30; };
          github_token = { type = "string"; default = ""; sensitive = true; };
          flake_ref = { type = "string"; default = "github:pleme-io/kindling-profiles#ami-builder"; };
        };
        packer = {
          required_plugins = {
            amazon = {
              version = ">= 1.3.0";
              source = "github.com/hashicorp/amazon";
            };
          };
        };
        source.amazon-ebs.nixos = {
          ami_name = "\${var.ami_name}";
          region = "\${var.region}";
          instance_type = "\${var.instance_type}";
          source_ami_filter = {
            filters = {
              name = "nixos/25.*";
              architecture = "x86_64";
              virtualization-type = "hvm";
              root-device-type = "ebs";
            };
            owners = ["427812963091"];
            most_recent = true;
          };
          ssh_username = "root";
          ssh_timeout = "10m";
          # Tuned gp3: 8K IOPS + 500 MB/s throughput (default is 3K/125)
          # Eliminates disk I/O bottleneck during nix store writes
          launch_block_device_mappings = [{
            device_name = "/dev/xvda";
            volume_size = "\${var.volume_size}";
            volume_type = "gp3";
            iops = 8000;
            throughput = 500;
            delete_on_termination = true;
          }];
          # Replace existing AMI with same name (no manual cleanup needed)
          force_deregister = true;
          force_delete_snapshot = true;
          tags = {
            Name = "\${var.ami_name}";
            ManagedBy = "ami-forge";
            BuildTimestamp = "{{timestamp}}";
            SourceFlake = "\${var.flake_ref}";
          };
          run_tags = {
            Name = "ami-forge-packer-builder";
            ManagedBy = "ami-forge";
          };
        };
        build = [{
          sources = ["source.amazon-ebs.nixos"];
          provisioner.shell = {
            inline = [
              "set -euo pipefail"
              "echo '=== configuring nix ==='"
              # NixOS /etc/nix/nix.conf is read-only (nix store). Use drop-in config.
              "mkdir -p /root/.config/nix"
              "echo 'experimental-features = nix-command flakes' >> /root/.config/nix/nix.conf"
              "echo 'max-substitution-jobs = 64' >> /root/.config/nix/nix.conf"
              "echo 'narinfo-cache-negative-ttl = 0' >> /root/.config/nix/nix.conf"
              "if [ -n \"$GITHUB_TOKEN\" ]; then echo \"access-tokens = github.com=$GITHUB_TOKEN\" >> /root/.config/nix/nix.conf; fi"
              "systemctl restart nix-daemon && sleep 2"
              "echo '=== applying NixOS configuration ==='"
              "nixos-rebuild switch --flake $FLAKE_REF"
              "echo '=== running AMI validation ==='"
              "kindling ami-test"
              "echo '=== cleanup ==='"
              "nix-collect-garbage -d"
              "rm -f /root/.config/nix/nix.conf"
              "journalctl --rotate --vacuum-time=1s 2>/dev/null || true"
              "rm -rf /tmp/* /var/tmp/* /var/log/journal/* 2>/dev/null || true"
              "fstrim / 2>/dev/null || true"
              "echo '=== complete ==='"
            ];
            environment_vars = [
              "GITHUB_TOKEN=\${var.github_token}"
              "FLAKE_REF=\${var.flake_ref}"
            ];
          };
          post-processor.manifest = {
            output = "packer-manifest.json";
            strip_path = true;
          };
        }];
      };
    in pkgs.writeText "packer-template.pkr.json" (builtins.toJSON template);

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
        }
      ];
    };

    # NixOS VM tests — validate WireGuard tunnel connectivity
    checks.x86_64-linux.vpn-test = import ./checks/vpn-test.nix {
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      lib = nixpkgs.lib;
    };

    # ── nix run apps — orchestrate AMI build + test pipeline ──
    # All apps run from aarch64-darwin (developer machine) and target x86_64 AMIs.
    apps.aarch64-darwin = let
      pkgs = import nixpkgs { system = "aarch64-darwin"; };
      forgePackage = inputs.ami-forge.packages.aarch64-darwin.default;
      template = self.packages.aarch64-darwin.packer-template;

      # Shared config
      ssmParam = "/pangea/akeyless-dev/nixos-ami-id";
      region = "us-east-1";

      mkApp = name: script: {
        type = "app";
        program = toString (pkgs.writeShellScript name ''
          set -euo pipefail
          export PATH="${pkgs.lib.makeBinPath [ forgePackage pkgs.packer pkgs.awscli2 ]}:$PATH"
          TEMPLATE="${template}"
          SSM="${ssmParam}"
          REGION="${region}"
          GITHUB_TOKEN="''${GITHUB_TOKEN:-}"
          ${script}
        '');
      };
    in {
      # Build AMI via Packer (no integration tests)
      ami-build = mkApp "ami-build" ''
        echo "=== Building AMI via Packer ==="
        ami-forge packer \
          --template "$TEMPLATE" \
          --ssm "$SSM" \
          --region "$REGION" \
          --var "github_token=$GITHUB_TOKEN"
      '';

      # Build AMI + run boot test before promoting
      ami-build-tested = mkApp "ami-build-tested" ''
        echo "=== Building AMI with boot test gate ==="
        ami-forge packer \
          --template "$TEMPLATE" \
          --ssm "$SSM" \
          --region "$REGION" \
          --var "github_token=$GITHUB_TOKEN" \
          --boot-test
      '';

      # Build AMI + run VPN connectivity test before promoting
      ami-build-vpn-tested = mkApp "ami-build-vpn-tested" ''
        echo "=== Building AMI with VPN test gate ==="
        ami-forge packer \
          --template "$TEMPLATE" \
          --ssm "$SSM" \
          --region "$REGION" \
          --var "github_token=$GITHUB_TOKEN" \
          --vpn-test
      '';

      # Build AMI + run ALL tests before promoting
      ami-build-full = mkApp "ami-build-full" ''
        echo "=== Building AMI with full test suite ==="
        ami-forge packer \
          --template "$TEMPLATE" \
          --ssm "$SSM" \
          --region "$REGION" \
          --var "github_token=$GITHUB_TOKEN" \
          --boot-test \
          --vpn-test
      '';

      # Boot-test an existing AMI by ID
      ami-boot-test = mkApp "ami-boot-test" ''
        AMI_ID="''${1:-$(aws ssm get-parameter --name "$SSM" --region "$REGION" --query 'Parameter.Value' --output text)}"
        echo "=== Boot testing AMI: $AMI_ID ==="
        ami-forge boot-test --ami-id "$AMI_ID" --region "$REGION"
      '';

      # VPN-test an existing AMI by ID
      ami-vpn-test = mkApp "ami-vpn-test" ''
        AMI_ID="''${1:-$(aws ssm get-parameter --name "$SSM" --region "$REGION" --query 'Parameter.Value' --output text)}"
        echo "=== VPN testing AMI: $AMI_ID ==="
        ami-forge vpn-test --ami-id "$AMI_ID" --region "$REGION"
      '';

      # Show current AMI status
      ami-status = mkApp "ami-status" ''
        ami-forge status --ssm "$SSM" --region "$REGION"
      '';
    };

    # Profile library — used by kindling's generated flake
    lib.profiles = {
      macos-developer = ./profiles/macos-developer;
      k3s-server = ./profiles/k3s-server;
      k3s-agent = ./profiles/k3s-agent;
      k3s-cloud-server = ./profiles/k3s-cloud-server;
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
    };
  };
}
