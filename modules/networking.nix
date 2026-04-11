# modules/networking.nix
# Typed control surface for network configuration.
#
# Provides a single option tree for all network-level convergence controls.
# Profiles select which networking features are active. The VPN configuration
# comes from kindling.nodeIdentity at runtime (not baked into the module).
{ config, lib, ... }:
let
  cfg = config.kindling.networking;
  k3sDefaults = import ../lib/k3s-defaults.nix { inherit lib; };
in {
  options.kindling.networking = {
    vpn.enable = lib.mkEnableOption "WireGuard VPN mesh (configured at runtime via kindling-init)";

    firewall = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable NixOS firewall with K3s-aware defaults";
      };

      allowedTCPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ 22 6443 80 443 10250 ];
        description = "TCP ports to allow (K3s defaults: SSH, API, HTTP, HTTPS, kubelet)";
      };

      allowedUDPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ 8472 ];
        description = "UDP ports to allow (K3s default: Flannel VXLAN)";
      };

      trustedInterfaces = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "cni0" "flannel.1" ];
        description = "Interfaces to trust (K3s CNI bridges)";
      };
    };

    podCIDR = lib.mkOption {
      type = lib.types.str;
      default = k3sDefaults.defaultClusterCIDR;
      description = "Pod network CIDR";
    };

    serviceCIDR = lib.mkOption {
      type = lib.types.str;
      default = k3sDefaults.defaultServiceCIDR;
      description = "Service network CIDR";
    };

    clusterDNS = lib.mkOption {
      type = lib.types.str;
      default = k3sDefaults.defaultClusterDNS;
      description = "Cluster DNS IP";
    };
  };

  config = lib.mkIf cfg.firewall.enable {
    networking.firewall = {
      enable = true;
      allowPing = true;
      allowedTCPPorts = cfg.firewall.allowedTCPPorts;
      allowedUDPPorts = cfg.firewall.allowedUDPPorts;
      trustedInterfaces = cfg.firewall.trustedInterfaces;
    };
  };
}
