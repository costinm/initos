# Building initOS

Settings and defaults:

```shell
# Set to a directory where the output volumes and temp files should be stored, 
export WORK=/x/initos
export SECRETS=$HOME/.ssh/initos # only used for signing, ideally on a separate machine.
export SRCDIR=/ws/initos
export REPO=ghcr.io/costinm/initos
export TAG=latest
```

# Dockerfile

For convenience, a Dockerfile-based build can be used.
The Dockerfile is not typical - most RUN commands are based on scripts in the 'recovery'
image, and can be replicated in a container or host.

```shell


# All components. Result in ${WORK}/boot/efi - can be copied to a USB EFI partition.
./setup.sh all

```

Modern Dockerfiles allows caching - so full reproduction between 2 runs is not guaranteed anymore, and 
it was wasteful anyways - a clean build (in a different volume) provides the same benefits. 

A Dockerfile contains multiple 'stages', a stage can copy or mount files from a previous stage.
Instead, each stage is a standalone 'run' operation, with mounted volumes.
Instead of Dockerfile syntax, regular shell is used (or any other language).
Images are pushed and manipulated with 'crane'.

# OCI images

The build generates 2 main images:
- debkernel - containing debian slim plus kernel/modules, including the cloud version.
- initos-base - the (almost) minimal image required to boot.

The boot disk (EFI) is generated from the 2 images, combined with a local volume that 
includes the root keys for signing and additional (small) configurations to bundle in the signed EFI.

First build is slow, as it generates SQFS and initrd images. Signing different EFI images and configs
is fast, only packs and signs the required files.

## Alternative layout - SQFS included

Another approach that seems to work very well for quick generation of the EFI files at the expense of flexibility is
to pre-generate the SQFS file containing the debian modules, firmware and the Alpine image that will be used.


# Signing the EFI and adding root certs

Best done on a separate, secure host capable of running docker:
1. copy the WORK dir from the build machine.
2. `./setup.sh sign`

Can also be run on the build machine, if you trust keeping the signing keys where builds are happening.
The build is using containers and not using 'priviledged', but there are still risks.

# Container-based

Alternatively, step-by-step build by running the same scripts in a container/pod/VM/host.

I realized that I 'reinvented' buildah, but using docker for execution. I think this would also work with kubectl/Pods - and planning to 
move to using actual buildah (but keep the wrappers and allow docker/k8s execution).

```shell

# start and build the recovery container locally, from edge:alpine.
# All other steps will use the docker image.
./setup.sh recovery

# Build a 'recovery.sqfs' and verity signatures, using the recovery OCI image.
./setup.sh recovery_sqfs

# Download linux alpine kernel, modules and firmware
# The kernel version is in ${WORK}/boot/version - other kernel versions and modules can be copied from
# debian, alpine, ubuntu, etc, following the same layout.
./setup.sh drun linux_alpine
./setup.sh drun firmware_sqfs
./setup.sh drun linux_debian
./setup.sh drun mods_sqfs

# Build the UKI - using boot/version, the kernel, modules.
./setup.sh drun efi
# Second build - fast incremental (only replaces init)
./setup.sh drun efi2

```

## Container-based build details

All the build steps run in a container/chroot/pod with some common mounts:
- with the work dir in /x/PROJECT,
- source under /ws/PROJECT,

'docker build' is executing each command in a container and does weird and complex
 optimizations to provide an 'isolated' build environment and compensate for 
 moving a lot of files around. A lot of the problems are caused by attempting to
 build on a remote machine. The concept of 'isolated build' is not bad - for
 a release - but incremental builds should be fast and simple. 

So I am using simple (no fancy features, just lists of commands and few 'if') shell script 
and containers - it also works with chroots for the most part, or any other container, including Pods.

`start-docker start` will start a build container that will mount out/cache volumes and sleep.

`start-docker drun CMD` will run an ephemeral container for one build command - equivalent to a RUN in
dockerfiles.

# Un-obfuscated containers

The main goal is to isolate (or jail) execution and data, and provide 'zero trust' on the application code.

There are few ways to do this, with different degrees of isolation:
- chroot + user IDs - the classical - weakest but fine if no root or excessive mounts are used.
- namespaces - add PID, network, etc - usually fine unless 'privileged' is used
- VMs - separate kernel, even better
- different host - even stronger, great for the 'control plane' and 'gateways'
- different region, project, provider, etc - can be protected even if the admin / control plane on one vendor is lost.

In all cases, there is 'data' and 'execution'. 

Buildah is intended as a 'docker build' alternative, breaking the obfuscated Dockerfile into individual scriptable
steps. It is also using most of the code of podman - and despite its docs can be used for running anything.

Typical approach to 'simplify' is to have 'opinionated' choices mixed together and hidden behind another, even more
complex interface. While the concept of downloading signed files can be complex - it is burried deep in a framework.
Buildah is also doing this - 'buildah from' is a great command to download an image and expand it, like 'crane export' - 
but the result (typically ~/.local/share/containers/storage/vfs/dir/CONTAINERID)

## Mounts

A VM can dynamically add disks, and can mount remote or local filesystems. A pod - for good reasons - doesn't have
permissions to do that, but there is no reasons for the mounts to be static at startup time. Buildah does allow
each command to run with different mounts - because it starts a new container on the same rootfs.

In reality the containers are just using a different mount namespace - network and mounts can be changed at any point,
and as long as the rootfs is not hidden, bind mounts can be added. That wouldn't work with some storage drivers,
but it's fine - unionfs or dir are most common and the goal is make it easier for user not to keep some storage drivers dumb.

How:
- at startup, inspect or determine the rootfs based on container ID, create a link under /run/volumes/CONTAINER_NAME/rootfs
- bind mount at will
- no more 'docker copy' - can use any app to modify the rootfs.

A per-host service can also do additional mounts on behalf of the pod, depending on permissions and rules.

Similarly, exposing the network namespace would allow dynamic changes. In the case of VMs, adding network devices 
and handling the host size is possible - for the guest side some agent is needed, or just using ssh and running
some commands.

## Buildah 

A K8S Pod or typical container will run as long as the 'init' runs, and typically has a 'sleep' that
holds is alive. "Exec", "copy" and exporting current layer to images are done on the live container.

Buildah doesn't require the long-running process. Each command enters the namespace and leaves it
around.

You can do the same operations with a regular container and buildah, using same style of 
driving it from a shell. Even a regular VM - using ssh - can do the same, but VM and K8S
pods lack support for exporting the current layer. Buildah uses fuse-overlay to keep the 
active layer.

Syntax is:

- `buildah from --pull --name NAME -v VOL:MOUNT IMAGE`
- `buildah commit --rm NAME [--squash] IMAGE`
- buildah containers, images - list active
- `buildah config --cmd CMD --entrypoint EP  -e KEY=VALUE -v VOLUME ... NAME`
- `buildah copy NAME --from OTHERNAME src dst`
-  `buildah mount` - mount the container to host - it effectively prints the dir or 'merged' overlay if root,
must be run inside 'buildah unshare'
- unshare is only setting user namespace - mapping current user to root and all the users in the container to expected UID.
If running as root - the merged dir has right IDs.

In user mode it is using cp (with COW), netavark for networking, aardvark-dns, uidmap and fuse-overlay.

Netavark is rust-based. Podman and buildah deprecated CNI.

Podman defaults: podman interface, 10.88.0.0/16 (as root) bridge.
Pasta: NAT, interface with default route or first if.


Pasta/passt - VM and container networking using TAP but without TCP termination.
slirp4netns - using slirp, which use tcp stack, 10.0.2.0/24 - TAP base.

How it works:
- download the image, as user use 'dir' (copy on write when possible)
- for every command, generate a 'userdata/buildah.json' with the command
- buildah-oci-runtime to run that command

## EFI stubs

Currently Alpine is using the old gummiboot-stub.

Alternatives: https://github.com/puzzleos/stubby
