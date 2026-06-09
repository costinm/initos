{
  description = "initos — verified boot + mesh-init artifacts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
  };

  outputs = { self, nixpkgs, rust-overlay, crane }:
    let
      system = "x86_64-linux";
      muslTarget = "x86_64-unknown-linux-musl";
      efiTarget = "x86_64-unknown-uefi";

      overlays = [ (import rust-overlay) ];
      pkgs = import nixpkgs {
        inherit system overlays;
      };

      rustToolchain = pkgs.rust-bin.stable.latest.default.override {
        targets = [ muslTarget efiTarget ];
      };

      craneLib = (crane.mkLib pkgs).overrideToolchain (_: rustToolchain);
      src = craneLib.cleanCargoSource ./.;

      muslLinkerName = "x86_64-unknown-linux-musl-gcc";
      muslLinkerVar = "CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER";

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
          if [ -f $out/bin/efi.efi ]; then
              cp $out/bin/efi.efi $out/bin/BOOTX64.EFI
          elif [ -f $out/bin/efi ]; then
              mv $out/bin/efi $out/bin/efi.efi
              cp $out/bin/efi.efi $out/bin/BOOTX64.EFI
          fi
        '';
      });

      # ── Runtime deps for signing ────────────────────────────────────────
      signRuntimeDeps = with pkgs; [
        coreutils
        gnused
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
      ];

      signRuntimePath = pkgs.lib.makeBinPath signRuntimeDeps;
      linuxFlake = (import ./linux/flake.nix).outputs {
        self = ./linux;
        inherit nixpkgs;
      };

      initos-signer = pkgs.runCommand "initos-signer" {
        src = ./.;
        nativeBuildInputs = with pkgs; [
          cpio gzip erofs-utils mtools makeWrapper
        ] ++ [ initos efi ];
      } ''
        export out="$out"
        export USE_BUSYBOX="${pkgs.pkgsStatic.busybox}/bin/busybox"
        export INITOS_BIN="${initos}/bin/initos"
        export EFI_BIN="${efi}/bin/efi.efi"

        bash $src/scripts/build.sh build_initos
        bash $src/scripts/build.sh build_boot
        bash $src/scripts/build.sh build_bin

        # Move artifacts to the root of $out
        mv $out/artifacts/* $out/
        rmdir $out/artifacts
      '';

      usrBinEnv = pkgs.runCommand "usr-bin-env" {} ''
        mkdir -p $out/usr/bin
        ln -s ${pkgs.coreutils}/bin/env $out/usr/bin/env
      '';

      tmpDir = pkgs.runCommand "tmp-dir" {} ''
        mkdir -p $out/tmp
        chmod 1777 $out/tmp
      '';

      # ── Docker Image (runs signer) ──────────────────────────────────────

      docker-image = pkgs.dockerTools.buildImage {
        name = "initos-signer";
        tag = "latest";
        copyToRoot = [ initos-signer pkgs.coreutils usrBinEnv pkgs.bash tmpDir linuxFlake.packages.${system}.kernel-host ] ++ signRuntimeDeps;
        config = {
          Entrypoint = [ "/bin/sign.sh" ];
          Env = [ "PATH=/bin" ];
          WorkingDir = "/";
        };
      };

    in
    {
      packages.${system} = {
        inherit initos efi initos-signer docker-image;
        default = initos-signer;
      };
    };
}
