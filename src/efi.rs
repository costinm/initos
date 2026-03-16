//! EFI variable reader — parse UEFI variables from sysfs.
//!
//! Reads raw EFI variable files from `/sys/firmware/efi/efivars/` and parses:
//! - `SecureBoot` → 0 or 1
//! - `BootCurrent` → boot entry number (u16)
//! - `PK` (Platform Key) → list of X.509 certificates with public keys and SANs

use std::fmt;
use std::fs;
use std::io;
use std::path::Path;

use base64::Engine;
use x509_cert::der::{Decode, Encode};

/// Default sysfs path for EFI variables.
const EFIVARS_DIR: &str = "/sys/firmware/efi/efivars";

/// EFI global variable GUID.
const EFI_GLOBAL_GUID: &str = "8be4df61-93ca-11d2-aa0d-00e098032b8c";

/// EFI_CERT_X509_GUID: {a5c059a1-94e4-4aa7-87b5-ab155c2bf072}
const EFI_CERT_X509_GUID: [u8; 16] = [
    0xa1, 0x59, 0xc0, 0xa5, 0xe4, 0x94, 0xa7, 0x4a, 0x87, 0xb5, 0xab, 0x15, 0x5c, 0x2b, 0xf0,
    0x72,
];

/// An X.509 certificate extracted from an EFI Signature List.
#[derive(Debug)]
pub struct PkCert {
    /// Base64-encoded SubjectPublicKeyInfo (DER).
    pub public_key_b64: String,
    /// Subject Common Name.
    pub cn: String,
    /// Subject Alternative Names (formatted strings like "DNS:example.com").
    pub sans: Vec<String>,
}

impl fmt::Display for PkCert {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} CN={}", self.public_key_b64, self.cn)?;
        if !self.sans.is_empty() {
            write!(f, " SAN={}", self.sans.join(","))?;
        }
        Ok(())
    }
}

/// Read raw EFI variable payload (strips 4-byte attribute header).
pub fn read_efi_var(name: &str, base_path: &str) -> io::Result<Vec<u8>> {
    let path = format!("{}/{}-{}", base_path, name, EFI_GLOBAL_GUID);
    let data = fs::read(&path)?;
    if data.len() < 4 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("EFI variable too short: {} bytes", data.len()),
        ));
    }
    // First 4 bytes are EFI variable attributes (uint32 LE), skip them
    Ok(data[4..].to_vec())
}

/// Read raw EFI variable payload from a raw file (strips 4-byte attribute header).
pub fn read_efi_var_file(path: &Path) -> io::Result<Vec<u8>> {
    let data = fs::read(path)?;
    if data.len() < 4 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("EFI variable too short: {} bytes", data.len()),
        ));
    }
    Ok(data[4..].to_vec())
}

/// Read SecureBoot EFI variable. Returns 0 (disabled) or 1 (enabled).
pub fn read_secure_boot(base_path: &str) -> io::Result<u8> {
    let payload = read_efi_var("SecureBoot", base_path)?;
    if payload.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "SecureBoot payload is empty",
        ));
    }
    Ok(payload[0])
}

/// Read BootCurrent EFI variable. Returns the boot entry number.
pub fn read_boot_current(base_path: &str) -> io::Result<u16> {
    let payload = read_efi_var("BootCurrent", base_path)?;
    if payload.len() < 2 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("BootCurrent payload too short: {} bytes", payload.len()),
        ));
    }
    Ok(u16::from_le_bytes([payload[0], payload[1]]))
}

/// Parse an EFI Signature List and extract X.509 certificates.
///
/// ESL binary format:
/// ```text
/// [16 bytes] SignatureType GUID
/// [4 bytes]  SignatureListSize (total including header)
/// [4 bytes]  SignatureHeaderSize (usually 0)
/// [4 bytes]  SignatureSize (per-signature, includes 16-byte owner GUID)
/// [SignatureHeaderSize bytes] SignatureHeader
/// Repeated signatures:
///   [16 bytes] SignatureOwner GUID
///   [SignatureSize - 16 bytes] DER X.509 certificate
/// ```
pub fn parse_esl(data: &[u8]) -> io::Result<Vec<PkCert>> {
    let mut certs = Vec::new();
    let mut offset = 0;

    while offset + 28 <= data.len() {
        // Parse ESL header
        let sig_type = &data[offset..offset + 16];
        let list_size =
            u32::from_le_bytes(data[offset + 16..offset + 20].try_into().unwrap()) as usize;
        let header_size =
            u32::from_le_bytes(data[offset + 20..offset + 24].try_into().unwrap()) as usize;
        let sig_size =
            u32::from_le_bytes(data[offset + 24..offset + 28].try_into().unwrap()) as usize;

        if sig_type != EFI_CERT_X509_GUID {
            // Skip non-X.509 signature lists
            if list_size == 0 {
                break;
            }
            offset += list_size;
            continue;
        }

        if sig_size < 16 || list_size < 28 + header_size {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid ESL signature size",
            ));
        }

        // Skip the header
        let sigs_start = offset + 28 + header_size;
        let sigs_end = offset + list_size;
        let cert_data_size = sig_size - 16; // subtract owner GUID

        let mut sig_offset = sigs_start;
        while sig_offset + sig_size <= sigs_end {
            // Skip 16-byte SignatureOwner GUID
            let der_start = sig_offset + 16;
            let der_end = der_start + cert_data_size;
            if der_end > data.len() {
                break;
            }
            let der_bytes = &data[der_start..der_end];
            match parse_x509_cert(der_bytes) {
                Ok(cert) => certs.push(cert),
                Err(e) => {
                    eprintln!("efi: failed to parse X.509 cert: {}", e);
                }
            }
            sig_offset += sig_size;
        }

        offset += list_size;
    }

    Ok(certs)
}

/// Read PK (Platform Key) EFI variable. Returns parsed certificates.
pub fn read_pk(base_path: &str) -> io::Result<Vec<PkCert>> {
    let payload = read_efi_var("PK", base_path)?;
    parse_esl(&payload)
}

/// Parse a DER-encoded X.509 certificate, extracting the public key and SANs.
fn parse_x509_cert(der_bytes: &[u8]) -> io::Result<PkCert> {
    let cert = x509_cert::Certificate::from_der(der_bytes)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("DER parse: {}", e)))?;

    let tbs = &cert.tbs_certificate;

    // Extract SubjectPublicKeyInfo as DER and base64-encode it
    let spki_der = tbs
        .subject_public_key_info
        .to_der()
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("SPKI DER: {}", e)))?;
    let public_key_b64 = base64::engine::general_purpose::STANDARD.encode(&spki_der);

    // Extract Subject CN
    let cn = extract_cn(&tbs.subject);

    // Extract SANs from extensions
    let sans = extract_sans(tbs);

    Ok(PkCert {
        public_key_b64,
        cn,
        sans,
    })
}

/// Extract the Common Name from an X.509 Name (RDN sequence).
fn extract_cn(name: &x509_cert::name::Name) -> String {
    use x509_cert::der::asn1::{PrintableStringRef, Utf8StringRef};
    use x509_cert::der::oid::db::rfc4519::CN;
    for rdn in name.0.iter() {
        for atv in rdn.0.iter() {
            if atv.oid == CN {
                // Try UTF-8 first, then PrintableString
                if let Ok(s) = Utf8StringRef::try_from(&atv.value) {
                    return s.as_str().to_string();
                }
                if let Ok(s) = PrintableStringRef::try_from(&atv.value) {
                    return s.as_str().to_string();
                }
                // Fallback: raw bytes as lossy UTF-8
                return String::from_utf8_lossy(atv.value.value()).to_string();
            }
        }
    }
    String::new()
}

/// Extract Subject Alternative Names from TBS certificate extensions.
fn extract_sans(tbs: &x509_cert::TbsCertificate) -> Vec<String> {
    use x509_cert::der::Decode as _;
    use x509_cert::ext::pkix::name::GeneralName;
    use x509_cert::ext::pkix::SubjectAltName;

    let extensions = match &tbs.extensions {
        Some(exts) => exts,
        None => return Vec::new(),
    };

    // SAN OID: 2.5.29.17
    let san_oid = x509_cert::der::oid::db::rfc5280::ID_CE_SUBJECT_ALT_NAME;

    for ext in extensions.iter() {
        if ext.extn_id == san_oid {
            if let Ok(san) = SubjectAltName::from_der(ext.extn_value.as_bytes()) {
                return san
                    .0
                    .iter()
                    .map(|gn| match gn {
                        GeneralName::DnsName(dns) => format!("DNS:{}", dns.as_str()),
                        GeneralName::Rfc822Name(email) => format!("email:{}", email.as_str()),
                        GeneralName::UniformResourceIdentifier(uri) => {
                            format!("URI:{}", uri.as_str())
                        }
                        GeneralName::IpAddress(ip) => {
                            let bytes = ip.as_bytes();
                            if bytes.len() == 4 {
                                format!("IP:{}.{}.{}.{}", bytes[0], bytes[1], bytes[2], bytes[3])
                            } else if bytes.len() == 16 {
                                // IPv6
                                let mut parts = Vec::new();
                                for chunk in bytes.chunks(2) {
                                    parts.push(format!(
                                        "{:x}",
                                        u16::from_be_bytes([chunk[0], chunk[1]])
                                    ));
                                }
                                format!("IP:{}", parts.join(":"))
                            } else {
                                format!("IP:<{} bytes>", bytes.len())
                            }
                        }
                        _ => format!("{:?}", gn),
                    })
                    .collect();
            }
        }
    }

    Vec::new()
}

/// Read and display all EFI info. Returns formatted output string.
pub fn read_efi_info(base_path: &str) -> io::Result<String> {
    let mut out = String::new();

    match read_secure_boot(base_path) {
        Ok(val) => out.push_str(&format!("SecureBoot: {}\n", val)),
        Err(e) => out.push_str(&format!("SecureBoot: error: {}\n", e)),
    }

    match read_boot_current(base_path) {
        Ok(val) => out.push_str(&format!("BootCurrent: {}\n", val)),
        Err(e) => out.push_str(&format!("BootCurrent: error: {}\n", e)),
    }

    match read_pk(base_path) {
        Ok(certs) => {
            for (i, cert) in certs.iter().enumerate() {
                out.push_str(&format!("PK[{}]: {} CN={}\n", i, cert.public_key_b64, cert.cn));
                if !cert.sans.is_empty() {
                    out.push_str(&format!("PK[{}] SAN: {}\n", i, cert.sans.join(", ")));
                }
            }
        }
        Err(e) => out.push_str(&format!("PK: error: {}\n", e)),
    }

    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn test_data_dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests")
    }

    #[test]
    fn test_efi_secure_boot() {
        let path = test_data_dir().join("SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c");
        let payload = read_efi_var_file(&path).unwrap();
        assert_eq!(payload.len(), 1);
        assert_eq!(payload[0], 1, "test data should show SecureBoot enabled");
    }

    #[test]
    fn test_efi_boot_current() {
        let path = test_data_dir().join("BootCurrent-8be4df61-93ca-11d2-aa0d-00e098032b8c");
        let payload = read_efi_var_file(&path).unwrap();
        let val = u16::from_le_bytes([payload[0], payload[1]]);
        assert_eq!(val, 3, "test data should show BootCurrent = 3");
    }

    #[test]
    fn test_efi_pk() {
        let path = test_data_dir().join("PK-8be4df61-93ca-11d2-aa0d-00e098032b8c");
        let payload = read_efi_var_file(&path).unwrap();
        let certs = parse_esl(&payload).unwrap();
        assert_eq!(certs.len(), 1, "test PK should contain exactly 1 cert");
        let cert = &certs[0];
        assert!(
            cert.cn.contains("webinf.info"),
            "CN should contain webinf.info, got: {}",
            cert.cn
        );
        assert!(
            !cert.public_key_b64.is_empty(),
            "public key should not be empty"
        );
        eprintln!("PK cert: {}", cert);
    }

    #[test]
    fn test_efi_secure_boot_value_zero() {
        // Construct a synthetic SecureBoot variable with value 0
        let data = [0x06, 0x00, 0x00, 0x00, 0x00]; // attrs=6, value=0
        let dir = tempfile::tempdir().unwrap();
        let path = dir
            .path()
            .join("SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c");
        std::fs::write(&path, &data).unwrap();
        let val = read_secure_boot(dir.path().to_str().unwrap()).unwrap();
        assert_eq!(val, 0);
    }

    #[test]
    fn test_efi_var_too_short() {
        let dir = tempfile::tempdir().unwrap();
        let var_path = dir
            .path()
            .join("SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c");
        std::fs::write(&var_path, &[0x01, 0x02]).unwrap(); // only 2 bytes
        let result = read_secure_boot(dir.path().to_str().unwrap());
        assert!(result.is_err());
    }

    #[test]
    #[ignore] // Run on EFI system: cargo test test_efi_live -- --ignored
    fn test_efi_live() {
        let info = read_efi_info(EFIVARS_DIR).unwrap();
        eprintln!("{}", info);
    }
}
