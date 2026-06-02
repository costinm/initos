{ pkgs, src, branch ? "6.18" }:

let
  lib = pkgs.lib;
  baseKernel = pkgs.linuxKernel.kernels.linux_6_18;

  configFragments = [
    "linux/builtins.fragment"
    "linux/filesystems.fragment"
    "linux/crypto.fragment"
    "linux/containers.fragment"
    "linux/net.fragment"
    "linux/block.fragment"
    "linux/usb.fragment"
    "linux/networking.fragment"
    "linux/mods2.fragment"
    "linux/efi.fragment"
    "linux/host-lenovo.fragment"
    "linux/cros/hatch.fragment"
    "linux/host-chromeos.fragment"
    "linux/tpm2.fragment"
    "linux/display.fragment"
    "linux/y-remove.fragment"
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
      stdenv.cc
      xz
    ];
  } ''
    tar -xf ${baseKernel.src}
    kernelSrc="$PWD/linux-${baseKernel.version}"
    buildRoot="$PWD/build"
    mergeRoot="$PWD/merge"
    mkdir -p "$buildRoot" "$mergeRoot"

    install -m 0644 ${src}/linux/${branch}/config.amd64 "$buildRoot/.config"
    cd "$mergeRoot"
    "$kernelSrc/scripts/kconfig/merge_config.sh" -m -O "$buildRoot" "$buildRoot/.config" ${src}/linux/${branch}/config
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
in
pkgs.runCommand "initos-kernel-host" {
  nativeBuildInputs = [ pkgs.erofs-utils ];
  passthru = {
    inherit kernel mergedConfig nvidiaOpen firmwarePackages;
  };
} ''
  mkdir -p "$out/img"

  if [ -f ${kernel}/bzImage ]; then
    cp ${kernel}/bzImage "$out/img/bzImage"
  elif [ -f ${kernel}/vmlinuz ]; then
    cp ${kernel}/vmlinuz "$out/img/bzImage"
  else
    echo "ERROR: could not find built x86 kernel image in ${kernel}" >&2
    find ${kernel} -maxdepth 2 -type f >&2
    exit 1
  fi

  cp ${mergedConfig} "$out/img/config"

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
    (cd "$combined" && mkfs.erofs -zlz4 "$out/img/modules-${kernel.modDirVersion}.erofs" .)
  fi

  firmwareRoot="$TMPDIR/firmware"
  mkdir -p "$firmwareRoot"
  ${firmwareCopyCommands}
  chmod -R u+w "$firmwareRoot"
  (cd "$firmwareRoot" && mkfs.erofs -zlz4 "$out/img/firmware.erofs" .)

  echo "kernel-host:"
  ls -lh "$out/img"
''
