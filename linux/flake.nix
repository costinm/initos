{
  description = "initos — standalone kernel build";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };

        kernel-host-raw = import ./kernel-host.nix {
          inherit pkgs;
          src = ./.;
        };
      in
      {
        packages = rec {
          kernel-host = pkgs.runCommand "initos-kernel-host-restructured" { } ''
            mkdir -p $out/boot/EFI/BOOT $out/img
            
            # Copy bzImage to boot/EFI/BOOT/bzImage
            if [ -f ${kernel-host-raw}/img/bzImage ]; then
              cp ${kernel-host-raw}/img/bzImage $out/boot/EFI/BOOT/bzImage
            fi
            
            # Copy modules and firmware EROFS to img/
            for f in ${kernel-host-raw}/img/modules-*.erofs; do
              [ -f "$f" ] && cp "$f" $out/img/
            done
            if [ -f ${kernel-host-raw}/img/firmware.erofs ]; then
              cp ${kernel-host-raw}/img/firmware.erofs $out/img/
            fi
          '';
          default = kernel-host;
        };
      }
    );
}
