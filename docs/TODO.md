# Remaining work and ideas

## P0

- [] cleanup 
- [x] mount modules/firmware from rust, verify
- [] install script 
    - generate build system keys
    - sign
    - create vfat and 'state' img
    - create intaller img.
- [] user docs
- [x] uinput didn't get compiled in

## P1 

- [x] merge busybox and the scripts in the initrd
    - [x] if 'secure boot' disabled - run the dev script, else run the initos-init.sh ( merge -ver into the main script) and attempt to move all the steps into rust.
    - [x] also if STATE or any error - drop to shell (not in secure boot)

- [] update 'setup-deb' script to install 'deb+nix' - debian slim docker image plus nix package manager. Maybe move it to the dockerfile. 

- [] add FQDN of the mesh domain to sign.sh, default command.
    - test multiple DB keys, key rotation using 'auth' files.

## P2

When initrd is super stable: 

- [x] add a 3rd EFI option: plain kernel with cmdline/initrd built-in and not accepting further modifications or input, no more efi bootloader.
    - [ ] switch to the pure-linux, no stub boot, remove the others.

- [] script to convert docker images or bwrap rootfs to signed initos-erofs to boot
    - [] add ssh-mesh and mesh-init based rootfs

## P5

- [] build an aarch64 kernel and starter.
