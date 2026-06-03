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
        kernelConfigSrc = pkgs.lib.cleanSource ./linux;

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

        # ── Kernel artifacts ───────────────────────────────────────────────

        kernel-cloud = import ./linux/kernel-cloud.nix {
          inherit pkgs;
          src = kernelConfigSrc;
        };

        kernel-host = import ./linux/kernel-host.nix {
          inherit pkgs;
          src = kernelConfigSrc;
        };

        # Firmware: pack pkgs.linux-firmware into a single erofs image.
        # Pure derivation — always reproducible from the nixpkgs linux-firmware.
        firmware-erofs = pkgs.runCommand "firmware-erofs" {
          nativeBuildInputs = [ pkgs.erofs-utils ];
        } ''
          mkdir -p $out/img

          if [ -d "${pkgs.linux-firmware}/lib/firmware" ]; then
            FW_SRC="${pkgs.linux-firmware}/lib/firmware"
          elif [ -d "${pkgs.linux-firmware}" ]; then
            FW_SRC="${pkgs.linux-firmware}"
          else
            echo "ERROR: linux-firmware not found at expected path" >&2
            exit 1
          fi

          FW_SIZE=$(du -sh "$FW_SRC" | cut -f1)
          echo "Packing firmware ($FW_SIZE) into erofs..."
          mkfs.erofs -zlz4 "$out/img/firmware.erofs" "$FW_SRC"

          echo "firmware-erofs:"
          ls -lh $out/img/
        '';

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

        mkInitosArtifacts = { withKernels ? false }:
        pkgs.runCommand (if withKernels then "initos-artifacts-with-kernels" else "initos-artifacts") {
          nativeBuildInputs = with pkgs; [
            cpio gzip erofs-utils mtools openssl sbsigntool
          ] ++ [ initos efi ]
            ++ pkgs.lib.optionals withKernels [ kernel-cloud kernel-host firmware-erofs ];
        } ''
          USE_BUSYBOX=${pkgs.pkgsStatic.busybox}/bin/busybox

          # Repo source (read-only nix store path)
          CARGO_TOML=${./Cargo.toml}
          SIDECAR_BIN=${./sidecar/bin}
          SCRIPTS_DIR=${./scripts}
          PREBUILT_DIR=${./prebuilt}

          # Build in temp dir
          WRITABLE="$TMPDIR/build"
          mkdir -p "$WRITABLE"/{prebuilt/boot/EFI/BOOT,prebuilt/testdata,prebuilt/bin,sidecar/bin}

          ln -sf "$PREBUILT_DIR/boot/EFI/BOOT/bzImage" "$WRITABLE/prebuilt/boot/EFI/BOOT/bzImage"
          ln -sf "$PREBUILT_DIR/boot/EFI/BOOT/BOOTX64.EFI" "$WRITABLE/prebuilt/boot/EFI/BOOT/BOOTX64.EFI"
          ln -sf "$PREBUILT_DIR/boot/EFI/BOOT/limine.conf" "$WRITABLE/prebuilt/boot/EFI/BOOT/limine.conf"
          cp -R "$PREBUILT_DIR/testdata/." "$WRITABLE/prebuilt/testdata/"
          ln -sf "$SCRIPTS_DIR" "$WRITABLE/scripts"

          cp -R "$SIDECAR_BIN/." "$WRITABLE/sidecar/bin/"
          chmod 755 "$WRITABLE/sidecar/bin/"*
          cp "$CARGO_TOML" "$WRITABLE/Cargo.toml"

          BUILD_SRC="$WRITABLE"
          BUILD_OUT="$WRITABLE/target"
          mkdir -p "$BUILD_OUT"/{disks/state/img,disks/boot/EFI/BOOT,test/img}

          mkdir -p "$BUILD_OUT"/x86_64-unknown-linux-musl/release
          cp ${initos}/bin/initos "$BUILD_OUT/x86_64-unknown-linux-musl/release/initos"
          mkdir -p "$BUILD_OUT"/x86_64-unknown-uefi/release
          cp ${efi}/bin/efi.efi "$BUILD_OUT/x86_64-unknown-uefi/release/efi.efi"
          cp $USE_BUSYBOX "$WRITABLE/prebuilt/bin/busybox"

          # Run build.sh functions — must call individually ( "$@" dispatches only the first)
          export IMG_DIR="$BUILD_OUT/disks/state/img"
          for fn in build_initos build_initrd build_boot_initos_unsigned; do
            echo "=== build.sh $fn ==="
            src="$BUILD_SRC" out="$BUILD_OUT" \
              bash "$BUILD_SRC/scripts/build.sh" "$fn" 2>&1
          done
          echo "=== All build.sh functions complete ==="

          # ── Assemble into $out ──
          mkdir -p "$out"/img "$out"/bin "$out"/boot

          # initos rootfs
          if [ -f "$BUILD_OUT/disks/state/img/initos.erofs" ]; then
            cp "$BUILD_OUT/disks/state/img/initos.erofs" "$out"/img/initos.erofs
          fi

          # Expanded rootfs tool directories used to inspect or repackage
          # the unsigned artifact output without unpacking initos.erofs.
          mkdir -p "$out"/opt
          cp -R "$BUILD_OUT/disks/initos/opt/busybox" "$out"/opt/
          cp -R "$BUILD_OUT/disks/initos/opt/initos" "$out"/opt/

          # Expanded unsigned EFI System Partition content. Site-specific
          # signatures and FAT images are generated later by bin/sign.sh.
          cp -R "$BUILD_OUT/disks/boot/." "$out"/boot/

          # Kernel staged in boot/
          if [ -f "$WRITABLE/prebuilt/boot/EFI/BOOT/bzImage" ]; then
            cp "$WRITABLE/prebuilt/boot/EFI/BOOT/bzImage" "$out"/img/bzImage-cloud
          fi

          ${pkgs.lib.optionalString withKernels ''
          # Cloud kernel
          if [ -f ${kernel-cloud}/img/vmlinux ]; then
            cp ${kernel-cloud}/img/vmlinux "$out"/img/vmlinux-cloud
          fi
          if [ -f ${kernel-cloud}/img/bzImage ]; then
            cp ${kernel-cloud}/img/bzImage "$out"/img/vmlinuz-cloud
          fi
          for m in ${kernel-cloud}/img/modules-*.erofs; do
            [ -f "$m" ] && cp "$m" "$out"/img/modules-cloud.erofs
          done

          # Host kernel
          if [ -f ${kernel-host}/img/bzImage ]; then
            cp ${kernel-host}/img/bzImage "$out"/img/vmlinuz-host
          fi
          for m in ${kernel-host}/img/modules-*.erofs; do
            [ -f "$m" ] && cp "$m" "$out"/img/modules-host.erofs
          done

          # Firmware
          if [ -f ${firmware-erofs}/img/firmware.erofs ]; then
            cp ${firmware-erofs}/img/firmware.erofs "$out"/img/firmware.erofs
          fi
          ''}

          # bin/
          cp ${initos}/bin/initos "$out"/bin/initos
          cp ${efi}/bin/efi.efi "$out"/bin/efi.efi
          cp ${efi}/bin/BOOTX64.EFI "$out"/bin/BOOTX64.EFI 2>/dev/null || true
          cp ${./scripts/sign.sh} "$out"/bin/sign.sh.lib
          printf '%s\n' \
            '#!${pkgs.runtimeShell}' \
            'export PATH="${signRuntimePath}:$PATH"' \
            "exec \"$out/bin/sign.sh.lib\" \"\$@\"" \
            > "$out"/bin/sign.sh
          chmod 755 "$out"/bin/*

          if find "$out" -type f \( -name '*.sig' -o -name '*signed*.img' \) | grep -q .; then
            echo "ERROR: unsigned artifact output contains signed artifacts" >&2
            find "$out" -type f \( -name '*.sig' -o -name '*signed*.img' \) >&2
            exit 1
          fi

          echo "initos-artifacts:"
          find "$out" -type f | sort | sed "s|$out/|  |"
        '';

        initos-artifacts = mkInitosArtifacts { };
        initos-artifacts-with-kernels = mkInitosArtifacts { withKernels = true; };

        vm-cloud-profile = pkgs.runCommand "initos-vm-cloud-profile" { } ''
          mkdir -p "$out"/{bin,boot,img}

          ln -s ${initos-artifacts}/img/initos.erofs "$out/img/initos.erofs"
          ln -s ${initos-artifacts}/boot/EFI/BOOT/initrd.img "$out/boot/initrd.img"
          ln -s ${kernel-cloud}/img/vmlinux "$out/img/vmlinux-cloud"
          ln -s ${initos-artifacts}/opt "$out/opt"

          for m in ${kernel-cloud}/img/modules-*.erofs; do
            if [ -f "$m" ]; then
              ln -s "$m" "$out/img/modules-cloud.erofs"
            fi
          done

          ln -s ${pkgs.cloud-hypervisor}/bin/cloud-hypervisor "$out/bin/cloud-hypervisor"
          ln -s ${pkgs.cloud-hypervisor}/bin/ch-remote "$out/bin/ch-remote"
          ln -s ${pkgs.virtiofsd}/bin/virtiofsd "$out/bin/virtiofsd"
          ln -s ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "$out/bin/qemu-system-x86_64"
          ln -s ${pkgs.crosvm}/bin/crosvm "$out/bin/crosvm"
          ln -s ${pkgs.socat}/bin/socat "$out/bin/socat"
          ln -s ${./sidecar/bin/vrun} "$out/bin/vrun"

          cat > "$out/bin/initos-vrun" <<EOF
#!${pkgs.runtimeShell}
export VIRT="\''${VIRT:-$out}"
export PATH="$out/bin:\$PATH"
exec "$out/bin/vrun" "\$@"
EOF
          chmod 755 "$out/bin/initos-vrun"

          cat > "$out/README" <<EOF
          initos VM cloud profile

          Important paths:
            $out/img/initos.erofs
            $out/img/vmlinux-cloud
            $out/img/modules-cloud.erofs
            $out/boot/initrd.img
            $out/opt

          sidecar/bin/vrun-compatible entrypoint:
            $out/bin/initos-vrun
          EOF
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
          inherit initos efi kernel-cloud kernel-host firmware-erofs
                  initos-artifacts initos-artifacts-with-kernels
                  vm-cloud-profile
                  docker-image oci-cache-image;
          default = initos-artifacts;
        };

        apps = {
          vm-cloud = {
            type = "app";
            program = "${vm-cloud-profile}/bin/initos-vrun";
          };
        };
      }
    );
}
