
Difference between debian and alpine kernel:

- has simple-drm linked in
- no zstd on firmware load - any firmware must be decompressed


The debian rootfs needs few adjustments:
- disable lid switch if using a laptop (otherwise the screen will turn off when closing the lid)
- remove grub, initramfs-tools etc - if it was installed
- install ifupdown-ng - same config as in alpine, more deterministic
-  `systemctl disable systemd-networkd-wait-online.service`
- disable systemd-networkd.service

Also useful: remove journamd, use busybox syslogd with circular buffer.

- remove firmware-linux-free after the sqfs is created (for saving it)

Wifi:
systemctl enable wpa_supplicant@wlan0.service
cp /z/initos/insecure/wpa_supplicant.conf wpa_supplicant-wlan0.conf

# In a VM

- apt purge systemd !
- add vc
- ifupdown-ng

Files to update:
/etc/network/interfaces
/etc/hosts
/etc/wpa_supplicant/wpa_supplicant.conf

- add docker br-lan network
- fix-docker iptables for router
- machine id ? 