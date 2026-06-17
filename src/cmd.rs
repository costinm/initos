//! Subcommand implementations for the `initos` binary.
//!
//! Contains encrypt/decrypt, recovery encryption, and shared utilities
//! that don't belong in the core library modules.

use std::env;
use std::fs;
use std::io::{self, Write};

// ─── Shared Utilities ───────────────────────────────────────────────────────

/// Read a secret from stdin without echoing.
pub fn read_secret(prompt: &str) -> Result<String, Box<dyn std::error::Error>> {
    eprint!("{}", prompt);
    io::stderr().flush()?;

    let mut termios = unsafe {
        let mut t = std::mem::zeroed();
        if libc::tcgetattr(libc::STDIN_FILENO, &mut t) != 0 {
            // If not a TTY, just read normally
            let mut input = String::new();
            io::stdin().read_line(&mut input)?;
            return Ok(input.trim().to_string());
        }
        t
    };

    let original_lflag = termios.c_lflag;
    termios.c_lflag &= !libc::ECHO;

    unsafe {
        if libc::tcsetattr(libc::STDIN_FILENO, libc::TCSADRAIN, &termios) != 0 {
            return Err(io::Error::last_os_error().into());
        }
    }

    let mut input = String::new();
    let res = io::stdin().read_line(&mut input);

    termios.c_lflag = original_lflag;
    unsafe {
        libc::tcsetattr(libc::STDIN_FILENO, libc::TCSADRAIN, &termios);
    }

    eprintln!(); // Add a newline after Enter

    match res {
        Ok(_) => Ok(input.trim().to_string()),
        Err(e) => Err(e.into()),
    }
}

/// Get the fscrypt key: from FSCRYPT_KEY env var if set, otherwise prompt from stdin.
/// AES-256-XTS requires a 64-byte raw key; short keys are padded by repeating.
pub fn get_fscrypt_key() -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let raw = if let Ok(key_str) = env::var("FSCRYPT_KEY") {
        key_str.into_bytes()
    } else {
        read_secret("Enter key: ")?.into_bytes()
    };

    if raw.is_empty() {
        return Err("fscrypt key is empty".into());
    }

    // Pad to 64 bytes (AES-256-XTS needs 64) by repeating key material.
    // HKDF will later be used by the kernel to derive actual keys,
    // but the master key should be consistent.
    let mut key = vec![0u8; 64];
    for i in 0..64 {
        key[i] = raw[i % raw.len()];
    }
    eprintln!(
        "initos: fscrypt key ready ({} raw bytes, padded to 64)",
        raw.len()
    );
    Ok(key)
}

// ─── Encrypt / Decrypt ──────────────────────────────────────────────────────

/// Encrypt stdin using age with x25519 recipients from args and/or scrypt passphrase from KEY env.
pub fn cmd_encrypt() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Read;
    use std::str::FromStr;

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

/// Decrypt stdin or file using age with scrypt passphrase from KEY env var, or x25519 from ID env var, KEY_FILE, CLI argument, or password prompt.
pub fn cmd_decrypt() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Read;
    use std::str::FromStr;

    let args: Vec<String> = std::env::args().skip(2).collect();
    let mut identities_files = Vec::new();
    let mut output_file = Option::<String>::None;
    let mut input_file = Option::<String>::None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-i" => {
                if i + 1 < args.len() {
                    identities_files.push(args[i + 1].clone());
                    i += 2;
                } else {
                    return Err("missing argument for -i".into());
                }
            }
            "-o" => {
                if i + 1 < args.len() {
                    output_file = Some(args[i + 1].clone());
                    i += 2;
                } else {
                    return Err("missing argument for -o".into());
                }
            }
            other => {
                if other.starts_with('-') {
                    return Err(format!("unknown option: {}", other).into());
                }
                if input_file.is_some() {
                    return Err("multiple input files specified".into());
                }
                input_file = Some(other.to_string());
                i += 1;
            }
        }
    }

    let mut identities: Vec<Box<dyn age::Identity>> = Vec::new();

    // Try identities from command line -i arguments
    for id_path in &identities_files {
        if let Ok(content) = fs::read_to_string(id_path) {
            let mut found = false;
            for line in content.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                if let Ok(identity) = age::x25519::Identity::from_str(line) {
                    identities.push(Box::new(identity));
                    found = true;
                    break;
                }
            }
            if !found {
                return Err(format!("no valid identities found in file '{}'", id_path).into());
            }
        } else {
            // Try parsing string directly as x25519 identity
            if let Ok(identity) = age::x25519::Identity::from_str(id_path) {
                identities.push(Box::new(identity));
            } else {
                return Err(format!("failed to read identity file or parse identity from '{}'", id_path).into());
            }
        }
    }

    // Try scrypt passphrase from KEY environment variable
    if identities.is_empty() {
        if let Ok(pass) = env::var("KEY") {
            if !pass.is_empty() {
                identities.push(Box::new(age::scrypt::Identity::new(pass.into())));
            }
        }
    }

    // Try ID environment variable for direct key
    if identities.is_empty() {
        if let Ok(key_string) = env::var("ID") {
            if !key_string.is_empty() {
                // Try to parse as x25519 identity directly
                if let Ok(identity) = age::x25519::Identity::from_str(&key_string) {
                    identities.push(Box::new(identity));
                }
            }
        }
    }

    // Try KEY_FILE
    if identities.is_empty() {
        if let Ok(key_file) = env::var("KEY_FILE") {
            let content = fs::read_to_string(key_file)?;
            for line in content.lines() {
                let line = line.trim();
                // Skip comments and empty lines
                if line.is_empty() || line.starts_with('#') {
                    continue;
                }
                // Try to parse this line as an age x25519 identity
                if let Ok(identity) = age::x25519::Identity::from_str(line) {
                    identities.push(Box::new(identity));
                    break;
                }
            }
        }
    }

    // Read ciphertext from file or stdin
    let mut cipher = Vec::new();
    if let Some(ref path) = input_file {
        cipher = fs::read(path).map_err(|e| format!("failed to read input file '{}': {}", path, e))?;
    } else {
        io::stdin().read_to_end(&mut cipher)?;
    }

    // If no identity resolved yet, try parsing first line of ciphertext as x25519 identity
    if identities.is_empty() {
        if let Some(nl_pos) = cipher.iter().position(|&b| b == b'\n') {
            let first_line = &cipher[..nl_pos];
            let first_line_str = std::str::from_utf8(first_line).unwrap_or("");
            if let Ok(identity) = age::x25519::Identity::from_str(first_line_str.trim()) {
                identities.push(Box::new(identity));
                // Use remaining data after the newline as ciphertext
                cipher.drain(..=nl_pos);
            }
        }
    }

    // If still empty and an input file is specified, prompt for a password
    if identities.is_empty() {
        if input_file.is_some() {
            let pass = read_secret("Enter passphrase: ")?;
            if pass.is_empty() {
                return Err("passphrase is empty".into());
            }
            identities.push(Box::new(age::scrypt::Identity::new(pass.into())));
        }
    }

    if identities.is_empty() {
        return Err(
            "need KEY (for scrypt passphrase), ID (for private key), or KEY_FILE to decrypt".into(),
        );
    }

    // Decrypt
    let decryptor = age::Decryptor::new(std::io::Cursor::new(&cipher))
        .map_err(|e| format!("decryptor: {}", e))?;
    let mut reader = decryptor
        .decrypt(identities.iter().map(|i| &**i as &dyn age::Identity))
        .map_err(|e| format!("decrypt: {}", e))?;

    let mut result = Vec::new();
    reader
        .read_to_end(&mut result)
        .map_err(|e| format!("read: {}", e))?;

    if let Some(ref path) = output_file {
        fs::write(path, &result)
            .map_err(|e| format!("failed to write output file '{}': {}", path, e))?;
    } else {
        io::stdout()
            .write_all(&result)
            .map_err(|e| format!("write: {}, bytes={}", e, result.len()))?;
    }
    Ok(())
}

// ─── Recovery Encryption ────────────────────────────────────────────────────

/// Encrypt the secret for recovery using the provided base64 Ed25519 public key.
/// Returns the encrypted data (ephemeral public key + nonce + ciphertext).
pub fn encrypt_for_recovery(
    secret: &[u8],
    pub_key_b64: &str,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    use base64::Engine;
    use chacha20poly1305::{aead::Aead, ChaCha20Poly1305, KeyInit, Nonce};
    use curve25519_dalek::edwards::CompressedEdwardsY;
    use rand_core::{OsRng, RngCore};

    let pub_key_bytes = base64::engine::general_purpose::STANDARD
        .decode(pub_key_b64)
        .map_err(|e| format!("bad base64 pub_key: {}", e))?;
    if pub_key_bytes.len() != 32 {
        return Err("ed25519 public key must be 32 bytes".into());
    }

    let compressed_y = CompressedEdwardsY::from_slice(&pub_key_bytes)
        .map_err(|_| "Invalid Ed25519 public key length")?;
    let edwards_pt = compressed_y
        .decompress()
        .ok_or("Invalid Ed25519 public key point")?;
    let target_montgomery = edwards_pt.to_montgomery();

    let mut rng = OsRng;
    let mut ephemeral_secret_bytes = [0u8; 32];
    rng.fill_bytes(&mut ephemeral_secret_bytes);
    let ephemeral_secret =
        curve25519_dalek::scalar::Scalar::from_bytes_mod_order(ephemeral_secret_bytes);
    let ephemeral_public = curve25519_dalek::constants::X25519_BASEPOINT * ephemeral_secret;
    let ephemeral_pub_bytes = ephemeral_public.to_bytes();

    let shared_secret = ephemeral_secret * target_montgomery;

    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(shared_secret.to_bytes());
    let symmetric_key = hasher.finalize();

    let cipher = ChaCha20Poly1305::new(&symmetric_key);
    let mut nonce_bytes = [0u8; 12];
    rng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, secret)
        .map_err(|e| format!("Encryption failed: {:?}", e))?;

    let mut result = Vec::with_capacity(32 + 12 + ciphertext.len());
    result.extend_from_slice(&ephemeral_pub_bytes);
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);

    Ok(result)
}

/// Encrypt a secret for recovery and write the binary payload to stdout.
pub fn cmd_recovery_encrypt(
    secret: &str,
    pub_key_b64: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let encrypted = encrypt_for_recovery(secret.as_bytes(), pub_key_b64)?;
    io::stdout().write_all(&encrypted)?;
    Ok(())
}

/// Print usage information.
pub fn print_help() {
    eprintln!("initos — Unified init tool: TPM2 unseal, fscrypt, verified boot, image mount.");
    eprintln!();
    eprintln!("Usage: initos [COMMAND] [ARGS...]");
    eprintln!();
    eprintln!("Commands:");
    eprintln!("  (no args)                     As PID 1: full boot sequence. Otherwise: unseal.");
    eprintln!(
        "  boot                          Full initrd boot sequence (mount, verify, switch_root)"
    );
    eprintln!("  mount <IMG> <DIR>             Verify and loop-mount an erofs image");
    eprintln!(
        "  verify <IMG>                  Verify fsverity digest + .sig signature of an image"
    );
    eprintln!("  efi                           Read EFI variables (SecureBoot, BootCurrent, db)");
    eprintln!("  unseal [--dev|--secure] [--handle HANDLE]");
    eprintln!("                                 Unseal TPM2 key via PCR SHA256:7 policy");
    eprintln!("  seal [--dev|--secure] [--handle HANDLE] <SECRET>");
    eprintln!("                                 Seal a key to TPM2 with PCR SHA256:7 policy");
    eprintln!("  primary                       Create a TPM2 primary key and persist it");
    eprintln!("  lock_tpm                      Extend PCR 7 to prevent further unsealing");
    eprintln!("  fscrypt <PATH>                Add encryption key to filesystem keyring (unlock)");
    eprintln!("  fscrypt-setup <DIR>           Add key to keyring + set encryption policy");
    eprintln!("  encrypt [RECIPIENT...]        Encrypt stdin using age to x25519 recipients");
    eprintln!("  decrypt [FILE] [-i KEY] [-o OUT]");
    eprintln!(
        "                                Decrypt file or stdin using age with identity from KEY_FILE, KEY, or CLI"
    );
    eprintln!("  recovery-encrypt <SECRET> [PUB_KEY]");
    eprintln!(
        "                                Encrypt a secret for recovery using an Ed25519 public key"
    );
    eprintln!("  help                          Show this help message");
    eprintln!();
    eprintln!("Environment:");
    eprintln!("  INITOS_PUB_KEY   base64 ed25519 public key (empty = skip verification)");
    eprintln!("  INITOS_IMG       image path (default: /img/initos.erofs, boot mode)");
    eprintln!("  INITOS_DATA      partition label (default: STATE, boot mode)");
    eprintln!("  INITOS_INIT      init path (default: /opt/initos/bin/initos-init)");
    eprintln!("  FSCRYPT_KEY      raw fscrypt passphrase/key material");
    eprintln!("  KEY              age scrypt passphrase for encrypt/decrypt");
    eprintln!("  ID               age x25519 identity for decrypt");
    eprintln!("  KEY_FILE         file containing an age identity for decrypt");
}
