# TODO and ideas

[x] Before releasing - remove the debug shell in secure, mode unless LUKS is unlocked by user password.
Only unsigned usb installer should have shell on console.

[ ] Code to turn off console and backlights

[x] change boot order, save A/B/latest and versions
    - added efibootmgr creation, need to figure out order

[ ] Automatic enroll of the keys (mok)

[ ] Finish up vrun

[x] move files around, no more recovery dir
    - move to boota/bootb separate partitions 

[ ] Finish auto-install script

[ ] Test with nvidia server and move my last computer to it.

[ ] add kasminit https://github.com/linuxserver/docker-baseimage-kasmvnc/blob/master/root/kasminit and test using linuxserver images directly, including AppInit sqfs, layout, etc

[ ] Break out vm, net tools, etc to separate containers.

[ ] Go back to smaller single EFI partition with 2 img partitions, use file on the EFI partition to identify active img.
    It is much simpler/clener than using efi vars and faster than probing. Also allows switching to signed ext4 (like chromebooks), which may 
    be faster since the plan is to keep it as a sidecar. 


# Ideas 

## Firmwared 

Debian uses ZX, Alpine ZSTD - to have the firmware independent of distribution we effectively need to 
uncompress (which is fine since we put it in a sqfs). A different approach is to use a service that
may also download firmware from a control plane, and only keep network and disk on the boot.

## Linuxserver containers

https://github.com/linuxserver/docker-mods
- uses root/ directory as base ("COPY root/ / ")
- has a /defaults top ?
- etc/s6-overlay/s6-rc.d/svc-mod-EXAMPLE/run
- module handler install packages from `mod-repo-packages-to-install.list`

Desktop:
- pulseaudio, openbox, i3 too
- /custom-cont-init.d - for init scripts ( all run)
- /custom-services.d 

- /config - mounted configs, application data.
- /dataN is also used
- recommends /opt/appdata/my-config.. on host for the volume src, also seen /home/USER/appdata/FOO
- env PUID, PGID (1000 as default) - is the UID on the host, will be swapped as default user id on container.

Things I don't like:
- "-p" port forwarding instead of bridge.

Uses 'lscr.io' which redirects to ghcr.io.

Useful containers:
- 