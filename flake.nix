{
  description = "zig-router flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    zig-stdenv.url = "github:Cloudef/nix-zig-stdenv";
  };

  outputs = { flake-utils, nixpkgs, zig-stdenv, ... }:
  (flake-utils.lib.eachDefaultSystem (system:
    let
      pkgs = nixpkgs.outputs.legacyPackages."${system}";
      zig = zig-stdenv.versions.${system}.master;
      app = script: {
        type = "app";
        program = toString (pkgs.writeShellApplication {
          name = "app";
          runtimeInputs = [ zig ];
          text = ''
            # shellcheck disable=SC2059
            error() { printf -- "error: $1" "''${@:1}" 1>&2; exit 1; }
            [[ -f ./flake.nix ]] || error 'Run this from the project root'
            ${script}
            '';
        }) + "/bin/app";
      };

    in {
      # nix run
      apps.default = app "zig build example";

      # nix run .#test
      apps.test = app "zig build test";

      # nix run .#docs
      apps.docs = app "zig build docs";

      # nix run .#version
      apps.version = app "zig version";

      # nix develop
      devShells.default = pkgs.mkShell {
        buildInputs = [ zig ];
        shellHook = "export ZIG_BTRFS_WORKAROUND=1";
      };
    }));
}
