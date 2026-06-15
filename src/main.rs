//! initos — Unified init tool: TPM2 unseal, fscrypt, verified boot, image mount.
//!
//! Subcommands:
//!   (no args)              As PID 1: full boot sequence. Otherwise: unseal.
//!   unseal [--dev|--secure] [--handle HANDLE]
//!                          Unseal TPM2 key via PCR SHA256:7 policy
//!   lock_tpm               Extend PCR 7 to prevent further unsealing
//!   primary                Create a TPM2 primary key and persist it, required for seal.
//!   seal [--dev|--secure] [--handle HANDLE] <SECRET>
//!                          Seal a key to TPM2 with PCR SHA256:7 policy
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
use std::io::{self, Write};
use std::process;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let result = if args.len() < 2 {
        // No args: PID 1 → boot, otherwise unseal
        if process::id() == 1 {
            initos::boot::cmd_boot()
        } else {
            cmd_unseal(detect_seal_mode(), None)
        }
    } else {
        match args[1].as_str() {
            "unseal" => match parse_unseal_args(&args[2..]) {
                Ok((mode, handle)) => cmd_unseal(mode, handle),
                Err(e) => {
                    eprintln!("{}", e);
                    eprintln!("Usage: initos unseal [--dev|--secure] [--handle HANDLE]");
                    process::exit(1);
                }
            },
            "lock_tpm" => cmd_lock_tpm(),
            "primary" => cmd_primary(),
            "seal" => {
                let (mode, handle, secret) = match parse_seal_args(&args[2..]) {
                    Ok(parsed) => parsed,
                    Err(e) => {
                        eprintln!("{}", e);
                        eprintln!("Usage: initos seal [--dev|--secure] [--handle HANDLE] <SECRET>");
                        process::exit(1);
                    }
                };
                cmd_seal(&secret, mode, handle)
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
            "boot" => initos::boot::cmd_boot(),
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

/// Extend PCR 7 with random data to prevent other applications from unsealing
/// the key in the same boot session.
fn cmd_lock_tpm() -> Result<(), Box<dyn std::error::Error>> {
    let mut dev = initos::tpm2::open()?;
    initos::tpm2::pcr_extend(&mut dev, 7)?;
    eprintln!("initos: PCR 7 extended (sealed against further unseal)");
    Ok(())
}

/// Unseal and print to stdout.
fn cmd_unseal(mode: SealMode, handle: Option<u32>) -> Result<(), Box<dyn std::error::Error>> {
    let secret = match handle {
        Some(handle) => initos::boot::unseal_key_from_handle(handle, mode.prefix(), mode.name())?,
        None => initos::boot::unseal_key(mode.is_secure())?,
    };
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
    let mut dev = initos::tpm2::open()?;

    let transient = initos::tpm2::create_primary(&mut dev)?;
    eprintln!("initos: primary transient=0x{:08X}", transient);

    let persistent = initos::tpm2::DEFAULT_PRIMARY_HANDLE;
    initos::tpm2::try_evict_persistent(&mut dev, persistent);
    initos::tpm2::evict_control(&mut dev, transient, persistent)?;
    eprintln!("initos: persisted primary at 0x{:08X}", persistent);
    Ok(())
}

enum SealMode {
    Dev,
    Secure,
}

impl SealMode {
    fn is_secure(&self) -> bool {
        matches!(self, SealMode::Secure)
    }

    fn persistent_handle(&self) -> u32 {
        match self {
            SealMode::Dev => initos::tpm2::DEFAULT_SEALED_HANDLE_DEV,
            SealMode::Secure => initos::tpm2::DEFAULT_SEALED_HANDLE_SECURE,
        }
    }

    fn prefix(&self) -> &'static [u8] {
        match self {
            SealMode::Dev => b"devc:",
            SealMode::Secure => b"secc:",
        }
    }

    fn name(&self) -> &'static str {
        match self {
            SealMode::Dev => "dev",
            SealMode::Secure => "secure",
        }
    }
}

fn parse_unseal_args(args: &[String]) -> Result<(SealMode, Option<u32>), String> {
    let mut mode = None;
    let mut handle = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--secure" => mode = Some(SealMode::Secure),
            "--dev" => mode = Some(SealMode::Dev),
            "--handle" => {
                i += 1;
                let value = args
                    .get(i)
                    .ok_or_else(|| "--handle requires a value".to_string())?;
                handle = Some(parse_tpm_handle(value)?);
            }
            other => return Err(format!("unexpected unseal argument: {}", other)),
        }
        i += 1;
    }
    Ok((mode.unwrap_or_else(detect_seal_mode), handle))
}

fn parse_seal_args(args: &[String]) -> Result<(SealMode, Option<u32>, String), String> {
    let mut mode = None;
    let mut handle = None;
    let mut secret = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--secure" => mode = Some(SealMode::Secure),
            "--dev" => mode = Some(SealMode::Dev),
            "--handle" => {
                i += 1;
                let value = args
                    .get(i)
                    .ok_or_else(|| "--handle requires a value".to_string())?;
                handle = Some(parse_tpm_handle(value)?);
            }
            value if value.starts_with("--") => {
                return Err(format!("unexpected seal argument: {}", value));
            }
            value => {
                if secret.is_some() {
                    return Err("seal accepts exactly one SECRET argument".to_string());
                }
                secret = Some(value.to_string());
            }
        }
        i += 1;
    }

    let secret = secret.ok_or_else(|| "seal requires SECRET".to_string())?;
    Ok((mode.unwrap_or_else(detect_seal_mode), handle, secret))
}

fn parse_tpm_handle(value: &str) -> Result<u32, String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err("TPM handle is empty".to_string());
    }

    let hex = trimmed
        .strip_prefix("0x")
        .or_else(|| trimmed.strip_prefix("0X"))
        .unwrap_or(trimmed);
    if !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!("bad TPM handle '{}': expected hex", value));
    }

    let parsed =
        u32::from_str_radix(hex, 16).map_err(|e| format!("bad TPM handle '{}': {}", value, e))?;
    let handle = if !trimmed.starts_with("0x") && !trimmed.starts_with("0X") && hex.len() <= 4 {
        0x8100_0000 | parsed
    } else {
        parsed
    };
    if !(0x8100_0000..=0x81FF_FFFF).contains(&handle) {
        return Err(format!(
            "bad TPM handle 0x{:08X}: expected persistent handle 0x81000000..0x81FFFFFF",
            handle
        ));
    }
    Ok(handle)
}

fn detect_seal_mode() -> SealMode {
    let base_path =
        env::var("INITOS_EFI_PATH").unwrap_or_else(|_| "/sys/firmware/efi/efivars".to_string());
    match initos::efi::read_secure_boot(&base_path) {
        Ok(value) if value != 0 => {
            eprintln!("initos: EFI SecureBoot={} using secure TPM handle", value);
            SealMode::Secure
        }
        Ok(value) => {
            eprintln!("initos: EFI SecureBoot={} using dev TPM handle", value);
            SealMode::Dev
        }
        Err(e) => {
            let pub_key_set = env::var("INITOS_PUB_KEY").is_ok_and(|key| !key.is_empty());
            let mode = if pub_key_set {
                SealMode::Secure
            } else {
                SealMode::Dev
            };
            eprintln!(
                "initos: failed to read EFI SecureBoot from {}, using {} TPM handle from INITOS_PUB_KEY fallback: {}",
                base_path,
                mode.name(),
                e
            );
            mode
        }
    }
}

/// Seal: create trial policy, create sealed object, load, and persist at fixed handle.
fn cmd_seal(
    secret: &str,
    mode: SealMode,
    handle: Option<u32>,
) -> Result<(), Box<dyn std::error::Error>> {
    let primary = initos::tpm2::DEFAULT_PRIMARY_HANDLE;
    eprintln!("initos: seal under primary=0x{:08X}", primary);

    let mut dev = initos::tpm2::open()?;

    // 1. Get the PCR policy digest via a trial session
    let trial = initos::tpm2::start_trial_session(&mut dev)?;
    initos::tpm2::policy_pcr(&mut dev, trial)?;
    let digest = initos::tpm2::policy_get_digest(&mut dev, trial)?;
    initos::tpm2::flush_context(&mut dev, trial)?;
    eprintln!("initos: policy digest ({} bytes)", digest.len());

    // 2. Create sealed object under the primary
    let mut sealed_secret = Vec::with_capacity(mode.prefix().len() + secret.len());
    sealed_secret.extend_from_slice(mode.prefix());
    sealed_secret.extend_from_slice(secret.as_bytes());
    let (priv_area, pub_area) = initos::tpm2::create(&mut dev, primary, &sealed_secret, &digest)?;
    eprintln!(
        "initos: created sealed object (priv={}, pub={})",
        priv_area.len(),
        pub_area.len()
    );

    // 3. Load it
    let loaded = initos::tpm2::load(&mut dev, primary, &priv_area, &pub_area)?;
    eprintln!("initos: loaded transient=0x{:08X}", loaded);

    // 4. Persist it
    let persistent = handle.unwrap_or_else(|| mode.persistent_handle());
    initos::tpm2::try_evict_persistent(&mut dev, persistent);
    initos::tpm2::evict_control(&mut dev, loaded, persistent)?;
    eprintln!(
        "initos: persisted {} sealed at 0x{:08X}",
        mode.name(),
        persistent
    );
    Ok(())
}

// ─── Verify / Mount ────────────────────────────────────────────────────────

/// Verify and loop-mount an erofs image.
fn cmd_mount(img: &str, mount_point: &str) -> Result<(), Box<dyn std::error::Error>> {
    let pub_key = env::var("INITOS_PUB_KEY").unwrap_or_default();
    initos::boot::verify_image_if_key(img, &pub_key)?;

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
