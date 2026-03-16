//! Raw TPM2 wire protocol over /dev/tpmrm0.
//!
//! Implements: StartAuthSession, PolicyPCR, PolicyGetDigest, FlushContext,
//! CreatePrimary, Create, Load, EvictControl, Unseal, PCR_Extend.
//!
//! Zero external dependencies — only uses std.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};

// ─── TPM2 command codes ─────────────────────────────────────────────────────

const TPM2_CC_STARTUP: u32 = 0x0000_0144;
const TPM2_CC_START_AUTH_SESSION: u32 = 0x0000_0176;
const TPM2_CC_POLICY_PCR: u32 = 0x0000_017F;
const TPM2_CC_UNSEAL: u32 = 0x0000_015E;
const TPM2_CC_CREATE_PRIMARY: u32 = 0x0000_0131;
const TPM2_CC_CREATE: u32 = 0x0000_0153;
const TPM2_CC_LOAD: u32 = 0x0000_0157;
const TPM2_CC_EVICT_CONTROL: u32 = 0x0000_0120;
const TPM2_CC_POLICY_GET_DIGEST: u32 = 0x0000_0189;
const TPM2_CC_FLUSH_CONTEXT: u32 = 0x0000_0165;
const TPM2_CC_PCR_EXTEND: u32 = 0x0000_0182;
const TPM2_CC_DA_LOCK_RESET: u32 = 0x0000_0139;

// ─── TPM2 constants ─────────────────────────────────────────────────────────

const TPM_ST_NO_SESSIONS: u16 = 0x8001;
const TPM_ST_SESSIONS: u16 = 0x8002;
const TPM_RH_NULL: u32 = 0x4000_0007;
const TPM_RH_OWNER: u32 = 0x4000_0001;
const TPM_RH_LOCKOUT: u32 = 0x4000_000A;
const TPM_RS_PW: u32 = 0x4000_0009;
const TPM_SE_POLICY: u8 = 0x01;
const TPM_SE_TRIAL: u8 = 0x03;
const TPM_ALG_SHA256: u16 = 0x000B;
const TPM_ALG_NULL: u16 = 0x0010;
const TPM_ALG_RSA: u16 = 0x0001;
const TPM_ALG_AES: u16 = 0x0006;
const TPM_ALG_CFB: u16 = 0x0043;
const TPM_ALG_KEYEDHASH: u16 = 0x0008;

const SHA256_DIGEST_SIZE: usize = 32;
const RSP_BUF_SIZE: usize = 4096;

/// RSA-2048 storage key object attributes:
/// fixedTPM | fixedParent | sensitiveDataOrigin | userWithAuth | restricted | decrypt
const STORAGE_KEY_ATTRS: u32 = 0x0003_0072;

/// Sealed data object attributes: fixedTPM | fixedParent
const SEALED_OBJ_ATTRS: u32 = 0x0000_0012;

/// Default persistent handles
pub const DEFAULT_PRIMARY_HANDLE: u32 = 0x8100_0000;
pub const DEFAULT_SEALED_HANDLE: u32 = 0x8100_0001;

/// Config paths
pub const TPM_DIR: &str = "/z/initos/tpm";
pub const PRIMARY_HANDLE_PATH: &str = "/z/initos/tpm/tpm_primary";
pub const SEALED_HANDLE_PATH: &str = "/z/initos/tpm/tpm_handle";
const TPM_DEVICE: &str = "/dev/tpmrm0";

const PW_AUTH_SIZE: u32 = 9; // 4+2+1+2

// ─── Public API ─────────────────────────────────────────────────────────────

/// Open the TPM device.
pub fn open() -> Result<File, Box<dyn std::error::Error>> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .open(TPM_DEVICE)
        .map_err(|e| format!("failed to open {}: {}", TPM_DEVICE, e).into())
}

/// Send TPM2_Startup(Clear). Needed for swtpm and some TPM initialization flows.
pub fn startup(dev: &mut (impl Read + Write)) -> Result<(), Box<dyn std::error::Error>> {
    let cmd_size: u32 = 10 + 2;
    let mut cmd = vec![0u8; cmd_size as usize];
    let off = write_header(&mut cmd, TPM_ST_NO_SESSIONS, cmd_size, TPM2_CC_STARTUP);
    put_u16(&mut cmd, off, 0x0000); // TPM_SU_CLEAR
    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "Startup")
}

/// Read a hex handle from a file, falling back to a default.
pub fn read_handle_file(path: &str, default: u32) -> Result<u32, Box<dyn std::error::Error>> {
    match fs::read_to_string(path) {
        Ok(s) => {
            let s = s.trim();
            let s = s
                .strip_prefix("0x")
                .or_else(|| s.strip_prefix("0X"))
                .unwrap_or(s);
            u32::from_str_radix(s, 16)
                .map_err(|e| format!("bad handle in {}: '{}': {}", path, s, e).into())
        }
        Err(_) => {
            eprintln!("tpm2: {} not found, using 0x{:08X}", path, default);
            Ok(default)
        }
    }
}

/// Start an auth session (policy or trial).
pub fn start_auth_session(
    dev: &mut (impl Read + Write),
    session_type: u8,
) -> Result<u32, Box<dyn std::error::Error>> {
    let cmd_size: u32 = 10 + 4 + 4 + (2 + SHA256_DIGEST_SIZE as u32) + 2 + 1 + 2 + 2;
    let mut cmd = vec![0u8; cmd_size as usize];

    let mut off = write_header(
        &mut cmd,
        TPM_ST_NO_SESSIONS,
        cmd_size,
        TPM2_CC_START_AUTH_SESSION,
    );
    off = put_u32(&mut cmd, off, TPM_RH_NULL);
    off = put_u32(&mut cmd, off, TPM_RH_NULL);
    off = put_u16(&mut cmd, off, SHA256_DIGEST_SIZE as u16);
    off += SHA256_DIGEST_SIZE; // zeros
    off = put_u16(&mut cmd, off, 0);
    cmd[off] = session_type;
    off += 1;
    off = put_u16(&mut cmd, off, TPM_ALG_NULL);
    put_u16(&mut cmd, off, TPM_ALG_SHA256);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "StartAuthSession")?;
    Ok(get_u32(&rsp, 10))
}

/// Start a policy session.
pub fn start_policy_session(
    dev: &mut (impl Read + Write),
) -> Result<u32, Box<dyn std::error::Error>> {
    start_auth_session(dev, TPM_SE_POLICY)
}

/// Start a trial session.
pub fn start_trial_session(
    dev: &mut (impl Read + Write),
) -> Result<u32, Box<dyn std::error::Error>> {
    start_auth_session(dev, TPM_SE_TRIAL)
}

/// Apply PolicyPCR (SHA256, PCR 7) to a session.
pub fn policy_pcr(
    dev: &mut (impl Read + Write),
    session: u32,
) -> Result<(), Box<dyn std::error::Error>> {
    let cmd_size: u32 = 10 + 4 + 2 + 4 + 2 + 1 + 3;
    let mut cmd = vec![0u8; cmd_size as usize];

    let mut off = write_header(&mut cmd, TPM_ST_NO_SESSIONS, cmd_size, TPM2_CC_POLICY_PCR);
    off = put_u32(&mut cmd, off, session);
    off = put_u16(&mut cmd, off, 0);
    off = put_u32(&mut cmd, off, 1);
    off = put_u16(&mut cmd, off, TPM_ALG_SHA256);
    cmd[off] = 3;
    off += 1;
    cmd[off] = 0x80; // PCR 7

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "PolicyPCR")
}

/// Get the policy digest from a session.
pub fn policy_get_digest(
    dev: &mut (impl Read + Write),
    session: u32,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let cmd_size: u32 = 10 + 4;
    let mut cmd = vec![0u8; cmd_size as usize];
    let off = write_header(
        &mut cmd,
        TPM_ST_NO_SESSIONS,
        cmd_size,
        TPM2_CC_POLICY_GET_DIGEST,
    );
    put_u32(&mut cmd, off, session);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "PolicyGetDigest")?;
    let sz = get_u16(&rsp, 10) as usize;
    Ok(rsp[12..12 + sz].to_vec())
}

/// Extend a PCR with random data from /dev/urandom.
pub fn pcr_extend(
    dev: &mut (impl Read + Write),
    pcr_index: u32,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut digest = [0u8; SHA256_DIGEST_SIZE];
    let mut urand = OpenOptions::new()
        .read(true)
        .open("/dev/urandom")
        .map_err(|e| format!("open /dev/urandom: {}", e))?;
    urand.read_exact(&mut digest)?;

    let cmd_size: u32 = 10 + 4 + 4 + PW_AUTH_SIZE + 4 + 2 + SHA256_DIGEST_SIZE as u32;
    let mut cmd = vec![0u8; cmd_size as usize];

    let mut off = write_header(&mut cmd, TPM_ST_SESSIONS, cmd_size, TPM2_CC_PCR_EXTEND);
    off = put_u32(&mut cmd, off, pcr_index);
    off = put_u32(&mut cmd, off, PW_AUTH_SIZE);
    off = write_pw_auth(&mut cmd, off);
    off = put_u32(&mut cmd, off, 1);
    off = put_u16(&mut cmd, off, TPM_ALG_SHA256);
    cmd[off..off + SHA256_DIGEST_SIZE].copy_from_slice(&digest);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "PCR_Extend")
}

/// Flush a transient handle or session.
pub fn flush_context(
    dev: &mut (impl Read + Write),
    handle: u32,
) -> Result<(), Box<dyn std::error::Error>> {
    let cmd_size: u32 = 10 + 4;
    let mut cmd = vec![0u8; cmd_size as usize];
    let off = write_header(
        &mut cmd,
        TPM_ST_NO_SESSIONS,
        cmd_size,
        TPM2_CC_FLUSH_CONTEXT,
    );
    put_u32(&mut cmd, off, handle);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "FlushContext")
}

/// Unseal a sealed object using a policy session.
pub fn unseal(
    dev: &mut (impl Read + Write),
    item_handle: u32,
    session: u32,
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let auth_size: u32 = 4 + 2 + 1 + 2;
    let cmd_size: u32 = 10 + 4 + 4 + auth_size;
    let mut cmd = vec![0u8; cmd_size as usize];

    let mut off = write_header(&mut cmd, TPM_ST_SESSIONS, cmd_size, TPM2_CC_UNSEAL);
    off = put_u32(&mut cmd, off, item_handle);
    off = put_u32(&mut cmd, off, auth_size);
    off = put_u32(&mut cmd, off, session);
    off = put_u16(&mut cmd, off, 0);
    cmd[off] = 0x00;
    off += 1;
    put_u16(&mut cmd, off, 0);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "Unseal")?;

    let data_size = get_u16(&rsp, 14) as usize;
    Ok(rsp[16..16 + data_size].to_vec())
}

/// Create an RSA-2048 storage primary key under the owner hierarchy.
/// Returns the transient handle.
pub fn create_primary(dev: &mut (impl Read + Write)) -> Result<u32, Box<dyn std::error::Error>> {
    let tpmt_public_size: u16 = 26;
    let sensitive_size: u16 = 4;

    let cmd_size: u32 =
        10 + 4 + 4 + PW_AUTH_SIZE + 2 + sensitive_size as u32 + 2 + tpmt_public_size as u32 + 2 + 4;

    let mut cmd = vec![0u8; cmd_size as usize];
    let mut off = write_header(&mut cmd, TPM_ST_SESSIONS, cmd_size, TPM2_CC_CREATE_PRIMARY);

    off = put_u32(&mut cmd, off, TPM_RH_OWNER);
    off = put_u32(&mut cmd, off, PW_AUTH_SIZE);
    off = write_pw_auth(&mut cmd, off);

    off = put_u16(&mut cmd, off, sensitive_size);
    off = put_u16(&mut cmd, off, 0);
    off = put_u16(&mut cmd, off, 0);

    off = put_u16(&mut cmd, off, tpmt_public_size);
    off = put_u16(&mut cmd, off, TPM_ALG_RSA);
    off = put_u16(&mut cmd, off, TPM_ALG_SHA256);
    off = put_u32(&mut cmd, off, STORAGE_KEY_ATTRS);
    off = put_u16(&mut cmd, off, 0);
    off = put_u16(&mut cmd, off, TPM_ALG_AES);
    off = put_u16(&mut cmd, off, 128);
    off = put_u16(&mut cmd, off, TPM_ALG_CFB);
    off = put_u16(&mut cmd, off, TPM_ALG_NULL);
    off = put_u16(&mut cmd, off, 2048);
    off = put_u32(&mut cmd, off, 0);
    off = put_u16(&mut cmd, off, 0);

    off = put_u16(&mut cmd, off, 0);
    put_u32(&mut cmd, off, 0);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "CreatePrimary")?;
    Ok(get_u32(&rsp, 10))
}

/// Persist (or unpersist) a transient handle.
pub fn evict_control(
    dev: &mut (impl Read + Write),
    object_handle: u32,
    persistent_handle: u32,
) -> Result<(), Box<dyn std::error::Error>> {
    let cmd_size: u32 = 10 + 4 + 4 + 4 + PW_AUTH_SIZE + 4;
    let mut cmd = vec![0u8; cmd_size as usize];

    let mut off = write_header(&mut cmd, TPM_ST_SESSIONS, cmd_size, TPM2_CC_EVICT_CONTROL);
    off = put_u32(&mut cmd, off, TPM_RH_OWNER);
    off = put_u32(&mut cmd, off, object_handle);
    off = put_u32(&mut cmd, off, PW_AUTH_SIZE);
    off = write_pw_auth(&mut cmd, off);
    put_u32(&mut cmd, off, persistent_handle);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "EvictControl")
}

/// Try to evict an existing persistent object. Ignores errors.
/// Clears any DA lockout that may result from the failed attempt.
pub fn try_evict_persistent(dev: &mut (impl Read + Write), persistent_handle: u32) {
    if evict_control(dev, persistent_handle, persistent_handle).is_err() {
        // A failed EvictControl on a non-existent handle may increment the
        // DA failure counter, eventually triggering TPM_RC_LOCKOUT. Clear it.
        let _ = dictionary_attack_lock_reset(dev);
    }
}

/// Reset the Dictionary Attack lockout counter.
/// Uses TPM_RH_LOCKOUT with empty password auth.
pub fn dictionary_attack_lock_reset(
    dev: &mut (impl Read + Write),
) -> Result<(), Box<dyn std::error::Error>> {
    let cmd_size: u32 = 10 + 4 + 4 + PW_AUTH_SIZE;
    let mut cmd = vec![0u8; cmd_size as usize];
    let mut off = write_header(&mut cmd, TPM_ST_SESSIONS, cmd_size, TPM2_CC_DA_LOCK_RESET);
    off = put_u32(&mut cmd, off, TPM_RH_LOCKOUT);
    off = put_u32(&mut cmd, off, PW_AUTH_SIZE);
    write_pw_auth(&mut cmd, off);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "DictionaryAttackLockReset")
}

/// Create a sealed data object under a parent key.
/// Returns (outPrivate, outPublic) as raw TPM2B blobs.
pub fn create(
    dev: &mut (impl Read + Write),
    parent: u32,
    data: &[u8],
    policy_digest: &[u8],
) -> Result<(Vec<u8>, Vec<u8>), Box<dyn std::error::Error>> {
    let sensitive_inner: u16 = 2 + 2 + data.len() as u16;
    let tpmt_public_size: u16 = 2 + 2 + 4 + (2 + policy_digest.len() as u16) + 2 + 2;

    let cmd_size: u32 = 10
        + 4
        + 4
        + PW_AUTH_SIZE
        + (2 + sensitive_inner as u32)
        + (2 + tpmt_public_size as u32)
        + 2
        + 4;

    let mut cmd = vec![0u8; cmd_size as usize];
    let mut off = write_header(&mut cmd, TPM_ST_SESSIONS, cmd_size, TPM2_CC_CREATE);

    off = put_u32(&mut cmd, off, parent);
    off = put_u32(&mut cmd, off, PW_AUTH_SIZE);
    off = write_pw_auth(&mut cmd, off);

    off = put_u16(&mut cmd, off, sensitive_inner);
    off = put_u16(&mut cmd, off, 0);
    off = put_u16(&mut cmd, off, data.len() as u16);
    cmd[off..off + data.len()].copy_from_slice(data);
    off += data.len();

    off = put_u16(&mut cmd, off, tpmt_public_size);
    off = put_u16(&mut cmd, off, TPM_ALG_KEYEDHASH);
    off = put_u16(&mut cmd, off, TPM_ALG_SHA256);
    off = put_u32(&mut cmd, off, SEALED_OBJ_ATTRS);
    off = put_u16(&mut cmd, off, policy_digest.len() as u16);
    cmd[off..off + policy_digest.len()].copy_from_slice(policy_digest);
    off += policy_digest.len();
    off = put_u16(&mut cmd, off, TPM_ALG_NULL);
    off = put_u16(&mut cmd, off, 0);

    off = put_u16(&mut cmd, off, 0);
    put_u32(&mut cmd, off, 0);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "Create")?;

    let mut roff: usize = 14;
    let priv_size = get_u16(&rsp, roff) as usize;
    let priv_blob = rsp[roff..roff + 2 + priv_size].to_vec();
    roff += 2 + priv_size;

    let pub_size = get_u16(&rsp, roff) as usize;
    let pub_blob = rsp[roff..roff + 2 + pub_size].to_vec();

    Ok((priv_blob, pub_blob))
}

/// Load a key/sealed object under a parent. Returns the transient handle.
pub fn load(
    dev: &mut (impl Read + Write),
    parent: u32,
    priv_area: &[u8],
    pub_area: &[u8],
) -> Result<u32, Box<dyn std::error::Error>> {
    let cmd_size: u32 = 10 + 4 + 4 + PW_AUTH_SIZE + priv_area.len() as u32 + pub_area.len() as u32;
    let mut cmd = vec![0u8; cmd_size as usize];

    let mut off = write_header(&mut cmd, TPM_ST_SESSIONS, cmd_size, TPM2_CC_LOAD);
    off = put_u32(&mut cmd, off, parent);
    off = put_u32(&mut cmd, off, PW_AUTH_SIZE);
    off = write_pw_auth(&mut cmd, off);

    cmd[off..off + priv_area.len()].copy_from_slice(priv_area);
    off += priv_area.len();
    cmd[off..off + pub_area.len()].copy_from_slice(pub_area);

    let rsp = tpm_transact(dev, &cmd)?;
    check_response(&rsp, "Load")?;
    Ok(get_u32(&rsp, 10))
}

// ─── Internal helpers ───────────────────────────────────────────────────────

/// TPM_RC_RETRY — transient condition, retry the command.
const TPM_RC_RETRY: u32 = 0x0000_0922;
/// TPM_RC_YIELDED — the TPM has suspended execution, retry.
const TPM_RC_YIELDED: u32 = 0x0000_0908;
/// TPM_RC_LOCKOUT — DA lockout active, retry after reset.
const TPM_RC_LOCKOUT: u32 = 0x0000_0921;
/// Maximum number of retries for transient errors.
const TPM_MAX_RETRIES: u32 = 20;
/// Delay between retries in milliseconds.
const TPM_RETRY_DELAY_MS: u64 = 50;

fn tpm_transact(
    dev: &mut (impl Read + Write),
    cmd: &[u8],
) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    for attempt in 0..=TPM_MAX_RETRIES {
        dev.write_all(cmd)?;
        let mut rsp = vec![0u8; RSP_BUF_SIZE];
        let n = dev.read(&mut rsp)?;
        rsp.truncate(n);
        if n < 10 {
            return Err(format!("TPM response too short: {} bytes", n).into());
        }
        let rc = get_u32(&rsp, 6);
        if rc == TPM_RC_RETRY || rc == TPM_RC_YIELDED || rc == TPM_RC_LOCKOUT {
            if attempt < TPM_MAX_RETRIES {
                if rc == TPM_RC_LOCKOUT {
                    // Try to clear DA lockout before retrying
                    let _ = da_lock_reset_raw(dev);
                }
                std::thread::sleep(std::time::Duration::from_millis(TPM_RETRY_DELAY_MS));
                continue;
            }
        }
        return Ok(rsp);
    }
    unreachable!()
}

/// Raw DA lockout reset — bypasses tpm_transact to avoid recursion.
fn da_lock_reset_raw(dev: &mut (impl Read + Write)) {
    let cmd_size: u32 = 10 + 4 + 4 + PW_AUTH_SIZE;
    let mut cmd = vec![0u8; cmd_size as usize];
    let mut off = write_header(&mut cmd, TPM_ST_SESSIONS, cmd_size, TPM2_CC_DA_LOCK_RESET);
    off = put_u32(&mut cmd, off, TPM_RH_LOCKOUT);
    off = put_u32(&mut cmd, off, PW_AUTH_SIZE);
    write_pw_auth(&mut cmd, off);
    let _ = dev.write_all(&cmd);
    let mut rsp = vec![0u8; RSP_BUF_SIZE];
    let _ = dev.read(&mut rsp);
}

fn check_response(rsp: &[u8], cmd_name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let rc = get_u32(rsp, 6);
    if rc != 0 {
        Err(format!("{}: TPM2 error 0x{:08X}", cmd_name, rc).into())
    } else {
        Ok(())
    }
}

fn write_pw_auth(buf: &mut [u8], off: usize) -> usize {
    let mut o = off;
    o = put_u32(buf, o, TPM_RS_PW);
    o = put_u16(buf, o, 0);
    buf[o] = 0x00;
    o += 1;
    o = put_u16(buf, o, 0);
    o
}

#[inline]
fn put_u16(buf: &mut [u8], off: usize, val: u16) -> usize {
    buf[off..off + 2].copy_from_slice(&val.to_be_bytes());
    off + 2
}
#[inline]
fn put_u32(buf: &mut [u8], off: usize, val: u32) -> usize {
    buf[off..off + 4].copy_from_slice(&val.to_be_bytes());
    off + 4
}
#[inline]
fn get_u16(buf: &[u8], off: usize) -> u16 {
    u16::from_be_bytes([buf[off], buf[off + 1]])
}
#[inline]
fn get_u32(buf: &[u8], off: usize) -> u32 {
    u32::from_be_bytes([buf[off], buf[off + 1], buf[off + 2], buf[off + 3]])
}

fn write_header(buf: &mut [u8], tag: u16, size: u32, code: u32) -> usize {
    let mut off = 0;
    off = put_u16(buf, off, tag);
    off = put_u32(buf, off, size);
    put_u32(buf, off, code)
}
