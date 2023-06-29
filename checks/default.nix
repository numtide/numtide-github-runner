{ self, ... }:
pkgs:
let
  inherit (pkgs) lib;

  # Only check the configurations for the current system
  sysConfigs = lib.filterAttrs (_name: value: value.pkgs.system == pkgs.system) self.nixosConfigurations;

  # Add all the nixos configurations to the checks
  nixosChecks =
    lib.mapAttrs'
      (name: value: { name = "nixos-${name}"; value = value.config.system.build.toplevel; })
      sysConfigs;
in
nixosChecks