# modules/identity.nix
# Typed control surface for node identity and secrets management.
#
# Defines HOW the node identifies itself and manages secrets.
# Actual identity values (hostname, cluster name) come at runtime via kindling-init.
# This module expresses WHAT identity capabilities are available in the AMI.
{ config, lib, ... }:
let
  cfg = config.kindling.identity;
in {
  options.kindling.identity = {
    secretsProvider = lib.mkOption {
      type = lib.types.enum [ "sops" "akeyless" ];
      default = "sops";
      description = "Secrets management provider (sops-nix or akeyless-nix)";
    };

    ageKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/sops-nix/key.txt";
      description = "Path to age private key for SOPS decryption";
    };

    bootstrapMethod = lib.mkOption {
      type = lib.types.enum [ "userdata" "nats" "manual" ];
      default = "userdata";
      description = "How the node receives its identity at boot (EC2 userdata, NATS message, or manual)";
    };
  };
}
