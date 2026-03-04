//! initos — minimal rdinit binary for initrd
//!
//! Runs as PID 1 in an initrd to:
//! 1. Mount core pseudo-filesystems (proc, sys, dev)
//! 2. Find and mount an ext4 partition by label
//! 3. Verify the fs-verity digest of an image file against a signature
//! 4. Loop-mount the verified image as the root filesystem
//! 5. switch_root and exec /sbin/init
//!
//! All configuration is via environment variables (set by kernel cmdline):
//!
//! - INITOS_OP:       "boot" (full init) or "verify" (verify+mount only)
//! - INITOS_IMG:      path to image file (default: /img/ROOT-A.img)
//! - INITOS_PUB_KEY:  hex-encoded ed25519 public key
//! - INITOS_DATA:     partition name to find (default: STATE)
//! - INITOS_FS:     filesystem type (default: ext4)

use std::env;
use std::process;

fn main() {
    let op = env::var("INITOS_OP").unwrap_or_else(|_| "boot".to_string());
    let img = env::var("INITOS_IMG").unwrap_or_else(|_| "/img/ROOT-A.img".to_string());
    let pub_key = env::var("INITOS_PUB_KEY").unwrap_or_default();
    let data = env::var("INITOS_DATA").unwrap_or_else(|_| "STATE".to_string());
    let fs = env::var("INITOS_FS").unwrap_or_else(|_| "ext4".to_string());

    eprintln!("initos: op={} img={} data={} fs={}", op, img, data, fs);

    let result = match op.as_str() {
        "boot" => do_boot(&img, &pub_key, &data, &fs),
        "verify" => do_verify(&img, &pub_key),
        other => {
            eprintln!("initos: unknown operation: {}", other);
            process::exit(1);
        }
    };

    match result {
        Ok(()) => {
            eprintln!("initos: {} completed successfully", op);
        }
        Err(e) => {
            eprintln!("initos: {} failed: {}", op, e);
            process::exit(1);
        }
    }
}

/// Full boot sequence: mount filesystems, find partition, verify image, switch root.
fn do_boot(
    img: &str,
    pub_key: &str,
    data: &str,
    fs: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    // 1. Mount pseudo-filesystems
    eprintln!("initos: mounting proc");
    initos::mount::mount_pseudo_fs("proc", "/proc")?;

    eprintln!("initos: mounting sysfs");
    initos::mount::mount_pseudo_fs("sysfs", "/sys")?;

    eprintln!("initos: mounting devtmpfs");
    initos::mount::mount_pseudo_fs("devtmpfs", "/dev")?;

    // 2. Find partition by label
    eprintln!("initos: looking for partition with label '{}'", data);
    let dev = initos::mount::find_partition_by_label(data)?;
    eprintln!("initos: found partition: {:?}", dev);

    // 3. Mount the partition based on filesystem type
    let mount_point = "/mnt/data";
    eprintln!(
        "initos: mounting {:?} at {} (filesystem: {})",
        dev, mount_point, fs
    );
    initos::mount::mount_filesystem(dev.to_str().unwrap(), mount_point, fs, false)?;

    // 4. Verify the image
    let img_path = format!("{}/{}", mount_point, img.trim_start_matches('/'));
    eprintln!("initos: verifying image {}", img_path);

    if pub_key.is_empty() {
        return Err("INITOS_PUB_KEY not set".into());
    }

    let valid = match initos::verify::verify_image(&img_path, pub_key) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("initos: verify_image failed: {}", e);
            if env::var("INITOS_INSECURE_SKIP_VERITY").unwrap_or_default() == "1" {
                eprintln!(
                    "initos: WARNING: INITOS_INSECURE_SKIP_VERITY=1 is set. Proceeding ANYWAY!"
                );
                true
            } else {
                return Err(e.into());
            }
        }
    };

    if !valid {
        if env::var("INITOS_INSECURE_SKIP_VERITY").unwrap_or_default() == "1" {
            eprintln!("initos: WARNING: image signature FAILED but INITOS_INSECURE_SKIP_VERITY=1 is set. Proceeding ANYWAY!");
        } else {
            return Err("image signature verification FAILED".into());
        }
    }
    eprintln!("initos: image signature check completed");

    // 5. Loop-mount the verified image
    let root_mount = "/mnt/root";
    eprintln!("initos: mounting verified image at {}", root_mount);
    initos::mount::mount_loop(&img_path, root_mount)?;
    eprintln!("initos: mount_ok {}", root_mount);

    // 6. Switch root
    eprintln!("initos: switching root to {}", root_mount);
    initos::mount::switch_root(root_mount, "/sbin/init")?;

    Ok(())
}

/// Verify-only mode: assumes filesystems are already mounted.
/// Verifies the image and optionally mounts it.
fn do_verify(img: &str, pub_key: &str) -> Result<(), Box<dyn std::error::Error>> {
    if pub_key.is_empty() {
        return Err("INITOS_PUB_KEY not set".into());
    }

    eprintln!("initos: verifying image {}", img);

    // Get verity digest
    let (alg, digest) = initos::verity::measure_verity(img)?;
    let digest_hex = initos::verity::digest_to_hex(&digest);
    eprintln!("initos: verity digest (alg={}): {}", alg, digest_hex);

    // Read signature file
    let sig_path = format!("{}.sig", img);
    let sig_bytes =
        std::fs::read(&sig_path).map_err(|e| format!("failed to read {}: {}", sig_path, e))?;
    eprintln!(
        "initos: read signature from {} ({} bytes)",
        sig_path,
        sig_bytes.len()
    );

    // Verify
    let valid = initos::verify::verify_signature(&digest, &sig_bytes, pub_key)?;
    if valid {
        eprintln!("initos: VERIFIED OK");

        // Optionally mount the image
        let root_mount = "/mnt/root";
        eprintln!("initos: mounting verified image at {}", root_mount);
        initos::mount::mount_loop(img, root_mount)?;
    } else {
        return Err("signature verification FAILED".into());
    }

    Ok(())
}
