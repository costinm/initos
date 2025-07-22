# TPM use

TPM2 is a relatively simple and useful tool - made insanely complicated by inventing a lot of terms and complexity.

I don't fully understand all the things it can do - but the core functionality can be used with the tpm2-tools.

The assumption is that 'secure boot' is enabled - so only a signed kernel and init can run, which in turns verifies the rootfs and doesn't allow someone with physical access to the machine to make any changes.

If secure boot is not enabled - the TPM is useless, since the attacker can boot a different kernel and use the TPM as they wish.

It is not perfect protection - but 'evil maid' or 'theft' without very advanced tools can't do much, only way for the LUKS volume to be loaded and server to work is via the secure boot, and no root shell should be available.

## Background

TPM can do a lot of things, but the important ones are:

- secure persistent storage for a small set of secrets, up to 128 bytes each.
- secure private key storage - exposing sign/decrypt operations (encrypt/verify use the public part). The public key is exported as PEM.
- detect if BIOS settings, in particular secure boot, are changed - and not allow access to the keys if they are. It doesn't appear to wipe/clear the keys, moving back to secure boot the keys are available again.


## Basic setup

Primitives:

- create a keypair - the private key is stored in the TPM, set to self-destruct
if the BIOS settings are changed ( i.e. disable secure boot).
- save a key in the TPM persistent memory
- load a key from the TPM persistent memory on boot, use it to unlock LUKS.



## TODO

- use of TPM2 with SSH.


