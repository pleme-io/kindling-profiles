# kindling-profiles

> **★★★ CSE / Knowable Construction.** This repo operates under **Constructive Substrate Engineering** — canonical specification at [`pleme-io/theory/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md`](https://github.com/pleme-io/theory/blob/main/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md). The Compounding Directive (operational rules: solve once, load-bearing fixes only, idiom-first, models stay current, direction beats velocity) is in the org-level pleme-io/CLAUDE.md ★★★ section. Read both before non-trivial changes.


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

## Composable Compliance Layers

FedRAMP controls are modeled as NixOS modules under `modules/compliance/`.
Each module is a convergence layer — an independent set of invariants that
can be toggled, tested, and composed.

```
modules/compliance/
  ac.nix              Access Control (SSH, fail2ban, PAM) — AC-2/4/6/17
  au.nix              Audit & Accountability (auditd) — AU-2/3/9/11/12
  cm.nix              Configuration Management (tmpfs, TTY, USB) — CM-2/6/7/8
  sc.nix              System & Comms Protection (sysctl, firewall) — SC-5/7/8/13/28/45
  si.nix              System & Info Integrity (lynis, aide) — SI-2/4/7
  fedramp-high.nix    FedRAMP High additive (kernel lockdown, persistent audit, FIPS)
  soc2.nix            SOC 2 Type II (CC6/CC7/CC8, composes NIST layers)
  pci.nix             PCI DSS 4.0 (Req 1-10, network connection audit)
  cis-l1.nix          CIS Linux Benchmark Level 1 (sections 1-6, TMOUT, umask)
```

Each module:
- Has `kindling.compliance.{family}.enable` option
- Is gated with `lib.mkIf cfg.enable` (zero-cost when disabled)
- Maps to specific NIST 800-53 Rev 5 controls (documented in file header)
- Is independently verifiable via NixOS VM test in `checks/`

**k3s-cloud-server** enables all Moderate layers by default:
```nix
kindling.compliance = {
  ac.enable = true;   # SSH, fail2ban, PAM
  au.enable = true;   # auditd
  cm.enable = true;   # tmpfs, TTY, USB
  sc.enable = true;   # sysctl, firewall
  si.enable = true;   # lynis, aide
};
```

FedRAMP High is available but disabled: `kindling.compliance.fedramp-high.enable = false`.

**K3s-incompatible hardening** is disabled by bare values in the profile (not mkForce):
- `kernel.enable = false` — lockdown=confidentiality breaks IPVS
- `apparmor.enable = false` — needs custom K3s container profiles
- `autoUpgrade.enable = false` — node cycling causes CP downtime

---

## NixOS VM Compliance Tests

Free, local QEMU tests verifying each compliance layer independently:

| Test | Controls | What it verifies |
|------|----------|-----------------|
| `compliance-ac-test` | AC-2/6/17 | SSH key-only, fail2ban running, PAM limits |
| `compliance-au-test` | AU-2/3/12 | auditd running, rules loaded, log directory |
| `compliance-sc-test` | SC-5/7/13/28, SI-16 | 11 sysctl values, firewall active |
| `vpn-test` | SC-7(4) | WireGuard tunnel connectivity, firewall isolation |

Run all: `nix flake check`

---

## Structure

```
profiles/              Machine profile definitions
  k3s-cloud-server/    Cloud K3s (VPN + FluxCD + compliance layers)
  k8s-cloud-server/    Cloud upstream K8s (kubeadm + containerd + etcd)
  k3s-server/          Bare-metal K3s server
  k3s-agent/           K3s worker node
  attic-server/        Nix binary cache server
  macos-developer/     macOS workstation
modules/
  node-identity.nix    Shared node identity interface
  compliance/          Composable FedRAMP compliance layers (6 modules)
  networking.nix       VPN, firewall, CIDRs (kindling.networking.*)
  orchestration.nix    K3s/kubeadm, FluxCD, profiles (kindling.orchestration.*)
  identity.nix         Secrets provider, bootstrap method (kindling.identity.*)
  observability.nix    Logging, metrics, tracing (kindling.observability.*)
  fleet.nix            Reverse-access fleet control (kindling.fleet.*)
lib/
  k3s-defaults.nix     K3s kernel modules, flags, CIDRs, server flags
  mk-profile.nix       Profile construction helper
schema/                Profile schema definitions
checks/
  vpn-test.nix         WireGuard tunnel connectivity (2 VMs)
  compliance-ac-test.nix  Access Control layer (SSH, fail2ban, PAM)
  compliance-au-test.nix  Audit layer (auditd, rules, logs)
  compliance-sc-test.nix  System protection layer (sysctl, firewall)
flake.nix              Packer templates, AMI pipelines, profile exports, checks
docs/
  convergence-ami.md   AMI as convergence checkpoint (18 gates, cache strategy)
  lattice-modules.md   Module as universal lattice primitive (design rules, cross-system)
```
