# modules/fleet.nix
# Typed control surface for reverse-access fleet control.
#
# Nodes phone home to pull instructions — zero inbound access required.
# Multiple "home" endpoints provide redundancy and geographic distribution.
# Node identity determines which instructions to pull.
# Instructions ARE convergence deltas — homes ARE convergence memory.
#
# This module defines the AMI-level capabilities. Runtime configuration
# (specific home URLs, credentials) comes via kindling-init user_data.
{ config, lib, ... }:
let
  cfg = config.kindling.fleet;
in {
  options.kindling.fleet = {
    enable = lib.mkEnableOption "Reverse-access fleet control (node phones home)";

    homes = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Human-readable home identifier";
          };
          type = lib.mkOption {
            type = lib.types.enum [ "nats" "cloudflare-tunnel" "reverse-ssh" "http-poll" ];
            description = "Transport type for reaching this home";
          };
          endpoint = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Endpoint URL (set at runtime via kindling-init)";
          };
          priority = lib.mkOption {
            type = lib.types.int;
            default = 100;
            description = "Failover priority (lower = preferred)";
          };
        };
      });
      default = [];
      description = "Home endpoints that this node will phone to for instructions";
    };

    polling = {
      intervalSec = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = "How often to poll homes for new instructions (seconds)";
      };

      jitterSec = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "Random jitter added to polling interval (prevents thundering herd)";
      };
    };

    labels = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Node labels for instruction targeting. Homes use these labels
        to match instructions to nodes via glob, filter, and regex.
        Example: { role = "server"; cluster = "seph"; region = "us-east-1"; }
      '';
    };

    groups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Named groups this node belongs to. Supports group-of-groups
        composition for fleet-wide instruction targeting.
        Example: [ "production" "us-east" "k3s-servers" ]
      '';
    };
  };
}
