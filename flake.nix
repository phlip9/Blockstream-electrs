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

            doCheck = true;

            # This hook runs before `cargo test` and sets envs so the e2e tests
            # can find the bitcoind/electrum binaries.
            # WARNING: the nixpkgs versions of these binaries != the expected
            # Cargo.toml versions.
            preCheck = ''
              export RUST_BACKTRACE=1
              export BITCOIND_EXE=${pkgs.bitcoind}/bin/bitcoind
              export ELECTRUMD_EXE=${pkgs.electrum}/bin/electrum
            '';
          });
          binLiquid = craneLib.buildPackage (commonArgs // {
            inherit cargoArtifacts;
            cargoExtraArgs = "--features liquid";

            doCheck = true;

            # This hook runs before `cargo test` and sets envs so the e2e tests
            # can find the elementsd/electrum binaries.
            # WARNING: the nixpkgs versions of these binaries != the expected
            # Cargo.toml versions.
            preCheck = ''
              export RUST_BACKTRACE=1
              export ELEMENTSD_EXE=${pkgs.elements}/bin/elementsd
              export ELECTRUMD_EXE=${pkgs.electrum}/bin/electrum

              # phlip9: this got typo'ed upstream -- remove this line when
              # <https://github.com/RCasatta/elementsd/pull/17> gets merged.
              export ELECTRSD_SKIP_DOWNLOAD=1
            '';
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
