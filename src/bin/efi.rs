#![cfg_attr(target_os = "uefi", no_std)]
#![cfg_attr(target_os = "uefi", no_main)]

#[cfg(target_os = "uefi")]
extern crate alloc;

#[cfg(target_os = "uefi")]
mod uefi_bin {
    extern crate alloc;

use alloc::string::{String, ToString};
use alloc::vec::Vec;
use alloc::format;
use core::arch::asm;
use core::ptr::addr_of;
use uefi::prelude::*;
use uefi::proto::loaded_image::LoadedImage;
use uefi::proto::media::file::{File, FileAttribute, FileInfo, FileMode};
use uefi::proto::media::fs::SimpleFileSystem;
use uefi::boot::{self, AllocateType, MemoryType};
use uefi::runtime::VariableVendor;
use uefi::println;
use x509_cert::der::Decode;
use rsa::{RsaPublicKey, Pkcs1v15Sign, pkcs1::DecodeRsaPublicKey};
use sha2::{Sha256, Digest};

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

type HandoverFn = unsafe extern "sysv64" fn(
    image: *mut core::ffi::c_void,
    system_table: *mut core::ffi::c_void,
    setup: *mut SetupHeader,
) -> !;

unsafe fn linux_efi_handover(
    image: Handle,
    setup: *mut SetupHeader,
) -> ! {
    let code32_start = core::ptr::read_unaligned(addr_of!((*setup).code32_start));
    let handover_offset = core::ptr::read_unaligned(addr_of!((*setup).handover_offset));
    let handover_addr = (code32_start as usize) + 512 + (handover_offset as usize);
    
    println!("Handover info: code32_start=0x{:x}, offset=0x{:x}, addr=0x{:x}", 
             code32_start, handover_offset, handover_addr);
    
    let st = uefi::table::system_table_raw().expect("No system table").as_ptr();
    println!("Args: image={:p}, st={:p}, setup={:p}", 
             image.as_ptr(), st, setup);

    #[cfg(target_arch = "x86_64")]
    asm!("cli", options(nomem, nostack));

    let handover: HandoverFn = core::mem::transmute(handover_addr);
    
    println!("Jumping to handover...");
    handover(image.as_ptr(), st as *mut _, setup);
}

fn load_file_to_memory(
    path: &str,
) -> uefi::Result<Vec<u8>> {
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
    let info = file.get_info::<FileInfo>(&mut info_buf).map_err(|e| e.status())?;
    let size = info.file_size() as usize;

    let mut data = Vec::with_capacity(size);
    unsafe { data.set_len(size) };
    file.read(&mut data).map_err(|e| e.status())?;

    Ok(data)
}

fn load_kernel_to_address(
    path: &str,
) -> uefi::Result<(usize, usize)> {
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
    let info = file.get_info::<FileInfo>(&mut info_buf).map_err(|e| e.status())?;
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

fn linux_exec(
    cmdline: &str,
    kernel_addr: usize,
    initrd_addr: usize,
    initrd_size: usize,
) -> Status {
    let image_setup = kernel_addr as *const SetupHeader;

    let sig = unsafe { core::ptr::read_unaligned(addr_of!((*image_setup).signature)) };
    let hdr = unsafe { core::ptr::read_unaligned(addr_of!((*image_setup).header)) };

    if sig != 0xAA55 || hdr != SETUP_MAGIC {
        println!("Invalid kernel signature: 0x{:x}, header: 0x{:x}", sig, hdr);
        return Status::LOAD_ERROR;
    }

    let version = unsafe { core::ptr::read_unaligned(addr_of!((*image_setup).version)) };
    let relocatable = unsafe { core::ptr::read_unaligned(addr_of!((*image_setup).relocatable_kernel)) };

    if version < 0x20b || relocatable == 0 {
        println!("Unsupported kernel version: 0x{:x}, relocatable: {}", version, relocatable);
        return Status::LOAD_ERROR;
    }

    let pages_needed = 4;
    let boot_setup_addr = match boot::allocate_pages(
        AllocateType::MaxAddress(0x40000000),
        MemoryType::LOADER_DATA,
        pages_needed,
    ) {
        Ok(addr) => addr,
        Err(e) => return e.status(),
    };

    let boot_setup_ptr = boot_setup_addr.as_ptr() as *mut SetupHeader;

    unsafe {
        core::ptr::write_bytes(boot_setup_ptr as *mut u8, 0, 4096);
        core::ptr::copy_nonoverlapping(
            kernel_addr as *const u8,
            boot_setup_ptr as *mut u8,
            1024, // Copy first 1024 bytes which includes the whole SetupHeader and more
        );
        
        let setup = &mut *boot_setup_ptr;
        setup.loader_id = 0xff;
        
        let setup_secs = core::ptr::read_unaligned(addr_of!((*image_setup).setup_secs));
        let ramdisk_max = core::ptr::read_unaligned(addr_of!((*image_setup).ramdisk_max));
        println!("Kernel setup_secs: {}, ramdisk_max: 0x{:x}", setup_secs, ramdisk_max);
        setup.code32_start = (kernel_addr + (setup_secs as usize + 1) * 512) as u32;

        let cmdline_len = cmdline.len();
        let cmdline_pool = boot::allocate_pool(MemoryType::LOADER_DATA, cmdline_len + 1).unwrap();
        core::ptr::copy_nonoverlapping(cmdline.as_ptr(), cmdline_pool.as_ptr(), cmdline_len);
        *cmdline_pool.as_ptr().add(cmdline_len) = 0;
        setup.cmd_line_ptr = cmdline_pool.as_ptr() as u32;

        if initrd_size > 0 {
            setup.ramdisk_start = initrd_addr as u32;
            setup.ramdisk_len = initrd_size as u32;
        }

        linux_efi_handover(boot::image_handle(), boot_setup_ptr);
    }
}

const EFI_CERT_X509_GUID: uefi::Guid = uefi::guid!("a5c059a1-94e4-4aa7-87b5-ab155c2bf072");

fn extract_cn(name: &x509_cert::name::Name) -> String {
    use x509_cert::der::asn1::{PrintableStringRef, Utf8StringRef};
    use x509_cert::der::oid::db::rfc4519::CN;
    for rdn in name.0.iter() {
        for atv in rdn.0.iter() {
            if atv.oid == CN {
                if let Ok(s) = Utf8StringRef::try_from(&atv.value) {
                    return s.as_str().to_string();
                }
                if let Ok(s) = PrintableStringRef::try_from(&atv.value) {
                    return s.as_str().to_string();
                }
                return String::from_utf8_lossy(atv.value.value()).to_string();
            }
        }
    }
    String::new()
}

fn extract_sans(tbs: &x509_cert::TbsCertificate) -> Vec<String> {
    use x509_cert::ext::pkix::name::GeneralName;
    use x509_cert::ext::pkix::SubjectAltName;

    let extensions = match &tbs.extensions {
        Some(exts) => exts,
        None => return Vec::new(),
    };

    let san_oid = x509_cert::der::oid::db::rfc5280::ID_CE_SUBJECT_ALT_NAME;

    for ext in extensions.iter() {
        if ext.extn_id == san_oid {
            if let Ok(san) = SubjectAltName::from_der(ext.extn_value.as_bytes()) {
                return san.0.iter().map(|gn| match gn {
                    GeneralName::DnsName(dns) => dns.as_str().to_string(),
                    GeneralName::Rfc822Name(email) => email.as_str().to_string(),
                    GeneralName::UniformResourceIdentifier(uri) => uri.as_str().to_string(),
                    _ => format!("{:?}", gn),
                }).collect();
            }
        }
    }
    Vec::new()
}

fn verify_data_signature(data: &[u8], pk_data: &[u8], sig_path_template: &str, label: &str) -> bool {
    let mut offset = 0;
    let mut verified = false;

    let rsa_oid = x509_cert::der::oid::ObjectIdentifier::new_unwrap("1.2.840.113549.1.1.1");

    while offset + 28 <= pk_data.len() {
        let sig_type = uefi::Guid::from_bytes(pk_data[offset..offset+16].try_into().unwrap());
        let list_size = u32::from_le_bytes(pk_data[offset+16..offset+20].try_into().unwrap()) as usize;
        let header_size = u32::from_le_bytes(pk_data[offset+20..offset+24].try_into().unwrap()) as usize;
        let sig_size = u32::from_le_bytes(pk_data[offset+24..offset+28].try_into().unwrap()) as usize;

        if sig_type != EFI_CERT_X509_GUID {
            if list_size == 0 { break; }
            offset += list_size;
            continue;
        }

        let sigs_start = offset + 28 + header_size;
        let sigs_end = offset + list_size;
        let cert_data_size = sig_size - 16; 

        let mut sig_offset = sigs_start;
        while sig_offset + sig_size <= sigs_end {
            let der_bytes = &pk_data[sig_offset+16..sig_offset+16+cert_data_size];
            if let Ok(cert) = x509_cert::Certificate::from_der(der_bytes) {
                let tbs = &cert.tbs_certificate;
                let cn = extract_cn(&tbs.subject);
                let mut sans = extract_sans(tbs);
                
                if sans.is_empty() && !cn.is_empty() {
                    sans.push(cn.clone());
                }

                for san in &sans {
                    let sig_path = sig_path_template.replace("{}", san);
                    if let Ok(sig_data) = load_file_to_memory(&sig_path) {
                        println!("  Checking {} signature: {}", label, sig_path);
                        
                        let algo_oid = tbs.subject_public_key_info.algorithm.oid;
                        let mut hasher = Sha256::new();
                        hasher.update(data);
                        let digest = hasher.finalize();

                        if algo_oid == rsa_oid {
                            let pub_key_bytes = tbs.subject_public_key_info.subject_public_key.as_bytes().unwrap();
                            if let Ok(rsa_pub) = RsaPublicKey::from_pkcs1_der(pub_key_bytes) {
                                if rsa_pub.verify(Pkcs1v15Sign::new::<Sha256>(), &digest, &sig_data).is_ok() {
                                    println!("  ✅ RSA Signature VERIFIED for {} SAN: {}", label, san);
                                    verified = true;
                                } else {
                                    println!("  ❌ RSA Signature mismatch for {} SAN: {}", label, san);
                                }
                            }
                        }
                    }
                }
            }
            sig_offset += sig_size;
        }
        offset += list_size;
    }
    verified
}

#[entry]
fn main() -> Status {
    uefi::helpers::init().unwrap();
    println!("InitOS EFI Loader starting...");

    // 1. Read config file
    println!("Reading config file...");
    let config_data = match load_file_to_memory("\\EFI\\BOOT\\config") {
        Ok(data) => data,
        Err(e) => {
            println!("Failed to read config file: {:?}", e);
            loop {}
        }
    };
    
    let config_str = String::from_utf8_lossy(&config_data);
    let cmdline = config_str.lines().next().unwrap_or("").trim().to_string();
    println!("Command line: {}", cmdline);

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

    let mut pk_buf = [0u8; 4096];
    let pk_slice: &[u8] = if secure_boot {
        println!("Secure Boot is ENABLED. Reading PK variable...");
        let mut pk_name_buf = [0u16; 16];
        let pk_name = uefi::CStr16::from_str_with_buf("PK", &mut pk_name_buf).unwrap();
        
        match uefi::runtime::get_variable(
            pk_name,
            &VariableVendor::GLOBAL_VARIABLE,
            &mut pk_buf,
        ) {
            Ok((data, _)) => data,
            Err(e) => {
                println!("Failed to read PK variable: {:?}", e);
                &[]
            }
        }
    } else {
        println!("Secure Boot is DISABLED. Skipping verification.");
        &[]
    };

    // 3. Verify config signature
    if secure_boot && !pk_slice.is_empty() {
        println!("Verifying config signature...");
        if verify_data_signature(&config_data, pk_slice, "\\EFI\\BOOT\\{}.sig", "config") {
            println!("✅ CONFIG VERIFIED OK");
        } else {
            println!("❌ CONFIG VERIFICATION FAILED!");
            loop {}
        }
    }

    // 4. Load kernel
    println!("Loading kernel...");
    let (kernel_addr, kernel_size) = match load_kernel_to_address("\\EFI\\BOOT\\BZIMAGE") {
        Ok(res) => res,
        Err(e) => {
            println!("Failed to load kernel: {:?}", e);
            loop {}
        }
    };
    println!("Kernel loaded at 0x{:x} ({} bytes)", kernel_addr, kernel_size);

    // 5. Load initrd (optional)
    let (initrd_addr, initrd_size) = match load_kernel_to_address("\\EFI\\BOOT\\INITRD.IMG") {
        Ok((addr, size)) => {
            println!("Initrd loaded at 0x{:x} ({} bytes)", addr, size);
            
            // Verify initrd signature if secure boot is enabled
            if secure_boot && !pk_slice.is_empty() {
                println!("Verifying initrd signature...");
                let initrd_data = unsafe { core::slice::from_raw_parts(addr as *const u8, size) };
                if verify_data_signature(initrd_data, pk_slice, "\\EFI\\BOOT\\{}.initrd.sig", "initrd") {
                    println!("✅ INITRD VERIFIED OK");
                } else {
                    println!("❌ INITRD VERIFICATION FAILED!");
                    loop {}
                }
            }
            (addr, size)
        }
        Err(_) => {
            println!("No initrd found, continuing...");
            (0, 0)
        }
    };

    println!("Booting Linux...");
    linux_exec(&cmdline, kernel_addr, initrd_addr, initrd_size)
}
}

#[cfg(target_os = "uefi")]
pub use uefi_bin::*;

#[cfg(not(target_os = "uefi"))]
fn main() {
    println!("The 'efi' binary is only for target x86_64-unknown-uefi");
}
