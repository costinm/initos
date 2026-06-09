//! initos — Unified init tool: TPM2 unseal, fscrypt, verified boot, image mount.
//!
//! Subcommands:
//!   (no args)              As PID 1: full boot sequence. Otherwise: unseal.
//!   unseal                 Unseal TPM2 key via PCR SHA256:7 policy
//!   lock_tpm               Extend PCR 7 to prevent further unsealing
//!   primary                Create a TPM2 primary key and persist it, required for seal.
//!   seal <SECRET>          Seal a key to TPM2 with PCR SHA256:7 policy
//!   fscrypt <PATH>         Check FSCRYPT_KEY env or prompt for key + add to filesystem keyring (unlock)
//!   fscrypt-setup <DIR>    Check FSCRYPT_KEY env or prompt for key + add to keyring + set encryption policy
//!   boot                   Full initrd boot sequence (mount, verify, switch_root)
//!   mount <IMG> <DIR>      Verify verity SHA matches the .sig, and loop-mount an image
//!   verify <IMG>           Verify fsverity digest + .sig signature of an image
//!   efi                    Read EFI variables (SecureBoot, BootCurrent, db)
//!   encrypt [ARGS]         Encrypt stdin using age to x25519 recipients (args).
//!   decrypt                Decrypt stdin using age with x25519 identity from KEY_FILE or KEY
//!   recovery-encrypt <SECRET> [PUB_KEY]
//!                          Encrypt a secret for recovery using an Ed25519 public key.
//!
//! Environment for initrd boot:
//!   INITOS_PUB_KEY   base64 ed25519 public key (empty = skip verification)
//!   INITOS_IMG       image path (default: /img/initos.erofs, boot mode)
//!   INITOS_DATA      partition label (default: STATE, boot mode)

use std::env;
use std::fs;
use std::io::{self, Write};
use std::process;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let result = if args.len() < 2 {
        // No args: PID 1 → boot, otherwise unseal
        if process::id() == 1 {
            cmd_boot()
        } else {
            cmd_unseal()
        }
    } else {
        match args[1].as_str() {
            "unseal" => cmd_unseal(),
            "lock_tpm" => cmd_lock_tpm(),
            "primary" => cmd_primary(),
            "seal" => {
                if args.len() < 3 {
                    eprintln!("Usage: initos seal <SECRET>");
                    process::exit(1);
                }
                cmd_seal(&args[2])
            }
            "fscrypt" => {
                if args.len() < 3 {
                    eprintln!("Usage: initos fscrypt <MOUNTPOINT>");
                    process::exit(1);
                }
                cmd_fscrypt(&args[2])
            }
            "fscrypt-setup" => {
                if args.len() < 3 {
                    eprintln!("Usage: initos fscrypt-setup <DIR>");
                    process::exit(1);
                }
                cmd_fscrypt_setup(&args[2])
            }
            "boot" => cmd_boot(),
            "mount" => {
                if args.len() < 4 {
                    eprintln!("Usage: initos mount <IMAGE> <MOUNTPOINT>");
                    process::exit(1);
                }
                cmd_mount(&args[2], &args[3])
            }
            "verify" => {
                if args.len() < 3 {
                    eprintln!("Usage: initos verify <IMAGE>");
                    process::exit(1);
                }
                cmd_verify(&args[2])
            }
            "efi" => cmd_efi(),
            "encrypt" => initos::cmd::cmd_encrypt(),
            "decrypt" => initos::cmd::cmd_decrypt(),
            "recovery-encrypt" => {
                if args.len() < 3 {
                    eprintln!("Usage: initos recovery-encrypt <SECRET> [PUB_KEY_B64]");
                    process::exit(1);
                }
                let pub_key = if args.len() >= 4 {
                    args[3].clone()
                } else {
                    match env::var("INITOS_PUB_KEY") {
                        Ok(key) => key,
                        Err(_) => {
                            eprintln!("PUB_KEY_B64 argument or INITOS_PUB_KEY is required");
                            process::exit(1);
                        }
                    }
                };
                initos::cmd::cmd_recovery_encrypt(&args[2], &pub_key)
            }
            "help" | "--help" | "-h" => {
                initos::cmd::print_help();
                Ok(())
            }
            other => {
                eprintln!("Unknown command: {}", other);
                initos::cmd::print_help();
                process::exit(1);
            }
        }
    };
    if let Err(e) = result {
        eprintln!("initos: {}", e);
        process::exit(1);
    }
}

// ─── Subcommands ────────────────────────────────────────────────────────────

/// Unseal the key from TPM and return raw bytes.
fn unseal_key() -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let handle = initos::tpm2::read_handle_file(
        initos::tpm2::SEALED_HANDLE_PATH,
        initos::tpm2::DEFAULT_SEALED_HANDLE,
    )?;
    eprintln!("initos: unseal handle=0x{:08X}", handle);
    let mut dev = initos::tpm2::open()?;
    let session = initos::tpm2::start_policy_session(&mut dev)?;
    initos::tpm2::policy_pcr(&mut dev, session)?;
    let secret = initos::tpm2::unseal(&mut dev, handle, session)?;
    eprintln!("initos: unsealed {} bytes", secret.len());

    Ok(secret)
}

/// Extend PCR 7 with random data to prevent other applications from unsealing
/// the key in the same boot session.
fn cmd_lock_tpm() -> Result<(), Box<dyn std::error::Error>> {
    let mut dev = initos::tpm2::open()?;
    initos::tpm2::pcr_extend(&mut dev, 7)?;
    eprintln!("initos: PCR 7 extended (sealed against further unseal)");
    Ok(())
}



/// Unseal and print to stdout.
fn cmd_unseal() -> Result<(), Box<dyn std::error::Error>> {
    let secret = unseal_key()?;
    io::stdout().write_all(&secret)?;
    Ok(())
}

/// Fscrypt unlock: get key, add to filesystem keyring.
fn cmd_fscrypt(mountpoint: &str) -> Result<(), Box<dyn std::error::Error>> {
    let key = initos::cmd::get_fscrypt_key()?;
    let identifier = initos::fscrypt::add_key(mountpoint, &key)?;
    eprintln!(
        "initos: fscrypt key added (id={}) on {}",
        initos::fscrypt::hex(&identifier),
        mountpoint
    );
    Ok(())
}

/// Fscrypt setup: get key (env or prompt), add to keyring, set v2 policy on empty directory.
fn cmd_fscrypt_setup(dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    let key = initos::cmd::get_fscrypt_key()?;
    let identifier = initos::fscrypt::add_key(dir, &key)?;
    eprintln!(
        "initos: fscrypt key added (id={})",
        initos::fscrypt::hex(&identifier)
    );

    initos::fscrypt::set_policy(dir, &identifier)?;
    eprintln!("initos: fscrypt policy set on {}", dir);
    Ok(())
}

/// Primary: create RSA-2048 storage primary key, persist at 0x81000000, save handle.
fn cmd_primary() -> Result<(), Box<dyn std::error::Error>> {
    fs::create_dir_all(initos::tpm2::TPM_DIR)?;
    let mut dev = initos::tpm2::open()?;

    let transient = initos::tpm2::create_primary(&mut dev)?;
    eprintln!("initos: primary transient=0x{:08X}", transient);

    let persistent = initos::tpm2::DEFAULT_PRIMARY_HANDLE;
    initos::tpm2::try_evict_persistent(&mut dev, persistent);
    initos::tpm2::evict_control(&mut dev, transient, persistent)?;
    eprintln!("initos: persisted primary at 0x{:08X}", persistent);

    fs::write(
        initos::tpm2::PRIMARY_HANDLE_PATH,
        format!("0x{:08X}\n", persistent),
    )?;
    eprintln!("initos: saved {}", initos::tpm2::PRIMARY_HANDLE_PATH);
    Ok(())
}



/// Seal: create trial policy, create sealed object, load, persist, save handle.
fn cmd_seal(secret: &str) -> Result<(), Box<dyn std::error::Error>> {
    fs::create_dir_all(initos::tpm2::TPM_DIR)?;

    let primary = initos::tpm2::read_handle_file(
        initos::tpm2::PRIMARY_HANDLE_PATH,
        initos::tpm2::DEFAULT_PRIMARY_HANDLE,
    )?;
    eprintln!("initos: seal under primary=0x{:08X}", primary);

    let mut dev = initos::tpm2::open()?;

    // 1. Get the PCR policy digest via a trial session
    let trial = initos::tpm2::start_trial_session(&mut dev)?;
    initos::tpm2::policy_pcr(&mut dev, trial)?;
    let digest = initos::tpm2::policy_get_digest(&mut dev, trial)?;
    initos::tpm2::flush_context(&mut dev, trial)?;
    eprintln!("initos: policy digest ({} bytes)", digest.len());

    // 2. Create sealed object under the primary
    let (priv_area, pub_area) =
        initos::tpm2::create(&mut dev, primary, secret.as_bytes(), &digest)?;
    eprintln!(
        "initos: created sealed object (priv={}, pub={})",
        priv_area.len(),
        pub_area.len()
    );

    // 3. Load it
    let loaded = initos::tpm2::load(&mut dev, primary, &priv_area, &pub_area)?;
    eprintln!("initos: loaded transient=0x{:08X}", loaded);

    // 4. Persist it
    let persistent = initos::tpm2::DEFAULT_SEALED_HANDLE;
    initos::tpm2::try_evict_persistent(&mut dev, persistent);
    initos::tpm2::evict_control(&mut dev, loaded, persistent)?;
    eprintln!("initos: persisted sealed at 0x{:08X}", persistent);

    // 5. Save handle
    fs::write(
        initos::tpm2::SEALED_HANDLE_PATH,
        format!("0x{:08X}\n", persistent),
    )?;
    eprintln!("initos: saved {}", initos::tpm2::SEALED_HANDLE_PATH);
    Ok(())
}

// ─── Verify / Mount / Boot ──────────────────────────────────────────────────

/// Full initrd boot sequence (PID 1): mount pseudo-fs, find STATE, verify image,
/// loop-mount, switch_root.
fn cmd_boot() -> Result<(), Box<dyn std::error::Error>> {
    let pub_key = env::var("INITOS_PUB_KEY").unwrap_or_default();
    let is_dev_mode = pub_key.is_empty();

    let boot_run = || -> Result<(), Box<dyn std::error::Error>> {
        let img = env::var("INITOS_IMG").unwrap_or_else(|_| "/img/initos.erofs".to_string());
        let data = env::var("INITOS_DATA").unwrap_or_else(|_| "STATE".to_string());
        let init = env::var("INITOS_INIT")
            .unwrap_or_else(|_| "/opt/initos/bin/initos-init-ver".to_string());
        eprintln!(
            "initos: boot mode (PID {}) img={} data={} init={}",
            process::id(),
            img,
            data,
            init
        );

        // 1. Mount pseudo-filesystems
        for (fs, mp) in [("proc", "/proc"), ("sysfs", "/sys"), ("devtmpfs", "/dev")] {
            eprintln!("initos: mounting {}", fs);
            match initos::mount::mount_pseudo_fs(fs, mp) {
                Ok(_) => {}
                // May happen in debug mode if already mounted
                Err(e) => eprintln!("initos: failed to mount {} at {}: {}", fs, mp, e),
            };
        }

        // 2. Find and mount STATE device
        eprintln!("initos: looking for data device '{}'", data);
        let dev = initos::mount::find_partition_by_label(&data)?;
        eprintln!("initos: found data device: {:?}", dev);

        let mount_point = "/mnt/data";
        initos::mount::mount_filesystem(dev.to_str().unwrap(), mount_point, "ext4", false)?;

        // 3. Verify image
        let img_path = format!("{}/{}", mount_point, img.trim_start_matches('/'));
        verify_image_if_key(&img_path, &pub_key)?;

        // 4. Loop-mount
        let root_mount = "/mnt/root";
        eprintln!("initos: mounting image at {}", root_mount);
        initos::mount::mount_loop(&img_path, root_mount)?;

        let state_mount = format!("{}/z", root_mount);
        eprintln!("initos: binding {} to {}", mount_point, state_mount);
        initos::mount::bind_mount(mount_point, &state_mount)?;

        // 5. Switch root
        eprintln!("initos: switching root to {} init={}", root_mount, init);
        initos::mount::switch_root(root_mount, &init)?;
        Ok(())
    };

    if let Err(e) = boot_run() {
        eprintln!("initos: boot failed: {}", e);
        if is_dev_mode {
            let dev_init_path = "/opt/initos/bin/initos-init-dev";
            eprintln!("initos: executing dev init fallback: {}", dev_init_path);
            let init_c = std::ffi::CString::new(dev_init_path).unwrap();
            let argv = [init_c.as_ptr(), std::ptr::null()];
            unsafe { libc::execv(init_c.as_ptr(), argv.as_ptr()) };

            eprintln!("initos: failed to exec dev init fallback: {}", std::io::Error::last_os_error());
            process::exit(1);
        } else {
            eprintln!("initos: waiting 10 seconds before exit");
            std::thread::sleep(std::time::Duration::from_secs(10));
            process::exit(1);
        }
    }

    Ok(())
}

/// Verify and loop-mount an erofs image.
fn cmd_mount(img: &str, mount_point: &str) -> Result<(), Box<dyn std::error::Error>> {
    let pub_key = env::var("INITOS_PUB_KEY").unwrap_or_default();
    verify_image_if_key(img, &pub_key)?;

    eprintln!("initos: mounting image {} at {}", img, mount_point);
    initos::mount::mount_loop(img, mount_point)?;
    eprintln!("initos: mount_ok {}", mount_point);
    Ok(())
}

/// Verify the fsverity digest + signature of an image.
fn cmd_verify(img: &str) -> Result<(), Box<dyn std::error::Error>> {
    let pub_key = env::var("INITOS_PUB_KEY").unwrap_or_default();
    if pub_key.is_empty() {
        eprintln!("initos: INITOS_PUB_KEY not set, nothing to verify");
        return Ok(());
    }
    let valid = initos::verify::verify_image(img, &pub_key)?;
    if !valid {
        return Err("image signature verification FAILED".into());
    }
    eprintln!("initos: VERIFIED OK: {}", img);
    Ok(())
}

/// Verify an image using verify_image if INITOS_PUB_KEY is set.
fn verify_image_if_key(img: &str, pub_key: &str) -> Result<(), Box<dyn std::error::Error>> {
    if pub_key.is_empty() {
        eprintln!("initos: INITOS_PUB_KEY not set, skipping verification");
    } else {
        eprintln!("initos: verifying image {}", img);
        let valid = initos::verify::verify_image(img, pub_key)?;
        if !valid {
            return Err("image signature verification FAILED".into());
        }
        eprintln!("initos: image signature verified OK");
    }
    Ok(())
}

/// Read and display EFI variables.
fn cmd_efi() -> Result<(), Box<dyn std::error::Error>> {
    let base_path =
        env::var("INITOS_EFI_PATH").unwrap_or_else(|_| "/sys/firmware/efi/efivars".to_string());
    let info = initos::efi::read_efi_info(&base_path)?;
    print!("{}", info);
    Ok(())
}



#[cfg(test)]
mod tests {
    use super::*;
    use age::secrecy::ExposeSecret;
    use std::io::Cursor;
    use std::io::Read;
    use std::process::Command;
    use std::str::FromStr;
    use tempfile::NamedTempFile;

    fn gen_keypair() -> (String, String) {
        let identity = age::x25519::Identity::generate();
        let recipient = identity.to_public();
        (
            identity.to_string().expose_secret().to_string(),
            recipient.to_string(),
        )
    }

    fn encrypt_for_test(
        recipient: &str,
        plaintext: &[u8],
    ) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let recip = age::x25519::Recipient::from_str(recipient)?;
        let encryptor =
            age::Encryptor::with_recipients(std::iter::once(&recip as &dyn age::Recipient))?;
        let mut buf = Vec::new();
        let mut w = encryptor.wrap_output(&mut buf)?;
        w.write_all(plaintext)?;
        w.finish()?;
        Ok(buf)
    }

    fn initos_binary() -> Result<std::path::PathBuf, Box<dyn std::error::Error>> {
        if let Ok(path) = std::env::var("INITOS_BINARY") {
            return Ok(path.into());
        }

        if let Ok(path) = std::env::var("CARGO_BIN_EXE_initos") {
            return Ok(path.into());
        }

        let mut path = std::env::current_exe()?;
        path.pop();
        if path.file_name().is_some_and(|name| name == "deps") {
            path.pop();
        }
        path.push("initos");
        Ok(path)
    }

    fn decrypt_for_test(
        identity: &str,
        cipher: &[u8],
    ) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
        let id = age::x25519::Identity::from_str(identity)?;
        let decryptor = age::Decryptor::new(Cursor::new(cipher))?;
        let mut decrypted = Vec::new();
        let mut r = decryptor.decrypt(std::iter::once(&id as &dyn age::Identity))?;
        r.read_to_end(&mut decrypted)?;
        Ok(decrypted)
    }

    #[test]
    #[ignore = "Requires initos binary to be in PATH or set INITOS_BINARY"]
    fn test_encrypt_compatible_with_age_cli() -> Result<(), Box<dyn std::error::Error>> {
        let (identity, recipient) = gen_keypair();
        let plaintext = b"test encrypt compatible";
        let encrypted = encrypt_for_test(&recipient, plaintext)?;

        let mut identity_file = NamedTempFile::new()?;
        identity_file.write_all(identity.as_bytes())?;
        identity_file.flush()?;

        // Write encrypted data to temp file
        let mut cipher_file = NamedTempFile::new()?;
        cipher_file.write_all(&encrypted)?;
        cipher_file.flush()?;

        let status = Command::new("age")
            .args([
                "-d",
                "-i",
                identity_file.path().to_str().unwrap(),
                "-o",
                "/dev/null",
                cipher_file.path().to_str().unwrap(),
            ])
            .spawn()
            .unwrap();
        let output = status.wait_with_output()?;
        assert!(
            output.status.success(),
            "age decryption failed: {:?}",
            output
        );
        Ok(())
    }

    #[test]
    #[ignore = "Requires initos binary to be in PATH or set INITOS_BINARY"]
    fn test_age_cli_encrypt_compatible_with_decrypt() -> Result<(), Box<dyn std::error::Error>> {
        let (identity, recipient) = gen_keypair();
        let plaintext = b"test decrypt compatible";

        let mut input_file = NamedTempFile::new()?;
        input_file.write_all(plaintext)?;
        input_file.flush()?;

        let output_file = NamedTempFile::new()?;
        let output_path = output_file.path().to_path_buf();
        drop(output_file);

        let status = Command::new("age")
            .args(["-r", &recipient, "-o", output_path.to_str().unwrap()])
            .stdin(std::process::Stdio::null())
            .arg(input_file.path())
            .spawn()
            .unwrap();
        let result = status.wait_with_output()?;
        assert!(
            result.status.success(),
            "age encryption failed: {:?}",
            result
        );

        let encrypted = std::fs::read(&output_path)?;
        let decrypted = decrypt_for_test(&identity, &encrypted)?;
        assert_eq!(&decrypted[..], plaintext);
        Ok(())
    }

    #[test]
    #[ignore = "Requires initos binary to be in PATH or set INITOS_BINARY"]
    fn test_scrypt_encrypt_decrypt() -> Result<(), Box<dyn std::error::Error>> {
        let plaintext = b"test scrypt";
        let pass = "testpassphrase123".to_string();

        let recip = age::scrypt::Recipient::new(pass.clone().into());
        let encryptor =
            age::Encryptor::with_recipients(std::iter::once(&recip as &dyn age::Recipient))?;
        let mut encrypted = Vec::new();
        let mut w = encryptor.wrap_output(&mut encrypted)?;
        w.write_all(plaintext)?;
        w.finish()?;

        let identity = age::scrypt::Identity::new(pass.into());
        let decryptor = age::Decryptor::new(Cursor::new(&encrypted))?;
        let mut decrypted = Vec::new();
        let mut r = decryptor.decrypt(std::iter::once(&identity as &dyn age::Identity))?;
        r.read_to_end(&mut decrypted)?;

        assert_eq!(&decrypted[..], plaintext);
        Ok(())
    }

    #[test]
    #[ignore = "Requires initos binary to be in PATH or set INITOS_BINARY"]
    fn test_scrypt_compatible_with_age_cli() -> Result<(), Box<dyn std::error::Error>> {
        let pass = "testpassphrase456".to_string();
        let plaintext = b"scrypt compatible test";

        let recip = age::scrypt::Recipient::new(pass.clone().into());
        let encryptor =
            age::Encryptor::with_recipients(std::iter::once(&recip as &dyn age::Recipient))?;
        let mut encrypted = Vec::new();
        let mut w = encryptor.wrap_output(&mut encrypted)?;
        w.write_all(plaintext)?;
        w.finish()?;

        let mut cipher_file = NamedTempFile::new()?;
        cipher_file.write_all(&encrypted)?;
        cipher_file.flush()?;

        let output_path = NamedTempFile::new()?.into_temp_path();

        // Use rexpect to create a pseudo-terminal (pty) since age requires /dev/tty
        // for interactive scrypt passphrases
        let cmd = format!(
            "age -d -o {} {}",
            output_path.to_str().unwrap(),
            cipher_file.path().to_str().unwrap()
        );

        let mut p = rexpect::spawn(&cmd, Some(2000))
            .unwrap_or_else(|e| panic!("Failed to run age via rexpect: {}", e));

        p.exp_regex("Enter passphrase.*")
            .unwrap_or_else(|e| panic!("Failed to match passphrase prompt: {}", e));
        p.send_line(&pass).unwrap();

        p.exp_eof()
            .unwrap_or_else(|e| panic!("Failed expecting EOF from age: {}", e));

        let decrypted = std::fs::read(&output_path)?;
        assert_eq!(&decrypted[..], plaintext);
        Ok(())
    }

    #[test]
    fn test_decrypt_with_ID_env_var() -> Result<(), Box<dyn std::error::Error>> {
        let (identity_str, recipient) = gen_keypair();
        let plaintext = b"test decrypt with ID env var";
        let encrypted = encrypt_for_test(&recipient, plaintext)?;

        // Test with ID environment variable (no env_clear, just add ID)
        let mut status = Command::new(initos_binary()?)
            .env("ID", &identity_str)
            .args(["decrypt"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();

        // Write encrypted data to the process stdin
        let mut stdin = status.stdin.take().unwrap();
        stdin.write_all(&encrypted)?;
        drop(stdin);

        let output = status.wait_with_output()?;
        assert!(
            output.status.success(),
            "initos decrypt with ID failed: {:?}",
            output
        );
        assert_eq!(&output.stdout[..], plaintext);
        Ok(())
    }

    #[test]
    fn test_decrypt_with_raw_key_on_stdin() -> Result<(), Box<dyn std::error::Error>> {
        let (identity_str, recipient) = gen_keypair();
        let plaintext = b"test decrypt with key on stdin";
        let encrypted = encrypt_for_test(&recipient, plaintext)?;

        // Create a temp file with encrypted data only (no identity)
        let mut cipher_file = NamedTempFile::new()?;
        cipher_file.write_all(&encrypted)?;
        cipher_file.flush()?;
        drop(cipher_file);

        // Pass identity directly on stdin
        let mut encrypted_bytes = Vec::new();
        encrypted_bytes.extend_from_slice(identity_str.as_bytes());
        encrypted_bytes.push(b'\n');

        let mut status = Command::new(initos_binary()?)
            .args(["decrypt"])
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();

        // Write identity followed by encrypted data to stdin
        let mut stdin = status.stdin.take().unwrap();
        stdin.write_all(&identity_str.as_bytes())?;
        stdin.write_all(b"\n")?;
        stdin.write_all(&encrypted)?;
        drop(stdin);

        let output = status.wait_with_output()?;
        assert!(
            output.status.success(),
            "initos decrypt with key on stdin failed: {:?}",
            output
        );
        assert_eq!(&output.stdout[..], plaintext);
        Ok(())
    }

    #[test]
    fn test_decrypt_with_KEY_FILE_env_var() -> Result<(), Box<dyn std::error::Error>> {
        let (identity_str, recipient) = gen_keypair();
        let plaintext = b"test decrypt with KEY_FILE env var";
        let encrypted = encrypt_for_test(&recipient, plaintext)?;

        // Create temp file with identity for KEY_FILE (keep alive until test ends)
        let mut key_file = NamedTempFile::new()?;
        key_file.write_all(identity_str.as_bytes())?;
        key_file.flush()?;
        let key_path = key_file.path().to_owned();

        // Create temp file with encrypted data (keep alive until test ends)
        let mut cipher_file = NamedTempFile::new()?;
        cipher_file.write_all(&encrypted)?;
        cipher_file.flush()?;
        let cipher_path = cipher_file.path().to_owned();

        // Test with KEY_FILE environment variable (no env_clear)
        let status = Command::new(initos_binary()?)
            .env("KEY_FILE", key_path.to_string_lossy().as_ref())
            .args(["decrypt"])
            .stdin(std::process::Stdio::from(std::fs::File::open(
                &cipher_path,
            )?))
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();

        let output = status.wait_with_output()?;
        assert!(
            output.status.success(),
            "initos decrypt with KEY_FILE failed: {:?}",
            output
        );
        assert_eq!(&output.stdout[..], plaintext);
        Ok(())
    }

}
