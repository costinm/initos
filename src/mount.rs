//! Filesystem mount operations for the initrd boot process.
//!
//! Provides functions to mount pseudo-filesystems (proc, sys, devtmpfs),
//! find partitions by label, mount ext4/erofs filesystems, set up loop devices,
//! and perform switch_root.

use std::ffi::CString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Mount a pseudo-filesystem (proc, sysfs, devtmpfs).
///
/// # Arguments
/// * `fstype` - Filesystem type string (e.g., "proc", "sysfs", "devtmpfs")
/// * `target` - Mount point path
pub fn mount_pseudo_fs(fstype: &str, target: &str) -> io::Result<()> {
    // Create target directory if it doesn't exist
    fs::create_dir_all(target)?;

    let source =
        CString::new(fstype).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let target_c =
        CString::new(target).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let fstype_c =
        CString::new(fstype).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

    // TODO: add noexec,nosuid,nodev
    let ret = unsafe {
        libc::mount(
            source.as_ptr(),
            target_c.as_ptr(),
            fstype_c.as_ptr(),
            0,
            std::ptr::null(),
        )
    };

    if ret != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Find a block device partition by its filesystem label.
///
/// Scans `/sys/class/block/` entries for one whose
/// `/sys/class/block/<dev>/device/../<dev>/partition` and label match.
///
/// If the label starts with "USB", retries up to 10 times (1s sleep)
/// to allow slow USB devices to enumerate.
pub fn find_partition_by_label(label: &str) -> io::Result<PathBuf> {
    if label.starts_with("/dev/") {
        return Ok(PathBuf::from(label));
    }

    let max_attempts = if label.starts_with("USB") { 10 } else { 1 };

    for attempt in 1..=max_attempts {
        if let Some(dev) = scan_sysfs_for_label(label) {
            return Ok(dev);
        }

        if attempt < max_attempts {
            eprintln!(
                "initos: partition '{}' not found, retrying ({}/{})",
                label, attempt, max_attempts
            );
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    }

    // Final failure — dump diagnostics
    let block_dir = Path::new("/sys/class/block");
    eprintln!(
        "initos: Could not find partition with label '{}'. Dumping block devices:",
        label
    );
    if block_dir.exists() {
        if let Ok(entries) = fs::read_dir(block_dir) {
            for entry in entries.flatten() {
                let dev_name = entry.file_name();
                let uevent_path = entry.path().join("uevent");
                let mut properties = Vec::new();
                if let Ok(uevent) = fs::read_to_string(&uevent_path) {
                    for line in uevent.lines() {
                        if line.starts_with("PARTNAME=")
                            || line.starts_with("DEVNAME=")
                            || line.starts_with("DEVTYPE=")
                        {
                            properties.push(line.to_string());
                        }
                    }
                }
                eprintln!("initos:   - {:?}: {}", dev_name, properties.join(", "));
            }
        }
    } else {
        eprintln!("initos:   /sys/class/block does not exist!");
    }

    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("partition with label '{}' not found", label),
    ))
}

/// Scan sysfs block devices for a partition matching the given label.
/// Returns `Some(PathBuf)` with the `/dev/<name>` path on match, `None` otherwise.
fn scan_sysfs_for_label(label: &str) -> Option<PathBuf> {
    let block_dir = Path::new("/sys/class/block");
    if !block_dir.exists() {
        return None;
    }

    let entries = fs::read_dir(block_dir).ok()?;
    for entry in entries.flatten() {
        let dev_name = entry.file_name();
        let dev_name_str = dev_name.to_string_lossy().to_string();

        // Skip non-partition entries (no "partition" file)
        if !entry.path().join("partition").exists() {
            continue;
        }

        let uevent_path = entry.path().join("uevent");
        if let Ok(uevent) = fs::read_to_string(&uevent_path) {
            eprintln!("initos: block device {} uevent:\n{}", dev_name_str, uevent);
            for line in uevent.lines() {
                if let Some(val) = line.strip_prefix("PARTNAME=") {
                    if val == label {
                        return Some(PathBuf::from(format!("/dev/{}", dev_name_str)));
                    }
                }
            }
        }
    }

    None
}

/// Mount a filesystem.
///
/// # Arguments
/// * `device` - Block device path (e.g., "/dev/sda1")
/// * `target` - Mount point path
/// * `fs_type` - Filesystem type (e.g., "ext4", "erofs")
pub fn mount_filesystem(
    device: &str,
    target: &str,
    fs_type: &str,
    readonly: bool,
) -> io::Result<()> {
    fs::create_dir_all(target)?;

    let source =
        CString::new(device).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let target_c =
        CString::new(target).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let fstype = CString::new(fs_type)?;

    let flags = if readonly { libc::MS_RDONLY } else { 0 };

    eprintln!(
        "initos: mount_filesystem api - dev={} target={} fstype={} flags={}",
        device, target, fs_type, flags
    );

    let ret = unsafe {
        libc::mount(
            source.as_ptr(),
            target_c.as_ptr(),
            fstype.as_ptr(),
            flags,
            std::ptr::null(),
        )
    };

    if ret != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Mount an ext4 filesystem.
///
/// # Arguments
/// * `device` - Block device path (e.g., "/dev/sda1")
/// * `target` - Mount point path
pub fn mount_ext4(device: &str, target: &str) -> io::Result<()> {
    mount_filesystem(device, target, "ext4", true)
}

/// Set up a loop device for the given image file and mount it as erofs.
///
/// Uses /dev/loop-control to allocate a free loop device, then configures
/// it with the given image path.
pub fn mount_loop(image_path: &str, target: &str) -> io::Result<()> {
    eprintln!("initos: mount_loop - create_dir_all {}", target);
    fs::create_dir_all(target)?;

    eprintln!("initos: mount_loop - opening /dev/loop-control");
    let ctrl_path = CString::new("/dev/loop-control").unwrap();
    let ctrl_fd = unsafe { libc::open(ctrl_path.as_ptr(), libc::O_RDWR) };
    if ctrl_fd < 0 {
        return Err(io::Error::last_os_error());
    }

    const LOOP_CTL_GET_FREE: libc::c_int = 0x4C82;
    let free_idx = unsafe { libc::ioctl(ctrl_fd, LOOP_CTL_GET_FREE) };
    unsafe { libc::close(ctrl_fd) };

    if free_idx < 0 {
        return Err(io::Error::last_os_error());
    }

    let loop_dev = format!("/dev/loop{}", free_idx);
    eprintln!("initos: mount_loop - acquired {}", loop_dev);

    let loop_dev_c = CString::new(loop_dev.as_str())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let loop_fd = unsafe { libc::open(loop_dev_c.as_ptr(), libc::O_RDWR) };
    if loop_fd < 0 {
        return Err(io::Error::last_os_error());
    }

    eprintln!("initos: mount_loop - opening image file {}", image_path);
    let img_c =
        CString::new(image_path).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let img_fd = unsafe { libc::open(img_c.as_ptr(), libc::O_RDONLY) };
    if img_fd < 0 {
        let err = io::Error::last_os_error();
        unsafe { libc::close(loop_fd) };
        return Err(err);
    }

    eprintln!("initos: mount_loop - LOOP_SET_FD");
    const LOOP_SET_FD: libc::c_int = 0x4C00;
    let ret = unsafe { libc::ioctl(loop_fd, LOOP_SET_FD, img_fd) };
    unsafe { libc::close(img_fd) };

    if ret < 0 {
        let err = io::Error::last_os_error();
        unsafe { libc::close(loop_fd) };
        return Err(err);
    }
    unsafe { libc::close(loop_fd) };

    eprintln!("initos: mount_loop - mounting erofs on {}", loop_dev);
    mount_filesystem(&loop_dev, target, "erofs", true)
}

/// Switch root to the new filesystem and exec init.
///
/// This performs:
/// 1. chdir to new_root
/// 2. mount --move . /
/// 3. chroot .
/// 4. exec init_path
///
/// This function does not return on success.
pub fn switch_root(new_root: &str, init_path: &str) -> io::Result<()> {
    let new_root_c =
        CString::new(new_root).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let init_c =
        CString::new(init_path).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let dot = CString::new(".").unwrap();
    let slash = CString::new("/").unwrap();

    eprintln!("initos: switch_root - chdir to {}", new_root);
    if unsafe { libc::chdir(new_root_c.as_ptr()) } != 0 {
        let err = io::Error::last_os_error();
        eprintln!("initos: chdir failed: {}", err);
        return Err(err);
    }

    eprintln!("initos: switch_root - mount --move . /");
    let fstype_null: *const libc::c_char = std::ptr::null();
    if unsafe {
        libc::mount(
            dot.as_ptr(),
            slash.as_ptr(),
            fstype_null,
            libc::MS_MOVE,
            std::ptr::null(),
        )
    } != 0
    {
        let err = io::Error::last_os_error();
        eprintln!("initos: mount --move failed: {}", err);
        return Err(err);
    }

    eprintln!("initos: switch_root - chroot .");
    if unsafe { libc::chroot(dot.as_ptr()) } != 0 {
        let err = io::Error::last_os_error();
        eprintln!("initos: chroot failed: {}", err);
        return Err(err);
    }

    eprintln!("initos: switch_root - chdir /");
    if unsafe { libc::chdir(slash.as_ptr()) } != 0 {
        let err = io::Error::last_os_error();
        eprintln!("initos: post-chroot chdir / failed: {}", err);
        return Err(err);
    }

    eprintln!("initos: switch_root - execv {}", init_path);
    let argv = [init_c.as_ptr(), std::ptr::null()];
    unsafe { libc::execv(init_c.as_ptr(), argv.as_ptr()) };

    let err = io::Error::last_os_error();
    eprintln!("initos: execv failed: {}", err);
    Err(err)
}
