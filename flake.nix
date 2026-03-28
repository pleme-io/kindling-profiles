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

    # Packer templates — generated via substrate ami-build.nix
    packages.aarch64-darwin = let
      pkgs = import nixpkgs { system = "aarch64-darwin"; };
      amiBuild = import "${inputs.substrate}/lib/infra/ami-build.nix" { inherit pkgs; };
    in {
      # Build template: base NixOS → nixos-rebuild → kindling ami-test → snapshot
      build-template = amiBuild.mkBuildTemplate {
        amiName = "nixos-k3s-cloud-server";
        flakeRef = "github:pleme-io/kindling-profiles#ami-builder";
        provisionerScript = [
          "set -euo pipefail"
          "echo '=== configuring nix ==='"
          # Write to BOTH user and system nix config — daemon reads /etc/nix/nix.conf
          "mkdir -p /root/.config/nix /etc/nix"
          "for CONF in /root/.config/nix/nix.conf /etc/nix/nix.conf; do echo 'experimental-features = nix-command flakes' >> $CONF; echo 'max-substitution-jobs = 64' >> $CONF; echo 'narinfo-cache-negative-ttl = 0' >> $CONF; if [ -n \"$GITHUB_TOKEN\" ]; then echo \"access-tokens = github.com=$GITHUB_TOKEN\" >> $CONF; fi; done"
          "systemctl restart nix-daemon && sleep 2"
          "echo '=== applying NixOS configuration ==='"
          "nixos-rebuild switch --flake $FLAKE_REF"
          "echo"
          "export PATH=/run/current-system/sw/bin:$PATH"
          "hash -r"
          "echo '=== running AMI validation ==='"
          "/run/current-system/sw/bin/kindling ami-test"
          "echo '=== cleanup ==='"
          "nix-collect-garbage -d"
          "rm -f /root/.config/nix/nix.conf /etc/nix/nix.conf"
          "rm -f /root/.ssh/authorized_keys"
          "journalctl --rotate --vacuum-time=1s 2>/dev/null || true"
          "rm -rf /tmp/* /var/tmp/* /var/log/journal/* 2>/dev/null || true"
          "fstrim / 2>/dev/null || true"
          "echo '=== complete ==='"
        ];
      };

      # Test template: boot from built AMI, verify binaries + services
      test-template = amiBuild.mkTestTemplate {};
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

    # NixOS VM tests — validate WireGuard tunnel connectivity
    checks.x86_64-linux.vpn-test = import ./checks/vpn-test.nix {
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      lib = nixpkgs.lib;
    };

    # AMI pipeline apps — Packer orchestrates, ami-forge is a tool
    apps.aarch64-darwin = let
      pkgs = import nixpkgs { system = "aarch64-darwin"; };
      amiBuild = import "${inputs.substrate}/lib/infra/ami-build.nix" { inherit pkgs; };
    in amiBuild.mkAmiBuildPipeline {
      forgePackage = inputs.ami-forge.packages.aarch64-darwin.default;
      buildTemplate = self.packages.aarch64-darwin.build-template;
      testTemplate = self.packages.aarch64-darwin.test-template;
      ssmParameter = "/pangea/akeyless-dev/nixos-ami-id";
      amiName = "nixos-k3s-cloud-server";
      awsProfile = "akeyless-development";
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
