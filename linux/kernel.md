# Differences from Android kernels

Both host and VM kernels should be able to run android apps
as well as docker, podman and nested VMs.

- android disables POSIX_MQUEUE, WATCH_QUEUE, SYSVIPC - other apps need these so added back, but ideally not using this in any rust/go app.

- various modules for laptops/etc are included

## Built in required


- EXT4, EROFS - pluse FS-VERITY, DM-VERITY and FS-CRYPT
- NVME, SATA, MMC, USB controllers - along with USB storage, keyboard and ethernet
- TPM/2 - can be handled from modules but easier if it is built-in
- EFI and EFI-based consoles 

As module only, not built in:
- DRM and anything requiring firmware


# Console

One of the top problems compiling the kernel is to get the damn console to work.

Docs:
- system driver - only one, can be deactivated. 
- efi driver works, but not accelerated
- modular driver takes over.
- /sys/class/vtconsole/vtcon0/name
DeviceDrivers->Char devices->Support for binding/unbinding

Debian recent disables VT - only graphics.

To enable:
CONFIG_VT=y
CONFIG_VT_CONSOLE=y

## Efifb

- any device with EFI, must boot with EFI
- most universal but slow
- `video=efifb:list,nowc' ?

video=

console=efifb - keeps it, tty0 disables it.

## Vesa

- vesafb and vgacon drives

earlyprintk=efi,keep - keep it.
earlycon=efifb

## Module signing 

Modules will be distributed in signed EROFS volumes. 

Kernel signing is still useful because it prevents an attacker with root from
inserting their own modules.

Given the update model is 'full set of modules + kernel' - not individual pieces - 
using the ephemeral signing keys is acceptable.

# Building 

The build happens in a container named 'initos-kernel-dev', created from Debian 13 slim with the setup-kernel installing the required packages and handling the build.
Using rootless podman.

The layout is:
- current dir mapped directly to the container on the same path (.../initos)
- /build directory used to pull kernel and other binaries - should be mounted from 
$HOME/.cache/initos-kernel-dev
- ${out} used to copy the artifacts.

# Signing and install

Signing and distribution happen on the host/VM - will sync the ${out}/img directory
to various machines, and run the upgrade script.



# Debugging and hacking

make LSMOD="/home/build/ws/initos/linux/lenovo.lsmod" localmodconfig 