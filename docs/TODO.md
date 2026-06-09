# Remaining work and ideas

## P0

- [] cleanup 
- [] install script 
    - generate build system keys
    - sign
    - create vfat and 'state' img
    - create intaller img.
- [] user docs


## P1 

- [] merge busybox and the scripts in the initrd
    - [] if 'secure boot' disabled - run the dev script, else run the initos-init.sh ( merge -ver into the main script) and attempt to move all the steps into rust.
    - [] also if STATE or any error - drop to shell (not in secure boot)

- [] add a 3rd EFI option: plain kernel with cmdline/initrd built-in and not accepting further modifications or input.


## P5

- [] build an aarch64 kernel and starter.
