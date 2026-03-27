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
    # AMI builder via nixos-generators — produces Amazon-format images
    mkAmi = system: inputs.nixos-generators.nixosGenerate {
      inherit system;
      format = "amazon";
      modules = [
        self.nixosModules.default
        inputs.sops-nix.nixosModules.sops
        ./profiles/k3s-cloud-server
        # Increase disk image size — default is too small for the NixOS closure
        # with k3s + blackmatter modules (~5GB). Also force diskSize to avoid
        # "No space left on device" during install-to-disk phase.
        {
          virtualisation.diskSize = 8192; # 8GB
        }
        {
          # Minimal node identity for AMI build (overridden at boot by kindling)
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
        }
      ];
    };
  in {
    # Module exports — each target type imports the node identity interface
    darwinModules.default = {imports = [./modules/node-identity.nix];};
    nixosModules.default = {imports = [./modules/node-identity.nix inputs.blackmatter.nixosModules.blackmatter];};
    homeManagerModules.default = {imports = [./modules/node-identity.nix];};

    # AMI packages — built by CodeBuild for EC2 import-image
    packages.x86_64-linux.ami = mkAmi "x86_64-linux";
    packages.aarch64-linux.ami = mkAmi "aarch64-linux";

    # Nix-builder OCI images — used by CI/CD to build AMIs
    packages.x86_64-linux.nix-builder-image = let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
    in pkgs.dockerTools.buildImage {
      name = "ghcr.io/pleme-io/nix-builder";
      tag = "latest";

      copyToRoot = pkgs.buildEnv {
        name = "nix-builder-root";
        paths = [
          pkgs.nix
          pkgs.awscli2
          inputs.ami-forge.packages.x86_64-linux.default
          pkgs.git
          pkgs.coreutils
          pkgs.bash
          pkgs.cacert
        ];
        pathsToLink = [ "/bin" "/etc" "/share" ];
      };

      config = {
        Env = [
          "NIX_CONFIG=experimental-features = nix-command flakes"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          "PATH=/bin"
        ];
        Cmd = [ "/bin/bash" ];
      };
    };

    packages.aarch64-linux.nix-builder-image = let
      pkgs = import nixpkgs { system = "aarch64-linux"; };
    in pkgs.dockerTools.buildImage {
      name = "ghcr.io/pleme-io/nix-builder";
      tag = "latest";

      copyToRoot = pkgs.buildEnv {
        name = "nix-builder-root";
        paths = [
          pkgs.nix
          pkgs.awscli2
          inputs.ami-forge.packages.aarch64-linux.default
          pkgs.git
          pkgs.coreutils
          pkgs.bash
          pkgs.cacert
        ];
        pathsToLink = [ "/bin" "/etc" "/share" ];
      };

      config = {
        Env = [
          "NIX_CONFIG=experimental-features = nix-command flakes"
          "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
          "PATH=/bin"
        ];
        Cmd = [ "/bin/bash" ];
      };
    };

    # AMI build app — used by CodeBuild buildspec (`nix run .#build-ami`)
    # ami-forge is a flake input derivation, not fetched at runtime.
    apps.x86_64-linux.build-ami = let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      amiForge = inputs.ami-forge.packages.x86_64-linux.default;
    in {
      type = "app";
      program = toString (pkgs.writeShellScript "build-ami" ''
        set -euo pipefail
        echo "[build-ami] Building NixOS AMI image..."
        nix build .#packages.x86_64-linux.ami --out-link result --no-write-lock-file

        echo "[build-ami] Running ami-forge pipeline..."
        ${amiForge}/bin/ami-forge build \
          --image result/ \
          --bucket "''${ARTIFACTS_BUCKET}" \
          --ami-name "''${AMI_NAME}" \
          --ssm "''${SSM_PARAMETER_NAME}" \
          --role-name "''${VMIMPORT_ROLE_NAME}"
      '');
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
