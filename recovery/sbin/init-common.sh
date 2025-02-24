#!/bin/sh

export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"

# Based on Alpine mkinitrd, but with different init script:
# - various checks to detect an BTRFS rootfs in 'insecure' mode, fallback to recovery subvol or sqfs
# - removed all networking or alpine-specific init - only job is to load a rootfs
#
# This allows using the simpler initrd, with a number of small specialized functions.
# It is also usable for VM - when the kernel lacks some drivers (btrfs, etc), to allow kernel+fixed initrd without
# using EFI + Grub + Dracut/systemd

## First step - expand busybox and mount the basic filesystems
# TODO: add timer to check if it's faster than having a volume
# that already has the links created.
initramfs_1st() {

  # No kernel options processed - we build intitramfs and cmdline in the same efi.
  # May read an initrc file if needed - but the goal is to keep it precise and simple.
  # Initramfs does not include the links (for some reason?)
  /bin/busybox mkdir -p /usr/bin \
    /usr/sbin \
    /proc \
    /sys \
    /dev \
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
  
  mkdir -p /sysroot /z /x /initos /boot/efi \
     /boot/efi2 /lib/modules /lib/firmware \
     /home /var/log /var/cache


  # shared memory area (later system will need it)
  mkdir -p /dev/shm
  mkdir -p /run

  mount -t tmpfs tmpfs /run

  # Module not present
  #mount  -t efivarfs efivarfs /sys/firmware/efi/efivars

  mount -t tmpfs -o nodev,nosuid,noexec shm /dev/shm
}

initramfs_common() {
  initramfs_1st
  mount_proc
  
  # Not sure this is still needed (used for vm)
  cmdline /proc/cmdline

  logi "Starting INITOS initramfs $(uname -r)"

  sysctl -w kernel.printk="2 4 1 7"

  # Load a set of core modules we use to load the VERITY
  # image.
  initramfs_mods

  # Attempt to find the root device - need to load modules and check blocks until
  # we find the root we want.
  udev_start

  echo "Press 'r' for remote recovery"
  echo "      'c' for manual LUKS unlock" 
  # Also: "a" for admin boot - will enable shells during init
  # "s" for starting a shell in the rootfs. Both only in insecure mode.
  read -t 4 -n 1 key

  export MODE=$key

  udevadm settle
}

# Mount a partition to a destination, creating the dir. For vfat also run a fsck
# and remove remaining FSCK files after.
# This is used for the EFI partition, to find the VERITY image.
mount_disk() {
  bootd=${1}
  boott=${2:-vfat}
  dst=${3:-/boot/efi}

  mkdir -p $dst

  if [ "$boott" == "vfat" ] ; then
    fsck.vfat -y $bootd
  fi 

  mount -t ${boott} ${bootd} ${dst}
  if [ $? -ne 0 ]; then
    lfatal "Failed to mount $bootd partition"
  fi
  
  if [ "$boott" == "vfat" ] ; then
    rm -f ${dst}/FSCK*.REC || true
  fi
}


# Load modules we may need - modules are also loaded if we get to udev
# or nlplug-findfs, but we may skip that if the core modules are enough.
initramfs_mods() {
  # Not including USB drivers.

  # Required on alpine kernel - without this there is no display
  # Debian appears to have it compiled in the kernel.
  modprobe -a simpledrm

  modprobe scsi_mod
  # Support scsi disks - needed for sata ?
  modprobe sd_mod

  # nvme appears to be linked in both deb and alpine

  # for loading recovery, modules, firmware
  modprobe squashfs
  modprobe loop
  modprobe dm-verity
  modprobe mmc_block
  # btrfs, vfat are are normally present - but may be loaded if missing
}

# Load modules we may need - modules are also loaded if we get to udev or nlplug-findfs, but 
# if we may skip that if the core modules are enough.
# 
# Unlike 'init-secure', this also loads usb drivers - will look for USB recovery
initramfs_mods_usb() {
  # For loading recovery from USB disk
  modprobe usbcore
  modprobe ehci-hcd
  modprobe ohci-hcd
  modprobe xhci-hcd
  modprobe usb-storage
}


# Mount the boot image - verity and unionfs
# This is (usually, for simplicity) the EFI partition.
mount_boot() {
  local dir=${1:-/boot/efi/initos/img}

  # It would be tempting to add persistent overlay here and make the root
  # modifiable - but that breaks the security model, we can't verify the overlay.
  # For any configs, certs, etc - we can add them to the UKI or rebuild.
  mkdir -p /initos /z/initos/log /z/initos/initos

  mount -t tmpfs root-tmpfs /initos

  mkdir -p /initos/recovery /initos/ro /initos/work /initos/rw

  logi "Mounting boot partition, signatures"

  ver=$(uname -r)

  if [ -f ${dir}/recovery.sqfs ]; then
    mkdir -p /lib/firmware
    mkdir -p /lib/modules/${ver}
    mount_verity recovery /initos/recovery ${dir}
    mount -o bind /initos/recovery/lib/firmware /lib/firmware
    mount -o bind /initos/recovery/lib/modules/${ver} /lib/modules/${ver}
    return
  fi
}

# Mount a SQFS file as a dm-verity device (if signatures found on the
# initrd /boot dir, in secure mode).
#
# The destintion dir will be an overlay drive.
mount_verity() {
  local name=$1
  local dst=$2
  local dir=${3:-/z/initos/img}

  # TODO: move it all to /var/lib/initos/ and /opt/initos
  mkdir -p /initos/ro/${name} /initos/rw/${name} /initos/work/${name}

  # The hash is on the /boot UKI, created by sign !

  # For SECURE, use /boot/hash.${name} which is signed. For insecure - it is only
  # used to verify integrity, not authenticity.
  veritysetup open ${dir}/${name}.sqfs ${name} ${dir}/${name}.sqfs.verity \
      $(cat /boot/hash.${name})
  if [ $? -ne 0 ]; then
     logi "Error: Failed to mount ${name} - verity integrity or missing files"
     
     lfatal "Error: Failed to mount ${name}"
     return 1
  fi

  mount_overlay $name $dst /dev/mapper/${name} squashfs
}

# Configure the sysroot with files from the signed image (for secure)
# or unsecure image (if LUKS failed).
root_conf() {
  mkdir -p /sysroot/boot
  if [ -f /boot/root.pem ]; then
    cp /boot/root.pem /sysroot/boot/root.pem
  fi
  if [ -f /boot/domainname ]; then
    cp /boot/domainname /sysroot/boot/domainname
  fi

  # Set MAC to the mac address
  find_mac

  # Just in case
  rm -f /sysroot/.dockerenv

  # Save logs for this boot
  if [ -d /x/initos/log ]; then
    edump /sysroot/x/initos/log/boot
    mv /tmp/hwdrivers* /sysroot/x/initos/log/boot
  fi
}

is_secure() {
  modprobe efivarfs
  mount -t efivarfs none /sys/firmware/efi/efivars
  
  LD_LIBRARY_PATH=/initos/recovery/usr/lib \
     /initos/recovery/usr/bin/mokutil --sb-state
}

# After mounting /lib/modules and firmware, load all drivers.
load_drivers() {
    # this is normally done by sysinit - we want tpm2 to be loaded
  # Needs to happen after full firmware and modules are in place
  hwdrivers > /tmp/hwdrivers.log 2>&1
  logi "hwdrivers loaded $(ls -l /dev/tpm*)"
  udevadm trigger
  udevadm settle

  logi "udevadm settle $(ls -l /dev/tpm*)"
  hwdrivers  /tmp/hwdrivers2.log 2>&1 # TPM seems to need some time to init
  logi "hwdrivers2 $(ls -l /dev/tpm*)"
}

# All remaining mounted dirs will be moved under same dir in /sysroot,
# ready to switch_root
move_mounted_to_sysroot() {
  # Will be started again in sysroot
  udevadm control --exit || true

  # From original alpine init
  cat /proc/mounts 2>/dev/null | while read DEV DIR TYPE OPTS ; do
    if [ "$DIR" != "/" -a "$DIR" != "/sysroot" -a -d "$DIR" ]; then
      mkdir -p /sysroot$DIR
      mount -o move $DIR /sysroot$DIR
    fi
  done

  sync
}

# Info log - shown on console, logged.
logi() {
	last_emsg="$*"
	echo "INITOS: $last_emsg..." > /dev/kmsg
	echo "$last_emsg\n"
}

# Verbose log - saved but not shown on console
logv() {
  local msg="$*"
	echo "INITOS: $msg..." > /dev/kmsg
}

lfatal() {
  echo "FAILED: $*"
  edump

  if [ "${INIT_OS}" = "secure" ]; then
    sleep 10
    reboot -f
  fi
  busybox ash
}

# dump info to the EFI partition (which exists if we managed to get the
#  kernel running). One goal is to support machines without display/keyboard,
# install state will be saved on the USB disk.
# Log destinations:
# - before 'boot' is mounted: in memory, console on failure to mount boot
# - after 'boot' is mounted: /z/initos/log on failure, recovery /var/log/boot
# - after 'rootfs' is mounted, on tmpfs if it works, /boot/efi if not.
#
# All 'fatal' logs go to /boot/efi if it is mounted.
edump() {
  local dst=${1:-/z/initos/log/${MAC}}

  if [ ! -e /z/initos ]; then
    echo "Boot disk not found"
    return
  fi

  # current date and time
  export LOG_DIR=${dst}/$(date +"%Y-%m-%d-%H-%M-%S")
  mkdir -p ${LOG_DIR}

  echo "$ORIG_DEVICES" > ${LOG_DIR}/devices_before_mods

  blkid > ${LOG_DIR}/blkid
  cat /proc/filesystems > ${LOG_DIR}/filesystems
  cat /proc/devices > ${LOG_DIR}/devices

  mount > ${LOG_DIR}/initrafms.mounts
  lsmod > ${LOG_DIR}/lsmod.log

  dmesg > ${LOG_DIR}/dmesg.log

  env > ${LOG_DIR}/env.log
}

# unlock the encrypted disk using the TPM. 'c' mapper will be used.

unlock_tpm() {
  local part=$1

  if [ -z "$part" ]; then
    part=$(blkid | grep 'TYPE="crypto_LUKS"' | cut -d: -f1 )
  fi

  # Arch recommends: 1,2,5,7 ( firmware, firmware options, GPT layout, secure boot status)
  #PCRS="0,1,7"
  # 2 = pluggable executable code
  # 3 = pluggable firmware data
  # 4 = boot manager code
  # 5 = boot manager data, include GPT partitions
  # 6 = resume events
  # 7 = secure boot status, certificates

  # The setup script makes sure this handle is set - we may try multiple handles or
  # list nv persistent and try all.

  #export TPM2TOOLS_TCTI="device:/dev/tpm0"
  HANDLES=$(tpm2_getcap handles-persistent)
  logi "Persistent handles $HANDLES" 

  handle=0x81000001
  if [ -f /z/initos/luks.handle ]; then
    handle=$(cat /z/initos/luks.handle)
  fi
  
  set +x
  PASSPHRASE=$(tpm2_unseal -c ${handle} -p pcr:sha256:7)
  if [ -z $PASSPHRASE ]; then 
    logi "Handle $handle:7 failed, try L8" 
    PASSPHRASE=$(tpm2_unseal -c ${handle} -p pcr:sha256:8)
  fi 
  if [ -z $PASSPHRASE ]; then 
    logi "Handle $handle:8 failed, try 8100..2" 
    PASSPHRASE=$(tpm2_unseal -c 0x81000002 -p pcr:sha256:7)
  fi 
  if [ -z $PASSPHRASE ]; then 
    logi "Handle $handle:8 failed, try 8100..2" 
    PASSPHRASE=$(tpm2_unseal -c 0x81800001 -p pcr:sha256:7)
  fi 
  
  echo -n "$PASSPHRASE" | cryptsetup open $part c -
}


# Mount an overlayfs on top of a squashfs, dm-verity or other RO device.
# name and destination are needed, device (default to /dev/mapper/NAME)
# and type (default to squashfs) are optional.
mount_overlay() {
  local name=$1
  local dst=$2
  local dev=${3:-/dev/mapper/${name}}
  local type=${4:-squashfs}

  mkdir -p /initos/ro/${name} /initos/rw/${name} /initos/work/${name} ${dst}
  mount -t $type $dev /initos/ro/${name}
  if [ $? -ne 0 ]; then
     lfatal "Error: Failed to sqfs ${name}"
     return 1
  fi

  mkdir -p ${dst}
  mount -t overlay \
    -o lowerdir=/initos/ro/${name},upperdir=/initos/rw/${name},workdir=/initos/work/${name} \
    overlayfs ${dst}
  if [ $? -ne 0 ]; then
     lfatal "Error: Failed to mount overlay ${name}"
  fi
}

# Logic to find and mount the root device.
#
# To properly mount we also need to find the modules/firmware, and will also mount
# the recovery image which can be used as a container/chroot.
#
# - in 'dev' mode - wait for a key for 6 seconds.
#    - 'r' will use the recovery image on USB (by label)
#    - 'a' will use the recovery image on USB (by label), open a shell
#    - 'c' will mount the LUKS with user-input
#    - default - will try to mount LUKS with TPM2, fallback to recovery
# - in 'secure' mode - will attempt to boot LUKS with TPM2, fallback to recovery
# - recovery and boot partitions are mounted
# -

# open LUKS drive using keyboard
# If successful, /x will be mounted as btrfs.
open_luks_manual() {
  cryptd=$(blkid | grep 'TYPE="crypto_LUKS"' | cut -d: -f1 )
  if [ -n "$cryptd" ]; then
    logi Attempting to mount LUKS using keyboard $cryptd
    cryptsetup luksOpen $cryptd c
    if [ $? -eq 0 ]; then
      logi "Manual LUKS worked, mounting" 
      mount_btrfs_raw /dev/mapper/c /x
      if [ $? -eq 0 ]; then
        logi "BTRFS mounted using user key"
        return
      fi
    fi
    
  fi
}

open_luks() {
  local crypted=$1
  
  echo "Found LUKS device: ${cryptd}"
  
  unlock_tpm $cryptd
  if [ $? -eq 0 ]; then
    logi "TPM unlocked, mounting btrfs on /x"
    mount_btrfs_raw /dev/mapper/c /x
    if [ $? -eq 0 ]; then
        logi "BTRFS mounted"
        return
    fi
  fi
}

mount_btrfs_raw() {
  local root_device=${1}
  local dst=${2}

  BTRFS_OPTS="-o nobarrier -o compress"

  mkdir -p /dst

  mount -t btrfs "${root_device}" ${dst}
  if [ $? -ne 0 ]; then
      logi "Error: Failed to mount BTRFS partition"
      return 1
  fi
}

# Mount /sysroot from the BTRFS subvolume, mount additional volumes.
mount_rootfs() {
  root_device=${1:-/dev/mapper/c}

  if [ -f /x/swap ]; then
    swapon /x/swap
  fi

  if [ -f /x/initos/initos.env ]; then
    . /x/initos/initos.env
  fi

  if [ -z $INITOS_ROOT ]; then
    if [ -d "/x/@" ]; then
      INITOS_ROOT="@"
    else
      INITOS_ROOT="NOTFOUND"
    fi
  fi

  if [ -d /x/${INITOS_ROOT} ]; then
    mount -t btrfs "${root_device}" /sysroot -o subvol=${INITOS_ROOT} \
      -o noatime -o nodiratime
    if [ $? -ne 0 ]; then
      logi "Error: Failed to mount BTRFS partition ${INITOS_ROOT}, fallback to recovery"
    fi
  fi

  if [ -d /x/@home ] ; then
    mount -o bind /x/@home /home
  fi
  if [ -d /x/@cache ]; then
    mount -o bind /x/@cache /var/cache
  fi
  if [ -d /x/@log ]; then
    mount -o bind /x/@log /var/log
  fi

  # if [ -d /x/@recovery/rw ]; then
  #   echo Persistent overlay
  #   mkdir -p /initos/precovery /x/@recovery/work
  #   mount -t overlay \
  #     -o lowerdir=/initos/ro/recovery,upperdir=/x/@recovery/rw,workdir=/x/@recovery/work \
  #     overlayfs /initos/precovery
  #   if [ $? -ne 0 ]; then
  #      logi "Error: Failed to mount precovery"
  #   fi
  # fi
}


# Mount recovery using the signed image. This happens only if the TPM can't decrypt the LUKS partition.
#
# Few untrusted files will be added for networking, from the non-encrypted disk - enough to get SSH started.
# Keep the ssh keys and IPs separate from the ones in the encrypted disk, only for remote recovery.
mount_recovery() {
  dir=${1:-/boot/efi/insecure}

  logi "Mounting recovery squash as rootfs, using EFI minimal files"
  if [ -d /initos/precovery/etc ]; then
    mount -o bind /initos/precovery /sysroot
  else
    mount -o bind /initos/recovery /sysroot
  fi

  if [ -f ${dir}/interfaces ]; then
    cp ${dir}/interfaces /sysroot/etc/network/interfaces
  fi

  if [ -d ${dir}/ssh ]; then
    cp -a ${dir}/ssh /sysroot/etc
    chmod 700 /sysroot/etc/ssh/ssh_host*
 fi

  # TODO: from boot partition !
  if [ -f ${dir}/authorized_keys ]; then
    mkdir -p /sysroot/root/.ssh
    cp ${dir}/authorized_keys /sysroot/root/.ssh/authorized_keys
    chown -R root /sysroot/root
  fi
 
  if [ -f ${dir}/wpa_supplicant.conf ]; then
    cp ${dir}/wpa_supplicant.conf /sysroot/etc/wpa_supplicant/wpa_supplicant.conf
  fi

  # Patch the init files on the host to current version (image may be older)
  cp /sbin/init-* /sysroot/sbin

  if [ ! -f /sysroot/etc/resolv.conf ]; then
    echo "nameserver 1.1.1.1" > /sysroot/etc/resolv.conf
  fi
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
    if [[ "$key" =~ "initos.*" ]]; then
      key=${key/-/_}
      export "KOPT_${key/./_}"="$value" || true
    fi
  done
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

# host files identifies the (insecure) host config. It is used for the recovery
# image customization or for the rootfs configuration.
# In secure mode it can be signed or encrypted - but it can't hold private keys
# secure unless TPM is used - however at that point a real disk is simpler.
find_mac() {
  if [ -f /sys/class/net/wlan0/address ]; then
    export MAC=$(cat /sys/class/net/wlan0/address)
  elif [ -f /sys/class/net/eth0/address ]; then
    export MAC=$(cat /sys/class/net/eth0/address)
  else
    export MAC="00:00:00:00:00:00"
  fi

  MAC=${MAC//:/-}

}

