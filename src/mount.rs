//! Filesystem mount operations for the initrd boot process.
//!
//! Provides functions to mount pseudo-filesystems (proc, sys, devtmpfs),
//! find block devices by label, mount ext4/erofs filesystems, set up loop devices,
//! and perform switch_root.

use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
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

    let flags = if fstype == "devtmpfs" {
        libc::MS_NOSUID | libc::MS_NOEXEC
    } else {
        libc::MS_NOSUID | libc::MS_NODEV | libc::MS_NOEXEC
    };
    let ret = unsafe {
        libc::mount(
            source.as_ptr(),
            target_c.as_ptr(),
            fstype_c.as_ptr(),
            flags,
            std::ptr::null(),
        )
    };

    if ret != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Find a block device by partition label or ext4 filesystem label.
///
/// Direct `/dev/...` paths are returned as-is. Otherwise this first checks
/// `/dev/disk/by-label/<label>`, then scans `/sys/class/block/` for ext4
/// filesystem labels and partition names.
///
/// If the label starts with "USB", retries up to 10 times (1s sleep).
pub fn find_partition_by_label(label: &str) -> io::Result<PathBuf> {
    if label.starts_with("/dev/") {
        return Ok(PathBuf::from(label));
    }

    let max_attempts = if label.starts_with("USB") { 10 } else { 1 };

    for attempt in 1..=max_attempts {
        if let Some(dev) = device_by_filesystem_label(label) {
            return Ok(dev);
        }

        if let Some(dev) = scan_sysfs_for_label(label) {
            return Ok(dev);
        }

        if attempt < max_attempts {
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    }

    Err(io::Error::new(
        io::ErrorKind::NotFound,
        format!("block device with label '{}' not found", label),
    ))
}

/// Find a block device by a filesystem label path when userspace created one.
fn device_by_filesystem_label(label: &str) -> Option<PathBuf> {
    let label_path = Path::new("/dev/disk/by-label").join(label);
    if label_path.exists() {
        match fs::canonicalize(&label_path) {
            Ok(path) => return Some(path),
            Err(_) => return Some(label_path),
        }
    }
    None
}

/// Scan sysfs block devices for an ext4 filesystem label or partition label.
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
        let dev_path = PathBuf::from(format!("/dev/{}", dev_name_str));

        match read_ext4_label(&dev_path) {
            Ok(Some(fs_label)) if fs_label == label => return Some(dev_path),
            _ => {}
        }

        let uevent_path = entry.path().join("uevent");
        if let Ok(uevent) = fs::read_to_string(&uevent_path) {
            for line in uevent.lines() {
                if let Some(val) = line.strip_prefix("PARTNAME=") {
                    if val == label {
                        return Some(dev_path);
                    }
                }
            }
        }
    }

    None
}

/// Read an ext2/3/4 filesystem volume name directly from the superblock.
fn read_ext4_label(device: &Path) -> io::Result<Option<String>> {
    let mut file = File::open(device)?;
    let mut superblock = [0u8; 136];
    file.seek(SeekFrom::Start(1024))?;
    file.read_exact(&mut superblock)?;

    if superblock[56] != 0x53 || superblock[57] != 0xef {
        return Ok(None);
    }

    let raw_label = &superblock[120..136];
    let end = raw_label
        .iter()
        .position(|&b| b == 0)
        .unwrap_or(raw_label.len());
    let label = String::from_utf8_lossy(&raw_label[..end])
        .trim()
        .to_string();
    if label.is_empty() {
        Ok(None)
    } else {
        Ok(Some(label))
    }
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

/// Bind mount an existing mounted path at another path.
pub fn bind_mount(source: &str, target: &str) -> io::Result<()> {
    fs::create_dir_all(target)?;

    let source_c =
        CString::new(source).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let target_c =
        CString::new(target).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

    let ret = unsafe {
        libc::mount(
            source_c.as_ptr(),
            target_c.as_ptr(),
            std::ptr::null(),
            libc::MS_BIND,
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
    fs::create_dir_all(target)?;

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

    let loop_dev_c = CString::new(loop_dev.as_str())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let loop_fd = unsafe { libc::open(loop_dev_c.as_ptr(), libc::O_RDWR) };
    if loop_fd < 0 {
        return Err(io::Error::last_os_error());
    }

    let img_c =
        CString::new(image_path).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let img_fd = unsafe { libc::open(img_c.as_ptr(), libc::O_RDONLY) };
    if img_fd < 0 {
        let err = io::Error::last_os_error();
        unsafe { libc::close(loop_fd) };
        return Err(err);
    }

    const LOOP_SET_FD: libc::c_int = 0x4C00;
    let ret = unsafe { libc::ioctl(loop_fd, LOOP_SET_FD, img_fd) };
    unsafe { libc::close(img_fd) };

    if ret < 0 {
        let err = io::Error::last_os_error();
        unsafe { libc::close(loop_fd) };
        return Err(err);
    }
    unsafe { libc::close(loop_fd) };

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

    if unsafe { libc::chdir(new_root_c.as_ptr()) } != 0 {
        let err = io::Error::last_os_error();
        eprintln!("initos: chdir failed: {}", err);
        return Err(err);
    }

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

    if unsafe { libc::chroot(dot.as_ptr()) } != 0 {
        let err = io::Error::last_os_error();
        eprintln!("initos: chroot failed: {}", err);
        return Err(err);
    }

    if unsafe { libc::chdir(slash.as_ptr()) } != 0 {
        let err = io::Error::last_os_error();
        eprintln!("initos: post-chroot chdir / failed: {}", err);
        return Err(err);
    }

    let argv = [init_c.as_ptr(), std::ptr::null()];
    unsafe { libc::execv(init_c.as_ptr(), argv.as_ptr()) };

    let err = io::Error::last_os_error();
    eprintln!("initos: execv failed: {}", err);
    Err(err)
}
