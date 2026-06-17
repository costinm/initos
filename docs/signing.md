# Kernel and modules signing and trust.

Distros sign bootloaders/kernels/modules with their own keys, using broad certs (Microsoft).

Distro hoping (just using a different distro kernel and options) is a problem - in practice you
can't lock down EFI to only the software you want as long as the Microsoft broad keys are in 'db'.
If we hold any private data in TPM, tied to the secure boot status - another signed kernel from
a different distro can boot and get the secret, unless a more fragile/complicated policy is used.

For Androd, Chrome - bootloader is locked with one key per device, kernel signed by vendor with 
that key. That's far more secure than typical Linux - but only the vendor can sign the kernels.
It is safe to unlock the disk using TPM because no other kernel and init can be booted as long
as bootloader is locked.

InitOS goal is for the user (or an org) to download or build their own kernel and sign
with their own keys, with clean enough boot path that a user or LLM can follow and review/modify. 
Similar to Android/Chrome - but with my own keys.

Initios main app is a script that signs the EFI, kernel, initrd - with a simplified boot that
allows storing disk keys in TPM, tied to secure boot and DB keys status.

## Module signing 

Now we get to the modules: they need to be signed as well. If they get signed at kernel build time,
the builder of the kernel has the keys and can create modules that could be loaded by the kernel.

Technically, InitOS distributes the modules in a signed erofs - it is not possible to replace them
with a different set, but as root it is possible to load a module from a different place.

I want  the owner of the machine (or set of machines) to control and sign with its keys 
all binaries that run with high priviledge.

Option 1: have the owner compile the entire thing, with the build machine having access to the 
signing keys. It's simpler, but it requires giving access to a machine that runs all kind of build scripts to the sensitive private keys.

Option 2: leave space in kernel for the key, build without signing - and at sign time insert your
signing key into the kernel. The problem: this required the uncompressed vmlinux and all kind of
scripts and objects to build the bzImage. This is what I've tried and mostly worked but far too 
complex.

Option 3: a tiny patch to the kernel to allow the use of 'db' key for checking the modules. If
the db key is compromised - the boot EFI and kernel would be as well. I don't see a lot of 
reasons for not trusting it for modules. I don't think the root on a machine should compile
or sign modules - this should be done on the trusted build server and signed as any binary.

There are other options - using the EFI loader to insert 'MOK' keys into some EFI vars, or to
decompress the kernel without a bzImage - but the goal is to eventually boot the kernel directly
without the complexity of an extra loader, with the initrd/cmdline inside the kernel.


