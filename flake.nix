{
  description = "initos — verified boot + mesh-init artifacts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    flake-utils.url = "github:numtide/flake-utils";
    ssh-mesh = {
      url = "github:costinm/ssh-mesh";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, rust-overlay, crane, flake-utils, ssh-mesh }:
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
        diffutils
        erofs-utils
        gnused
        efitools
        findutils
        fsverity-utils
        gnugrep
        gawk
        kmod
        mtools
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
      gpuFlake = (import ./sidecar/gpu/flake.nix).outputs {
        self = ./sidecar/gpu;
        inherit nixpkgs;
      };
      vmFlake = (import ./vm/flake.nix).outputs {
        self = ./vm;
        inherit nixpkgs flake-utils;
      };
      sshMesh = ssh-mesh.packages.${system}.default;
      gpu = gpuFlake.packages.${system}.default;
      vm = pkgs.symlinkJoin {
        name = "initos-vm";
        paths = with vmFlake.packages.${system}; [ kernel-cloud vm-tools vm-scripts ];
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
        bash $src/scripts/build.sh build_initrd
        bash $src/scripts/build.sh build_bin

        # The signer owns only the unsigned InitOS/EFI inputs.  The kernel,
        # including bzImage, modules, composefs metadata, and NVIDIA, belongs exclusively
        # to kernel-host.  Do not leave build staging in the package output.
        mkdir -p "$out/img"
        mv "$out/artifacts/img/initos.erofs" "$out/img/"
        mv "$out/artifacts/boot/EFI/BOOT/initrd.img" "$out/img/"
        cp "$EFI_BIN" "$out/img/initos.EFI"
        mv "$out/artifacts/bin" "$out/bin"
        rm -rf "$out/artifacts" "$out/staging"

        # Wrap sign.sh so it finds all runtime tools when invoked from a nix profile
        wrapProgram $out/bin/sign.sh \
          --prefix PATH : "${signRuntimePath}"
      '';

      directBootInitrd = pkgs.runCommand "initos-direct-boot-initrd" {
        src = ./.;
        nativeBuildInputs = with pkgs; [
          cpio gzip erofs-utils mtools makeWrapper
        ] ++ [ initos efi ];
      } ''
        finalOut="$out"
        buildOut="$TMPDIR/initos-direct-boot-initrd-build"
        export out="$buildOut"
        export USE_BUSYBOX="${pkgs.pkgsStatic.busybox}/bin/busybox"
        export INITOS_BIN="${initos}/bin/initos"
        export EFI_BIN="${efi}/bin/efi.efi"
        export KERNEL_DIR="${linuxFlake.packages.${system}.kernel-host}/opt/kernel-image"

        bash $src/scripts/build.sh build_initrd

        mkdir -p "$finalOut"
        cp "$buildOut/artifacts/boot/EFI/BOOT/initrd.img" "$finalOut/initrd.cpio.gz"
      '';

      directBootCmdline =
        "rdinit=/init console=tty1 console=ttyS0,115200 console=hvc0 loglevel=6 net.ifnames=0 panic=5";

      linux-direct-efi =
        linuxFlake.packages.${system}.kernel-host.passthru.mkKernelHostWithExtraConfig {
          packageName = "initos-linux-direct-efi";
          outputDir = "linux-direct-efi";
          extraConfigText = ''
            CONFIG_INITRAMFS_SOURCE="${directBootInitrd}/initrd.cpio.gz"
            CONFIG_INITRAMFS_COMPRESSION_NONE=y
            # CONFIG_INITRAMFS_COMPRESSION_GZIP is not set
            CONFIG_CMDLINE_BOOL=y
            CONFIG_CMDLINE="${directBootCmdline}"
            CONFIG_CMDLINE_OVERRIDE=y
          '';
        };
      kernel-host-direct-efi = linux-direct-efi;

      usrBinEnv = pkgs.runCommand "usr-bin-env" {} ''
        mkdir -p $out/usr/bin
        ln -s ${pkgs.coreutils}/bin/env $out/usr/bin/env
      '';

      tmpDir = pkgs.runCommand "tmp-dir" {} ''
        mkdir -p $out/tmp
        chmod 1777 $out/tmp
      '';

      # ── Docker images ───────────────────────────────────────────────────

      # Signing executable, unsigned initrd/boot inputs, and signing tools.
      # Kernel artifacts are intentionally excluded so this image can be
      # updated independently from the kernel/NVIDIA payload.
      docker-signer-tools-image = pkgs.dockerTools.buildLayeredImage {
        name = "initos-signer-tools";
        tag = "latest";
        contents = [ initos-signer pkgs.coreutils usrBinEnv pkgs.bash tmpDir ] ++ signRuntimeDeps;
        config = {
          Entrypoint = [ "/bin/sign.sh" ];
          Env = [ "PATH=/bin" ];
          WorkingDir = "/";
        };
      };

      # Build artifacts matched as one unit: kernel, unpacked modules,
      # composefs firmware metadata, sign-file, and NVIDIA compute userspace under
      # /opt/kernel-image. No signer scripts or signing runtime tools.
      docker-kernel-artifacts-image = pkgs.dockerTools.buildLayeredImage {
        name = "initos-kernel-artifacts";
        tag = "latest";
        contents = [ linuxFlake.packages.${system}.kernel-host ];
        config = {
          WorkingDir = "/";
        };
      };

      # Compatibility image for workflows that still need both halves.
      docker-signer-kernel-image = pkgs.dockerTools.buildLayeredImage {
        name = "initos-signer";
        tag = "latest";
        contents = [ initos-signer pkgs.coreutils usrBinEnv pkgs.bash tmpDir linuxFlake.packages.${system}.kernel-host ] ++ signRuntimeDeps;
        config = {
          Entrypoint = [ "/bin/sign.sh" ];
          Env = [ "PATH=/bin" ];
          WorkingDir = "/";
        };
      };

      deps = pkgs.symlinkJoin {
        name = "initos-deps";
        paths = signRuntimeDeps;
      };

      hostRuntimeDeps = with pkgs; [
        bash
        bash-completion
        bind
        bridge-utils
        btrfs-progs
        bubblewrap
        cacert
        coreutils
        curl
        dig
        dosfstools
        e2fsprogs
        e2tools
        efibootmgr
        erofs-utils
        ethtool
        file
        findutils
        fsverity-utils
        fuse-overlayfs
        fuse3
        genext2fs
        git
        gnupg
        gptfdisk
        hdparm
        i2c-tools
        inetutils
        iperf3
        iproute2
        iptables
        iputils
        iw
        kmod
        less
        lsof
        mc
        minisign
        mtools
        nettools
        nftables
        nix
        openssh
        openssl
        pciutils
        radvd
        rsync
        sbsigntool
        tini
        tmux
        unzip
        usbutils
        util-linux
        vim
        wget
        wpa_supplicant
        sshMesh
      ];

      initos-host = pkgs.symlinkJoin {
        name = "initos-host";
        # Host tooling intentionally excludes kernel-coupled userspace.  The
        # matching NVIDIA compute payload is packaged by kernel-host under
        # /opt/kernel-image/nvidia-compute and ships with the signer-kernel
        # image so driver modules and userspace upgrade together.  Signing
        # tools are generic host capabilities and are included here without
        # their kernel or NVIDIA inputs.
        paths = hostRuntimeDeps ++ signRuntimeDeps;
      };

      # Package roots copied into a Docker image do not include the Nix store
      # registration database.  Keep closure metadata alongside /result so
      # sign.sh can register the image's store paths in a temporary source DB
      # before copying them to a daemon or fresh chroot store.
      initos-host-closure = pkgs.closureInfo {
        rootPaths = [ initos-host ];
      };

      host-runtime-root = pkgs.runCommand "initos-host-runtime-root" { } ''
        mkdir -p "$out"
        ln -s ${initos-host} "$out/result"
        ln -s ${initos-host-closure} "$out/result-closure"
        printf '%s\n' '${initos-host}' > "$out/result-path"
      '';

      docker-host-runtime-image = pkgs.dockerTools.buildLayeredImage {
        name = "initos-host-runtime";
        tag = "latest";
        contents = [ host-runtime-root ];
        config = {
          WorkingDir = "/";
        };
      };

      # The workflow image transfers the generic host package set together with
      # NVIDIA compute userspace stays distinct from the standalone host-runtime
      # image: it is available when a workflow image upgrades a host, while
      # the CUDA llama.cpp profile remains an explicit optional `.#gpu` package.
      initos-host-with-nvidia = pkgs.symlinkJoin {
        name = "initos-host-with-nvidia";
        paths = [ initos-host linuxFlake.packages.${system}.nvidia-compute ];
      };

      initos-host-with-nvidia-closure = pkgs.closureInfo {
        rootPaths = [ initos-host-with-nvidia ];
      };

      workflow-runtime-root = pkgs.runCommand "initos-workflow-runtime-root" { } ''
        mkdir -p "$out"
        ln -s ${initos-host-with-nvidia} "$out/result"
        ln -s ${initos-host-with-nvidia-closure} "$out/result-closure"
        printf '%s\n' '${initos-host-with-nvidia}' > "$out/result-path"
      '';

      # Retain the original all-in-one workflow image, but make the smaller
      # signer and host-runtime images independently selectable and measurable.
      docker-image = pkgs.dockerTools.buildLayeredImage {
        # Keep this tag aligned with the published GHCR workflow.
        name = "initos-signer";
        tag = "latest";
        contents = [ initos-signer pkgs.coreutils usrBinEnv pkgs.bash tmpDir linuxFlake.packages.${system}.kernel-host workflow-runtime-root ] ++ signRuntimeDeps;
        config = {
          Entrypoint = [ "/bin/sign.sh" ];
          Env = [ "PATH=/bin" ];
          WorkingDir = "/";
        };
      };

    in
    {
      packages.${system} = {
        inherit initos efi initos-signer directBootInitrd linux-direct-efi kernel-host-direct-efi docker-image docker-signer-tools-image docker-kernel-artifacts-image docker-signer-kernel-image docker-host-runtime-image deps initos-host initos-host-with-nvidia gpu vm;
        default = initos-signer;
      };
    };
}
