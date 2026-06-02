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
    "linux/cloud.fragment"
    "linux/virtio.fragment"
  ];

  mergeFragmentCommands = lib.concatMapStringsSep "\n" (fragment: ''
    "$kernelSrc/scripts/kconfig/merge_config.sh" -m -O "$buildRoot" "$buildRoot/.config" ${src}/${fragment}
  '') configFragments;

  mergedConfig = pkgs.runCommand "initos-kernel-cloud-config-${baseKernel.version}" {
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

    install -m 0644 ${src}/linux/${branch}/cloud/config.cloud-amd64 "$buildRoot/.config"
    cd "$mergeRoot"
    "$kernelSrc/scripts/kconfig/merge_config.sh" -m -O "$buildRoot" "$buildRoot/.config" ${src}/linux/${branch}/cloud/config.cloud
    ${mergeFragmentCommands}

    make -C "$kernelSrc" O="$buildRoot" ARCH=x86 olddefconfig
    cp "$buildRoot/.config" "$out"
  '';

  kernel = pkgs.linuxKernel.manualConfig {
    pname = "initos-kernel-cloud";
    inherit (baseKernel) version src modDirVersion;
    configfile = mergedConfig;
    allowImportFromDerivation = true;
  };
in
pkgs.runCommand "initos-kernel-cloud" {
  nativeBuildInputs = [ pkgs.erofs-utils ];
  passthru = {
    inherit kernel mergedConfig;
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
  if [ -d "$moduleDir" ]; then
    (cd "$moduleDir" && mkfs.erofs -zlz4 "$out/img/modules-${kernel.modDirVersion}.erofs" .)
  fi

  echo "kernel-cloud:"
  ls -lh "$out/img"
''
