#!/bin/sh


# Based on Alpine mkinitrd, but with different init script:
# - various checks to detect an BTRFS rootfs in 'insecure' mode, fallback to recovery subvol or sqfs
# - removed all networking or alpine-specific init - only job is to load a rootfs
#
# This allows using the simpler initrd, with a number of small specialized functions.
# It is also usable for VM - when the kernel lacks some drivers (btrfs, etc), to allow kernel+fixed initrd without
# using EFI + Grub + Dracut/systemd

## First step - expand busybox and mount the basic filesystems
initramfs_1st() {

  # No kernel options processed - we build intitramfs and cmdline in the same efi.
  # May read an initrc file if needed - but the goal is to keep it precise and simple.
  # Initramfs does not include the links (for some reason?)
  /bin/busybox mkdir -p /usr/bin \
    /usr/sbin \
    /proc \
    /sys \
    /dev \
    /sysroot \
    /media/cdrom \
    /media/usb \
    /tmp \
    /etc \
    /run/cryptsetup

  # Spread out busybox symlinks and make them available without full path
  # This appears slightly faster than having the initramfs include all symlinks ?
  /bin/busybox --install -s

  # Make sure /dev/null is a device node. If /dev/null does not exist yet, the command
  # mounting the devtmpfs will create it implicitly as an file with the "2>" redirection.
  # The -c check is required to deal with initramfs with pre-seeded device nodes without
  # error message.
  [ -c /dev/null ] || mknod -m 666 /dev/null c 1 3
}

# mount proc, sys, etc
mount_proc() {
  if [ -e /proc/cmdline ]; then
    return
  fi

  mount -t sysfs -o noexec,nosuid,nodev sysfs /sys

  mount -t devtmpfs -o exec,nosuid,mode=0755,size=2M devtmpfs /dev 2>/dev/null \
    || mount -t tmpfs -o exec,nosuid,mode=0755,size=2M tmpfs /dev

  # Make sure /dev/kmsg is a device node. Writing to /dev/kmsg allows the use of the
  # earlyprintk kernel option to monitor early init progress. As above, the -c check
  # prevents an error if the device node has already been seeded.
  [ -c /dev/kmsg ] || mknod -m 660 /dev/kmsg c 1 11

  mount -t proc -o noexec,nosuid,nodev proc /proc

  # pty device nodes (later system will need it)
  [ -c /dev/ptmx ] || mknod -m 666 /dev/ptmx c 5 2
  [ -d /dev/pts ] || mkdir -m 755 /dev/pts

  mount -t devpts -o gid=5,mode=0620,noexec,nosuid devpts /dev/pts

  # shared memory area (later system will need it)
  mkdir -p /dev/shm
  mkdir -p /run

  mount -t tmpfs tmpfs /run

  # Module not present
  #mount  -t efivarfs efivarfs /sys/firmware/efi/efivars

  mount -t tmpfs -o nodev,nosuid,noexec shm /dev/shm
}


export LOG_V=""

# Info log - shown on console, logged.
logi() {
	last_emsg="$*"
	echo "INITOS: $last_emsg..." > /dev/kmsg

	echo -n "$last_emsg"
}

# Verbose log - saved but not shown on console
logv() {
  local msg="$*"

  LOG_V="${LOG_V}\n${msg}"
}

lfatal() {
  echo "FAILED: $*"
  edump

  if [ "${INIT_OS}" -eq "secure" ]; then
    sleep 5
    reboot -f
  fi
  busybox ash
}

# dump info to the EFI partition (which exists if we managed to get the
#  kernel running). One goal is to support machines without display/keyboard,
# install state will be saved on the USB disk.
# Log destinations:
# - before 'boot' is mounted: in memory, console on failure to mount boot
# - after 'boot' is mounted: /boot/efi/TMPDIR on failure, recovery /var/log/boot
# - after 'rootfs' is mounted, on tmpfs if it works, /boot/efi if not.
#
# All 'fatal' logs go to /boot/efi if it is mounted.
edump() {
  local dst=${1:-/boot/efi}

  if [ ! -d /boot/efi/EFI ]; then
    echo $LOGV
    return
  fi

  mkdir -p ${dst}
  export LOG_DIR=$(mktemp -d -p ${dst} )

  echo $LOGV > ${LOG_DIR}/logv

  echo "$ORIG_BLKID" > ${LOG_DIR}/blkid_before_mods
  echo "$ORIG_FS" > ${LOG_DIR}/filesystems_before_mods
  echo "$ORIG_DEVICES" > ${LOG_DIR}/devices_before_mods

  blkid > ${LOG_DIR}/blkid
  cat /proc/filesystems > ${LOG_DIR}/filesystems
  cat /proc/devices > ${LOG_DIR}/devices

  mount > ${LOG_DIR}/initrafms.mounts
  lsmod > ${LOG_DIR}/lsmod.log

  dmesg > ${LOG_DIR}/dmesg.log

}


# All remaining mounted dirs will be moved under same dir in /sysroot,
# ready to switch_root
move_mounted_to_sysroot() {
  # From original alpine init
  cat /proc/mounts 2>/dev/null | while read DEV DIR TYPE OPTS ; do
    if [ "$DIR" != "/" -a "$DIR" != "/sysroot" -a -d "$DIR" ]; then
      mkdir -p /sysroot/$DIR
      mount -o move $DIR /sysroot/$DIR
    fi
  done

  sync
}


unlock_tpm() {
  local part=$1

  # The setup script makes sure this handle is set - we may try multiple handles or
  # list nv persistent and try all.

  #export TPM2TOOLS_TCTI="device:/dev/tpm0"
  PASSPHRASE=$(tpm2_unseal -c 0x81800000 -p pcr:sha256:0,1,2,3)
  echo -n "$PASSPHRASE" | cryptsetup open $part c -
}

# Mount a boot disk - with recovery, firmware, modules, etc.
# Each component is a separate unionfs.
mount_boot() {
  local dir=${1:-/boot/efi}
  # It would be tempting to add persistent overlay here and make the root
  # modifiable - but that breaks the security model, we can't verify the overlay.
  # For any configs, certs, etc - we can add them to the UKI or rebuild.

  # From alpine original script
  mkdir -p /initos/recovery
  logi "Mounting boot partition, signatures $(ls /boot)"

  msqfs $dir recovery /initos/recovery

  if [ -f ${dir}/firmware.sqfs ]; then
    mkdir -p /lib/firmware
    msqfs $dir firmware /lib/firmware
  fi

  ver=$(uname -r)
  if [ -f ${dir}/modules-${ver}.sqfs ]; then
    mkdir -p /lib/modules/${ver}
    msqfs $dir modules-${ver} /lib/modules/${ver}
  fi
}

# Mount a SQFS file as a dm-verity device (if signatures found on the
# initrd /boot dir, in secure mode).
#
# The destintion dir will be an overlay drive.
msqfs() {
  local dir=$1
  local name=$2
  local dst=$3

  mkdir -p /mnt/${name}
  mount -t tmpfs root-tmpfs /mnt/${name}
  mkdir -p /mnt/${name}/ro /mnt/${name}/rw /mnt/${name}/work

  veritysetup open ${dir}/${name}.sqfs ${name} ${dir}/${name}.sqfs.verity $(cat /boot/efi/hash.${name})
  if [ $? -ne 0 ]; then
     logi "Error: Failed to mount ${name}"
     if [ "${INIT_OS}" -eq "secure" ]; then
       lfatal "Error: Failed to mount ${name}"
     else
       busybox ash
     fi
     return 1
  fi

  mount -t squashfs /dev/mapper/${name} /mnt/${name}/ro
  if [ $? -ne 0 ]; then
     lfatal "Error: Failed to sqfs ${name}"
     return 1
  fi

  mount -t overlay \
    -o lowerdir=/mnt/${name}/ro,upperdir=/mnt/${name}/rw,workdir=/mnt/${name}/work \
    overlayfs ${dst}
  if [ $? -ne 0 ]; then
     lfatal "Error: Failed to mount overlay ${name}"
  fi
}


# Mount a BTRFS subvolume as /sysroot - ready for the switch root
mount_btrfs() {
  local root_device=$1

  BTRFS_OPTS="-o nobarrier -o compress"

  # Mount the root device. It is expected that modules, firmware are present and updated.
  mkdir -p /sysroot /x
  mount -t btrfs "${root_device}" /x
  if [ $? -ne 0 ]; then
      logi "Error: Failed to mount BTRFS partition"
      return 1
    fi

  INITOS_ROOT=${INITOS_ROOT:-initos/recovery}

  if [ -f /x/initos/initos.env ]; then
    . /x/initos/initos.env
  else
    if [ -d "/x/@" ]; then
      INITOS_ROOT="@"
    fi
  fi

  mount -t btrfs "${root_device}" /sysroot -o subvol=${INITOS_ROOT} \
    -o noatime -o nodiratime
  if [ $? -ne 0 ]; then
    logi "Error: Failed to mount BTRFS partition ${INITOS_ROOT}, fallback to recovery"
    mount -t btrfs "${root_device}" /sysroot -o subvol=initos/recovery \
    -o noatime -o nodiratime
    if [ $? -ne 0 ]; then
        logi "Error: Failed to mount BTRFS recovery"
        return 1
    fi
  fi


  mkdir -p /lib/modules /lib/firmware /home /var/log /var/cache
  #mount -o bind /x/initos/modules /lib/modules
  mount -o bind /x/@home /home
  mount -o bind /x/@cache /var/cache
  mount -o bind /x/@log /var/log
  #mount -o bind /x/initos/firmware /lib/firmware

  # TODO: if the lib/modules and firmware are missing - unsquash the modloop-lts after
  # verifying the signature/
}

# retry function. Not used right now, will be used for LVM open
retry() {
  retries=$1
  shift

  count=0
  until "$@"; do
    exit=$?
    wait=$((count + 1))
    count=$((count + 1))
    if [ "$count" -lt "$retries" ]; then
      echo "Retry $count/$retries exited $exit, retrying in $wait seconds..."
      sleep $wait
    else
      echo "Retry $count/$retries exited $exit, no more retries left."
      return $exit
    fi
  done
}

setup_chroot() {

    # https://wiki.gentoo.org/wiki/Chroot/en
    mount --rbind /dev ${R}/dev
    mount --make-rslave ${R}/dev
    mount -t proc /proc ${R}/proc
    mount --rbind /sys ${R}/sys
    mount --make-rslave ${R}/sys
    mount --rbind /tmp ${R}/tmp
}

chroot_clean() {
    X=${1}

    umount ${X}/dev/pts
    umount  ${X}/dev/
    umount  ${X}/proc/
    umount  ${X}/tmp/
    umount  ${X}/sys/
}

cmdline() {
  local c=$(cat $1)

  # look for "--" in cmd, extract everything after
  # [[ is for extended tests, =~ regex
  if [[ "$c" =~ ".*--.*" ]]; then
    # The # means 'remove patern', ## remove longest pattern
    export KOPT_cmd="${c#*--}"
    # % and %% remove from the end
    c="${c%%--*}"
  fi


  set -- $c

  for opt; do
    #echo $opt
    # split opt in key and value
    key="${opt%%=*}"
    value="${opt#*=}"
    export "KOPT_${key/./_}"="$value" || true
  done
#  echo "cmdline: $c"
#  echo "cmd: $KOPT_cmd"
#
#  env
#  if [ -n "$KOPT_cmd" ]; then
#    echo "Will running command instead of init: $KOPT_cmd"
#  fi
}

upstamp() {
  # 10 ms precision
  read up rest </proc/uptime
  t1="${up%.*}${up#*.}0"
  echo $t1
}


# Scan /sys for 'modalias', sort and load the modules.
# This should load TPM if it is available
hwdrivers() {
  find /sys -name modalias -type f -print0 | xargs -0 sort -u | xargs modprobe -b -a
}


# support for eudev. see /etc/init.d/udev*
# At the end we need to call
# udevadm control --exit
# Requires udevd to be added to initramfs.
# Alternative: alpine nlplug-findfs
udev_start()
{
  if [ -f /sbin/udevd ]; then
    if [ -e /proc/sys/kernel/hotplug ]; then
      echo "" >/proc/sys/kernel/hotplug
    fi
    [ -d /etc/udev/rules.d ] || mkdir -p /etc/udev/rules.d

    udevd -d

    udevadm hwdb --update

    # Populating /dev with existing devices through uevents
    udevadm trigger --type=subsystems --action=add
    udevadm trigger --type=devices --action=add
    echo Udevadm  $?
	fi
}
