//! Filesystem mount operations for the initrd boot process.
//!
//! Provides functions to mount pseudo-filesystems (proc, sys, devtmpfs),
//! find block devices by label, mount ext4/erofs filesystems, set up loop devices,
//! and perform switch_root.

use std::ffi::CString;
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
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

fn read_uevent_value(path: &Path, key: &str) -> io::Result<Option<String>> {
    let uevent = fs::read_to_string(path)?;
    let prefix = format!("{}=", key);
    Ok(uevent
        .lines()
        .find_map(|line| line.strip_prefix(&prefix).map(str::to_owned)))
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

/// Get the parent disk name from a partition device name.
/// e.g., "sda1" -> "sda", "nvme0n1p101" -> "nvme0n1"
pub fn partition_parent_disk(partition_name: &str) -> Option<String> {
    let stripped = partition_name.trim_end_matches(|c: char| c.is_ascii_digit());
    let stripped = if stripped.ends_with('p')
        && stripped[..stripped.len() - 1].ends_with(|c: char| c.is_ascii_digit())
    {
        &stripped[..stripped.len() - 1]
    } else {
        stripped
    };
    if stripped.is_empty() {
        None
    } else {
        Some(stripped.to_string())
    }
}

/// Resolve a partition device path to its parent disk device path.
/// Uses /sys/block/ to find the parent disk.
pub fn resolve_parent_disk(partition_path: &Path) -> io::Result<Option<PathBuf>> {
    // Try to find the sysfs entry for this device
    let dev_name = partition_path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "cannot extract device name"))?;

    let sys_block = Path::new("/sys/block");
    if !sys_block.exists() {
        return Ok(None);
    }

    // /sys/class/block entries are symlinks. Their resolved parent is the disk
    // for ordinary partitions such as sda1, nvme0n1p101, and mmcblk0p1.
    let part_sys = sys_block.join(dev_name);
    if part_sys.exists() && part_sys.join("partition").exists() {
        if let Ok(canonical) = fs::canonicalize(&part_sys) {
            if let Some(disk_name) = canonical
                .parent()
                .and_then(Path::file_name)
                .and_then(|name| name.to_str())
            {
                return Ok(Some(PathBuf::from(format!("/dev/{}", disk_name))));
            }
        }
    }

    // Search all block devices for one that contains this partition
    for entry in fs::read_dir(sys_block)? {
        let entry = entry?;
        let disk_name = entry.file_name().to_string_lossy().to_string();
        let disk_sys = entry.path();

        // Check if this disk has the partition
        let part_path = disk_sys.join(dev_name);
        if part_path.exists() && part_path.join("partition").exists() {
            return Ok(Some(PathBuf::from(format!("/dev/{}", disk_name))));
        }
    }

    // Fallback: use name-based heuristic
    if let Some(disk_name) = partition_parent_disk(dev_name) {
        let disk_dev = PathBuf::from(format!("/dev/{}", disk_name));
        if disk_dev.exists() {
            return Ok(Some(disk_dev));
        }
    }

    Ok(None)
}

/// List all partitions of a given disk as /dev/ paths.
pub fn list_disk_partitions(disk_path: &Path) -> io::Result<Vec<PathBuf>> {
    let disk_name = disk_path
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "cannot extract disk name"))?;

    let mut partitions = Vec::new();
    let disk_sys = format!("/sys/block/{}", disk_name);

    if let Ok(entries) = fs::read_dir(&disk_sys) {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            // A partition entry under /sys/block/<disk>/ has a "partition" file
            if entry.path().join("partition").exists() {
                partitions.push(PathBuf::from(format!("/dev/{}", name)));
            }
        }
    }

    // Sort by partition number (numeric sort)
    partitions.sort_by(|a, b| {
        let a_name = a
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let b_name = b
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let a_num: u32 = a_name
            .chars()
            .filter(|c| c.is_ascii_digit())
            .collect::<String>()
            .parse()
            .unwrap_or(0);
        let b_num: u32 = b_name
            .chars()
            .filter(|c| c.is_ascii_digit())
            .collect::<String>()
            .parse()
            .unwrap_or(0);
        a_num.cmp(&b_num)
    });

    Ok(partitions)
}

/// Check if a block device has an ext4 filesystem by reading the superblock magic.
pub fn is_ext4(device: &Path) -> io::Result<bool> {
    let mut file = File::open(device)?;
    let mut magic = [0u8; 2];
    file.seek(SeekFrom::Start(1024 + 56))?;
    file.read_exact(&mut magic)?;
    Ok(magic == [0x53, 0xef])
}

/// Find a partition on a specific disk by label.
/// Scans only the partitions of the given disk.
pub fn find_partition_on_disk_by_label(
    disk_path: &Path,
    label: &str,
) -> io::Result<Option<PathBuf>> {
    let partitions = list_disk_partitions(disk_path)?;

    for part in &partitions {
        // Check ext4 superblock label
        if let Ok(Some(fs_label)) = read_ext4_label(part) {
            if fs_label == label {
                return Ok(Some(part.clone()));
            }
        }

        // Check partition name/label via uevent
        let part_name = part.file_name().and_then(|n| n.to_str()).unwrap_or("");
        let uevent_path = format!(
            "/sys/block/{}/{}",
            disk_path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            part_name
        );
        let uevent_file = format!("{}/uevent", uevent_path);
        if let Ok(uevent) = fs::read_to_string(&uevent_file) {
            for line in uevent.lines() {
                if let Some(val) = line.strip_prefix("PARTNAME=") {
                    if val == label {
                        return Ok(Some(part.clone()));
                    }
                }
            }
        }

        // Also check /dev/disk/by-label symlink
        let label_path = Path::new("/dev/disk/by-label").join(label);
        if label_path.exists() {
            if let Ok(canonical) = fs::canonicalize(&label_path) {
                if canonical.ends_with(part) {
                    return Ok(Some(part.clone()));
                }
            }
        }
    }

    Ok(None)
}

/// Find partition N on a disk (by partition number).
pub fn find_partition_by_number(
    disk_path: &Path,
    partition_number: u32,
) -> io::Result<Option<PathBuf>> {
    let partitions = list_disk_partitions(disk_path)?;

    for part in &partitions {
        let part_name = part.file_name().and_then(|n| n.to_str()).unwrap_or("");

        let disk_name = disk_path
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("");
        let part_num_path = Path::new("/sys/block")
            .join(disk_name)
            .join(part_name)
            .join("partition");
        if let Ok(num_str) = fs::read_to_string(part_num_path) {
            if let Ok(num) = num_str.trim().parse::<u32>() {
                if num == partition_number {
                    return Ok(Some(part.clone()));
                }
            }
        }
    }

    Ok(None)
}

/// Find the boot disk by matching EFI boot device info against sysfs.
/// Returns (disk_path, partition_path) if found.
pub fn find_boot_disk(
    partition_guid: Option<&[u8; 16]>,
    partition_number: Option<u32>,
) -> io::Result<Option<(PathBuf, PathBuf)>> {
    let block_dir = Path::new("/sys/class/block");
    if !block_dir.exists() {
        return Ok(None);
    }

    let partition_guid = partition_guid.map(|g| {
        format!(
            "{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
            g[3], g[2], g[1], g[0], g[5], g[4], g[7], g[6], g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15]
        )
    });

    let mut number_matches = Vec::new();

    for entry in fs::read_dir(block_dir)? {
        let entry = entry?;
        let dev_name = entry.file_name().to_string_lossy().to_string();
        let dev_path = PathBuf::from(format!("/dev/{}", dev_name));
        let part_num_path = entry.path().join("partition");
        if !part_num_path.exists() {
            continue;
        }

        let actual_number = fs::read_to_string(part_num_path)
            .ok()
            .and_then(|value| value.trim().parse::<u32>().ok());
        if partition_number.is_some() && actual_number != partition_number {
            continue;
        }
        let Some(disk_path) = resolve_parent_disk(&dev_path)? else {
            continue;
        };

        if let Some(ref expected_guid) = partition_guid {
            let actual_guid = read_uevent_value(&entry.path().join("uevent"), "PARTUUID")?
                .map(|value| value.replace('-', "").to_lowercase());
            if actual_guid.as_ref() == Some(expected_guid) {
                eprintln!(
                    "initos: found boot disk {} partition {} by GPT partition GUID",
                    disk_path.display(),
                    dev_name
                );
                return Ok(Some((disk_path, dev_path)));
            }
        } else if partition_number.is_some() {
            number_matches.push((disk_path, dev_path));
        }
    }

    if number_matches.len() == 1 {
        Ok(number_matches.pop())
    } else {
        if number_matches.len() > 1 {
            eprintln!(
                "initos: partition number {:?} is ambiguous across {} disks",
                partition_number,
                number_matches.len()
            );
        }
        Ok(None)
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

/// Mount a filesystem with an explicit comma-separated option string.
pub fn mount_filesystem_with_options(
    device: &str,
    target: &str,
    fs_type: &str,
    readonly: bool,
    options: &str,
) -> io::Result<()> {
    fs::create_dir_all(target)?;
    let source =
        CString::new(device).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let target_c =
        CString::new(target).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let fstype =
        CString::new(fs_type).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let data = CString::new(options).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let flags = if readonly { libc::MS_RDONLY } else { 0 };
    let ret = unsafe {
        libc::mount(
            source.as_ptr(),
            target_c.as_ptr(),
            fstype.as_ptr(),
            flags,
            data.as_ptr().cast(),
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
    switch_root_with_args(new_root, init_path, &[])
}

/// Switch root to the new filesystem and exec init with additional arguments.
pub fn switch_root_with_args(new_root: &str, init_path: &str, args: &[&str]) -> io::Result<()> {
    let new_root_c =
        CString::new(new_root).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let init_c =
        CString::new(init_path).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let arg_cstrings = args
        .iter()
        .map(|arg| CString::new(*arg).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e)))
        .collect::<io::Result<Vec<_>>>()?;
    let env_cstrings = current_environment()?;
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

    let mut argv = Vec::with_capacity(args.len() + 2);
    argv.push(init_c.as_ptr());
    argv.extend(arg_cstrings.iter().map(|arg| arg.as_ptr()));
    argv.push(std::ptr::null());

    let mut envp = Vec::with_capacity(env_cstrings.len() + 1);
    envp.extend(env_cstrings.iter().map(|entry| entry.as_ptr()));
    envp.push(std::ptr::null());

    unsafe { libc::execve(init_c.as_ptr(), argv.as_ptr(), envp.as_ptr()) };

    let err = io::Error::last_os_error();
    eprintln!("initos: execve failed: {}", err);
    Err(err)
}

fn current_environment() -> io::Result<Vec<CString>> {
    std::env::vars_os()
        .map(|(key, value)| {
            let mut entry = Vec::new();
            entry.extend_from_slice(key.as_os_str().as_bytes());
            entry.push(b'=');
            entry.extend_from_slice(value.as_os_str().as_bytes());
            CString::new(entry).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn partition_parent_names_cover_common_linux_devices() {
        assert_eq!(partition_parent_disk("sda1").as_deref(), Some("sda"));
        assert_eq!(
            partition_parent_disk("nvme0n1p101").as_deref(),
            Some("nvme0n1")
        );
        assert_eq!(
            partition_parent_disk("mmcblk0p102").as_deref(),
            Some("mmcblk0")
        );
    }

    #[test]
    fn ext4_detection_does_not_require_a_label() {
        let mut image = tempfile::NamedTempFile::new().unwrap();
        image.as_file_mut().set_len(2048).unwrap();
        image.seek(SeekFrom::Start(1024 + 56)).unwrap();
        image.write_all(&[0x53, 0xef]).unwrap();
        image.flush().unwrap();

        assert!(is_ext4(image.path()).unwrap());
    }

    #[test]
    fn reads_partuuid_from_partition_uevent() {
        let mut uevent = tempfile::NamedTempFile::new().unwrap();
        writeln!(
            uevent,
            "MAJOR=259\nPARTUUID=533f3dd0-2bc1-0545-b816-0d636099dad7"
        )
        .unwrap();
        assert_eq!(
            read_uevent_value(uevent.path(), "PARTUUID")
                .unwrap()
                .as_deref(),
            Some("533f3dd0-2bc1-0545-b816-0d636099dad7")
        );
    }
}
