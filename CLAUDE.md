# kindling-profiles

Reusable NixOS/nix-darwin machine profiles consumed by kindling fleet management
and the AMI build pipeline.

---

## Profile Library

| Profile | Platform | Purpose |
|---------|----------|---------|
| `k3s-cloud-server` | Linux | K3s control plane for cloud (AWS/Hetzner) with WireGuard mesh, FluxCD |
| `k8s-cloud-server` | Linux | Upstream Kubernetes (kubeadm) for cloud with containerd, etcd, WireGuard, FluxCD |
| `k3s-server` | Linux | K3s control plane for bare-metal with IPVS, production tuning |
| `k3s-agent` | Linux | K3s worker node with staging taints and node labels |
| `attic-server` | Linux | Nix binary cache (atticd + PostgreSQL) for AMI build acceleration |
| `macos-developer` | Darwin | Developer workstation with blackmatter shell, neovim, code search |

Profiles are path references (`./profiles/{name}`) exported via `lib.profiles`
and `lib.profileMeta`. Kindling's generated flake imports them.

---

## AMI Pipelines

Two independent pipelines build NixOS AMIs from this repo. Both follow the same
pattern: **build, test, promote** -- no shortcuts, no untested AMIs.

### K3s Pipeline (`nix run .#ami-build`)

Builds the `k3s-cloud-server` profile AMI.

```
Phase 1: Packer launches base NixOS EC2 → runs provisioner:
           nixos-rebuild switch --flake .#ami-builder
           kindling ami-build --skip-rebuild
             (clean K3s state → 11 validation checks → cleanup)
Phase 2: ami-forge extracts AMI ID from packer-manifest.json
Phase 3: Packer boots AMI with test userdata → kindling ami-integration-test
           (waits for kindling-init → validates VPN + K3s + kubectl)
Phase 4: ami-forge cluster-test: launches 5 EC2 instances (1 CP + 3 workers
           + 1 client), validates tag coordination, VPN peering, K3s cluster
           join, and kubectl from client node
Phase 5: ami-forge promotes AMI to SSM parameter
```

On any test failure, the AMI is **deregistered** (no bad AMIs in inventory).

### Attic Pipeline (`nix run .#attic-ami-build`)

Builds the `attic-server` profile AMI. Simpler test (no K3s/VPN):
validates `atticd.service` + `postgresql.service` are running.

### K8s Pipeline (`nix run .#k8s-ami-build`)

Builds the `k8s-cloud-server` profile AMI. Same pipeline structure as K3s:

```
Phase 1: Packer launches base NixOS EC2 -> runs provisioner:
           nixos-rebuild switch --flake .#k8s-ami-builder
           kindling ami-build --skip-rebuild
Phase 2: ami-forge extracts AMI ID from packer-manifest.json
Phase 3: Packer boots AMI with test userdata -> kindling ami-integration-test
Phase 4: ami-forge promotes AMI to SSM parameter
```

Additional `nix run` apps for K8s pipeline:
- `.#k8s-ami-build` -- Full pipeline (build, test, promote)
- `.#k8s-ami-test` -- Re-test an existing K8s AMI without rebuilding
- `.#k8s-ami-status` -- Show current promoted K8s AMI

---

## Test Userdata Injection

Integration tests inject a `ClusterConfig` JSON as EC2 userdata. Key fields:

- `skip_nix_rebuild: true` -- AMI already has the NixOS config baked in.
  kindling-init skips rebuild, writes K3s `config.yaml` from bootstrap_secrets,
  and K3s auto-starts via systemd `Before=k3s.service` ordering.
- `bootstrap_secrets` -- Ephemeral WireGuard keys and K3s tokens (test instance
  is destroyed after validation, so hardcoded keys are safe).
- `vpn.require_liveness: false` -- Don't fail if peer isn't reachable (single-node test).

- `role` -- Determines which sentinel kindling-init writes. CP node gets
  `role: "server"` (writes `/var/lib/kindling/server-mode`), agent nodes get
  `role: "agent"` (writes `/var/lib/kindling/agent-mode`).

The test userdata in `flake.nix` (`testClusterConfig`) is the canonical example.

---

## Packer Template Generation

Templates are generated via substrate's `lib/infra/ami-build.nix`:

- `mkBuildTemplate` -- produces `build.pkr.json` (provisions base NixOS → snapshot)
- `mkTestTemplate` -- produces `test.pkr.json` (boots AMI, runs validation)
- `mkAmiBuildPipeline` -- wires both into `nix run` apps that call `ami-forge pipeline-run`

Nix generates the JSON; Packer orchestrates SSH, instance lifecycle, and cleanup.
All build logic is Rust (kindling ami-build, ami-forge).

---

## NixOS Configurations

| Config | Target | Description |
|--------|--------|-------------|
| `nixosConfigurations.ami-builder` | x86_64-linux | K3s cloud server with kindling-init module |
| `nixosConfigurations.attic-builder` | x86_64-linux | Attic cache server |

Both include `amazon-image.nix` for EC2 support and `kindling.nixosModules.default`
for the kindling-init systemd service.

---

## NixOS VM Tests

`checks.x86_64-linux.vpn-test` launches two QEMU VMs and validates WireGuard
tunnel connectivity (bidirectional ping, firewall blocking, interface bounce).
Free to run (local QEMU, no cloud resources).

---

## Key Architecture Patterns

1. **Packer orchestrates instances** -- SSH keys, lifecycle, cleanup are Packer's job.
   ami-forge and kindling are tools Packer calls, not the other way around.
2. **No shell for logic** -- Provisioner scripts are max 3 lines (PATH, env, exec).
   All actual logic is Rust (kindling ami-build, ami-forge pipeline-run).
3. **Before=k3s.service** -- kindling-init orders before K3s in systemd, ensuring
   VPN and secrets are provisioned before K3s starts.
4. **Integration tests catch orchestration issues at build time** -- VPN peering,
   K3s cluster formation, kubectl -- not at deploy time.
5. **Ephemeral Attic cache** (planned) -- boot from last Attic AMI, K3s build
   uses it for Nix store caching, snapshot Attic with new NARs, tear down.
   Zero ongoing cost.
6. **Dual-sentinel role selection** -- k3s-cloud-server profile sets
   `roleConditionPath = { server = "/var/lib/kindling/server-mode"; agent = "/var/lib/kindling/agent-mode"; }`.
   Both k3s.service and k3s-agent.service are in wantedBy=multi-user.target
   with ConditionPathExists on their respective sentinel. kindling-init
   writes exactly one sentinel, and systemd deterministically starts the
   correct service. If neither sentinel exists (AMI build), neither starts.

---

## Structure

```
profiles/              Machine profile definitions
  k3s-cloud-server/    Cloud K3s server (VPN + FluxCD + firewall)
  k8s-cloud-server/    Cloud upstream K8s (kubeadm + containerd + etcd + VPN + FluxCD)
  k3s-server/          Bare-metal K3s server
  k3s-agent/           K3s worker node
  attic-server/        Nix binary cache server
  macos-developer/     macOS workstation
modules/
  node-identity.nix    Shared node identity interface
lib/
  k3s-defaults.nix     K3s kernel modules, flags, network defaults
  mk-profile.nix       Profile construction helper
schema/                Profile schema definitions
checks/
  vpn-test.nix         NixOS VM test for WireGuard
flake.nix              Packer templates, AMI pipelines, profile exports
```
