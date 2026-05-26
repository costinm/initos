{
  description = "initos flake";

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
                         else throw "Unsupported system: \${system}";

        muslLinkerVar = if system == "x86_64-linux" then "CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER"
                        else if system == "aarch64-linux" then "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER"
                        else throw "Unsupported system: \${system}";

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

        disk-initos = pkgs.stdenv.mkDerivation {
          name = "disk-initos";
          src = ./.;
          installPhase = ''
            STAGING=$out
            mkdir -p "$STAGING"/{bin,c,dev,proc,sys,home,run,etc,tmp,sbin,x,boot,data,z,mnt/data,mnt/root}
            mkdir -p "$STAGING"/lib/modules "$STAGING"/lib/firmware
            
            cp ${pkgs.pkgsStatic.busybox}/bin/busybox "$STAGING/bin/busybox"
            chmod 755 "$STAGING/bin/busybox"
            
            (
                cd $STAGING/bin 
                for applet in $($STAGING/bin/busybox --list); do
                    ln -s /bin/busybox $applet
                done
            )
            
            cp sidecar/bin/initos-init $STAGING/bin/initos-init
            chmod 755 $STAGING/bin/initos-init
            
            cp ${initos}/bin/initos $STAGING/init
            chmod 755 $STAGING/init
            
            cp ${initos}/bin/initos $STAGING/bin/initos
            chmod 755 $STAGING/bin/initos
          '';
          dontBuild = true;
        };

        docker-image = pkgs.dockerTools.buildImage {
          name = "initos";
          tag = "latest";
          copyToRoot = [ disk-initos ];
          config = {
            Cmd = [ "/init" ];
            Entrypoint = [ "/init" ];
          };
        };


      in
      {
        packages = {
          inherit initos efi disk-initos docker-image;
          default = disk-initos;
        };
      }
    );
}
