# Building initOS

```shell

# Set to a directory where the output volumes should be stored, 
# preferably on a btrfs disk.
export WORK=/x/initos

# All components. Result in ${WORK}/boot/efi - can be copied to a USB EFI partition.
./recovery/sbin/setup-in-docker all

```


Alternatively, step-by-step full build:

```shell

# start and build the recovery container locally, from edge:alpine.
# All other steps will use the docker image.
./recovery/sbin/setup-in-docker recovery

# Export the docker container to ${WORK}/recovery and build the sqfs (drun recovery_sqfs)
./recovery/sbin/setup-in-docker recovery_sqfs

# Download linux alpine kernel, modules and firmware
# The kernel version is in ${WORK}/boot/version - other kernel versions and modules can be copied from
# debian, alpine, ubuntu, etc, following the same layout.
./recovery/sbin/setup-in-docker drun linux_alpine
./recovery/sbin/setup-in-docker drun firmware_sqfs
./recovery/sbin/setup-in-docker drun mods_sqfs

# Build the UKI - using boot/version, the kernel, modules.
./recovery/sbin/setup-in-docker drun efi
# Second build - fast incremental (only replaces init)
./recovery/sbin/setup-in-docker drun efi2

# Optional - can be run on a different machine/VM with the root keys available.
# Will use a separate recovery container - the keys are not mounted on the regular container.
# The signed image does not allow shell or options.
./recovery/sbin/setup-in-docker drun sign


```

For testing or runnin on a VM:

```shell
# Download kernel, build the virt modules (virt/modloop-VERSION.sqfs)
./recovery/sbin/setup-in-docker drun vlinux_alpine

# Initfs - no need to create UEFI
./recovery/sbin/setup-in-docker drun vinit


```

# Building details

I am not using Dockerfiles - this project is mainly for my needs, so I will keep it
simpler. All the build steps run in a container/chroot/pod - with the work dir in /x/PROJECT, source under /ws/PROJECT,
both mounted as volumes.

'docker build' is executing each command in a container and does weird and complex optimizations to provide 
an 'isolated' build environment and compensate for moving a lot of files around. A lot of the problems are caused 
by attempting to build on a remote machine.

The concept of 'isolated build' is not bad - for a release - but incremental builds
should be fast and simple. 

So I am using simple (no fancy features, just lists of commands and few 'if') shell script and containers -
it also works with chroots for the most part, or any other container, and should work in a Pod too.

`setup-in-docker dstart` will start a build container that will mount out/cache volumes and sleep, while 
'drun' will run an ephemeral container for the build command.

