//! PID 1 boot sequence and initrd image handling.
//!
//! Keep docs/boot_sequence.md in sync with this module when changing boot
//! environment variables, paths, mount order, or switch-root behavior.

use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process;
use std::thread;
use std::time::{Duration, Instant};

const DEV_TPM_PREFIX: &[u8] = b"devc:";
const SECURE_TPM_PREFIX: &[u8] = b"secc:";

/// Unseal the key from TPM and return raw bytes.
pub fn unseal_key(secure_boot: bool) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let (handle, prefix, mode) = if secure_boot {
        (
            crate::tpm2::DEFAULT_SEALED_HANDLE_SECURE,
            SECURE_TPM_PREFIX,
            "secure",
        )
    } else {
        (
            crate::tpm2::DEFAULT_SEALED_HANDLE_DEV,
            DEV_TPM_PREFIX,
            "dev",
        )
    };
    unseal_key_from_handle(handle, prefix, mode)
}

pub fn unseal_key_from_handle(
    handle: u32,
    prefix: &[u8],
    mode: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    eprintln!("initos: unseal handle=0x{:08X}", handle);
    let mut dev = crate::tpm2::open()?;
    let session = crate::tpm2::start_policy_session(&mut dev)?;
    crate::tpm2::policy_pcr(&mut dev, session)?;
    let secret = strip_tpm_prefix(
        crate::tpm2::unseal(&mut dev, handle, session)?,
        prefix,
        mode,
    )?;
    eprintln!("initos: unsealed {} {} bytes", mode, secret.len());

    Ok(secret)
}

/// Full initrd boot sequence (PID 1): mount pseudo-fs, find STATE, verify images,
/// loop-mount, preserve host images under /mnt, and switch_root.
pub fn cmd_boot() -> Result<(), Box<dyn std::error::Error>> {
    let pub_key = env::var("INITOS_PUB_KEY").unwrap_or_default();
    let verified_boot_mode = std::cell::Cell::new(!pub_key.is_empty());

    let boot_run = || -> Result<(), Box<dyn std::error::Error>> {
        let img = env::var("INITOS_IMG").unwrap_or_else(|_| "/img/initos.erofs".to_string());
        let data = env::var("INITOS_DATA").unwrap_or_else(|_| "STATE".to_string());
        let kernel = kernel_release().unwrap_or_else(|e| format!("unknown ({})", e));
        eprintln!(
            "initos: boot start pid={} kernel={} img={} data={}",
            process::id(),
            kernel,
            img,
            data
        );

        for (fs, mp) in [
            ("proc", "/proc"),
            ("sysfs", "/sys"),
            ("efivarfs", "/sys/firmware/efi/efivars"),
            ("devtmpfs", "/dev"),
        ] {
            match crate::mount::mount_pseudo_fs(fs, mp) {
                Ok(_) => {}
                Err(e) => eprintln!("initos: failed to mount {} at {}: {}", fs, mp, e),
            };
        }
        let verified_boot = detect_verified_boot(!pub_key.is_empty());
        verified_boot_mode.set(verified_boot);

        let dev = find_data_device(&data)?;
        eprintln!("initos: found data device: {:?}", dev);

        let state_mount = "/z";
        crate::mount::mount_filesystem(dev.to_str().unwrap(), state_mount, "ext4", false)?;
        eprintln!("initos: mounted data device at {}", state_mount);
        unlock_state_c(state_mount, verified_boot)?;

        let root_mount = "/sysroot";
        mount_rootfs(state_mount, root_mount, &img, &pub_key)?;

        let new_state_mount = format!("{}/z", root_mount);
        crate::mount::bind_mount(state_mount, &new_state_mount)?;
        mount_host_images(state_mount, root_mount, &pub_key)?;
        bind_encrypted_state_paths(state_mount, root_mount)?;
        mount_system_filesystems(root_mount)?;

        let init = select_init(state_mount, root_mount)?;
        eprintln!(
            "initos: switching root to {} init={} args={:?}",
            root_mount, init.path, init.args
        );
        crate::mount::switch_root_with_args(root_mount, &init.path, &init.args)?;
        Ok(())
    };

    if let Err(e) = boot_run() {
        eprintln!("initos: boot failed: {}", e);
        if !verified_boot_mode.get() {
            let dev_init_path = "/opt/initos/bin/initos-initrd";
            let boot_error = e.to_string().replace('\0', "\\0");
            env::set_var("INITOS_BOOT_ERROR", &boot_error);
            eprintln!(
                "initos: executing initrd fallback: {} error={}",
                dev_init_path, boot_error
            );
            let init_c = std::ffi::CString::new(dev_init_path).unwrap();
            let argv = [init_c.as_ptr(), std::ptr::null()];
            unsafe { libc::execv(init_c.as_ptr(), argv.as_ptr()) };

            eprintln!(
                "initos: failed to exec dev init fallback: {}",
                std::io::Error::last_os_error()
            );
            process::exit(1);
        } else {
            eprintln!("initos: waiting 10 seconds before exit");
            std::thread::sleep(std::time::Duration::from_secs(10));
            process::exit(1);
        }
    }

    Ok(())
}

fn find_data_device(label: &str) -> io::Result<PathBuf> {
    if label != "USTATE" {
        return crate::mount::find_partition_by_label(label);
    }

    let deadline = Instant::now() + Duration::from_secs(20);
    eprintln!("initos: waiting for USTATE data device");
    loop {
        match crate::mount::find_partition_by_label(label) {
            Ok(dev) => return Ok(dev),
            Err(e) if Instant::now() < deadline => {
                let last_error = e;
                thread::sleep(Duration::from_secs(1));
                if Instant::now() >= deadline {
                    return Err(last_error);
                }
            }
            Err(e) => return Err(e),
        }
    }
}

fn mount_rootfs(
    state_mount: &str,
    root_mount: &str,
    img: &str,
    pub_key: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let root_name = env::var("INITOS_ROOT").unwrap_or_else(|_| "ROOTA".to_string());
    let encrypted_root = Path::new(state_mount).join("c/roots").join(&root_name);

    if encrypted_root.exists() {
        let encrypted_root_str = encrypted_root
            .to_str()
            .ok_or_else(|| format!("path is not valid UTF-8: {}", encrypted_root.display()))?;
        eprintln!(
            "initos: mounting encrypted root {} at {}",
            encrypted_root.display(),
            root_mount
        );
        recursive_bind_mount(encrypted_root_str, root_mount)?;
        return Ok(());
    }

    let img_path = format!("{}/{}", state_mount, img.trim_start_matches('/'));
    verify_image_if_key(&img_path, pub_key)?;
    crate::mount::mount_loop(&img_path, root_mount)?;
    eprintln!("initos: mounted root image at {}", root_mount);
    Ok(())
}

struct SelectedInit {
    path: String,
    args: Vec<&'static str>,
}

fn select_init(
    state_mount: &str,
    root_mount: &str,
) -> Result<SelectedInit, Box<dyn std::error::Error>> {
    if let Ok(init) = env::var("INITOS_INIT") {
        return Ok(SelectedInit {
            path: init,
            args: Vec::new(),
        });
    }

    let encrypted_init = Path::new(state_mount).join("c/initos/init");
    if encrypted_init.is_file() {
        return Ok(SelectedInit {
            path: "/z/c/initos/init".to_string(),
            args: Vec::new(),
        });
    }

    for candidate in ["/opt/initos/bin/initos-init", "/sbin/init"] {
        if Path::new(root_mount)
            .join(candidate.trim_start_matches('/'))
            .is_file()
        {
            return Ok(SelectedInit {
                path: candidate.to_string(),
                args: Vec::new(),
            });
        }
    }

    let systemd = "/lib/systemd/systemd";
    if resolve_root_path(root_mount, systemd.trim_start_matches('/'))?.is_file() {
        return Ok(SelectedInit {
            path: systemd.to_string(),
            args: vec!["--system"],
        });
    }

    Err("no init found: checked /z/c/initos/init, /opt/initos/bin/initos-init, /sbin/init, /lib/systemd/systemd".into())
}

fn unlock_state_c(
    state_mount: &str,
    verified_boot: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let c_dir = Path::new(state_mount).join("c");
    if !c_dir.exists() {
        return Ok(());
    }

    if c_is_unlocked(&c_dir) {
        if verified_boot {
            return Err(format!(
                "{} is already unlocked before initrd unlock",
                c_dir.display()
            )
            .into());
        }
        eprintln!("initos: {} is already unlocked", c_dir.display());
        return Ok(());
    }

    let c_age = Path::new(state_mount).join("initos/c.age");
    if Path::new("/dev/tpmrm0").exists() {
        match unlock_c_with_tpm(&c_dir, verified_boot) {
            Ok(()) => return Ok(()),
            Err(e) => eprintln!("initos: TPM /c unlock failed: {}", e),
        }
    }

    unlock_c_with_password(&c_dir, &c_age)
}

fn c_is_unlocked(c_dir: &Path) -> bool {
    c_dir.join("home").is_dir()
}

fn unlock_c_with_tpm(c_dir: &Path, verified_boot: bool) -> Result<(), Box<dyn std::error::Error>> {
    let fscrypt_key = unseal_key(verified_boot)?;
    add_fscrypt_key(c_dir, &fscrypt_key)?;
    if !c_is_unlocked(c_dir) {
        return Err(format!("{} did not unlock with TPM", c_dir.display()).into());
    }
    eprintln!("initos: unlocked {} using TPM", c_dir.display());
    Ok(())
}

fn unlock_c_with_password(c_dir: &Path, c_age: &Path) -> Result<(), Box<dyn std::error::Error>> {
    for attempt in 1..=3 {
        let prompt = if c_age.exists() {
            "Enter host unlock password: "
        } else {
            "Enter crypt password: "
        };
        let pass = crate::cmd::read_secret(prompt)?;
        if pass.is_empty() {
            continue;
        }

        let key_result = if c_age.exists() {
            decrypt_age_with_key_file(c_age, pass.as_bytes())
        } else {
            Ok(pass.into_bytes())
        };

        match key_result.and_then(|key| {
            add_fscrypt_key(c_dir, &key)?;
            if !c_is_unlocked(c_dir) {
                return Err(format!("{} did not unlock", c_dir.display()).into());
            }
            Ok(())
        }) {
            Ok(()) => {
                eprintln!("initos: unlocked {} using password", c_dir.display());
                return Ok(());
            }
            Err(e) if attempt < 3 => {
                eprintln!(
                    "initos: failed to unlock {}, try again: {}",
                    c_dir.display(),
                    e
                )
            }
            Err(e) => return Err(e),
        }
    }

    Err(format!("failed to unlock {}", c_dir.display()).into())
}

fn add_fscrypt_key(dir: &Path, raw_key: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
    if raw_key.is_empty() {
        return Err("fscrypt key is empty".into());
    }

    let mut key = vec![0u8; 64];
    for i in 0..64 {
        key[i] = raw_key[i % raw_key.len()];
    }

    let dir = dir
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", dir.display()))?;
    crate::fscrypt::add_key(dir, &key)?;
    Ok(())
}

fn decrypt_age_with_key_file(
    path: &Path,
    key_material: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let cipher = fs::read(path)?;
    decrypt_age_with_key(&cipher, key_material)
}

fn decrypt_age_with_key(
    cipher: &[u8],
    key_material: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    use std::str::FromStr;

    let key_string = String::from_utf8_lossy(key_material).trim().to_string();
    let mut identities: Vec<Box<dyn age::Identity>> = Vec::new();

    if !key_string.is_empty() {
        identities.push(Box::new(age::scrypt::Identity::new(
            key_string.clone().into(),
        )));
        if let Ok(identity) = age::x25519::Identity::from_str(&key_string) {
            identities.push(Box::new(identity));
        }
    }

    if identities.is_empty() {
        return Err("age decrypt key is empty".into());
    }

    let decryptor = age::Decryptor::new(std::io::Cursor::new(cipher))
        .map_err(|e| format!("decryptor: {}", e))?;
    let mut reader = decryptor
        .decrypt(identities.iter().map(|i| &**i as &dyn age::Identity))
        .map_err(|e| format!("decrypt: {}", e))?;

    let mut result = Vec::new();
    reader.read_to_end(&mut result)?;
    Ok(result)
}

fn strip_tpm_prefix(
    secret: Vec<u8>,
    prefix: &[u8],
    mode: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    secret
        .strip_prefix(prefix)
        .map(|stripped| stripped.to_vec())
        .ok_or_else(|| format!("TPM {} secret has wrong prefix", mode).into())
}

fn detect_verified_boot(pub_key_set: bool) -> bool {
    let base_path =
        env::var("INITOS_EFI_PATH").unwrap_or_else(|_| "/sys/firmware/efi/efivars".to_string());
    match crate::efi::read_secure_boot(&base_path) {
        Ok(value) => {
            let enabled = value != 0;
            eprintln!("initos: EFI SecureBoot={} verified_boot={}", value, enabled);
            enabled
        }
        Err(e) => {
            eprintln!(
                "initos: failed to read EFI SecureBoot from {}, using INITOS_PUB_KEY fallback: {}",
                base_path, e
            );
            pub_key_set
        }
    }
}

fn mount_host_images(
    state_mount: &str,
    root_mount: &str,
    pub_key: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let root_mnt = Path::new(root_mount).join("mnt");
    let root_mnt_str = root_mnt
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", root_mnt.display()))?;
    crate::mount::mount_filesystem("tmpfs", root_mnt_str, "tmpfs", false)?;

    mount_host_image(
        state_mount,
        root_mount,
        "firmware.erofs",
        "mnt/firmware",
        pub_key,
    )?;

    let kernel = kernel_release()?;
    let modules = format!("modules-{}.erofs", kernel);
    let modules_target = format!("mnt/modules/{}", kernel);
    mount_host_image(state_mount, root_mount, &modules, &modules_target, pub_key)?;
    bind_host_image_mounts(root_mount)?;
    Ok(())
}

fn bind_encrypted_state_paths(
    state_mount: &str,
    root_mount: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    bind_if_both_dirs_exist(
        &Path::new(state_mount).join("c/home"),
        &Path::new(root_mount).join("home"),
    )?;
    bind_if_both_dirs_exist(
        &Path::new(state_mount).join("c/home/root"),
        &Path::new(root_mount).join("root"),
    )?;
    bind_if_both_dirs_exist(
        &Path::new(state_mount).join("c/nix"),
        &Path::new(root_mount).join("nix"),
    )?;
    Ok(())
}

fn bind_if_both_dirs_exist(source: &Path, target: &Path) -> Result<(), Box<dyn std::error::Error>> {
    if !source.is_dir() || !target.is_dir() {
        eprintln!(
            "initos: skipping bind {} to {} (source or target missing)",
            source.display(),
            target.display()
        );
        return Ok(());
    }

    let source_str = source
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", source.display()))?;
    let target_str = target
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", target.display()))?;
    eprintln!(
        "initos: binding {} to {}",
        source.display(),
        target.display()
    );
    recursive_bind_mount(source_str, target_str)?;
    Ok(())
}

fn bind_host_image_mounts(root_mount: &str) -> Result<(), Box<dyn std::error::Error>> {
    bind_if_root_dir_exists(root_mount, "mnt/firmware", "lib/firmware")?;
    bind_if_root_dir_exists(root_mount, "mnt/modules", "lib/modules")?;
    Ok(())
}

fn bind_if_root_dir_exists(
    root_mount: &str,
    source_rel: &str,
    target_rel: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let source = Path::new(root_mount).join(source_rel);
    let target = resolve_root_path(root_mount, target_rel)?;

    if !target.is_dir() {
        eprintln!(
            "initos: {} not found in rootfs, skipping bind mount",
            target.display()
        );
        return Ok(());
    }

    let source_str = source
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", source.display()))?;
    let target_str = target
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", target.display()))?;
    eprintln!(
        "initos: binding {} to {}",
        source.display(),
        target.display()
    );
    recursive_bind_mount(source_str, target_str)?;
    Ok(())
}

fn recursive_bind_mount(source: &str, target: &str) -> io::Result<()> {
    fs::create_dir_all(target)?;

    let source_c = std::ffi::CString::new(source)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let target_c = std::ffi::CString::new(target)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;

    let ret = unsafe {
        libc::mount(
            source_c.as_ptr(),
            target_c.as_ptr(),
            std::ptr::null(),
            libc::MS_BIND | libc::MS_REC,
            std::ptr::null(),
        )
    };

    if ret != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn resolve_root_path(root_mount: &str, rel_path: &str) -> io::Result<PathBuf> {
    let root = Path::new(root_mount);
    let mut resolved = root.to_path_buf();

    for component in Path::new(rel_path).components() {
        let std::path::Component::Normal(part) = component else {
            continue;
        };

        let candidate = resolved.join(part);
        match fs::read_link(&candidate) {
            Ok(link) if link.is_absolute() => {
                let rel_link = link.strip_prefix("/").map_err(|e| {
                    io::Error::new(io::ErrorKind::InvalidData, format!("bad symlink: {}", e))
                })?;
                resolved = root.join(rel_link);
            }
            Ok(link) => {
                resolved = resolved.join(link);
            }
            Err(e) if e.kind() == io::ErrorKind::InvalidInput => {
                resolved = candidate;
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                resolved = candidate;
            }
            Err(e) => return Err(e),
        }
    }

    Ok(resolved)
}

fn mount_system_filesystems(root_mount: &str) -> Result<(), Box<dyn std::error::Error>> {
    mount_pseudo_in_root(root_mount, "proc", "proc")?;
    mount_pseudo_in_root(root_mount, "sysfs", "sys")?;
    mount_optional_pseudo_in_root(root_mount, "efivarfs", "sys/firmware/efi/efivars")?;
    mount_pseudo_in_root(root_mount, "devtmpfs", "dev")?;
    mount_fs_in_root(root_mount, "devpts", "dev/pts", "devpts")?;
    mount_fs_in_root(root_mount, "tmpfs", "dev/shm", "tmpfs")?;
    mount_fs_in_root(root_mount, "tmpfs", "run", "tmpfs")?;
    mount_fs_in_root(root_mount, "none", "sys/fs/cgroup", "cgroup2")?;
    mount_fs_in_root(root_mount, "tmpfs", "tmp", "tmpfs")?;
    Ok(())
}

fn mount_optional_pseudo_in_root(
    root_mount: &str,
    fs_type: &str,
    target_rel: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let target = Path::new(root_mount).join(target_rel);
    let target_str = target
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", target.display()))?;
    eprintln!("initos: mounting {} at {}", fs_type, target.display());
    if let Err(e) = crate::mount::mount_pseudo_fs(fs_type, target_str) {
        eprintln!(
            "initos: failed to mount {} at {}: {}",
            fs_type,
            target.display(),
            e
        );
    }
    Ok(())
}

fn mount_pseudo_in_root(
    root_mount: &str,
    fs_type: &str,
    target_rel: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let target = Path::new(root_mount).join(target_rel);
    let target_str = target
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", target.display()))?;
    eprintln!("initos: mounting {} at {}", fs_type, target.display());
    crate::mount::mount_pseudo_fs(fs_type, target_str)?;
    Ok(())
}

fn mount_fs_in_root(
    root_mount: &str,
    source: &str,
    target_rel: &str,
    fs_type: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let target = Path::new(root_mount).join(target_rel);
    let target_str = target
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", target.display()))?;
    eprintln!("initos: mounting {} at {}", fs_type, target.display());
    crate::mount::mount_filesystem(source, target_str, fs_type, false)?;
    Ok(())
}

fn mount_host_image(
    state_mount: &str,
    root_mount: &str,
    image_name: &str,
    target_rel: &str,
    pub_key: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let Some(image_path) = find_host_image(state_mount, image_name) else {
        eprintln!("initos: {} not found, skipping mount", image_name);
        return Ok(());
    };

    let image_path_str = image_path
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", image_path.display()))?;
    verify_image_if_key(image_path_str, pub_key)?;

    let target = Path::new(root_mount).join(target_rel);
    let target_str = target
        .to_str()
        .ok_or_else(|| format!("path is not valid UTF-8: {}", target.display()))?;
    eprintln!(
        "initos: mounting {} at {}",
        image_path.display(),
        target.display()
    );
    crate::mount::mount_loop(image_path_str, target_str)?;
    eprintln!(
        "initos: mounted {} at {}",
        image_path.display(),
        target.display()
    );
    Ok(())
}

fn find_host_image(state_mount: &str, image_name: &str) -> Option<PathBuf> {
    [
        Path::new(state_mount).join("img").join(image_name),
        Path::new("/img").join(image_name),
        Path::new("/data/img").join(image_name),
    ]
    .into_iter()
    .find(|path| path.exists())
}

fn kernel_release() -> Result<String, Box<dyn std::error::Error>> {
    match fs::read_to_string("/proc/sys/kernel/osrelease") {
        Ok(release) => Ok(release.trim().to_string()),
        Err(_) => {
            let mut uts = std::mem::MaybeUninit::<libc::utsname>::uninit();
            if unsafe { libc::uname(uts.as_mut_ptr()) } != 0 {
                return Err(io::Error::last_os_error().into());
            }
            let uts = unsafe { uts.assume_init() };
            let bytes: Vec<u8> = uts
                .release
                .iter()
                .take_while(|&&c| c != 0)
                .map(|&c| c as u8)
                .collect();
            Ok(String::from_utf8(bytes)?)
        }
    }
}

/// Verify an image using verify_image if INITOS_PUB_KEY is set.
pub fn verify_image_if_key(img: &str, pub_key: &str) -> Result<(), Box<dyn std::error::Error>> {
    if pub_key.is_empty() {
        return Ok(());
    }

    eprintln!("initos: verifying image {}", img);
    let valid = crate::verify::verify_image(img, pub_key)?;
    if !valid {
        return Err("image signature verification FAILED".into());
    }
    eprintln!("initos: image signature verified OK");
    Ok(())
}
