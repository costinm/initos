{
  description = "initos — standalone kernel build";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
        };
      };

      lib = pkgs.lib;
      baseKernel = pkgs.linuxKernel.kernels.linux_6_18;
      src = ./.;
      branch = "6.18";

      configFragments = [
        "builtins.fragment"
        "filesystems.fragment"
        "crypto.fragment"
        "containers.fragment"
        "net.fragment"
        "block.fragment"
        "usb.fragment"
        "networking.fragment"
        "mods2.fragment"
        "efi.fragment"
        "host-lenovo.fragment"
        "cros/hatch.fragment"
        "host-chromeos.fragment"
        "tpm2.fragment"
        "display.fragment"
        "y-remove.fragment"
        "host-rust.fragment"
      ];

      mergeFragmentCommands = lib.concatMapStringsSep "\n" (fragment: ''
        "$kernelSrc/scripts/kconfig/merge_config.sh" -m -O "$buildRoot" "$buildRoot/.config" ${src}/${fragment}
      '') configFragments;

      mergedConfig = pkgs.runCommand "initos-kernel-host-config-${baseKernel.version}" {
        nativeBuildInputs = with pkgs; [
          bc
          bison
          flex
          gnumake
          openssl
          perl
          rust-bindgen-unwrapped
          rustc-unwrapped
          stdenv.cc
          xz
        ];
        RUST_LIB_SRC = pkgs.rustPlatform.rustLibSrc;
      } ''
        tar -xf ${baseKernel.src}
        kernelSrc="$PWD/linux-${baseKernel.version}"
        buildRoot="$PWD/build"
        mergeRoot="$PWD/merge"
        mkdir -p "$buildRoot" "$mergeRoot"

        install -m 0644 ${src}/${branch}/config.amd64 "$buildRoot/.config"
        cd "$mergeRoot"
        "$kernelSrc/scripts/kconfig/merge_config.sh" -m -O "$buildRoot" "$buildRoot/.config" ${src}/${branch}/config
        ${mergeFragmentCommands}

        make -C "$kernelSrc" O="$buildRoot" ARCH=x86 olddefconfig
        cp "$buildRoot/.config" "$out"
      '';

      kernel = pkgs.linuxKernel.manualConfig {
        pname = "initos-kernel-host";
        inherit (baseKernel) version src modDirVersion;
        configfile = mergedConfig;
        allowImportFromDerivation = true;
      };

      nvidiaOpen = (pkgs.linuxPackagesFor kernel).nvidiaPackages.stable.open;

      firmwarePackages = [
        pkgs.linux-firmware
        pkgs.sof-firmware
        pkgs.alsa-firmware
      ];

      firmwareCopyCommands = lib.concatMapStringsSep "\n" (pkg: ''
        if [ -d ${pkg}/lib/firmware ]; then
          chmod -R u+w "$firmwareRoot"
          cp -a ${pkg}/lib/firmware/. "$firmwareRoot/"
        fi
      '') firmwarePackages;

      kernel-host = pkgs.runCommand "initos-kernel-host" {
        nativeBuildInputs = [ pkgs.erofs-utils ];
        passthru = {
          inherit kernel mergedConfig nvidiaOpen firmwarePackages;
        };
      } ''
        mkdir -p "$out/opt/kernel-image"

        if [ -f ${kernel}/bzImage ]; then
          cp ${kernel}/bzImage "$out/opt/kernel-image/bzImage"
        elif [ -f ${kernel}/vmlinuz ]; then
          cp ${kernel}/vmlinuz "$out/opt/kernel-image/bzImage"
        else
          echo "ERROR: could not find built x86 kernel image in ${kernel}" >&2
          find ${kernel} -maxdepth 2 -type f >&2
          exit 1
        fi

        cp ${mergedConfig} "$out/opt/kernel-image/config"

        moduleDir=${kernel.modules}/lib/modules/${kernel.modDirVersion}
        nvidiaModuleDir=${nvidiaOpen}/lib/modules/${kernel.modDirVersion}
        if [ -d "$moduleDir" ]; then
          combined="$TMPDIR/modules-${kernel.modDirVersion}"
          mkdir -p "$combined"
          cp -a "$moduleDir/." "$combined/"
          chmod -R u+w "$combined"
          if [ -d "$nvidiaModuleDir" ]; then
            cp -a "$nvidiaModuleDir/." "$combined/"
          else
            echo "ERROR: NVIDIA open modules missing for ${kernel.modDirVersion}" >&2
            find ${nvidiaOpen} -maxdepth 4 -type f >&2
            exit 1
          fi
          (cd "$combined" && mkfs.erofs -zlz4 "$out/opt/kernel-image/modules-${kernel.modDirVersion}.erofs" .)
        fi

        firmwareRoot="$TMPDIR/firmware"
        mkdir -p "$firmwareRoot"
        ${firmwareCopyCommands}
        chmod -R u+w "$firmwareRoot"
        (cd "$firmwareRoot" && mkfs.erofs -zlz4 "$out/opt/kernel-image/firmware.erofs" .)

        echo "kernel-host:"
        ls -lh "$out/opt/kernel-image"
      '';

      # This is a 'pure data' image - no app inside, just the artifacts.
      # Same as a tar
      docker-image = pkgs.dockerTools.buildImage {
        name = "initos-kernel-host";
        tag = "latest";
        copyToRoot = [ kernel-host ];
        config = {
          WorkingDir = "/";
        };
      };

    in
    {
      packages.${system} = {
        inherit kernel-host docker-image;
        default = kernel-host;
      };
    };
}
