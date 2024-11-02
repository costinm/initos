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

# Signing the EFI and adding root certs

Best done on a separate, secure host capable of running docker:
1. copy the WORK dir from the build machine.
2. `./setup.sh sign`

Can also be run on the build machine, if you trust keeping the signing keys where builds are happening.
The build is using containers and not using 'priviledged', but there are still risks.

# Container-based

Alternatively, step-by-step build by running the same scripts in a container/pod/VM/host:

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



