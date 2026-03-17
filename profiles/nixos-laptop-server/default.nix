# profiles/nixos-laptop-server/default.nix
# Stackable laptop-as-server layer.
# Enables: WiFi via NetworkManager, TLP power management, USB tethering.
#
# All values use mkDefault — nodes can override individual settings.
{ lib, ... }: {
  blackmatter.profiles.blizzard.networkingExtended.networkManager = {
    enable = lib.mkDefault true;
    wifi.powersave = lib.mkDefault false;
  };

  blackmatter.profiles.blizzard.laptopServer = {
    enable = lib.mkDefault true;
    tlp.enable = lib.mkDefault true;
    usbTethering = lib.mkDefault true;
  };
}
