OpenWRT has switched to APK - it did support installing alpine packages in the past, but now it works both ways.

https://downloads.openwrt.org/snapshots/targets/x86/64/packages/ is the 'core' 
distro.

Example:

```
echo "https://openwrt.meshtastic.org/main/$(cat /etc/apk/arch)/packages.adb" > /etc/apk/repositories.d/meshtastic.list
wget https://openwrt.meshtastic.org/meshtastic-apk.pem -O /etc/apk/keys/meshtastic-apk.pem
apk update
```

https://downloads.openwrt.org/snapshots/packages/x86_64/packages/