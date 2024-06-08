{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    crane = {
      url = "github:ipetkov/crane";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };
  };
  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          lib = nixpkgs.lib;
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ (import rust-overlay) ];
          };
          rustToolchain = pkgs.pkgsBuildHost.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

          src = craneLib.cleanCargoSource ./.;

          # Dependencies required only at build time
          nativeBuildInputs = [ pkgs.clang ];

          # Dependencies required at runtime
          buildInputs = [ ] ++ lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
          ];

          commonArgs = {
            inherit src buildInputs nativeBuildInputs;
            strictDeps = true; # ensure nativeBuildInputs don't leak to runtime

            env = {
              # For rocksdb
              LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";

              # nix builds in a sandbox without network access, so we have to
              # stop the bitcoind/electrumd/elementsd crates from downloading
              # binaries and instead provide them manually below.
              BITCOIND_SKIP_DOWNLOAD = true;
              ELECTRUMD_SKIP_DOWNLOAD = true;
              ELEMENTSD_SKIP_DOWNLOAD = true;
            };
          };

          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          bin = craneLib.buildPackage (commonArgs // {
            inherit cargoArtifacts;

            # TODO: do testing by providing executables via *_EXE env var for {bitcoin,elements,electrum}d
            doCheck = false;
          });
          binLiquid = craneLib.buildPackage (commonArgs // {
            inherit cargoArtifacts;
            cargoExtraArgs = "--features liquid";

            # TODO: do testing by providing executables via *_EXE env var for {bitcoin,elements,electrum}d
            doCheck = false;
          });


        in
        with pkgs;
        {
          packages = {
            default = bin;
            blockstream-electrs = bin;
            blockstream-electrs-liquid = binLiquid;
          };

          apps."blockstream-electrs-liquid" = {
            type = "app";
            program = "${binLiquid}/bin/electrs";
          };
          apps."blockstream-electrs" = {
            type = "app";
            program = "${bin}/bin/electrs";
          };


          devShells.default = mkShell {
            inputsFrom = [ bin ];
            LIBCLANG_PATH = "${pkgs.libclang.lib}/lib"; # for rocksdb
          };
        }
      );
}
