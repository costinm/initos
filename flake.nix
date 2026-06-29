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
        bc
        binutils
        bison
        flex
        gnused
        efitools
        findutils
        fsverity-utils
        gnugrep
        gawk
        gnumake
        kmod
        mtools
        minisign
        limine
        openssh
        openssl
        perl
        sbsigntool
        stdenv.cc
        swtpm
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
        ] ++ [ initos efi pkgs.limine ];
      } ''
        export out="$out"
        export USE_BUSYBOX="${pkgs.pkgsStatic.busybox}/bin/busybox"
        export LIMINE_EFI="${pkgs.limine}/share/limine/BOOTX64.EFI"
        export INITOS_BIN="${initos}/bin/initos"
        export EFI_BIN="${efi}/bin/efi.efi"
        export KERNEL_DIR="${linuxFlake.packages.${system}.kernel-host}/opt/kernel-image"

        bash $src/scripts/build.sh build_initos
        bash $src/scripts/build.sh build_boot
        bash $src/scripts/build.sh build_bin

        # Move artifacts to the root of $out
        mv $out/artifacts/* $out/
        rmdir $out/artifacts
      '';

      directBootInitrd = pkgs.runCommand "initos-direct-boot-initrd" {
        src = ./.;
        nativeBuildInputs = with pkgs; [
          cpio gzip erofs-utils mtools makeWrapper
        ] ++ [ initos efi pkgs.limine ];
      } ''
        finalOut="$out"
        buildOut="$TMPDIR/initos-direct-boot-initrd-build"
        export out="$buildOut"
        export USE_BUSYBOX="${pkgs.pkgsStatic.busybox}/bin/busybox"
        export LIMINE_EFI="${pkgs.limine}/share/limine/BOOTX64.EFI"
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

      # ── Docker Image (runs signer) ──────────────────────────────────────

      docker-image = pkgs.dockerTools.buildLayeredImage {
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
      ];

      initos-host = pkgs.symlinkJoin {
        name = "initos-host";
        paths = [ linuxFlake.packages.${system}.nvidia-compute ] ++ hostRuntimeDeps;
        postBuild = ''
          test -d "$out/opt/kernel-image/nvidia-compute"
        '';
      };

    in
    {
      packages.${system} = {
        inherit initos efi initos-signer directBootInitrd linux-direct-efi kernel-host-direct-efi docker-image deps initos-host;
        default = initos-signer;
      };
    };
}
