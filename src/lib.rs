#![cfg_attr(target_os = "uefi", no_std)]

#[cfg(not(target_os = "uefi"))]
pub mod efi;
#[cfg(not(target_os = "uefi"))]
pub mod fscrypt;
#[cfg(not(target_os = "uefi"))]
pub mod mount;
#[cfg(not(target_os = "uefi"))]
pub mod tpm2;
#[cfg(not(target_os = "uefi"))]
pub mod verify;
#[cfg(not(target_os = "uefi"))]
pub mod verity;
