# InitOS control plane

One of the main choices for improving machine security is to use secure boot and signed images plus encrypted disks. The signing keys for the EFI kernel must
stay on a separate, secure set of machines - which is responsible for signing and distributing the roots of trusts, orchestrating the upgrades and controlling the mesh.

It is possible to split the control plane if it gets complex - but for now 
all functions are implemented as simple scripts operating on static files, 
using SSH to control the machines and drive the upgrades, with InitOS as 
a sidecar on each machine.

The config files source should be a K8S cluster or git repo, and they can be
replicated on each machine (rsync, syncthing - or direct pull).

The control plane is also distributing the configs for the main OS (switch_root rootfs) or containers, VMs maintained by InitOS directly. 

