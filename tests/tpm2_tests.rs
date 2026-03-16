//! Integration tests for TPM2 wire protocol against swtpm (software TPM emulator).
//!
//! These tests start a real swtpm process and exercise the TPM2 commands
//! over a TCP connection.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicU16, Ordering};
use tempfile::TempDir;

/// Base port, incremented per test to avoid collisions with parallel tests.
static NEXT_PORT: AtomicU16 = AtomicU16::new(2321);

/// A running swtpm instance with its TCP connection.
struct SwtpmSession {
    /// The swtpm child process.
    _process: Child,
    /// TCP stream connected to the TPM command port.
    stream: TcpStream,
    /// Temp directory holding TPM state (dropped = cleaned up).
    _state_dir: TempDir,
}

impl SwtpmSession {
    /// Start swtpm and connect to it. Returns a ready-to-use session.
    fn start() -> Self {
        let state_dir = TempDir::new().expect("failed to create temp dir for swtpm state");
        let port = NEXT_PORT.fetch_add(2, Ordering::SeqCst);
        let ctrl_port = port + 1;

        let process = Command::new("swtpm")
            .args([
                "socket",
                "--tpm2",
                "--tpmstate",
                &format!("dir={}", state_dir.path().display()),
                "--server",
                &format!("type=tcp,port={port}"),
                "--ctrl",
                &format!("type=tcp,port={ctrl_port}"),
                "--flags",
                "not-need-init,startup-clear",
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("failed to start swtpm — is it installed?");

        // Wait for swtpm to start listening
        let mut stream = None;
        for _ in 0..20 {
            match TcpStream::connect(format!("127.0.0.1:{port}")) {
                Ok(s) => {
                    stream = Some(s);
                    break;
                }
                Err(_) => std::thread::sleep(std::time::Duration::from_millis(100)),
            }
        }
        let stream = stream.expect("failed to connect to swtpm after 2s");
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(2)))
            .unwrap();

        SwtpmSession {
            _process: process,
            stream,
            _state_dir: state_dir,
        }
    }
}

impl Drop for SwtpmSession {
    fn drop(&mut self) {
        let _ = self._process.kill();
        let _ = self._process.wait();
    }
}

impl Read for SwtpmSession {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.stream.read(buf)
    }
}

impl Write for SwtpmSession {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.stream.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.stream.flush()
    }
}

#[test]
fn test_create_primary() {
    let mut tpm = SwtpmSession::start();

    // Create an RSA-2048 primary storage key
    let transient_handle = initos::tpm2::create_primary(&mut tpm).expect("create_primary failed");

    eprintln!(
        "create_primary returned transient handle: 0x{:08X}",
        transient_handle
    );

    // Transient handles are in the range 0x80000000..0x80FFFFFF
    assert!(
        transient_handle >= 0x8000_0000 && transient_handle < 0x8100_0000,
        "expected transient handle range, got 0x{:08X}",
        transient_handle
    );

    // Flush the transient handle
    initos::tpm2::flush_context(&mut tpm, transient_handle).expect("flush_context failed");
}

#[test]
fn test_create_primary_and_persist() {
    let mut tpm = SwtpmSession::start();

    // Create primary key
    let transient = initos::tpm2::create_primary(&mut tpm).expect("create_primary failed");
    eprintln!("transient handle: 0x{:08X}", transient);

    // Persist it at the default handle
    let persistent = initos::tpm2::DEFAULT_PRIMARY_HANDLE;
    initos::tpm2::evict_control(&mut tpm, transient, persistent)
        .expect("evict_control (persist) failed");
    eprintln!("persisted at: 0x{:08X}", persistent);

    // Evict (unpersist) to clean up
    initos::tpm2::evict_control(&mut tpm, persistent, persistent)
        .expect("evict_control (unpersist) failed");
}

#[test]
fn test_seal_and_unseal() {
    let mut tpm = SwtpmSession::start();

    // 1. Create primary key (keep as transient)
    let primary = initos::tpm2::create_primary(&mut tpm).expect("create_primary failed");
    eprintln!("primary transient: 0x{:08X}", primary);

    // 2. Compute the policy digest via a trial session
    let trial = initos::tpm2::start_trial_session(&mut tpm).expect("start_trial_session failed");
    initos::tpm2::policy_pcr(&mut tpm, trial).expect("policy_pcr (trial) failed");
    let digest =
        initos::tpm2::policy_get_digest(&mut tpm, trial).expect("policy_get_digest failed");
    initos::tpm2::flush_context(&mut tpm, trial).expect("flush trial session failed");
    eprintln!("policy digest ({} bytes): {:02x?}", digest.len(), digest);
    assert_eq!(digest.len(), 32, "SHA256 policy digest should be 32 bytes");

    // 3. Seal a secret under the transient primary
    let secret = b"my-tpm-sealed-secret-42";
    let (priv_blob, pub_blob) =
        initos::tpm2::create(&mut tpm, primary, secret, &digest).expect("create (seal) failed");
    eprintln!(
        "sealed object: priv_blob={} bytes, pub_blob={} bytes",
        priv_blob.len(),
        pub_blob.len()
    );
    assert!(!priv_blob.is_empty(), "priv_blob should not be empty");
    assert!(!pub_blob.is_empty(), "pub_blob should not be empty");

    // 4. Load the sealed object under the transient primary
    let loaded = initos::tpm2::load(&mut tpm, primary, &priv_blob, &pub_blob)
        .expect("load sealed object failed");
    eprintln!("loaded transient: 0x{:08X}", loaded);

    // 5. Unseal using a real policy session (no need to persist for testing)
    let session =
        initos::tpm2::start_policy_session(&mut tpm).expect("start_policy_session failed");
    initos::tpm2::policy_pcr(&mut tpm, session).expect("policy_pcr failed");
    let unsealed = initos::tpm2::unseal(&mut tpm, loaded, session).expect("unseal failed");
    eprintln!("unsealed: {:?}", String::from_utf8_lossy(&unsealed));
    assert_eq!(
        unsealed, secret,
        "unsealed data should match original secret"
    );

    // 6. Extend PCR 7 (anti-replay) — second unseal should fail
    initos::tpm2::pcr_extend(&mut tpm, 7).expect("pcr_extend failed");

    let session2 =
        initos::tpm2::start_policy_session(&mut tpm).expect("start_policy_session 2 failed");
    initos::tpm2::policy_pcr(&mut tpm, session2).expect("policy_pcr 2 failed");
    let unseal2_result = initos::tpm2::unseal(&mut tpm, loaded, session2);
    assert!(
        unseal2_result.is_err(),
        "unseal should fail after PCR extension"
    );
    eprintln!(
        "second unseal correctly failed: {}",
        unseal2_result.unwrap_err()
    );

    // Clean up
    initos::tpm2::flush_context(&mut tpm, loaded).ok();
    initos::tpm2::flush_context(&mut tpm, primary).ok();
}

/// Full production-flow test: create_primary → persist → seal → persist → unseal.
/// This mirrors the actual `initos primary` + `initos seal` + `initos unseal` flow.
#[test]
fn test_full_seal_unseal_with_persist() {
    let mut tpm = SwtpmSession::start();

    // 1. Create and persist primary key (mirrors `cmd_primary`)
    let transient_primary = initos::tpm2::create_primary(&mut tpm).expect("create_primary failed");
    let primary_handle = initos::tpm2::DEFAULT_PRIMARY_HANDLE;
    initos::tpm2::try_evict_persistent(&mut tpm, primary_handle);
    initos::tpm2::evict_control(&mut tpm, transient_primary, primary_handle)
        .expect("persist primary failed");
    eprintln!("primary persisted at 0x{:08X}", primary_handle);

    // 2. Trial session to get policy digest (mirrors `cmd_seal`)
    let trial = initos::tpm2::start_trial_session(&mut tpm).expect("start_trial_session failed");
    initos::tpm2::policy_pcr(&mut tpm, trial).expect("policy_pcr (trial) failed");
    let digest =
        initos::tpm2::policy_get_digest(&mut tpm, trial).expect("policy_get_digest failed");
    initos::tpm2::flush_context(&mut tpm, trial).expect("flush trial session failed");

    // 3. Create sealed object under persistent primary
    let secret = b"production-flow-secret";
    let (priv_area, pub_area) = initos::tpm2::create(&mut tpm, primary_handle, secret, &digest)
        .expect("create (seal) failed");

    // 4. Load and persist the sealed object
    let loaded = initos::tpm2::load(&mut tpm, primary_handle, &priv_area, &pub_area)
        .expect("load sealed object failed");
    let sealed_handle = initos::tpm2::DEFAULT_SEALED_HANDLE;
    initos::tpm2::try_evict_persistent(&mut tpm, sealed_handle);
    initos::tpm2::evict_control(&mut tpm, loaded, sealed_handle)
        .expect("persist sealed object failed");
    eprintln!("sealed object persisted at 0x{:08X}", sealed_handle);

    // 5. Unseal via policy session (mirrors `cmd_unseal`)
    let session =
        initos::tpm2::start_policy_session(&mut tpm).expect("start_policy_session failed");
    initos::tpm2::policy_pcr(&mut tpm, session).expect("policy_pcr failed");
    let unsealed = initos::tpm2::unseal(&mut tpm, sealed_handle, session).expect("unseal failed");
    assert_eq!(unsealed, secret, "unsealed data mismatch");
    eprintln!("unsealed: {:?}", String::from_utf8_lossy(&unsealed));

    // 6. Anti-replay: extend PCR 7, verify unseal fails
    initos::tpm2::pcr_extend(&mut tpm, 7).expect("pcr_extend failed");
    let session2 =
        initos::tpm2::start_policy_session(&mut tpm).expect("start_policy_session 2 failed");
    initos::tpm2::policy_pcr(&mut tpm, session2).expect("policy_pcr 2 failed");
    let result = initos::tpm2::unseal(&mut tpm, sealed_handle, session2);
    assert!(result.is_err(), "unseal should fail after PCR extension");
    eprintln!("anti-replay verified: {}", result.unwrap_err());

    // Clean up persistent handles
    initos::tpm2::try_evict_persistent(&mut tpm, sealed_handle);
    initos::tpm2::try_evict_persistent(&mut tpm, primary_handle);
}
