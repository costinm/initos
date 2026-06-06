{
  description = "initos — verified boot + mesh-init artifacts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay, crane }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        muslTarget =
          if system == "x86_64-linux" then "x86_64-unknown-linux-musl"
          else if system == "aarch64-linux" then "aarch64-unknown-linux-musl"
          else throw "Unsupported system: ${system}";

        efiTarget =
          if system == "x86_64-linux" then "x86_64-unknown-uefi"
          else if system == "aarch64-linux" then "aarch64-unknown-uefi"
          else throw "Unsupported system: ${system}";

        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          targets = [ muslTarget efiTarget ];
        };

        craneLib = (crane.mkLib pkgs).overrideToolchain (_: rustToolchain);
        src = craneLib.cleanCargoSource ./.;

        muslLinkerName = if system == "x86_64-linux" then "x86_64-unknown-linux-musl-gcc"
                         else if system == "aarch64-linux" then "aarch64-unknown-linux-musl-gcc"
                         else throw "Unsupported system: ${system}";

        muslLinkerVar = if system == "x86_64-linux" then "CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER"
                        else if system == "aarch64-linux" then "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER"
                        else throw "Unsupported system: ${system}";

        commonArgs = {
          inherit src;
          strictDeps = true;
          doCheck = false;
          preBuild = ''
            mkdir -p .bin
            ln -s ${pkgs.pkgsStatic.stdenv.cc}/bin/${muslLinkerName} .bin/musl-gcc
            export PATH=$PWD/.bin:$PATH
          '';
        };

        # Build workspace dependencies for musl
        cargoArtifactsMusl = craneLib.buildDepsOnly (commonArgs // {
          CARGO_BUILD_TARGET = muslTarget;
          CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
          "\${muslLinkerVar}" = "\${pkgs.pkgsStatic.stdenv.cc}/bin/\${muslLinkerName}";
          cargoExtraArgs = "--bin initos";
        });

        initos = craneLib.buildPackage (commonArgs // {
          cargoArtifacts = cargoArtifactsMusl;
          pname = "initos";
          cargoExtraArgs = "--bin initos";
          CARGO_BUILD_TARGET = muslTarget;
          CARGO_BUILD_RUSTFLAGS = "-C target-feature=+crt-static";
          "\${muslLinkerVar}" = "\${pkgs.pkgsStatic.stdenv.cc}/bin/\${muslLinkerName}";
        });

        efi = craneLib.buildPackage (commonArgs // {
          cargoArtifacts = null;
          pname = "efi";
          cargoExtraArgs = "--bin efi";
          CARGO_BUILD_TARGET = efiTarget;
          
          postInstall = ''
            mkdir -p $out/bin
            EFI_NAME="BOOTX64.EFI"
            if [ "${system}" = "aarch64-linux" ]; then
              EFI_NAME="BOOTAA64.EFI"
            fi

            if [ -f $out/bin/efi.efi ]; then
                cp $out/bin/efi.efi $out/bin/$EFI_NAME
            elif [ -f $out/bin/efi ]; then
                mv $out/bin/efi $out/bin/efi.efi
                cp $out/bin/efi.efi $out/bin/$EFI_NAME
            fi
          '';
        });

        signRuntimePath = pkgs.lib.makeBinPath (with pkgs; [
          coreutils
          efitools
          findutils
          fsverity-utils
          gnugrep
          gawk
          mtools
          minisign
          openssh
          openssl
          sbsigntool
          tinyxxd
          util-linux
        ]);

        # ── Assemble all artifacts: initos.erofs, initrd, boot images ─────
        # Use runCommand (single phase) to avoid $out shadowing issues.

        initos-artifacts = pkgs.runCommand "initos-artifacts" {
          nativeBuildInputs = with pkgs; [
            cpio gzip erofs-utils mtools openssl sbsigntool
          ] ++ [ initos efi ];
        } ''
          export OUT="$out"
          export USE_BUSYBOX="${pkgs.pkgsStatic.busybox}/bin/busybox"
          export CARGO_TOML="${./Cargo.toml}"
          export SIDECAR_BIN="${./sidecar/bin}"
          export SCRIPTS_DIR="${./scripts}"
          export PREBUILT_DIR="${./prebuilt}"
          export INITOS_BIN="${initos}/bin/initos"
          export EFI_BIN="${efi}/bin/efi.efi"
          export WITH_KERNELS="0"
          export SIGN_SH_LIB="${./sidecar/bin/sign.sh}"
          export SIGN_RUNTIME_PATH="${signRuntimePath}"
          export RUNTIME_SHELL="${pkgs.runtimeShell}"

          bash ${./scripts/assemble_artifacts.sh}
        '';

        # ── Docker image ───────────────────────────────────────────────────

        docker-image = pkgs.dockerTools.buildImage {
          name = "initos";
          tag = "latest";
          copyToRoot = [ initos-artifacts ];
          config = {
            Env = [ "PATH=/bin" ];
            WorkingDir = "/";
          };
        };

        oci-cache-image = pkgs.dockerTools.buildLayeredImage {
          name = "ghcr.io/costinm/initos/nix-artifact-cache";
          tag = self.shortRev or "dirty";
          contents = [ initos-artifacts ];
          config = {
            Env = [ "PATH=/bin" ];
            WorkingDir = "/";
            Labels = {
              "org.opencontainers.image.source" = "https://github.com/costinm/initos";
              "org.opencontainers.image.description" = "Unsigned initos Nix artifact cache";
            };
          };
        };

      in
      {
        packages = {
          inherit initos efi initos-artifacts docker-image oci-cache-image;
          default = initos-artifacts;
        };

      }
    );
}
