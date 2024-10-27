

- has simple-drm linked in
- no zstd on firmware load - any firmware must be decompressed
- 

The debian rootfs needs few adjustments:
- disable lid switch if using a laptop (otherwise the screen will turn off when closing the lid)
- remove grub, initramfs-tools etc - if it was installed
- install ifupdown-ng - same config as in alpine, more deterministic
-  `systemctl disable systemd-networkd-wait-online.service`
- disable systemd-networkd.service

Also useful: remove journamd, use busybox syslogd with circular buffer.

- remove firmware-linux-free after the sqfs is created (for saving it)
- 
