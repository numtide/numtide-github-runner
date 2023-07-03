{
  description = "NixOS GitHub actions runners";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    queued-build-hook.url = "github:nix-community/queued-build-hook";
    queued-build-hook.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, ... }@inputs: {
    lib.supportedSystems = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    lib.eachSystem = f: nixpkgs.lib.genAttrs self.lib.supportedSystems (system: f nixpkgs.legacyPackages.${system});

    checks = self.lib.eachSystem (import ./checks inputs);
    nixosModules.numtide-github-runner = import ./nixos/numtide-github-runner inputs;
    nixosModules.default = self.nixosModules.numtide-github-runner;
    nixosConfigurations = import ./configurations.nix inputs;
  };
}
