# Module as Universal Lattice Primitive

Every NixOS/nix-darwin/home-manager module is an atom in the convergence
lattice. The module interface IS the lattice type signature.

## The Module Interface

```nix
{ options, config, lib, pkgs, ... }:
{
  options.domain.control = lib.mkEnableOption "description";
  config = lib.mkIf cfg.enable { ... };
}
```

| Interface Element | Lattice Operation | What It Does |
|-------------------|-------------------|--------------|
| `options` | Element type | Declares what CAN be controlled |
| `config` | Current position | Declares what IS controlled |
| `lib.mkIf` | Meet (⊓) | Conditional — config only when condition holds |
| `imports = [a b]` | Join (⊔) | Compose — union of options, merge of config |
| `lib.mkDefault` | Priority 1000 | Weak preference — overridable |
| bare value | Priority 100 | Normal — overrides mkDefault |
| `lib.mkForce` | Priority 50 | **Code smell** — signals wrong hierarchy |

## Design Rules

1. **Everything is a module.** Compliance, networking, orchestration, identity —
   every convergence domain is a set of modules with typed option interfaces.

2. **Modules compose by set union.** The NixOS merge algorithm IS the convergence
   function. When two modules set the same option, priority resolves it.

3. **mkForce means wrong hierarchy.** If you need mkForce, the modules are in
   the wrong partial order. Restructure so bare values naturally win.

4. **Test modules in isolation.** NixOS VM tests verify individual modules.
   If each module converges independently, their composition converges by
   categorical product — no integration test needed.

5. **Domain prefix convention.** Each convergence domain owns its option tree:
   - `kindling.compliance.*` — FedRAMP/SOC2/PCI controls
   - `kindling.networking.*` — VPN, firewall, DNS
   - `kindling.orchestration.*` — K3s/kubeadm, FluxCD
   - `kindling.identity.*` — node identity, secrets provider

## Lattice Operations on Modules

| Operation | Module Equivalent | Example |
|-----------|-------------------|---------|
| Join (⊔) | `imports = [ac.nix au.nix]` | Compose AC + AU compliance |
| Meet (⊓) | `lib.mkIf (ac && au)` | Config only when both layers active |
| Top (⊤) | No modules imported | Empty NixOS — all defaults |
| Bottom (⊥) | All modules, all enables true | Maximally converged |
| Complement (¬) | `enable = false` | Disable a layer |
| Partial order (≤) | Priority (50 < 100 < 1000) | Convergence direction |

## Cross-System Lattice Primitives

The module pattern maps to equivalent primitives in every system:

| System | Primitive | Typed Interface |
|--------|----------|-----------------|
| NixOS/darwin/HM | Module | `{ options, config, lib }` |
| Pangea | Architecture | `.build(synth, config)` → Dry::Struct |
| Helm | Chart values | `values.yaml` schema |
| FluxCD | Kustomization | `apiVersion, kind, spec` |
| Kubernetes | Manifest | `apiVersion, kind, metadata, spec` |
| tameshi | AttestationLayer | LayerType + BLAKE3 hash |
| kindling | ClusterConfig | JSON schema (distribution, role, vpn, fluxcd) |
| InSpec | Control | `control 'id' do ... end` |
| kensa | ComplianceSpec | TOML assertion |

Every system composes through its primitive. The theory is uniform.
