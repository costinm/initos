//! PID 1 boot sequence and initrd image handling.

use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process;
use std::thread;
use std::time::{Duration, Instant};

/// Unseal the key from TPM and return raw bytes.
pub fn unseal_key() -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let handle = crate::tpm2::read_handle_file(
        crate::tpm2::SEALED_HANDLE_PATH,
        crate::tpm2::DEFAULT_SEALED_HANDLE,
    )?;
    eprintln!("initos: unseal handle=0x{:08X}", handle);
    let mut dev = crate::tpm2::open()?;
    let session = crate::tpm2::start_policy_session(&mut dev)?;
    crate::tpm2::policy_pcr(&mut dev, session)?;
    let secret = crate::tpm2::unseal(&mut dev, handle, session)?;
    eprintln!("initos: unsealed {} bytes", secret.len());

    Ok(secret)
}

/// Full initrd boot sequence (PID 1): mount pseudo-fs, find STATE, verify images,
/// loop-mount, preserve host images under /mnt, and switch_root.
pub fn cmd_boot() -> Result<(), Box<dyn std::error::Error>> {
    let pub_key = env::var("INITOS_PUB_KEY").unwrap_or_default();
    let is_dev_mode = pub_key.is_empty();

    let boot_run = || -> Result<(), Box<dyn std::error::Error>> {
        let img = env::var("INITOS_IMG").unwrap_or_else(|_| "/img/initos.erofs".to_string());
        let data = env::var("INITOS_DATA").unwrap_or_else(|_| "STATE".to_string());
        let init =
            env::var("INITOS_INIT").unwrap_or_else(|_| "/opt/initos/bin/initos-init".to_string());
        let kernel = kernel_release().unwrap_or_else(|e| format!("unknown ({})", e));
        eprintln!(
            "initos: boot start pid={} kernel={} img={} data={} init={}",
            process::id(),
            kernel,
            img,
            data,
            init
        );

        for (fs, mp) in [("proc", "/proc"), ("sysfs", "/sys"), ("devtmpfs", "/dev")] {
            match crate::mount::mount_pseudo_fs(fs, mp) {
                Ok(_) => {}
                Err(e) => eprintln!("initos: failed to mount {} at {}: {}", fs, mp, e),
            };
        }

        let dev = find_data_device(&data)?;
        eprintln!("initos: found data device: {:?}", dev);

        let state_mount = "/z";
        crate::mount::mount_filesystem(dev.to_str().unwrap(), state_mount, "ext4", false)?;
        eprintln!("initos: mounted data device at {}", state_mount);
        unlock_state_c(state_mount)?;

        let img_path = format!("{}/{}", state_mount, img.trim_start_matches('/'));
        verify_image_if_key(&img_path, &pub_key)?;

        let root_mount = "/sysroot";
        crate::mount::mount_loop(&img_path, root_mount)?;
        eprintln!("initos: mounted root image at {}", root_mount);

        let new_state_mount = format!("{}/z", root_mount);
        crate::mount::bind_mount(state_mount, &new_state_mount)?;
        mount_host_images(state_mount, root_mount, &pub_key)?;

        eprintln!("initos: switching root to {} init={}", root_mount, init);
        crate::mount::switch_root(root_mount, &init)?;
        Ok(())
    };

    if let Err(e) = boot_run() {
        eprintln!("initos: boot failed: {}", e);
        if is_dev_mode {
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

fn unlock_state_c(state_mount: &str) -> Result<(), Box<dyn std::error::Error>> {
    let c_dir = Path::new(state_mount).join("c");
    if !c_dir.exists() {
        return Ok(());
    }

    let c_age = Path::new(state_mount).join("initos/c.age");
    let tpm_handle = Path::new(state_mount).join("initos/tpm/tpm_handle");

    if tpm_handle.exists() && Path::new("/dev/tpmrm0").exists() {
        match unlock_c_with_tpm(&c_dir, &c_age) {
            Ok(()) => return Ok(()),
            Err(e) => eprintln!("initos: TPM /c unlock failed: {}", e),
        }
    }

    unlock_c_with_password(&c_dir, &c_age)
}

fn unlock_c_with_tpm(c_dir: &Path, c_age: &Path) -> Result<(), Box<dyn std::error::Error>> {
    let tpm_key = unseal_key()?;
    let fscrypt_key = if c_age.exists() {
        decrypt_age_with_key_file(c_age, &tpm_key)?
    } else {
        tpm_key
    };
    add_fscrypt_key(c_dir, &fscrypt_key)?;
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

        match key_result.and_then(|key| add_fscrypt_key(c_dir, &key)) {
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

    let modules = format!("modules-{}.erofs", kernel_release()?);
    mount_host_image(state_mount, root_mount, &modules, "mnt/modules", pub_key)?;
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

    let valid = crate::verify::verify_image(img, pub_key)?;
    if !valid {
        return Err("image signature verification FAILED".into());
    }
    eprintln!("initos: image signature verified OK");
    Ok(())
}
