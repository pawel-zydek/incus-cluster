{
  description = "Testowy klaster Incus na NixOS (3 węzły)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }:
  let
    nodes = import ./nodes.nix;

    # Wspólny przepis na węzeł; różni się tylko nazwą (resztę bierze z nodes.nix)
    mkNode = name: nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit nodes; nodeName = name; };
      modules = [
        disko.nixosModules.disko
        ./modules/hardware.nix
        ./modules/disko.nix
        ./modules/base.nix
        ./modules/network.nix
        ./modules/incus.nix
      ];
    };
  in {
    # incus1, incus2, incus3 - po jednej konfiguracji na każdy wpis w nodes.nix
    nixosConfigurations = nixpkgs.lib.mapAttrs (name: _: mkNode name) nodes;
  };
}
