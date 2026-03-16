//! initos — Unified init tool: TPM2 unseal, fscrypt, verified boot, image mount.
//!
//! Subcommands:
//!   (no args)              As PID 1: full boot sequence. Otherwise: unseal.
//!   unseal                 Unseal TPM2 key via PCR SHA256:7 policy
//!   lock_tpm               Extend PCR 7 to prevent further unsealing
//!   primary                Create a TPM2 primary key and persist it, required for seal.
//!   seal <SECRET>          Seal a key to TPM2 with PCR SHA256:7 policy
//!   fscrypt <PATH>         Unseal key + add to filesystem keyring (unlock)
//!   fscrypt-setup <DIR>    Unseal key + add to keyring + set encryption policy
//!   boot                   Full initrd boot sequence (mount, verify, switch_root)
//!   mount <IMG> <DIR>      Verify verity SHA matches the .sig, and loop-mount an image
//!   verify <IMG>           Verify fsverity digest + .sig signature of an image
//!   efi                    Read EFI variables (SecureBoot, BootCurrent, PK)
//!   encrypt [ARGS]         Encrypt stdin using age to x25519 recipients (args)
//!   decrypt                Decrypt stdin using age with x25519 identity from KEY_FILE
//!
//! Environment:
//!   INITOS_PUB_KEY   base64 ed25519 public key (empty = skip verification)
//!   INITOS_IMG       image path (default: /img/initos.erofs, boot mode)
//!   INITOS_DATA      partition label (default: STATE, boot mode)

use std::env;
use std::fs;
use std::io::{self, Write};
use std::process;
use std::str::FromStr;

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
            "encrypt" => cmd_encrypt(),
            "decrypt" => cmd_decrypt(),
            other => {
                eprintln!("Unknown command: {}", other);
                eprintln!(
                    "Usage: initos [unseal|lock_tpm|primary|seal|fscrypt|fscrypt-setup|boot|mount|verify|efi|encrypt|decrypt] ..."
                );
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

/// Get the fscrypt key: from FSCRYPT_KEY env var if set, otherwise from TPM unseal.
/// AES-256-XTS requires a 64-byte raw key; short keys are padded by repeating.
fn get_fscrypt_key() -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    if let Ok(key_str) = env::var("FSCRYPT_KEY") {
        let raw = key_str.into_bytes();
        if raw.is_empty() {
            return Err("FSCRYPT_KEY is empty".into());
        }
        // Pad to 64 bytes (AES-256-XTS needs 64) by repeating key material
        let mut key = vec![0u8; 64];
        for i in 0..64 {
            key[i] = raw[i % raw.len()];
        }
        eprintln!(
            "initos: using FSCRYPT_KEY from environment ({} raw bytes, padded to 64)",
            raw.len()
        );
        Ok(key)
    } else {
        unseal_key()
    }
}

/// Unseal and print to stdout.
fn cmd_unseal() -> Result<(), Box<dyn std::error::Error>> {
    let secret = unseal_key()?;
    io::stdout().write_all(&secret)?;
    Ok(())
}

/// Fscrypt unlock: get key (env or TPM), add to filesystem keyring.
fn cmd_fscrypt(mountpoint: &str) -> Result<(), Box<dyn std::error::Error>> {
    let key = get_fscrypt_key()?;
    let identifier = initos::fscrypt::add_key(mountpoint, &key)?;
    eprintln!(
        "initos: fscrypt key added (id={}) on {}",
        initos::fscrypt::hex(&identifier),
        mountpoint
    );
    Ok(())
}

/// Fscrypt setup: get key (env or TPM), add to keyring, set v2 policy on empty directory.
fn cmd_fscrypt_setup(dir: &str) -> Result<(), Box<dyn std::error::Error>> {
    let key = get_fscrypt_key()?;
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

/// Encrypt the secret for recovery using the provided base64 Ed25519 public key.
/// Returns the encrypted data (ephemeral public key + nonce + ciphertext).
fn encrypt_for_recovery(
    secret: &[u8],
    pub_key_b64: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    use base64::Engine;
    use chacha20poly1305::{aead::Aead, ChaCha20Poly1305, KeyInit, Nonce};
    use curve25519_dalek::edwards::CompressedEdwardsY;
    use rand_core::{OsRng, RngCore};

    // Decode base64 Ed25519 public key
    let pub_key_bytes = base64::engine::general_purpose::STANDARD
        .decode(pub_key_b64)
        .map_err(|e| format!("bad base64 pub_key: {}", e))?;
    if pub_key_bytes.len() != 32 {
        return Err("ed25519 public key must be 32 bytes".into());
    }

    // Convert Ed25519 public key to X25519 public key (Montgomery point)
    let compressed_y = CompressedEdwardsY::from_slice(&pub_key_bytes)
        .map_err(|_| "Invalid Ed25519 public key length")?;
    let edwards_pt = compressed_y
        .decompress()
        .ok_or("Invalid Ed25519 public key point")?;
    let target_montgomery = edwards_pt.to_montgomery();

    // Generate ephemeral X25519 keypair
    let mut rng = OsRng;
    let mut ephemeral_secret_bytes = [0u8; 32];
    rng.fill_bytes(&mut ephemeral_secret_bytes);
    let ephemeral_secret =
        curve25519_dalek::scalar::Scalar::from_bytes_mod_order(ephemeral_secret_bytes);
    let ephemeral_public = curve25519_dalek::constants::X25519_BASEPOINT * ephemeral_secret;
    let ephemeral_pub_bytes = ephemeral_public.to_bytes();

    // Compute Diffie-Hellman shared secret
    let shared_secret = ephemeral_secret * target_montgomery;

    // Hash the shared secret (using SHA-256 for a 32-byte ChaCha20 key)
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(shared_secret.to_bytes());
    let symmetric_key = hasher.finalize();

    // Encrypt the secret using ChaCha20Poly1305
    let cipher = ChaCha20Poly1305::new(&symmetric_key);
    let mut nonce_bytes = [0u8; 12];
    rng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, secret)
        .map_err(|e| format!("Encryption failed: {:?}", e))?;

    // Format: [ephemeral_pub_bytes (32)] + [nonce (12)] + [ciphertext]
    let mut result = Vec::with_capacity(32 + 12 + ciphertext.len());
    result.extend_from_slice(&ephemeral_pub_bytes);
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);

    Ok(result)
}

/// Seal: create trial policy, create sealed object, load, persist, save handle.
fn cmd_seal(secret: &str) -> Result<(), Box<dyn std::error::Error>> {
    fs::create_dir_all(initos::tpm2::TPM_DIR)?;

    // Recovery encryption (if INITOS_PUB_KEY is provided)
    if let Ok(pub_key) = env::var("INITOS_PUB_KEY") {
        if !pub_key.is_empty() {
            eprintln!("initos: encrypting sealed secret for recovery");
            let encrypted = encrypt_for_recovery(secret.as_bytes(), &pub_key)?;
            let recovery_path = format!("{}/recovery", initos::tpm2::TPM_DIR);
            fs::write(&recovery_path, encrypted)?;
            eprintln!("initos: saved recovery data to {}", recovery_path);
        }
    }

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
    let img = env::var("INITOS_IMG").unwrap_or_else(|_| "/img/initos.erofs".to_string());
    let data = env::var("INITOS_DATA").unwrap_or_else(|_| "STATE".to_string());
    eprintln!(
        "initos: boot mode (PID {}) img={} data={}",
        process::id(),
        img,
        data
    );

    // 1. Mount pseudo-filesystems
    for (fs, mp) in [("proc", "/proc"), ("sysfs", "/sys"), ("devtmpfs", "/dev")] {
        eprintln!("initos: mounting {}", fs);
        initos::mount::mount_pseudo_fs(fs, mp)?;
    }

    // 2. Find and mount STATE partition
    eprintln!("initos: looking for partition '{}'", data);
    let dev = initos::mount::find_partition_by_label(&data)?;
    eprintln!("initos: found partition: {:?}", dev);

    let mount_point = "/mnt/data";
    initos::mount::mount_filesystem(dev.to_str().unwrap(), mount_point, "ext4", false)?;

    // 3. Verify image
    let img_path = format!("{}/{}", mount_point, img.trim_start_matches('/'));
    verify_image_if_key(&img_path, &pub_key)?;

    // 4. Loop-mount
    let root_mount = "/mnt/root";
    eprintln!("initos: mounting image at {}", root_mount);
    initos::mount::mount_loop(&img_path, root_mount)?;

    // 5. Switch root
    eprintln!("initos: switching root to {}", root_mount);
    initos::mount::switch_root(root_mount, "/bin/initos-init")?;
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
    let base_path = env::var("INITOS_EFI_PATH")
        .unwrap_or_else(|_| "/sys/firmware/efi/efivars".to_string());
    let info = initos::efi::read_efi_info(&base_path)?;
    print!("{}", info);
    Ok(())
}

/// Encrypt stdin using age with x25519 recipients from args and/or scrypt passphrase from KEY env.
fn cmd_encrypt() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Read;

    let args: Vec<String> = std::env::args().skip(2).collect();

    let mut plaintext = Vec::new();
    io::stdin().read_to_end(&mut plaintext)?;

    let mut recipients: Vec<Box<dyn age::Recipient>> = Vec::new();

    // Add scrypt passphrase recipient if KEY is set
    if let Ok(pass) = env::var("KEY") {
        if !pass.is_empty() {
            recipients.push(Box::new(age::scrypt::Recipient::new(pass.into())));
        }
    }

    // Add x25519 recipients from args
    for key_str in &args {
        if let Ok(recip) = age::x25519::Recipient::from_str(key_str) {
            recipients.push(Box::new(recip));
        }
    }

    if recipients.is_empty() {
        return Err("need KEY env var or at least one x25519 recipient argument".into());
    }

    let encryptor =
        age::Encryptor::with_recipients(recipients.iter().map(|r| &**r as &dyn age::Recipient))
            .map_err(|e| format!("encryptor: {}", e))?;

    let mut writer = encryptor
        .wrap_output(io::stdout())
        .map_err(|e| format!("wrap_output: {}", e))?;
    writer
        .write_all(&plaintext)
        .map_err(|e| format!("write: {}", e))?;
    writer.finish().map_err(|e| format!("finish: {}", e))?;

    Ok(())
}

/// Decrypt stdin using age with scrypt passphrase from KEY env var or x25519 from KEY_FILE.
fn cmd_decrypt() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Read;

    let mut cipher = Vec::new();
    io::stdin().read_to_end(&mut cipher)?;

    let mut identities: Vec<Box<dyn age::Identity>> = Vec::new();

    // Try scrypt passphrase from KEY
    if let Ok(pass) = env::var("KEY") {
        if !pass.is_empty() {
            identities.push(Box::new(age::scrypt::Identity::new(pass.into())));
        }
    } else if let Ok(key_file) = env::var("KEY_FILE") {
        // Try x25519 identity from file
        let content = fs::read_to_string(key_file)?;
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Ok(identity) = age::x25519::Identity::from_str(line) {
                identities.push(Box::new(identity));
            }
        }
    }

    if identities.is_empty() {
        return Err("need KEY env var or KEY_FILE env var with x25519 identity".into());
    }

    let decryptor = age::Decryptor::new(std::io::Cursor::new(&cipher))
        .map_err(|e| format!("decryptor: {}", e))?;
    let mut reader = decryptor
        .decrypt(identities.iter().map(|i| &**i as &dyn age::Identity))
        .map_err(|e| format!("decrypt: {}", e))?;

    let mut result = Vec::new();
    reader
        .read_to_end(&mut result)
        .map_err(|e| format!("read: {}", e))?;
    io::stdout()
        .write_all(&result)
        .map_err(|e| format!("write: {}", e))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use age::secrecy::ExposeSecret;
    use std::io::Cursor;
    use std::io::Read;
    use std::process::Command;
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
}
