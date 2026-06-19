//! Ed25519 signature verification for fs-verity digests.
//!
//! Provides functions to verify that a file's fs-verity digest was signed
//! by a trusted key. The public key is provided as a base64-encoded string
//! (compatible with wireguard/libsodium format).

use ed25519_dalek::{Signature, VerifyingKey};
use rsa::{pkcs1::DecodeRsaPublicKey, Pkcs1v15Sign, RsaPublicKey};
use sha2::{Digest, Sha256};
use std::fs;
use std::io;
use std::path::Path;

/// Verify an Ed25519 signature over a digest.
///
/// # Arguments
/// * `digest` - The raw digest bytes (e.g., from `measure_verity`)
/// * `signature_bytes` - The 64-byte Ed25519 signature
/// * `pub_key_b64` - Base64-encoded 32-byte Ed25519 public key
///
/// # Returns
/// * `Ok(true)` if the signature is valid
/// * `Ok(false)` if the signature is invalid
/// * `Err` if the key or signature bytes are malformed
pub fn verify_signature(
    digest: &[u8],
    signature_bytes: &[u8],
    pub_key_b64: &str,
) -> io::Result<bool> {
    use base64::Engine;
    // Decode base64 public key
    let pub_key_bytes = base64::engine::general_purpose::STANDARD
        .decode(pub_key_b64)
        .map_err(|e| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("bad base64 pub_key: {}", e),
            )
        })?;

    if pub_key_bytes.len() != 32 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "ed25519 public key must be 32 bytes, got {}",
                pub_key_bytes.len()
            ),
        ));
    }

    let pub_key_array: [u8; 32] = pub_key_bytes
        .try_into()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "pub key conversion failed"))?;

    let verifying_key = VerifyingKey::from_bytes(&pub_key_array).map_err(|e| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("bad ed25519 key: {}", e),
        )
    })?;

    if signature_bytes.len() != 64 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "ed25519 signature must be 64 bytes, got {}",
                signature_bytes.len()
            ),
        ));
    }

    let sig_array: [u8; 64] = signature_bytes
        .try_into()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "sig conversion failed"))?;

    let signature = Signature::from_bytes(&sig_array);

    match verifying_key.verify_strict(digest, &signature) {
        Ok(()) => Ok(true),
        Err(_) => Ok(false),
    }
}

/// Verify a file's fs-verity digest signature.
///
/// Reads the verity digest via ioctl and the signature from `{path}.sig`,
/// then verifies using the provided public key.
///
/// # Arguments
/// * `img_path` - Path to the image file with fs-verity enabled
/// * `pub_key_b64` - Base64-encoded 32-byte Ed25519 public key
///
/// # Returns
/// * `Ok(true)` if verification succeeds
/// * `Ok(false)` if the signature doesn't match
/// * `Err` on I/O or format errors
pub fn verify_image<P: AsRef<Path>>(img_path: P, pub_key_b64: &str) -> io::Result<bool> {
    let img = img_path.as_ref();

    // Get verity digest from the kernel
    let (_alg, digest) = measure_or_enable_verity(img)?;

    // Read signature file
    let sig_path = signature_path(img, "sig");
    let signature_bytes = fs::read(&sig_path).map_err(|e| {
        io::Error::new(
            e.kind(),
            format!("failed to read signature file {:?}: {}", sig_path, e),
        )
    })?;

    verify_signature(&digest, &signature_bytes, pub_key_b64)
}

/// Verify a file's fs-verity digest signature against RSA X.509 certs in UEFI db.
///
/// Signatures are read from `{path}.<key-id>.db.sig`, where `<key-id>` is the
/// first 16 hex chars of SHA-256(SubjectPublicKeyInfo DER) for the matching
/// UEFI db certificate. The signature is expected to be a PKCS#1 v1.5
/// RSA/SHA256 signature over the fs-verity digest bytes.
pub fn verify_image_db<P: AsRef<Path>>(img_path: P, efi_base_path: &str) -> io::Result<bool> {
    let img = img_path.as_ref();
    let (_alg, digest) = measure_or_enable_verity(img)?;
    let certs = crate::efi::read_db(efi_base_path)?;
    let mut digest_hasher = Sha256::new();
    digest_hasher.update(&digest);
    let signed_digest = digest_hasher.finalize();

    for cert in certs {
        if cert.rsa_public_key_b64.is_empty() {
            continue;
        }
        let sig_path = signature_path(img, &format!("{}.db.sig", cert.key_id));
        let signature_bytes = match fs::read(&sig_path) {
            Ok(sig) => sig,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => {
                return Err(io::Error::new(
                    e.kind(),
                    format!("failed to read db signature file {:?}: {}", sig_path, e),
                ));
            }
        };
        use base64::Engine;
        let key_der = base64::engine::general_purpose::STANDARD
            .decode(cert.rsa_public_key_b64.as_bytes())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("db key: {}", e)))?;
        let Ok(rsa_pub) = RsaPublicKey::from_pkcs1_der(&key_der) else {
            continue;
        };
        if rsa_pub
            .verify(
                Pkcs1v15Sign::new::<Sha256>(),
                &signed_digest,
                &signature_bytes,
            )
            .is_ok()
        {
            eprintln!(
                "initos: db signature verified with key_id={} CN={}",
                cert.key_id, cert.cn
            );
            return Ok(true);
        }
        eprintln!(
            "initos: db signature mismatch for key_id={} CN={}",
            cert.key_id, cert.cn
        );
    }

    Ok(false)
}

fn measure_or_enable_verity(img: &Path) -> io::Result<(u16, Vec<u8>)> {
    match crate::verity::measure_verity(img) {
        Ok(v) => Ok(v),
        Err(e) => {
            // Try enabling fs-verity by opening RO and calling the enable ioctl.
            // (Linux requires O_RDONLY, because any writable FD causes ETXTBSY)
            match std::fs::OpenOptions::new().read(true).open(img) {
                Ok(file) => {
                    if let Err(enable_err) = crate::verity::enable_verity_fd(&file) {
                        eprintln!(
                            "initos: dynamically enabling fs-verity failed: {}",
                            enable_err
                        );
                        Err(io::Error::new(
                            e.kind(),
                            format!("Measure failed: {}, Enable failed: {}", e, enable_err),
                        ))
                    } else {
                        crate::verity::measure_verity(img)
                    }
                }
                Err(open_err) => {
                    eprintln!(
                        "initos: failed to open image for verity enable: {}",
                        open_err
                    );
                    Err(e)
                }
            }
        }
    }
}

fn signature_path(img: &Path, suffix: &str) -> std::path::PathBuf {
    img.with_extension(
        img.extension()
            .map(|e| format!("{}.{}", e.to_string_lossy(), suffix))
            .unwrap_or_else(|| suffix.to_string()),
    )
}

/// Verify a pre-computed digest against a signature file.
///
/// This is useful for testing when fs-verity ioctl is not available.
/// The digest and signature are provided directly.
///
/// # Arguments
/// * `digest` - The digest bytes
/// * `sig_path` - Path to the signature file
/// * `pub_key_b64` - Base64-encoded 32-byte Ed25519 public key
pub fn verify_digest_with_sig_file<P: AsRef<Path>>(
    digest: &[u8],
    sig_path: P,
    pub_key_b64: &str,
) -> io::Result<bool> {
    let signature_bytes = fs::read(sig_path.as_ref())?;
    verify_signature(digest, &signature_bytes, pub_key_b64)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper to generate a keypair and sign data for testing.
    /// Only available in test builds (dev-dependencies include rand_core).
    fn test_sign(data: &[u8]) -> (String, Vec<u8>) {
        use base64::Engine;
        use ed25519_dalek::{Signer, SigningKey};
        use rand::rngs::OsRng;

        let signing_key = SigningKey::generate(&mut OsRng);
        let verifying_key = signing_key.verifying_key();
        let pub_key_b64 =
            base64::engine::general_purpose::STANDARD.encode(verifying_key.as_bytes());

        let signature = signing_key.sign(data);
        (pub_key_b64, signature.to_bytes().to_vec())
    }

    #[test]
    fn test_verify_signature_valid() {
        let digest = b"test-digest-32-bytes-long-xxxxx";
        let (pub_key_b64, sig_bytes) = test_sign(digest);

        let result = verify_signature(digest, &sig_bytes, &pub_key_b64).unwrap();
        assert!(result, "valid signature should verify");
    }

    #[test]
    fn test_verify_signature_invalid_sig() {
        let digest = b"test-digest-32-bytes-long-xxxxx";
        let (_pub_key_b64, mut sig_bytes) = test_sign(digest);
        let (pub_key_b64, _) = test_sign(b"different-data");

        // Tamper with the signature
        sig_bytes[0] ^= 0xFF;

        let result = verify_signature(digest, &sig_bytes, &pub_key_b64).unwrap();
        assert!(!result, "tampered signature should fail");
    }

    #[test]
    fn test_verify_signature_wrong_key() {
        let digest = b"test-digest-32-bytes-long-xxxxx";
        let (_orig_key, sig_bytes) = test_sign(digest);
        // Generate a different keypair
        let (wrong_key, _) = test_sign(b"other");

        let result = verify_signature(digest, &sig_bytes, &wrong_key).unwrap();
        assert!(!result, "wrong key should fail verification");
    }

    #[test]
    fn test_verify_signature_bad_key_b64() {
        let result = verify_signature(b"data", &[0u8; 64], "not-base64!!!");
        assert!(result.is_err(), "bad base64 should return error");
    }

    #[test]
    fn test_verify_signature_wrong_key_length() {
        use base64::Engine;
        let short_key = base64::engine::general_purpose::STANDARD.encode(&[0xaa, 0xbb, 0xcc, 0xdd]);
        let result = verify_signature(b"data", &[0u8; 64], &short_key);
        assert!(result.is_err(), "wrong key length should return error");
    }

    #[test]
    fn test_verify_signature_wrong_sig_length() {
        let (pub_key_b64, _) = test_sign(b"data");
        let result = verify_signature(b"data", &[0u8; 32], &pub_key_b64);
        assert!(result.is_err(), "wrong sig length should return error");
    }

    #[test]
    fn test_verify_digest_with_sig_file() {
        use std::io::Write;

        let digest = b"hello-world-digest-for-testing!!";
        let (pub_key_b64, sig_bytes) = test_sign(digest);

        let dir = tempfile::tempdir().unwrap();
        let sig_path = dir.path().join("test.sig");
        let mut f = fs::File::create(&sig_path).unwrap();
        f.write_all(&sig_bytes).unwrap();

        let result = verify_digest_with_sig_file(digest, &sig_path, &pub_key_b64).unwrap();
        assert!(result, "should verify with sig file");
    }
}
