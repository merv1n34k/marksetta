{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };
  outputs = {nixpkgs, ...}: let
    system = "aarch64-darwin"; # Change this to aarch64-darwin or x86_64-darwin
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      buildInputs = with pkgs; [
        pkg-config
        luajit
        luajitPackages.lux-lua
        lux-cli
      ];
    };
  };
}
