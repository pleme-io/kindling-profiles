# kindling-profiles

Reusable machine profiles for kindling fleet management.

## Overview

kindling-profiles defines composable machine profiles used by the kindling fleet manager. Each profile specifies a complete machine configuration (NixOS or nix-darwin) with appropriate components, services, and settings. Profiles are consumed by kindling's generated flake to produce per-node system configurations.

## Available Profiles

| Profile | Platform | Description |
|---------|----------|-------------|
| `macos-developer` | Darwin | Developer workstation with shell, neovim, code search, workspace tooling |
| `k3s-server` | Linux | K3s control plane with FluxCD, IPVS, production tuning |
| `k3s-agent` | Linux | K3s worker node with staging taints and node labels |
| `k3s-cloud-server` | Linux | K3s server for cloud hosts (Hetzner/AWS) with WireGuard mesh |

## Usage

```nix
# As a flake input
inputs.kindling-profiles.url = "github:pleme-io/kindling-profiles";

# Use a profile
kindling-profiles.lib.profiles.macos-developer

# Use the node identity module
kindling-profiles.darwinModules.default   # or nixosModules.default
```

## Structure

```
profiles/          -- Machine profile definitions
modules/
  node-identity.nix  -- Node identity interface (shared across all profiles)
schema/            -- Profile schema definitions
lib/               -- Helper functions
```

## License

MIT
