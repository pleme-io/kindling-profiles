# modules/observability.nix
# Typed control surface for observability configuration.
#
# Defines WHAT observability capabilities are available in the AMI.
# Actual endpoints and credentials come at runtime via kindling-init
# or FluxCD-managed Helm charts.
{ config, lib, ... }:
let
  cfg = config.kindling.observability;
in {
  options.kindling.observability = {
    logging = {
      journalPersistent = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Persist journal to disk (required for FedRAMP High AU-4)";
      };

      maxRetentionDays = lib.mkOption {
        type = lib.types.int;
        default = 7;
        description = "Journal retention in days (FedRAMP High: 90)";
      };

      forwardTo = lib.mkOption {
        type = lib.types.enum [ "none" "cloudwatch" "splunk" "vector" ];
        default = "none";
        description = "Log forwarding destination (configured at K8s layer via FluxCD)";
      };
    };

    metrics = {
      nodeExporter = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable Prometheus node exporter on the host";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.logging.journalPersistent {
      services.journald.extraConfig = lib.mkForce ''
        Storage=persistent
        SystemMaxUse=2G
        MaxRetentionSec=${toString cfg.logging.maxRetentionDays}day
      '';
    })
  ];
}
