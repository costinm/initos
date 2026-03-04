//! fs-verity digest measurement via FS_IOC_MEASURE_VERITY ioctl.
//!
//! Provides a function to retrieve the kernel-computed fs-verity Merkle tree
//! digest for a file that has fs-verity enabled.

use std::fs::File;
use std::io;
use std::os::unix::io::AsRawFd;
use std::path::Path;

// Use c_ulong to prevent sign extension on 64-bit systems.
// FS_IOC_MEASURE_VERITY is _IOWR('f', 134, struct fsverity_digest)
// 0xC0046686
const FS_IOC_MEASURE_VERITY: libc::c_ulong = 0xC004_6686;

// FS_IOC_ENABLE_VERITY is _IOW('f', 133, struct fsverity_enable_arg)
// 0x40806685
const FS_IOC_ENABLE_VERITY: libc::c_ulong = 0x4080_6685;

/// Matches the kernel's `struct fsverity_digest` from `linux/fsverity.h`.
#[repr(C)]
struct FsVerityDigest {
    digest_algorithm: u16,
    digest_size: u16,
    digest: [u8; 64],
}

#[repr(C)]
struct FsVerityEnableArg {
    version: u32,
    hash_algorithm: u32,
    block_size: u32,
    salt_size: u32,
    salt_ptr: u64,
    sig_size: u32,
    __reserved1: u32,
    sig_ptr: u64,
    __reserved2: [u64; 11],
}

/// Hash algorithm identifiers from the kernel.
#[allow(dead_code)]
pub const FS_VERITY_HASH_ALG_SHA256: u16 = 1;
#[allow(dead_code)]
pub const FS_VERITY_HASH_ALG_SHA512: u16 = 2;

pub fn measure_verity<P: AsRef<Path>>(path: P) -> io::Result<(u16, Vec<u8>)> {
    let file = File::open(path.as_ref())?;
    measure_verity_fd(&file)
}

pub fn measure_verity_fd(file: &File) -> io::Result<(u16, Vec<u8>)> {
    let fd = file.as_raw_fd();
    let mut digest = FsVerityDigest {
        digest_algorithm: 0,
        digest_size: 64,
        digest: [0u8; 64],
    };

    let ret = unsafe { libc::ioctl(fd, FS_IOC_MEASURE_VERITY as _, &mut digest as *mut _) };
    if ret != 0 {
        return Err(io::Error::last_os_error());
    }

    let size = digest.digest_size as usize;
    Ok((digest.digest_algorithm, digest.digest[..size].to_vec()))
}

/// Enable fs-verity on an open file descriptor.
/// The file must be opened with write access, and the underlying filesystem
/// must support fs-verity and be mounted read-write.
pub fn enable_verity_fd(file: &File) -> io::Result<()> {
    let fd = file.as_raw_fd();
    let mut arg = FsVerityEnableArg {
        version: 1, // FS_VERITY_VERSION_1
        hash_algorithm: FS_VERITY_HASH_ALG_SHA256 as u32,
        block_size: 4096,
        salt_size: 0,
        salt_ptr: 0,
        sig_size: 0,
        __reserved1: 0,
        sig_ptr: 0,
        __reserved2: [0; 11],
    };

    let ret = unsafe { libc::ioctl(fd, FS_IOC_ENABLE_VERITY as _, &mut arg as *mut _) };
    if ret != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Format a digest as a hex string.
pub fn digest_to_hex(digest: &[u8]) -> String {
    hex::encode(digest)
}
