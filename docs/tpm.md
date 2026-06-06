# TPM use

TPM2 is a relatively simple and useful tool - made insanely complicated by inventing a lot of terms and complexity.

I don't fully understand _all_ the things it can do - but the main feature
is holding a secret (private key or shared) that is later used to decrypt
the disk.

The key created when 'secure boot' is enabled can't be accessed if 
secure boot status changes or the accepted keys change - which mean that
if everything is signed and only our keys are installed in EFI, we know
that only initos can load the key from TPM2 and unlock the disk, and 
after that it can't be retrieved even by root - or with physical access 
to the machine.

If secure boot is not enabled - the TPM is useless, since the attacker can boot a different kernel and use the TPM as they wish. 

It is not perfect protection - but good enough for 'evil maid' or stolen/lost
machines.


## Background

TPM can do a lot of things, but the important ones are:

- secure persistent storage for a small set of secrets, up to 128 bytes each.
- secure private key storage - exposing sign/decrypt operations (encrypt/verify use the public part). The public key is exported as PEM.
- detect if BIOS settings, in particular secure boot, are changed - and not allow access to the keys if they are. It doesn't appear to wipe/clear the keys, moving back to secure boot the keys are available again.


Primitives:

- create a keypair - the private key is stored in the TPM, not accessible if the BIOS settings are changed ( i.e. disable secure boot).
- save a key in the TPM persistent memory
- load a key from the TPM persistent memory on boot

## Testing 

# qemu 

TIS = 1.3, memory mapped 
CRB = 2.0, memory mapped 0xfed40000-0xfed40fff 

```
-tpmdev passthrough,id=tpm0,path=/dev/tpm0 \
-device tpm-tis,tpmdev=tpm0 test.img
```

/sys/devices/LNXSYSTEM:00/LNXSYBUS:00/MSFT0101:00/tpm/tpm0/pcr-sha256/1

mkdir /tmp/mytpm1
swtpm socket --tpmstate dir=/tmp/mytpm1 \
  --ctrl type=unixio,path=/tmp/mytpm1/swtpm-sock \
  --tpm2 \
  --log level=20

  -chardev socket,id=chrtpm,path=/tmp/mytpm1/swtpm-sock \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 
  

