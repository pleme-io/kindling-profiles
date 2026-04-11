# modules/orchestration.nix
# Typed control surface for Kubernetes orchestration.
#
# Provides a single option tree for orchestrator selection and configuration.
# The actual K3s/kubeadm config comes from kindling.nodeIdentity at runtime.
# This module expresses WHAT orchestrator capabilities are available in the AMI.
{ config, lib, ... }:
let
  cfg = config.kindling.orchestration;
in {
  options.kindling.orchestration = {
    distribution = lib.mkOption {
      type = lib.types.enum [ "k3s" "kubernetes" ];
      default = "k3s";
      description = "Kubernetes distribution (k3s or upstream kubeadm)";
    };

    fluxcd.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable FluxCD GitOps bootstrap (CRDs + controllers baked into AMI)";
    };

    profiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "K3s cluster profiles to support (e.g., flannel-standard, cilium-mesh)";
    };

    disableComponents = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "traefik" ];
      description = "K3s components to disable (baked into AMI, not runtime)";
    };
  };
}
