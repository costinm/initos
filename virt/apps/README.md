# Applications

If an app can run in a podman/docker container without privileged or 
special settings - it can be run directly.

Otherwise it is run in a VM. Dev envs that require docker run as VMs.

If the machine has NVidia cards, a 'gpu' debian+systemd VM will be the 'master', will be passed the PCIe device.

Each VM has a virtio-fs "/z" disk, as 'shared' dir where host volumes
can be bind-mounted. Many things don't work well on virtio, but good
enough for (slow) file copy, no COW.

The runtime data is on '/x/vol/NAME' mounted as /data, containers are on /x/@cache and may be deleted/not backed up.
