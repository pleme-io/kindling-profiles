# AMI as Convergence Checkpoint

The K3s AMI is a maximally pre-converged system closure. Everything that
can be resolved at build time IS resolved. The runtime delta (kindling-init)
applies only identity + secrets.

## Convergence Chain

```
Nix eval (resolution)
  → nixos-rebuild switch (convergence)
    → kindling ami-test (18 gates — convergence proof)
      → Packer snapshot (checkpoint)
        → kindling ami-integration-test (delta verification)
          → SSM promote (publication)
```

## 18 AMI Gates

| # | Check | Category | Controls |
|---|-------|----------|----------|
| 1 | kindling-binary | Operational | Bootstrap agent present |
| 2 | wireguard-tools | Operational | VPN agent present |
| 3 | nixos-rebuild | Operational | System rebuild capability |
| 4 | k3s-binary | Operational | Orchestrator present |
| 5 | k3s-no-stale-state | Operational | Clean for PKI seeding |
| 6 | no-stale-tls | Operational | No residual certificates |
| 7 | kindling-init-service | Operational | Bootstrap service enabled |
| 8 | nix-daemon | Operational | Package manager available |
| 9 | amazon-init-disabled | Operational | Our init replaces AWS |
| 10 | no-leaked-secrets | Operational | No credentials in AMI |
| 11 | network-connectivity | Operational | Cache reachable |
| 12 | ssh-hardening | FedRAMP IA-2, AC-17 | Key-only, root restricted |
| 13 | auditd-enabled | FedRAMP AU-2, AU-12 | Audit daemon active |
| 14 | fail2ban-enabled | FedRAMP SC-5, SI-4 | Brute-force protection |
| 15 | sysctl-hardening | FedRAMP SC-5, SC-7, SI-16 | 4 kernel params verified |
| 16 | firewall-active | FedRAMP SC-7, AC-4 | iptables rules present |
| 17 | no-world-writable-bins | FedRAMP SI-7 | No chmod 777 binaries |
| 18 | closure-size | Minimality | <= 9 GiB (prevents bloat) |

Any single failure prevents the AMI from being created.

## Compliance Layers (Composable NixOS Modules)

```
modules/compliance/
  ac.nix    → kindling.compliance.ac.enable    (SSH, fail2ban, PAM)
  au.nix    → kindling.compliance.au.enable    (auditd)
  cm.nix    → kindling.compliance.cm.enable    (tmpfs, TTY, USB)
  sc.nix    → kindling.compliance.sc.enable    (sysctl, firewall)
  si.nix    → kindling.compliance.si.enable    (lynis, aide)
  fedramp-high.nix → kindling.compliance.fedramp-high.enable (kernel lockdown, FIPS, persistent audit)
```

Each layer is independently toggleable and testable (NixOS VM test).
All Moderate layers enabled by default. High is opt-in.

## Cache Strategy

The AMI is the largest cacheable unit — it caches the ENTIRE system closure
as a single EC2 snapshot. Boot time = fetch time. Zero convergence computation.

Cache hierarchy: **AMI > closure > store path > derivation**

sui is the global cache that pre-warms store paths across nodes.
When sui's cache is warm, nixos-rebuild becomes a fetch-only operation.

## Runtime Delta (kindling-init)

After AMI boot, kindling-init applies the minimal delta:
1. Read EC2 user_data (cluster config JSON)
2. Provision secrets to /run/secrets.d/
3. Write K3s config.yaml
4. Set up WireGuard tunnel
5. Write role sentinel (server-mode or agent-mode)
6. Write FluxCD manifest

K3s auto-starts via systemd ordering. FluxCD reconciles from Git.
The entire delta is ~10 seconds of file writes — no package installs.
