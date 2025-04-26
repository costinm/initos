# Choices and Options for InitOS 

There is a lot of "opinionated" software - and a lot of over-flexible as well. Making 
tradeoffs is universal - I think it is important to document the choices made (for the 'opinionated') and minimize option complexity, which are choices forced on the user.
Most choices ('opinions') are reversible with small changes in the scripts. 

The boot sequence is 'opinionated' and does not expose any option. Users can fork and modify the scripts ( using an assistant works great ) if they have different choices.


## Options

The /x/istio/istio.env is the main config file for the boot sequence. 

The /x/initos directory contains all the configurations - etc/ files are copied
to the sidecar and main OS /etc. It is expected that the 'control plane' machine
that is managing the upgrade will also push config files, using a git repo or K8S
as source.

After the encrypted disk is unlocked and network is up - InitOS will become a 
sidecar and give control to a 'main' rootfs. 

The main options are around which 'main' OS to use - I currently use debian, but most others should work - and how much control to give. 

The sidecar can start multiple VMs and containers - I usually run the main OS 
as a 'privileged' container and every other container either unprivileged or in a VM.
For development 'pods' - always VMs.

If the machine has NVidia cards - it is easier to run the apps using it (ollama, etc)
as the main privileged container, with direct access. Anything that is not using the GPU
goes to VMs or unprivileged containers.

Passing the GPU to a VM is not yet implemented.


## User choices 

Primary purpose of InitOS is to run a more secure server, with encrypted disks
and secure boot. 

For unlocking the disks, TPM/2 must be used for a server - most recent server-class machines have this and there is no other way that I know to protect the key. 

I also run it on laptops - my main laptop is a Chromebook which has even stronger
security, but I have older laptons out of support or not running Chromebook. 

If the laptop supports TPM/2, it is possible to auto-unlock the disk - this is an
option for a 'common use' laptop that auto-starts a guest user (like Guest in ChromeOS). For all other cases - since a password will be needed to login it is
not unreasonable to ask a password for unlocking the disk. I personally use the same
password, since unlocking the disk would give full access to the machine.


## System choices

- btrfs as main filesystem. It has COW, can auto-check the disk, subvolumes - ZFS is another choice, and it would work with any other filesystem - but not worth exposing it as an option.

- LUKS for encrypted disk

- FS Verity for protecting the sidecar/rootfs

- Non-configurable boot labels and partition layout. I tried initially to use chromeOS 
partition layout - but it is safer to use 2 EFI partitions instad of one.

- Alpine for EFI builder - size and the easy way to create a small initrd, 
sign.

- Alpine for sidecar - small, not using systemd (which is not designed for a 
read only minimal OS), commonly used in containers. The sidecar is not actually running
in a container - but it does not have its own kernel.

- Debian for rootfs - broad use, has NVidia support.

- SQFS for the sidecar and rootfs. Simple, small - but I may change it in the future,
using read-only partition like ChromeOS or non-compressed disk.



## Forced choices

- using TPM/2 - there is no other good place to store a secret to auto-unlock a server LUKS. Anything else can be read by an attacker with physical access. It is not 
perfect - I suspect a JTAG or advanced hardware can be used if the computer is stolen.

- UKI and the boot sequence. We need secure boot enabled - otherwise another OS 
can be started and it can read the TPM. The BIOS will need a signed EFI - and the
signing must be offline, storing the signing keys on each machine is not secure. The initrd can't be too large - so unlike others it just verifies the verity signatures
and lets the sidecar handle the rest.