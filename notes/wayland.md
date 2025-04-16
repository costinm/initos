# Using initos on a laptop (wayland)

Wayland may make sense as a driver for a laptop or desktop physical screen. For remote access or inside a container - no sense at all, X is still best option.

Chrome-Remote-Desktop or KasmVNC or any other VNC have minimal system requirements - no udev, PAM, seatd. 

Inside a container you want access to a window - not the full display, since the container is not trusted. 

Porting chromeOS sommelier and similar apps would be ideal for having wayland access in containers and VMs - but simple remote access is now getting easier, in particular for coding with the UI on client side instead of server.

## Alpine based

The same model - minimal system manager + containers applies to UI. 

We need:
- sway (rpi is using ...)
- rofi-wayland - best launcher IMO

DO NOT install apps - furtunately alpine doesn't have a lot of apps. Firefox, OSS VSCode and few others are available - but better to use them from an isolated environment !

## Debian based

Same as alpine - with a debian rootfs it is also better to only install basic wl-roots display and keep the apps in containers.

## Apps 

The apps: in debian-based containers or VMs, using Kasm (or CRD).

## 'Seats'/Homes

Chrome, Code and many others now prevent one home from running multiple instances (or make it very hard). Which is great - it forces each container to have its own separate 'home', with only few configs shared (pushed from a repo).

This solve one of the largest problems with current desktops - the sharing of HOME, with untrusted apps accessing each other's data.

The old model - which the 'Linux Desktops' are using - is fatally flawed, and things like Flatpack don't really solve it.

## Notes

Swaylock not working ? Check pam and the /etc/shadow group ownership.

Sway not starting ? Needs seatd, udevd.