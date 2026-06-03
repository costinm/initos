{
  description = "initos microvm echo test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    microvm.url = "github:microvm-nix/microvm.nix";
    initosProfile = {
      url = "path:./empty-profile";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, microvm, initosProfile }:
  let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    kernel = pkgs.runCommand "initos-microvm-kernel" { } ''
      mkdir -p "$out"
      ln -s "${initosProfile}/img/vmlinuz-cloud" "$out/${pkgs.stdenv.hostPlatform.linux-kernel.target}"
    '';
    emptyToplevel = pkgs.runCommand "initos-microvm-empty-toplevel" { } "mkdir -p $out";
    microvmConfig = rec {
      hostName = "initos-microvm";
      hypervisor = "qemu";
      vmHostPackages = pkgs;
      inherit kernel;
      initrdPath = "${initosProfile}/boot/initrd.img";
      vcpu = 1;
      mem = 512;
      balloon = false;
      initialBalloonMem = 0;
      deflateOnOOM = true;
      hotplugMem = 0;
      hotpluggedMem = 0;
      user = null;
      cpu = null;
      interfaces = [];
      forwardPorts = [];
      devices = [];
      shares = [
        {
          proto = "9p";
          tag = "src";
          source = "../../target/vm/microvm-echo/share";
          mountPoint = "/src";
          securityModel = "mapped";
          readOnly = false;
          socket = null;
          cache = "auto";
        }
      ];
      volumes = [
        {
          image = "${initosProfile}/img/initos.erofs";
          serial = null;
          direct = false;
          readOnly = true;
          label = null;
          mountPoint = null;
          size = 0;
          autoCreate = false;
          mkfsExtraArgs = [];
          fsType = "ext4";
          imageType = "raw";
        }
      ];
      socket = null;
      vsock = { cid = null; };
      graphics = {
        enable = false;
        backend = "gtk";
        socket = "initos-microvm-gpu.sock";
      };
      storeOnDisk = false;
      storeDisk = "";
      credentialFiles = {};
      qemu = {
        machine = "q35";
        machineOpts = null;
        extraArgs = [];
        serialConsole = true;
        pcieRootPorts = [];
        package = pkgs.qemu_kvm;
      };
      optimize.enable = true;
      prettyProcnames = true;
      registerWithMachined = false;
      machineId = null;
      preStart = "";
      extraArgsScript = null;
      binScripts = {};
      systemSymlink = false;
      kernelParams = [
        "root=/dev/vda"
        "rootfstype=erofs"
        "rootwait"
        "init=/opt/initos/bin/initos-init-vm"
        "net.ifnames=0"
        "initos_host=initos-microvm"
      ];
    };
  in {
    packages.${system} = rec {
      runner = microvm.lib.buildRunner {
        inherit pkgs;
        microvmConfig = microvmConfig;
        toplevel = emptyToplevel;
      };
      default = runner;
    };
  };
}
