# Why a custom kernel build

It is perfectly possible to use a 'distro' kernel - with 
an initrd that loads storage and filesystem modules. 

However it is far simpler to just have a kernel that 
has what it needs to boot - storage and filesystem for the 
system partition. 

Few distros do this - and their kernels could be used - but
I have a variety of old machines with odd drivers I don't want
to throw away - and I think for a secure boot it is quite
useful to have control and know how to build kernels. 

LLMs can handle this without any trouble - so a lot can 
be automated and just review is required.

## Required built-in components

- EXT4, EROFS 
- FS-VERITY and FS-CRYPT
- NVME, SATA, MMC
- USB controllers
  - along with USB storage, keyboard and ethernet
- TPM/2 - can be handled from modules but easier if it is built-in
- EFI and EFI-based consoles 

As module only, never built in:
- DRM 
- anything requiring firmware

# Console

One of the top problems compiling the kernel is to get the damn console to work.

Docs:
- system driver - only one, can be deactivated. 
- efi driver works, but not accelerated
- modular driver takes over.
- /sys/class/vtconsole/vtcon0/name
DeviceDrivers->Char devices->Support for binding/unbinding

Debian recent disables VT - only graphics.

To re-enable:
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

Kernel signing is still useful because it prevents an attacker with root from inserting their own modules.

Given the update model is 'full set of modules + kernel' - not individual pieces - using the ephemeral signing keys is acceptable.

# Building 

Can be built in a debian container or VM - with all deps installed, and in nix.

Main difference is that in nix it is using the kernel source
from a nix cache - while in debian it is getting directly 
from github. 

