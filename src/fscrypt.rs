//! fscrypt kernel integration via raw ioctls.
//!
//! Provides FS_IOC_ADD_ENCRYPTION_KEY and FS_IOC_SET_ENCRYPTION_POLICY
//! without requiring the fscrypt CLI.

use std::fs::OpenOptions;
use std::io;
use std::os::unix::io::AsRawFd;

/// FS_IOC_ADD_ENCRYPTION_KEY = _IOWR('f', 0x17, struct fscrypt_add_key_arg)
const FS_IOC_ADD_ENCRYPTION_KEY: libc::c_ulong = 0xC050_6617;
/// FS_IOC_SET_ENCRYPTION_POLICY = _IOR('f', 19, struct fscrypt_policy_v1)
/// Works for v2 policies too — kernel checks version byte.
const FS_IOC_SET_ENCRYPTION_POLICY: libc::c_ulong = 0x800C_6613;

const FSCRYPT_KEY_SPEC_TYPE_IDENTIFIER: u32 = 2;
const FSCRYPT_KEY_IDENTIFIER_SIZE: usize = 16;
const FSCRYPT_MODE_AES_256_XTS: u8 = 1;
const FSCRYPT_MODE_AES_256_CTS: u8 = 4;
const FSCRYPT_POLICY_V2: u8 = 2;
/// Pad filenames to 16 bytes (standard for ext4)
const FSCRYPT_POLICY_FLAGS_PAD_16: u8 = 0x02;

/// Add an encryption key to a filesystem's keyring via FS_IOC_ADD_ENCRYPTION_KEY.
///
/// `path` can be any path on the target filesystem (e.g., mountpoint or dir).
/// Returns the 16-byte key identifier assigned by the kernel.
pub fn add_key(path: &str, raw_key: &[u8]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    // struct fscrypt_add_key_arg layout (80 bytes + raw key):
    //   key_spec.type_       (u32)  offset 0
    //   key_spec.__reserved  (u32)  offset 4
    //   key_spec.u           (32B)  offset 8  (identifier returned here)
    //   raw_size             (u32)  offset 40
    //   key_id               (u32)  offset 44
    //   __reserved           (32B)  offset 48
    //   raw[]                       offset 80
    let base_size = 80usize;
    let total = base_size + raw_key.len();
    let mut buf = vec![0u8; total];

    buf[0..4].copy_from_slice(&FSCRYPT_KEY_SPEC_TYPE_IDENTIFIER.to_ne_bytes());
    buf[40..44].copy_from_slice(&(raw_key.len() as u32).to_ne_bytes());
    buf[base_size..total].copy_from_slice(raw_key);

    let file = OpenOptions::new()
        .read(true)
        .open(path)
        .map_err(|e| format!("open {}: {}", path, e))?;

    let ret = unsafe {
        libc::ioctl(
            file.as_raw_fd(),
            FS_IOC_ADD_ENCRYPTION_KEY as libc::c_int,
            buf.as_mut_ptr(),
        )
    };
    if ret < 0 {
        return Err(format!(
            "FS_IOC_ADD_ENCRYPTION_KEY on {}: {}",
            path,
            io::Error::last_os_error()
        )
        .into());
    }

    Ok(buf[8..8 + FSCRYPT_KEY_IDENTIFIER_SIZE].to_vec())
}

/// Set a v2 fscrypt encryption policy on an empty directory.
///
/// Uses AES-256-XTS for contents and AES-256-CTS for filenames.
pub fn set_policy(dir: &str, key_identifier: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
    // struct fscrypt_policy_v2 layout (24 bytes)
    let mut policy = [0u8; 24];
    policy[0] = FSCRYPT_POLICY_V2;
    policy[1] = FSCRYPT_MODE_AES_256_XTS;
    policy[2] = FSCRYPT_MODE_AES_256_CTS;
    policy[3] = FSCRYPT_POLICY_FLAGS_PAD_16;
    let id_len = key_identifier.len().min(FSCRYPT_KEY_IDENTIFIER_SIZE);
    policy[8..8 + id_len].copy_from_slice(&key_identifier[..id_len]);

    let file = OpenOptions::new()
        .read(true)
        .open(dir)
        .map_err(|e| format!("open {}: {}", dir, e))?;

    let ret = unsafe {
        libc::ioctl(
            file.as_raw_fd(),
            FS_IOC_SET_ENCRYPTION_POLICY as libc::c_int,
            policy.as_ptr(),
        )
    };
    if ret < 0 {
        return Err(format!(
            "FS_IOC_SET_ENCRYPTION_POLICY on {}: {}",
            dir,
            io::Error::last_os_error()
        )
        .into());
    }

    Ok(())
}

/// Format bytes as hex string.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}
