#![cfg_attr(target_os = "uefi", no_std)]
#![cfg_attr(target_os = "uefi", no_main)]

#[cfg(target_os = "uefi")]
extern crate alloc;

#[cfg(target_os = "uefi")]
mod uefi_bin {
    extern crate alloc;

    use alloc::format;
    use alloc::string::{String, ToString};
    use alloc::vec::Vec;
    use core::arch::asm;
    use core::fmt::Write;
    use core::ptr::addr_of;
    use rsa::{pkcs1::DecodeRsaPublicKey, Pkcs1v15Sign, RsaPublicKey};
    use sha2::{Digest, Sha256};
    use uefi::boot::{self, AllocateType, MemoryType};
    use uefi::prelude::*;
    use uefi::println;
    use uefi::proto::loaded_image::LoadedImage;
    use uefi::proto::media::file::{File, FileAttribute, FileInfo, FileMode};
    use uefi::proto::media::fs::SimpleFileSystem;
    use uefi::proto::misc::Timestamp;
    use uefi::runtime::{self, ResetType, VariableVendor};
    use x509_cert::der::Decode;

    #[repr(C, packed)]
    #[derive(Debug, Copy, Clone)]
    pub struct SetupHeader {
        pub boot_sector: [u8; 0x01f1],
        pub setup_secs: u8,
        pub root_flags: u16,
        pub sys_size: u32,
        pub ram_size: u16,
        pub video_mode: u16,
        pub root_dev: u16,
        pub signature: u16,
        pub jump: u16,
        pub header: u32,
        pub version: u16,
        pub su_switch: u16,
        pub setup_seg: u16,
        pub start_sys: u16,
        pub kernel_ver: u16,
        pub loader_id: u8,
        pub load_flags: u8,
        pub movesize: u16,
        pub code32_start: u32,
        pub ramdisk_start: u32,
        pub ramdisk_len: u32,
        pub bootsect_kludge: u32,
        pub heap_end: u16,
        pub ext_loader_ver: u8,
        pub ext_loader_type: u8,
        pub cmd_line_ptr: u32,
        pub ramdisk_max: u32,
        pub kernel_alignment: u32,
        pub relocatable_kernel: u8,
        pub min_alignment: u8,
        pub xloadflags: u16,
        pub cmdline_size: u32,
        pub hardware_subarch: u32,
        pub hardware_subarch_data: u64,
        pub payload_offset: u32,
        pub payload_length: u32,
        pub setup_data: u64,
        pub pref_address: u64,
        pub init_size: u32,
        pub handover_offset: u32,
    }

    const SETUP_MAGIC: u32 = 0x53726448; // "HdrS"
    const FAILURE_REBOOT_DELAY_SECONDS: usize = 15;

    type HandoverFn = unsafe extern "sysv64" fn(
        image: *mut core::ffi::c_void,
        system_table: *mut core::ffi::c_void,
        setup: *mut SetupHeader,
    ) -> !;

    unsafe fn linux_efi_handover(
        image: Handle,
        handover_addr: usize,
        setup: *mut SetupHeader,
    ) -> ! {
        let st = uefi::table::system_table_raw()
            .expect("No system table")
            .as_ptr();

        #[cfg(target_arch = "x86_64")]
        asm!("cli", options(nomem, nostack));

        let handover: HandoverFn = core::mem::transmute(handover_addr);

        handover(image.as_ptr(), st as *mut _, setup);
    }

    fn fail_and_reboot(message: &str) -> ! {
        println!("{}", message);
        println!(
            "Boot failed; rebooting in {} seconds so firmware can try the next boot option.",
            FAILURE_REBOOT_DELAY_SECONDS
        );
        boot::stall(FAILURE_REBOOT_DELAY_SECONDS * 1_000_000);
        runtime::reset(ResetType::WARM, Status::LOAD_ERROR, None);
    }

    fn sha256_hex(data: &[u8]) -> String {
        let digest = Sha256::digest(data);
        let mut out = String::new();
        for b in digest {
            let _ = write!(&mut out, "{:02x}", b);
        }
        out
    }

    fn fail_signature(label: &str, db_sha: &str, detail: String) -> ! {
        fail_and_reboot(&format!(
            "{} verification failed; db_sha256={}; {}",
            label, db_sha, detail
        ));
    }

    struct EfiTimer {
        timestamp: Option<boot::ScopedProtocol<Timestamp>>,
        frequency: u64,
        start: u64,
    }

    impl EfiTimer {
        fn new() -> Self {
            if let Ok(handle) = boot::get_handle_for_protocol::<Timestamp>() {
                if let Ok(timestamp) = boot::open_protocol_exclusive::<Timestamp>(handle) {
                    if let Ok(properties) = timestamp.get_properties() {
                        if properties.frequency != 0 {
                            let start = timestamp.get_timestamp();
                            return Self {
                                timestamp: Some(timestamp),
                                frequency: properties.frequency,
                                start,
                            };
                        }
                    }
                }
            }

            Self {
                timestamp: None,
                frequency: 0,
                start: 0,
            }
        }

        fn now(&self) -> Option<u64> {
            self.timestamp.as_ref().map(|ts| ts.get_timestamp())
        }

        fn elapsed_ms_since(&self, start: u64) -> Option<u64> {
            let now = self.now()?;
            let ticks = now.wrapping_sub(start);
            Some(ticks.saturating_mul(1000) / self.frequency)
        }

        fn total_ms(&self) -> Option<u64> {
            self.elapsed_ms_since(self.start)
        }
    }

    fn start_message() {
        match runtime::get_time() {
            Ok(time) => println!(
                "InitOS EFI starting {:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:09}",
                time.year(),
                time.month(),
                time.day(),
                time.hour(),
                time.minute(),
                time.second(),
                time.nanosecond()
            ),
            Err(_) => println!("InitOS EFI starting"),
        }
    }

    fn format_ms(value: Option<u64>) -> String {
        match value {
            Some(ms) => format!("{}ms", ms),
            None => "n/a".to_string(),
        }
    }

    fn load_file_to_memory(path: &str) -> uefi::Result<Vec<u8>> {
        let mut path_buf = [0u16; 128];
        let path_cstr = uefi::CStr16::from_str_with_buf(path, &mut path_buf)
            .map_err(|_| Status::INVALID_PARAMETER)?;

        let image_handle = boot::image_handle();
        let loaded_image = boot::open_protocol_exclusive::<LoadedImage>(image_handle)?;
        let dev_handle = loaded_image.device().expect("No device handle");

        let mut fs = boot::open_protocol_exclusive::<SimpleFileSystem>(dev_handle)?;
        let mut root = fs.open_volume()?;

        let handle = root.open(path_cstr, FileMode::Read, FileAttribute::empty())?;
        let mut file = match handle.into_type()? {
            uefi::proto::media::file::FileType::Regular(f) => f,
            _ => return Err(Status::NOT_FOUND.into()),
        };

        let mut info_buf = [0u8; 512];
        let info = file
            .get_info::<FileInfo>(&mut info_buf)
            .map_err(|e| e.status())?;
        let size = info.file_size() as usize;

        let mut data = Vec::with_capacity(size);
        unsafe { data.set_len(size) };
        file.read(&mut data).map_err(|e| e.status())?;

        Ok(data)
    }

    fn load_kernel_to_address(path: &str) -> uefi::Result<(usize, usize)> {
        let mut path_buf = [0u16; 128];
        let path_cstr = uefi::CStr16::from_str_with_buf(path, &mut path_buf)
            .map_err(|_| Status::INVALID_PARAMETER)?;

        let image_handle = boot::image_handle();
        let loaded_image = boot::open_protocol_exclusive::<LoadedImage>(image_handle)?;
        let dev_handle = loaded_image.device().expect("No device handle");

        let mut fs = boot::open_protocol_exclusive::<SimpleFileSystem>(dev_handle)?;
        let mut root = fs.open_volume()?;

        let handle = root.open(path_cstr, FileMode::Read, FileAttribute::empty())?;
        let mut file = match handle.into_type()? {
            uefi::proto::media::file::FileType::Regular(f) => f,
            _ => return Err(Status::NOT_FOUND.into()),
        };

        let mut info_buf = [0u8; 512];
        let info = file
            .get_info::<FileInfo>(&mut info_buf)
            .map_err(|e| e.status())?;
        let size = info.file_size() as usize;

        let pages_needed = (size + 4095) / 4096;
        let addr = boot::allocate_pages(
            AllocateType::MaxAddress(0x40000000),
            MemoryType::LOADER_DATA,
            pages_needed,
        )?;

        let dest = unsafe { core::slice::from_raw_parts_mut(addr.as_ptr(), size) };
        file.read(dest).map_err(|e| e.status())?;

        Ok((addr.as_ptr() as usize, size))
    }

    fn read_u32_le(data: &[u8], offset: usize) -> Option<u32> {
        if offset + 4 > data.len() {
            return None;
        }
        Some(u32::from_le_bytes([
            data[offset],
            data[offset + 1],
            data[offset + 2],
            data[offset + 3],
        ]))
    }

    fn pe_size_of_image(data: &[u8]) -> Option<usize> {
        if data.len() < 0x40 || data.get(0..2) != Some(b"MZ") {
            return None;
        }

        let pe_offset = read_u32_le(data, 0x3c)? as usize;
        if pe_offset + 0x5c > data.len() || data.get(pe_offset..pe_offset + 4) != Some(b"PE\0\0") {
            return None;
        }

        Some(read_u32_le(data, pe_offset + 0x50)? as usize)
    }

    fn load_pe_kernel_to_address(path: &str) -> uefi::Result<(usize, usize, usize)> {
        let data = load_file_to_memory(path)?;
        let file_size = data.len();
        let image_size = pe_size_of_image(&data).unwrap_or(file_size).max(file_size);
        let pages_needed = (image_size + 4095) / 4096;

        let addr = boot::allocate_pages(
            AllocateType::MaxAddress(0x40000000),
            MemoryType::LOADER_DATA,
            pages_needed,
        )?;

        unsafe {
            let dest = core::slice::from_raw_parts_mut(addr.as_ptr(), pages_needed * 4096);
            core::ptr::write_bytes(dest.as_mut_ptr(), 0, dest.len());
            core::ptr::copy_nonoverlapping(data.as_ptr(), dest.as_mut_ptr(), file_size);
        }

        Ok((addr.as_ptr() as usize, file_size, image_size))
    }

    fn linux_exec(
        cmdline: &str,
        kernel_addr: usize,
        initrd_addr: usize,
        initrd_size: usize,
        timer: &EfiTimer,
        bzimage_load_ms: Option<u64>,
        initrd_load_ms: Option<u64>,
    ) -> ! {
        let image_setup = kernel_addr as *const SetupHeader;

        let sig = unsafe { core::ptr::read_unaligned(addr_of!((*image_setup).signature)) };
        let hdr = unsafe { core::ptr::read_unaligned(addr_of!((*image_setup).header)) };

        if sig != 0xAA55 || hdr != SETUP_MAGIC {
            fail_and_reboot(&format!(
                "Kernel handover failed: invalid setup signature=0x{:x}, header=0x{:x}",
                sig, hdr
            ));
        }

        let version = unsafe { core::ptr::read_unaligned(addr_of!((*image_setup).version)) };
        let relocatable =
            unsafe { core::ptr::read_unaligned(addr_of!((*image_setup).relocatable_kernel)) };
        let xloadflags = unsafe { core::ptr::read_unaligned(addr_of!((*image_setup).xloadflags)) };

        if xloadflags & 0x08 == 0 {
            fail_and_reboot(&format!(
                "Kernel handover failed: xloadflags=0x{:x} does not report 64-bit EFI handover support",
                xloadflags
            ));
        }

        if version < 0x20b || relocatable == 0 {
            fail_and_reboot(&format!(
                "Kernel handover failed: unsupported version=0x{:x}, relocatable={}",
                version, relocatable
            ));
        }

        let pages_needed = 4;
        let boot_setup_addr = match boot::allocate_pages(
            AllocateType::MaxAddress(0x40000000),
            MemoryType::LOADER_DATA,
            pages_needed,
        ) {
            Ok(addr) => addr,
            Err(e) => {
                fail_and_reboot(&format!(
                    "Kernel handover failed: boot setup allocation failed: {:?}",
                    e.status()
                ));
            }
        };

        let boot_setup_ptr = boot_setup_addr.as_ptr() as *mut SetupHeader;

        unsafe {
            core::ptr::write_bytes(boot_setup_ptr as *mut u8, 0, pages_needed * 4096);
            let setup = &mut *boot_setup_ptr;

            let setup_secs = core::ptr::read_unaligned(addr_of!((*image_setup).setup_secs));
            let ramdisk_max = core::ptr::read_unaligned(addr_of!((*image_setup).ramdisk_max));
            let handover_offset =
                core::ptr::read_unaligned(addr_of!((*image_setup).handover_offset));
            let code32_start = kernel_addr + (setup_secs as usize + 1) * 512;
            let handover_addr = code32_start + 512 + handover_offset as usize;

            setup.loader_id = 0x21;
            setup.ramdisk_max = ramdisk_max;

            let cmdline_len = cmdline.len();
            let cmdline_pool = match boot::allocate_pool(MemoryType::LOADER_DATA, cmdline_len + 1) {
                Ok(pool) => pool,
                Err(e) => {
                    fail_and_reboot(&format!(
                        "Kernel handover failed: cmdline allocation failed: {:?}",
                        e.status()
                    ));
                }
            };
            core::ptr::copy_nonoverlapping(cmdline.as_ptr(), cmdline_pool.as_ptr(), cmdline_len);
            *cmdline_pool.as_ptr().add(cmdline_len) = 0;
            setup.cmd_line_ptr = cmdline_pool.as_ptr() as u32;

            if initrd_size > 0 {
                setup.ramdisk_start = initrd_addr as u32;
                setup.ramdisk_len = initrd_size as u32;
            }

            println!(
                "Starting Linux total={} bzImage_load={} initrd_load={}",
                format_ms(timer.total_ms()),
                format_ms(bzimage_load_ms),
                format_ms(initrd_load_ms)
            );
            linux_efi_handover(boot::image_handle(), handover_addr, boot_setup_ptr);
        }
    }

    const EFI_CERT_X509_GUID: uefi::Guid = uefi::guid!("a5c059a1-94e4-4aa7-87b5-ab155c2bf072");

    fn verify_data_signature(
        data: &[u8],
        db_data: &[u8],
        sig_path_template: &str,
        label: &str,
    ) -> Result<(), String> {
        let mut offset = 0;
        let mut cert_count = 0usize;
        let mut sig_file_count = 0usize;
        let mut mismatch_count = 0usize;
        let mut unsupported_count = 0usize;
        let mut last_key_id = String::new();
        let mut last_sig_path = String::new();

        let rsa_oid = x509_cert::der::oid::ObjectIdentifier::new_unwrap("1.2.840.113549.1.1.1");

        while offset + 28 <= db_data.len() {
            let sig_type = uefi::Guid::from_bytes(db_data[offset..offset + 16].try_into().unwrap());
            let list_size =
                u32::from_le_bytes(db_data[offset + 16..offset + 20].try_into().unwrap()) as usize;
            let header_size =
                u32::from_le_bytes(db_data[offset + 20..offset + 24].try_into().unwrap()) as usize;
            let sig_size =
                u32::from_le_bytes(db_data[offset + 24..offset + 28].try_into().unwrap()) as usize;

            if list_size == 0 {
                break;
            }
            if offset + list_size > db_data.len() {
                return Err(format!(
                    "malformed db: signature list at offset {} extends past db size {}",
                    offset,
                    db_data.len()
                ));
            }

            if sig_type != EFI_CERT_X509_GUID {
                offset += list_size;
                continue;
            }

            let sigs_start = offset + 28 + header_size;
            let sigs_end = offset + list_size;
            if sig_size < 16 || sigs_start > sigs_end {
                return Err(format!(
                    "malformed db: invalid X.509 list at offset {} header_size={} sig_size={}",
                    offset, header_size, sig_size
                ));
            }

            let cert_data_size = sig_size - 16;

            let mut sig_offset = sigs_start;
            while sig_offset + sig_size <= sigs_end {
                let der_bytes = &db_data[sig_offset + 16..sig_offset + 16 + cert_data_size];
                if let Ok(cert) = x509_cert::Certificate::from_der(der_bytes) {
                    cert_count += 1;
                    let tbs = &cert.tbs_certificate;

                    use x509_cert::der::Encode;
                    let spki_der_bytes = tbs.subject_public_key_info.to_der().unwrap_or_default();
                    let pub_key_bytes = tbs
                        .subject_public_key_info
                        .subject_public_key
                        .as_bytes()
                        .unwrap_or(&[]);

                    let mut hasher = Sha256::new();
                    hasher.update(&spki_der_bytes);
                    let digest = hasher.finalize();

                    let mut key_id = String::new();
                    for b in &digest[..8] {
                        let _ = write!(&mut key_id, "{:02x}", b);
                    }

                    let sig_path = sig_path_template.replace("{}", &key_id);
                    last_key_id = key_id;
                    last_sig_path = sig_path;

                    if let Ok(sig_data) = load_file_to_memory(&last_sig_path) {
                        sig_file_count += 1;

                        let algo_oid = tbs.subject_public_key_info.algorithm.oid;
                        let mut data_hasher = Sha256::new();
                        data_hasher.update(data);
                        let data_digest = data_hasher.finalize();

                        if algo_oid == rsa_oid {
                            if let Ok(rsa_pub) = RsaPublicKey::from_pkcs1_der(pub_key_bytes) {
                                if rsa_pub
                                    .verify(Pkcs1v15Sign::new::<Sha256>(), &data_digest, &sig_data)
                                    .is_ok()
                                {
                                    return Ok(());
                                } else {
                                    mismatch_count += 1;
                                }
                            } else {
                                unsupported_count += 1;
                            }
                        } else {
                            unsupported_count += 1;
                        }
                    }
                }
                sig_offset += sig_size;
            }
            offset += list_size;
        }

        if cert_count == 0 {
            Err("no X.509 certificates found in db".to_string())
        } else if sig_file_count == 0 {
            Err(format!(
                "no {} signature file matched any db cert; checked {} cert(s); last expected path={} KEY_ID={}",
                label, cert_count, last_sig_path, last_key_id
            ))
        } else if mismatch_count > 0 {
            Err(format!(
                "{} RSA signature mismatch; checked {} signature file(s); last path={} KEY_ID={}",
                label, sig_file_count, last_sig_path, last_key_id
            ))
        } else {
            Err(format!(
                "unsupported {} signing key or signature format; checked {} signature file(s), unsupported {}",
                label, sig_file_count, unsupported_count
            ))
        }
    }

    #[entry]
    fn main() -> Status {
        uefi::helpers::init().unwrap();
        let timer = EfiTimer::new();
        start_message();

        // 1. Read config file
        let config_data = match load_file_to_memory("\\EFI\\BOOT\\config") {
            Ok(data) => data,
            Err(e) => {
                println!("Failed to read config file: {:?}", e);
                fail_and_reboot("Config load failed");
            }
        };

        let config_str = String::from_utf8_lossy(&config_data);
        let cmdline = config_str.lines().next().unwrap_or("").trim().to_string();

        // 2. Check Secure Boot status
        let mut sb_name_buf = [0u16; 16];
        let sb_name = uefi::CStr16::from_str_with_buf("SecureBoot", &mut sb_name_buf).unwrap();
        let mut sb_buf = [0u8; 1];
        let secure_boot = match uefi::runtime::get_variable(
            sb_name,
            &VariableVendor::GLOBAL_VARIABLE,
            &mut sb_buf,
        ) {
            Ok((data, _)) => data.get(0).copied().unwrap_or(0) == 1,
            Err(_) => false,
        };

        // 3. Read db (Signature Database) to get certs for config/initrd verification.
        // When Secure Boot is enabled, a missing/unreadable/empty db is a hard
        // failure: we refuse to boot an unsigned kernel/initrd rather than
        // silently skipping verification.
        let mut db_buf = [0u8; 4096];
        let db_slice: &[u8] = if secure_boot {
            let mut db_name_buf = [0u16; 16];
            let db_name = uefi::CStr16::from_str_with_buf("db", &mut db_name_buf).unwrap();

            // db uses the Image Security Database GUID, not the global GUID
            let db_vendor = VariableVendor(uefi::guid!("d719b2cb-3d3a-4596-a3bc-dad00e67656f"));
            match uefi::runtime::get_variable(db_name, &db_vendor, &mut db_buf) {
                Ok((data, _)) if !data.is_empty() => data,
                Ok(_) => {
                    fail_and_reboot(
                        "db variable is empty; refusing to boot without a usable signature database",
                    );
                }
                Err(e) => {
                    println!(
                        "Failed to read db variable: {:?}; refusing to boot without a usable signature database",
                        e
                    );
                    fail_and_reboot("db variable read failed");
                }
            }
        } else {
            &[]
        };
        let db_sha = if secure_boot {
            sha256_hex(db_slice)
        } else {
            String::new()
        };

        // 4. Verify config signature using db certs
        if secure_boot {
            if let Err(detail) =
                verify_data_signature(&config_data, db_slice, "\\EFI\\BOOT\\{}.sig", "config")
            {
                fail_signature("config", &db_sha, detail);
            }
        }

        // 5. Load kernel
        let bzimage_load_start = timer.now();
        let (kernel_addr, kernel_size, _kernel_image_size) =
            match load_pe_kernel_to_address("\\EFI\\BOOT\\BZIMAGE") {
                Ok(res) => res,
                Err(e) => {
                    println!("Failed to load kernel: {:?}", e);
                    fail_and_reboot("Kernel load failed");
                }
            };
        let bzimage_load_ms = bzimage_load_start.and_then(|start| timer.elapsed_ms_since(start));

        // Verify kernel signature if secure boot is enabled
        if secure_boot {
            let kernel_data =
                unsafe { core::slice::from_raw_parts(kernel_addr as *const u8, kernel_size) };
            if let Err(detail) = verify_data_signature(
                kernel_data,
                db_slice,
                "\\EFI\\BOOT\\{}.kernel.sig",
                "kernel",
            ) {
                fail_signature("kernel", &db_sha, detail);
            }
        }

        // 6. Load initrd (optional)
        let initrd_load_start = timer.now();
        let mut initrd_load_ms = None;
        let (initrd_addr, initrd_size) = match load_kernel_to_address("\\EFI\\BOOT\\INITRD.IMG") {
            Ok((addr, size)) => {
                initrd_load_ms = initrd_load_start.and_then(|start| timer.elapsed_ms_since(start));
                // Verify initrd signature if secure boot is enabled
                if secure_boot && !db_slice.is_empty() {
                    let initrd_data =
                        unsafe { core::slice::from_raw_parts(addr as *const u8, size) };
                    if let Err(detail) = verify_data_signature(
                        initrd_data,
                        db_slice,
                        "\\EFI\\BOOT\\{}.initrd.sig",
                        "initrd",
                    ) {
                        fail_signature("initrd", &db_sha, detail);
                    }
                }
                (addr, size)
            }
            Err(_) => (0, 0),
        };

        linux_exec(
            &cmdline,
            kernel_addr,
            initrd_addr,
            initrd_size,
            &timer,
            bzimage_load_ms,
            initrd_load_ms,
        )
    }
}

#[cfg(target_os = "uefi")]
pub use uefi_bin::*;

#[cfg(not(target_os = "uefi"))]
fn main() {
    println!("The 'efi' binary is only for target x86_64-unknown-uefi");
}
