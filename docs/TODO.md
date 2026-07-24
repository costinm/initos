# Remaining work and ideas

## P0

- [] depmod still doesn't work - need to be done in sign.sh
- [] nvidia firmware not installed
- [] need the nvidia binaries and deps to be packaged - most likely in a nix store on USB
- [] scripts to copy the store from docker image or 'admin' server to a target.

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

- []  update 'setup-deb' script to install 'deb+nix' - debian slim docker image plus nix OS. Systemd from NixOS, debian slim doesn't need systemd, included for extra compat and to install deb-only apps. 
  [ ] Remove Dockerfile, just Nix - too much effort for both and Dockerfile is less ...

- [] add FQDN of the mesh domain to sign.sh, default command.
    - test multiple DB keys, key rotation using 'auth' files.

- [] add a menu at the end, select amoung NixOS versions, pass to /nix/var/nix/profiles/system. Examples for changing regular to 'container' NixOS (may keep grub around for migration, both grub and InitOS should work the same).

- [] Use special partition number (9?) to load root from USB. Easy to create for install/recovery - simplest code, no more params. Also switch boot to 1,2(mod 10), 'state' to 3(mod 10) on same disk by default.  

## P2

When initrd is super stable: 

- [x] add a 3rd EFI option: plain kernel with cmdline/initrd built-in and not accepting further modifications or input, no more efi bootloader.
    - [ ] switch to the pure-linux, no stub boot, remove the others.

- [] script to convert docker images, nixos containers or bwrap rootfs to signed initos-erofs to boot
    - [] add ssh-mesh and mesh-init based rootfs

- [] experiment: build/sign everything with an ephemeral key on the build server.
Sign it on a trusted machine with the KEK and verify it can be automatically rotated (added, later removed) using the 'auth' files. The key can also be per-host or per-host-groups - still short lived and private only on build server.

- message: entering key wrong 3 times (or entering 'debug' ?) will drop to a shell
before switch_root, in dev mode.

- cleanup unused files, reorg fragments

- switch to 7.x kernels

- stop using limine (keep the signing code for reference)

- Restore the old idea of creating a /run/initos/ containing info from initrd - boot timing
is visible in kmsg, but EFI partition used, STATE, secure mode.

## P5

- [] build an aarch64 kernel and starter.

- [] move images to [STATE]/initos/img/{1,2} (partition mod 10). Add a manifest to kernel images (version, build date, name).