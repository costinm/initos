
## Systemd 

Systemd rootfs is 'special' - and strongly discouraged as a main machine OS.

It is fine to run it in VMs, if you must use Gnome - a VM
is the only secure and reliable way to run Systemd, fully isolated, as it
reduces the risks of startup errors and the security risks due to systemd size.
Containers work too.

While I don't like systemd design - it is a requirement for Gnome 
and other software, and if it is contained in a VM it is less harmful and easier to test and manage - and has to be tolerate just like many other 
legacy tools.

It is also possible to run it as the 'main' switch_root OS - but on startup
it kills all the processes (there is an exception for @name). To handle that,
we can use a systemd unit that will start Initos back, in a chroot,
as a sidecar.

The rootfs should include minimal hardware configs and no network configs - this is handled by InitOS.

## Tools for using it in a VM

All hardware and network related units must be disalbed.

systemd-analyze critical-chain graphical.target
systemd-analyze blame
