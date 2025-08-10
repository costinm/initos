# Containers, init and isolations

Docker is strongly opinionated that a container should run a single process. I strongly disagree, but also agree.

Each process should be as isolated as possible - yes,
but there are multiple layers. The root problem with
Docker model is that it assumes there is only one solution for isolating, and docker==containers==isolation.

## Physical machine to jails

InitOS tries to secure the init sequence by signing
the EFI and initial rootfs. 

At the end if the init, it can give (almost) full control to a normal OS - or it can run it in a jail.

When giving control to another rootfs, InitOS will 
run itself as a 'host sidecar' - handling admin, upgrades and hardware operations - by launching
a sshd. This works even if switch_root is used with 
systemd, if arv[0][0] is '@' - but to be safer in the 
case of systemd InitOS sidecar can be started after
systemd init.

The other option is to not give full control - but run
the 'real' operating system in a jail. It can be 
as a VM or priviledged or unprivilegded container.

In this case - InitOS can run multiple jails, and if 
set to unpriviledged or VM, it maintains the hardware
isolation from the less trusted root fs.

## Ephemeral containers and DIND

It is very hard and insecure to run docker-in-docker, because the docker container drops a lot of permissions.

In K8S, CRI provides a per-node/VM API to start containers - but that's not visible inside a pod.

Instead, they allow 'ephemeral' containers to be created via API server, which can apply RBAC controls - and goes back to CRI service on the same host.



## Init

Like isolation, there is no single answer for init, 
except 'no systemd'.

Linuxservers seems pretty opinionated on s6. It's pretty good and useful for containers. 

I like openrc for hosts, and tini for zombies (as pid1 - but not required).

Another approach is chaining:
` [tini ->] helper1 -> helper2 -> app. `

The helpers can start ssh or other debug tools, handle 
mesh, mount disks.

# Podman

I use podman for 2 main reasons:
- it works very well as regular user, with no daemon
- it support `--rootfs` option so it can take a custom-created rootfs.

When running it without systemd - the config needs to be adjusted.

As user, files are in `~/.local/share/containers/storage`:
- vfs-containers/${ID}/userdata/[buildah,config].json - the runc config. 
  After the container stops - the file is left around. 
  `jq .root.path` to find the rootfs. 

- images under vfs-images/${ID}/ - json files with metadata/schema.
  `jq .layers[].digest` for the layers.

When building - or running - the container layers remain around and
may be reused.