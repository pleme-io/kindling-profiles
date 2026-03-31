# kindling-profiles

Reusable machine profiles for kindling fleet management and the AMI build pipeline.

## Overview

kindling-profiles defines composable machine profiles used by the kindling fleet manager. Each profile specifies a complete machine configuration (NixOS or nix-darwin) with appropriate components, services, and settings. Profiles are consumed by kindling's generated flake to produce per-node system configurations.

This repo also hosts the **AMI build pipelines** -- Nix-generated Packer templates that produce tested, production-ready NixOS AMIs.

## Available Profiles

| Profile | Platform | Description |
|---------|----------|-------------|
| `macos-developer` | Darwin | Developer workstation with shell, neovim, code search, workspace tooling |
| `k3s-server` | Linux | K3s control plane with FluxCD, IPVS, production tuning |
| `k3s-agent` | Linux | K3s worker node with staging taints and node labels |
| `k3s-cloud-server` | Linux | K3s server for cloud hosts (Hetzner/AWS) with WireGuard mesh |
| `k8s-cloud-server` | Linux | Upstream Kubernetes (kubeadm) for cloud with containerd, etcd, WireGuard, FluxCD |
| `attic-server` | Linux | Nix binary cache server (atticd + PostgreSQL) |

## Usage

```nix
# As a flake input
inputs.kindling-profiles.url = "github:pleme-io/kindling-profiles";

# Use a profile
kindling-profiles.lib.profiles.macos-developer

# Use the node identity module
kindling-profiles.darwinModules.default   # or nixosModules.default
```

## AMI Pipelines

Two pipelines build NixOS AMIs. Both enforce: **build, test, promote** -- no untested AMIs.

```bash
# K3s cloud server AMI (build → single-node test → cluster test → promote)
nix run .#ami-build

# Attic binary cache AMI (build → service test → promote)
nix run .#attic-ami-build

# Re-test an existing AMI without rebuilding
nix run .#ami-test

# K8s upstream pipeline (build -> test -> promote)
nix run .#k8s-ami-build

# Re-test an existing K8s AMI
nix run .#k8s-ami-test

# Show current promoted K8s AMI
nix run .#k8s-ami-status

# Show current promoted AMI
nix run .#ami-status
```

### Pipeline flow (K3s)

1. **Build** -- Packer launches base NixOS, runs `nixos-rebuild` + `kindling ami-build` (11 validation checks)
2. **Single-node test** -- Packer boots AMI with test userdata, `kindling ami-integration-test` validates VPN + K3s + kubectl
3. **Cluster test** -- `ami-forge cluster-test` launches 2 EC2 instances, validates 2-node K3s cluster with VPN peering
4. **Promote** -- AMI ID written to SSM parameter

On any test failure the AMI is deregistered.

## NixOS VM Tests

```bash
# Validate WireGuard tunnel connectivity (free, local QEMU VMs)
nix build .#checks.x86_64-linux.vpn-test
```

## Structure

```
profiles/              Machine profile definitions
  k3s-cloud-server/    Cloud K3s server (VPN + FluxCD + firewall)
  k3s-server/          Bare-metal K3s server
  k3s-agent/           K3s worker node
  k8s-cloud-server/    Cloud upstream K8s (kubeadm + containerd + etcd + VPN + FluxCD)
  attic-server/        Nix binary cache server
  macos-developer/     macOS workstation
modules/
  node-identity.nix    Node identity interface (shared across all profiles)
schema/                Profile schema definitions
lib/                   Helper functions (k3s-defaults, mk-profile)
checks/
  vpn-test.nix         NixOS VM test for WireGuard connectivity
```

## License

MIT
