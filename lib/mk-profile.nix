# lib/mk-profile.nix
# Helper for constructing kindling profiles.
# Provides a standard interface for building profile modules that consume
# kindling.nodeIdentity options.
{lib}: {
  # Create a profile module that automatically binds `ni` as a shorthand
  # for `config.kindling.nodeIdentity`.
  #
  # Usage:
  #   mkProfile ({ ni, config, lib, pkgs, ... }: {
  #     # ni.hostname, ni.user.name, etc. are available
  #     networking.hostName = ni.hostname;
  #   })
  mkProfile = profileFn: {
    config,
    lib,
    pkgs,
    ...
  } @ args: let
    ni = config.kindling.nodeIdentity;
  in
    profileFn (args // {inherit ni;});
}
