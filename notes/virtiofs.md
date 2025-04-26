# Workarounds for VirtioFS

- Intellij - and probably other java apps - seem to crash when trying to access files on a VirtioFS mount. 

According to AI:
This is due to the fact that VirtioFS does not support the `fallocate` syscall. To work around this, you can 
use the `LD_PRELOAD` environment variable to load a library that intercepts the `fallocate` syscall and 
returns an error code. This will cause the java app to fall back to a different method of allocating space for files.
To do this, you can use the `libfallocate.so` library from the `fallocate` package. You can find the library in the 
`/usr/lib64` directory. To use it, you can set the `LD_PRELOAD` environment variable like this...


Another option is to copy the binaries, ~/.cache and ~/.local/share/IntelliJ to a real disk.

- kernel modules on virtiofs: nvidia hangs, works fine on btrfs.

# LUKS 

LUKS is very convenient - but fstrim is not on by default.

Speed goes down: 1500 -> 500 on a fast disk.
920 -> 840 on another.

setutil uses the native NVME encryption - may be weaker, but ok
for home/small use. 

https://wiki.archlinux.org/title/Self-encrypting_drives

```shell

sedutil-cli --scan 
# Should show 'Yes'

sedutil-cli --initialsetup password drive
sedutil-cli --setadmin1pwd PASSWORD NEW_ADMIN1_PASSWORD DRIVE

sedutil-cli --setupLockingRange 1 RANGE_START RANGE_LENGTH PASSWORD DRIVE
sedutil-cli --enablelockingrange 1 PASSWORD DRIVE

# Full disk
#sedutil-cli --enableLockingRange 0 password drive


sedutil-cli --setMBREnable off password drive


# Unlock
sedutil-cli --setlockingrange 1 rw password drive



```

Cryptsetup also has `--hw-opal-only` option on luksFormat.

cryptsetup erase -v --hw-opal-factory-reset /dev... -> clear encryption, asks for opal admin pass
-> requires PSID from the device sticker !

- has a rescue system
- password unlock with EFI chaining


# Alternatives

fscrypt - for ext4, F2FS, Lustre, Ceph, UBIFS
- per dir
