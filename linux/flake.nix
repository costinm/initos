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
      kernelPatchFiles = [
        ./patches/module-signing-use-platform-keyring.patch
      ];
      applyKernelPatchCommands = lib.concatMapStringsSep "\n" (patchFile: ''
        patch -p1 < ${patchFile}
      '') kernelPatchFiles;

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

      kernelBase = pkgs.linuxKernel.manualConfig {
        pname = "initos-kernel-host";
        inherit (baseKernel) version src modDirVersion;
        configfile = mergedConfig;
        allowImportFromDerivation = true;
      };
      kernel = kernelBase.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ kernelPatchFiles;
      });

      nvidiaPackage = (pkgs.linuxPackagesFor kernel).nvidiaPackages.stable;
      nvidiaOpen = nvidiaPackage.open.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.removeReferencesTo ];
        postFixup = (old.postFixup or "") + ''
          find "$out" -type f -name '*.ko' -exec remove-references-to -t ${kernel.dev} '{}' +
        '';
      });

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

      mkMergedConfigWithExtra = { packageName, extraConfigText ? "" }:
        let
          extraConfigFile = pkgs.writeText "${packageName}-extra.config" extraConfigText;
        in
        pkgs.runCommand "${packageName}-config-${baseKernel.version}" {
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
          ${lib.optionalString (extraConfigText != "") ''
            "$kernelSrc/scripts/kconfig/merge_config.sh" -m -O "$buildRoot" "$buildRoot/.config" ${extraConfigFile}
          ''}

          make -C "$kernelSrc" O="$buildRoot" ARCH=x86 olddefconfig
          cp "$buildRoot/.config" "$out"
        '';

      mkPatchedKernel = { packageName, configfile }:
        let
          kernelBaseForConfig = pkgs.linuxKernel.manualConfig {
            pname = packageName;
            inherit (baseKernel) version src modDirVersion;
            inherit configfile;
            allowImportFromDerivation = true;
          };
        in
        kernelBaseForConfig.overrideAttrs (old: {
          patches = (old.patches or [ ]) ++ kernelPatchFiles;
        });

      mkNvidiaPackage = kernelForModules:
        (pkgs.linuxPackagesFor kernelForModules).nvidiaPackages.stable;

      mkNvidiaOpen = kernelForModules:
        (mkNvidiaPackage kernelForModules).open.overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.removeReferencesTo ];
          postFixup = (old.postFixup or "") + ''
            find "$out" -type f -name '*.ko' -exec remove-references-to -t ${kernelForModules.dev} '{}' +
          '';
        });

      mkKernelHostPackage = { packageName, kernel, configfile, nvidiaPackage, nvidiaOpen, outputDir ? "kernel-image" }:
        pkgs.runCommand packageName {
          nativeBuildInputs = [ pkgs.erofs-utils pkgs.kmod ];
          passthru = {
            mergedConfig = configfile;
            inherit kernel nvidiaPackage nvidiaOpen firmwarePackages;
          };
        } ''
          imageOut="$out/opt/${outputDir}"
          mkdir -p "$imageOut"

          if [ -f ${kernel}/bzImage ]; then
            cp ${kernel}/bzImage "$imageOut/bzImage"
          elif [ -f ${kernel}/vmlinuz ]; then
            cp ${kernel}/vmlinuz "$imageOut/bzImage"
          else
            echo "ERROR: could not find built x86 kernel image in ${kernel}" >&2
            find ${kernel} -maxdepth 2 -type f >&2
            exit 1
          fi

          cp ${configfile} "$imageOut/config"
          cp ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build/scripts/sign-file "$imageOut/sign-file"

          moduleDir=${kernel.modules}/lib/modules/${kernel.modDirVersion}
          nvidiaModuleDir=${nvidiaOpen}/lib/modules/${kernel.modDirVersion}
          if [ -d "$moduleDir" ]; then
            moduleRoot="$TMPDIR/module-root"
            combined="$moduleRoot/lib/modules/${kernel.modDirVersion}"
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
            depmod -b "$moduleRoot" ${kernel.modDirVersion}
            cp -a "$combined" "$imageOut/modules-${kernel.modDirVersion}"
          fi

          nvidiaCompute="$imageOut/nvidia-compute"
          mkdir -p "$nvidiaCompute/bin" "$nvidiaCompute/lib"
          for bin in \
            nvidia-cuda-mps-control \
            nvidia-cuda-mps-server \
            nvidia-smi
          do
            if [ -e "${nvidiaPackage.bin}/bin/$bin" ]; then
              cp -a "${nvidiaPackage.bin}/bin/$bin" "$nvidiaCompute/bin/"
            fi
          done
          for libPattern in \
            'libcuda.so*' \
            'libcudadebugger.so*' \
            'libnvcuvid.so*' \
            'libnvidia-allocator.so*' \
            'libnvidia-cfg.so*' \
            'libnvidia-encode.so*' \
            'libnvidia-fbc.so*' \
            'libnvidia-ml.so*' \
            'libnvidia-ngx.so*' \
            'libnvidia-nvvm.so*' \
            'libnvidia-nvvm70.so*' \
            'libnvidia-opticalflow.so*' \
            'libnvidia-ptxjitcompiler.so*'
          do
            find ${nvidiaPackage.out}/lib -maxdepth 1 \( -type f -o -type l \) -name "$libPattern" \
              -exec cp -a '{}' "$nvidiaCompute/lib/" \;
          done
          printf '%s\n' '${nvidiaPackage.version}' > "$imageOut/nvidia-version"

          firmwareRoot="$TMPDIR/firmware"
          mkdir -p "$firmwareRoot"
          ${firmwareCopyCommands}
          chmod -R u+w "$firmwareRoot"
          (cd "$firmwareRoot" && mkfs.erofs -zlz4 "$imageOut/firmware.erofs" .)

          echo "${packageName}:"
          ls -lh "$imageOut"
        '';

      mkKernelHostWithExtraConfig = { packageName ? "initos-kernel-host-extra", extraConfigText ? "", outputDir ? "kernel-image" }:
        let
          configfile = mkMergedConfigWithExtra { inherit packageName extraConfigText; };
          kernelForConfig = mkPatchedKernel { inherit packageName configfile; };
          nvidiaPackageForConfig = mkNvidiaPackage kernelForConfig;
          nvidiaOpenForConfig = mkNvidiaOpen kernelForConfig;
        in
        mkKernelHostPackage {
          inherit packageName configfile outputDir;
          kernel = kernelForConfig;
          nvidiaPackage = nvidiaPackageForConfig;
          nvidiaOpen = nvidiaOpenForConfig;
        };

      nvidia-compute =
        let
          nvidiaUserspace = pkgs.linuxPackages.nvidiaPackages.stable;
        in
        assert lib.assertMsg (nvidiaUserspace.version == nvidiaPackage.version)
          "nvidia-compute userspace version ${nvidiaUserspace.version} does not match kernel NVIDIA version ${nvidiaPackage.version}";
        pkgs.runCommand "initos-nvidia-compute" { } ''
          imageOut="$out/opt/kernel-image"
          nvidiaCompute="$imageOut/nvidia-compute"
          mkdir -p "$nvidiaCompute/bin" "$nvidiaCompute/lib"
          for bin in \
            nvidia-cuda-mps-control \
            nvidia-cuda-mps-server \
            nvidia-smi
          do
            if [ -e "${nvidiaUserspace.bin}/bin/$bin" ]; then
              cp -a "${nvidiaUserspace.bin}/bin/$bin" "$nvidiaCompute/bin/"
            fi
          done
          for libPattern in \
            'libcuda.so*' \
            'libcudadebugger.so*' \
            'libnvcuvid.so*' \
            'libnvidia-allocator.so*' \
            'libnvidia-cfg.so*' \
            'libnvidia-encode.so*' \
            'libnvidia-fbc.so*' \
            'libnvidia-ml.so*' \
            'libnvidia-ngx.so*' \
            'libnvidia-nvvm.so*' \
            'libnvidia-nvvm70.so*' \
            'libnvidia-opticalflow.so*' \
            'libnvidia-ptxjitcompiler.so*'
          do
            find ${nvidiaUserspace.out}/lib -maxdepth 1 \( -type f -o -type l \) -name "$libPattern" \
              -exec cp -a '{}' "$nvidiaCompute/lib/" \;
          done
          printf '%s\n' '${nvidiaUserspace.version}' > "$imageOut/nvidia-version"
          test -e "$nvidiaCompute/bin/nvidia-smi"
          test -e "$nvidiaCompute/lib/libcuda.so"
        '';

      kernel-host = (mkKernelHostPackage {
        packageName = "initos-kernel-host";
        configfile = mergedConfig;
        inherit kernel nvidiaPackage nvidiaOpen;
      }).overrideAttrs (old: {
        passthru = (old.passthru or { }) // {
          inherit mkKernelHostWithExtraConfig;
        };
      });

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
        inherit kernel-host docker-image nvidia-compute;
        default = kernel-host;
      };
    };
}
