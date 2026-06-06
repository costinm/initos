# FS-Verity

An alternative to signing an entire block device with dm-verity is using fs-verity. Supported on ext4 (and f2fs), also [btrfs](https://developers.facebook.com/blog/post/2021/10/19/fs-verity-support-in-btrfs/)

The main problem is that it can only be used to sign a single file.
The file can be deleted and created again, but can't be changed.

Best use (IMO) is similar to dm-verity - enabling it on erofs images
on the disk, signing the SHA and mounting them.

To keep things simple - how to sign different things is kept separate, currently it's a form of minisign/signify but may change
and have multiple formats/implementations.

Note that Nix directory or any other files stored on the fs-crypt 
directory are also protected and can't be changed by an 'evil maid'
with access to the machine - but they can be changed by root or 
after unlock. An erofs with signature can be on a non-encrypted
dir if it contains a public image.

## Initrd vs dm-verity root

EFI can verify linux, command line and initrd - but the rootfs
is not verified unless it is a dm-verity block. Doing this is 
a bit complicated and ugly - I've been doing this for some time,
ChromeOS is using it very well - but fs-verify is simpler and
can be used for other things besides rootfs. To reduce complexity
keeping only fs-verity - but that requires using an initrd to 
check the signatures and enable fs-verity.