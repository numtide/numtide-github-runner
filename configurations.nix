# We use the nixosConfigurations to test all the modules below.
#
# This is not optimal, but it gets the job done
{ self, nixpkgs, ... }:
let
  inherit (nixpkgs) lib;

  # some example configuration to make it eval
  dummy = { config, ... }: {
    networking.hostName = "example-common";
    system.stateVersion = config.system.nixos.version;
    users.users.root.initialPassword = "fnord23";
    boot.loader.grub.devices = lib.mkForce [ "/dev/sda" ];
    fileSystems."/".device = lib.mkDefault "/dev/sda";
  };
in
{
  example-services-numtide-github-runner = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.numtide-github-runner
      dummy
      {
        services.numtide-github-runner.cachix.cacheName = "cache-name";
        services.numtide-github-runner.cachix.tokenFile = "/run/cachix-token-file";
        services.numtide-github-runner.githubApp = {
          id = "1234";
          login = "foo";
          privateKeyFile = "/run/gha-token-file";
        };
        services.numtide-github-runner.url = "https://fixup";
      }
    ];
  };

  example-services-numtide-github-runner-queued-build-hook = lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.numtide-github-runner
      dummy
      {
        services.numtide-github-runner = {
          githubApp = {
            id = "1234";
            login = "foo";
            privateKeyFile = "/run/gha-token-file";
          };
          url = "https://fixup";
          binary-cache.script = ''
            exec nix copy --experimental-features nix-command --to "file:///var/nix-cache" $OUT_PATHS
          '';
        };
      }
    ];
  };
}
