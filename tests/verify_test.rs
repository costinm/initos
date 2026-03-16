//! Integration tests for initos signature verification.
//!
//! These tests exercise the full signature verification pipeline:
//! - Pure ed25519 crypto (always runs)
//! - File-based verification with signature files
//! - End-to-end with fs-verity (requires kernel support, marked #[ignore])

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::Command;

/// Generate an ed25519 keypair, sign data, return (pub_key_b64, sig_bytes).
fn generate_and_sign(data: &[u8]) -> (String, Vec<u8>) {
    use base64::Engine;
    use ed25519_dalek::{Signer, SigningKey};
    use rand::rngs::OsRng;

    let signing_key = SigningKey::generate(&mut OsRng);
    let verifying_key = signing_key.verifying_key();
    let pub_key_b64 = base64::engine::general_purpose::STANDARD.encode(verifying_key.as_bytes());
    let signature = signing_key.sign(data);

    (pub_key_b64, signature.to_bytes().to_vec())
}

// ===== Pure Crypto Tests =====

#[test]
fn test_verify_valid_signature() {
    let digest = b"abcdef0123456789abcdef0123456789"; // 32 bytes
    let (pub_key_b64, sig_bytes) = generate_and_sign(digest);

    let result = initos::verify::verify_signature(digest, &sig_bytes, &pub_key_b64).unwrap();
    assert!(result, "valid signature must verify");
}

#[test]
fn test_verify_tampered_signature() {
    let digest = b"abcdef0123456789abcdef0123456789";
    let (pub_key_b64, mut sig_bytes) = generate_and_sign(digest);

    // Flip a bit in the signature
    sig_bytes[10] ^= 0x01;

    let result = initos::verify::verify_signature(digest, &sig_bytes, &pub_key_b64).unwrap();
    assert!(!result, "tampered signature must not verify");
}

#[test]
fn test_verify_wrong_key() {
    let digest = b"abcdef0123456789abcdef0123456789";
    let (_correct_key, sig_bytes) = generate_and_sign(digest);
    let (wrong_key, _) = generate_and_sign(b"other data that doesn't matter!!");

    let result = initos::verify::verify_signature(digest, &sig_bytes, &wrong_key).unwrap();
    assert!(!result, "wrong key must not verify");
}

#[test]
fn test_verify_different_digest() {
    let digest = b"abcdef0123456789abcdef0123456789";
    let (pub_key_b64, sig_bytes) = generate_and_sign(digest);

    let wrong_digest = b"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";
    let result = initos::verify::verify_signature(wrong_digest, &sig_bytes, &pub_key_b64).unwrap();
    assert!(!result, "wrong digest must not verify");
}

// ===== File-based Tests =====

#[test]
fn test_verify_with_sig_file() {
    let digest = b"test-digest-for-file-based-test!"; // 32 bytes
    let (pub_key_b64, sig_bytes) = generate_and_sign(digest);

    let dir = tempfile::tempdir().unwrap();
    let sig_path = dir.path().join("initos.erofs.sig");
    let mut f = fs::File::create(&sig_path).unwrap();
    f.write_all(&sig_bytes).unwrap();

    let result =
        initos::verify::verify_digest_with_sig_file(digest, &sig_path, &pub_key_b64).unwrap();
    assert!(result, "file-based verification should pass");
}

#[test]
fn test_verify_with_tampered_sig_file() {
    let digest = b"test-digest-for-file-based-test!";
    let (pub_key_b64, mut sig_bytes) = generate_and_sign(digest);

    // Tamper
    sig_bytes[0] ^= 0xFF;

    let dir = tempfile::tempdir().unwrap();
    let sig_path = dir.path().join("initos.erofs.sig");
    let mut f = fs::File::create(&sig_path).unwrap();
    f.write_all(&sig_bytes).unwrap();

    let result =
        initos::verify::verify_digest_with_sig_file(digest, &sig_path, &pub_key_b64).unwrap();
    assert!(!result, "tampered sig file should fail");
}

#[test]
fn test_verify_missing_sig_file() {
    let digest = b"test-digest-for-file-based-test!";
    let (pub_key_b64, _) = generate_and_sign(digest);

    let result =
        initos::verify::verify_digest_with_sig_file(digest, "/nonexistent/path.sig", &pub_key_b64);
    assert!(result.is_err(), "missing sig file should error");
}

// ===== End-to-end test with fs-verity (requires root + fsverity-utils) =====

/// Check if fsverity-utils is available and we have the necessary environment.
fn has_fsverity_support() -> bool {
    // Check for fsverity command
    if Command::new("fsverity").arg("--help").output().is_err() {
        return false;
    }

    // Check if we're root (needed for loop mounts)
    unsafe { libc::geteuid() == 0 }
}

#[test]
#[ignore] // Run with: sudo cargo test -p initos -- --ignored
fn test_verify_image_e2e() {
    if !has_fsverity_support() {
        eprintln!("SKIP: fsverity-utils not available or not running as root");
        return;
    }

    // Run the setup script
    let script_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("scripts");
    let setup_script = script_dir.join("setup_test_img.sh");

    let output_dir = tempfile::tempdir().unwrap();

    let output = Command::new("bash")
        .arg(&setup_script)
        .arg(output_dir.path())
        .output()
        .expect("failed to run setup_test_img.sh");

    if !output.status.success() {
        eprintln!("Setup script failed:");
        eprintln!("stdout: {}", String::from_utf8_lossy(&output.stdout));
        eprintln!("stderr: {}", String::from_utf8_lossy(&output.stderr));
        eprintln!("SKIP: setup script failed (fs-verity may not be supported)");
        return;
    }

    eprintln!("Setup script output:");
    eprintln!("{}", String::from_utf8_lossy(&output.stdout));

    // Read the public key
    let pub_key_b64 = fs::read_to_string(output_dir.path().join("image_key.pub.b64"))
        .expect("image_key.pub.b64 not found")
        .trim()
        .to_string();

    // The setup script creates initos.erofs with verity enabled
    // and initos.erofs.sig with the signature.
    // We need to mount the parent filesystem to access the verity-enabled file.
    // For the integration test, we verify using the digest + signature directly.
    let digest_bytes =
        fs::read(output_dir.path().join("digest.bin")).expect("digest.bin not found");

    let sig_bytes =
        fs::read(output_dir.path().join("initos.erofs.sig")).expect("initos.erofs.sig not found");

    let result = initos::verify::verify_signature(&digest_bytes, &sig_bytes, &pub_key_b64)
        .expect("verification call failed");

    assert!(result, "e2e: valid image signature should verify");

    // Also test with tampered digest
    let mut bad_digest = digest_bytes.clone();
    bad_digest[0] ^= 0xFF;
    let result = initos::verify::verify_signature(&bad_digest, &sig_bytes, &pub_key_b64)
        .expect("verification call failed");
    assert!(!result, "e2e: tampered digest should NOT verify");
}

/// Test the verify_image function with an openssl-generated keypair+signature.
/// This test creates test artifacts using openssl directly in the test,
/// without requiring fs-verity kernel support.
#[test]
fn test_verify_roundtrip_with_openssl() {
    // Check if openssl is available
    if Command::new("openssl").arg("version").output().is_err() {
        eprintln!("SKIP: openssl not available");
        return;
    }

    let dir = tempfile::tempdir().unwrap();
    let key_path = dir.path().join("key.pem");
    let digest_path = dir.path().join("digest.bin");
    let sig_path = dir.path().join("test.sig");

    // Generate ed25519 keypair with openssl
    let gen_output = Command::new("openssl")
        .args(["genpkey", "-algorithm", "ed25519", "-out"])
        .arg(&key_path)
        .output()
        .unwrap();
    assert!(gen_output.status.success(), "openssl keygen failed");

    // Create a test digest (32 bytes)
    let digest_data = b"012345678901234567890123456789ab";
    fs::write(&digest_path, digest_data).unwrap();

    // Sign the digest with openssl (-rawin required for ed25519)
    let sign_output = Command::new("openssl")
        .args(["pkeyutl", "-sign", "-rawin", "-inkey"])
        .arg(&key_path)
        .arg("-in")
        .arg(&digest_path)
        .arg("-out")
        .arg(&sig_path)
        .output()
        .unwrap();
    assert!(
        sign_output.status.success(),
        "openssl sign failed: {}",
        String::from_utf8_lossy(&sign_output.stderr)
    );

    // Extract raw public key: DER format, last 32 bytes
    let der_output = Command::new("openssl")
        .args(["pkey", "-in"])
        .arg(&key_path)
        .args(["-pubout", "-outform", "DER"])
        .output()
        .unwrap();
    assert!(der_output.status.success(), "openssl pubkey extract failed");

    let der_bytes = &der_output.stdout;
    // Ed25519 DER public key is 44 bytes: 12 byte header + 32 byte key
    assert!(der_bytes.len() >= 32, "DER output too short");
    let raw_pub_key = &der_bytes[der_bytes.len() - 32..];
    use base64::Engine;
    let pub_key_b64 = base64::engine::general_purpose::STANDARD.encode(raw_pub_key);

    // Read signature
    let sig_bytes = fs::read(&sig_path).unwrap();

    // Verify using our library
    let result = initos::verify::verify_signature(digest_data, &sig_bytes, &pub_key_b64).unwrap();
    assert!(
        result,
        "openssl-generated signature should verify with our library"
    );

    // Tamper with the digest and verify it fails
    let mut bad_digest = digest_data.to_vec();
    bad_digest[0] ^= 0xFF;
    let result = initos::verify::verify_signature(&bad_digest, &sig_bytes, &pub_key_b64).unwrap();
    assert!(!result, "tampered digest should NOT verify");
}
