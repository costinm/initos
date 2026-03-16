#!/usr/bin/env bash
#
# test_qemu_efi.sh — Boot the initos test image set with QEMU
# using EFI and TPM2 emulation.
#
# Boot flow:
#   kernel → initrd(initos) → finds STATE partition → verifies initos.erofs → switch_root
#
# Usage: ./tests/test_qemu_efi.sh [test_dir]
#
#
# Expects test_dir (default: target/test) to contain:
#   state.ext4   - STATE partition (ext4) with initos.erofs + sig
#   initrd.img   - initrd with initos binary
#   image_key.pub.b64  - ed25519 public key (base64)
#
# Kernel: prebuilt/boot/EFI/BOOT/bzImage
#
# Requires: qemu-system-x86_64

set -euo pipefail

# test_qemu_efi.sh - Test the EFI loader with config file and signature verification

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

src=${PROJECT_ROOT}
out=${src}/target

TEST_DIR="target/test_efi"

build() {
    echo "=== Building ==="
    ${src}/scripts/build.sh 
    # Create the test ext4 disk
    ${src}/scripts/build.sh build_state 

    # 2. Prepare test dir
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR/EFI/BOOT"

    echo "=== Preparing Boot Files and Signing ==="
    # Create config file
    if [ -n "${INITOS_DEBUG:-}" ]; then
        echo "console=ttyS0 loglevel=6 panic=3 init=/bin/sh initos_dbg=1" > "$TEST_DIR/EFI/BOOT/config"
    else
        echo "console=ttyS0 loglevel=3 panic=3 init=/bin/sh" > "$TEST_DIR/EFI/BOOT/config"
    fi

    # Sign the loader (using db keys for Secure Boot)
    cp target/x86_64-unknown-uefi/release/efi.efi \
        ${TEST_DIR}/EFI/BOOT/BOOTX64.EFI
    
    cp prebuilt/boot/EFI/BOOT/bzImage ${TEST_DIR}/EFI/BOOT/BZIMAGE
    cp prebuilt/boot/EFI/BOOT/initrd.img "$TEST_DIR/EFI/BOOT/INITRD.IMG"
}

sign() {
    ${src}/scripts/sign.sh efi prebuilt/testdata/uefi-keys "$TEST_DIR"
    
    SIG_FILE="$TEST_DIR/EFI/BOOT/mesh.internal (PK).sig"
    echo "Signing config with PK.key..."
    openssl dgst -sha256 -sign prebuilt/testdata/uefi-keys/PK.key -out "$SIG_FILE" "$TEST_DIR/EFI/BOOT/config"

    # Create a signature for the initrd file using PK.key (RSA)
    INITRD_SIG_FILE="$TEST_DIR/EFI/BOOT/mesh.internal (PK).initrd.sig"
    echo "Signing initrd with PK.key..."
    openssl dgst -sha256 -sign prebuilt/testdata/uefi-keys/PK.key -out "$INITRD_SIG_FILE" "$TEST_DIR/EFI/BOOT/INITRD.IMG"
}

run() {
    # 4. Run QEMU
    OVMF="prebuilt/OVMF.fd"
    LOG_FILE="target/qemu_efi.log"
    rm -f "$LOG_FILE"

    if [[ -n "${FULL_DISK:-}" ]]; then
        # Testing with a gpt image - we need to validate
        # PARTLABEL code and the root.
        QEMU_ARGS=(
            -drive "file=${FULL_DISK},format=raw,if=virtio"
        )
       # TODO: also test without initrd, using dmverity root
       #            -drive "file=${INITOS_IMG},format=raw,if=virtio"
    else
        QEMU_ARGS=(
            -drive "file=fat:rw:${TEST_DIR},media=disk"
            -drive "file=${out}/test/state.ext4,format=raw,if=virtio"
        )

    fi

    # Same as: -bios $OVMF
    QEMU_ARGS+=(-drive "if=pflash,readonly=on,format=raw,file=${OVMF}")
    OVMF_VARS="$(dirname "${OVMF}")/OVMF_VARS.fd"
    if [[ -f "${OVMF_VARS}" ]]; then
        QEMU_ARGS+=(-drive "if=pflash,format=raw,file=${OVMF_VARS}")
    fi

    mkdir -p /tmp/mytpm1
    swtpm socket --tpmstate dir=/tmp/mytpm1   --ctrl type=unixio,path=/tmp/mytpm1/swtpm-sock   --tpm2  &
    tpm="-chardev socket,id=chrtpm,path=/tmp/mytpm1/swtpm-sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0" 
    QEMU_ARGS+=(${tpm})

    if [ -f /z/img/deb-host.img ]; then
        QEMU_ARGS+=(-drive "file=/z/img/deb-host.img,format=raw,if=virtio")
        # CMDLINE="${CMDLINE} INITOS_DATA=/dev/vdb" 
        # Also better to use the small bb init as trampoline.
    fi

    QEMU_ARGS+=(
        -fsdev "local,security_model=mapped,id=fsdev0,path=${out}/test"
        -device "virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=src"
    )

	# -display none or -nographic ?
    QEMU_ARGS+=(
        -m 512M
        -smp 2
        -no-reboot
        -nographic
        -nodefaults
    )
    if [[ -w /dev/kvm ]]; then
        QEMU_ARGS+=(-enable-kvm -cpu host)
    else
        echo "WARNING: KVM not available, using emulation (slower)"
        QEMU_ARGS+=(-cpu qemu64)
    fi

    # Run qemu and capture output via direct serial file.
    if [ -n "${INITOS_DEBUG:-}" ]; then
        QEMU_ARGS+=(
        -chardev stdio,mux=on,id=char0
        -serial chardev:char0
        -monitor chardev:char0
        )
        qemu-system-x86_64 "${QEMU_ARGS[@]}" | tee "$LOG_FILE"
    else
        echo "=== Starting QEMU (timeout 30s) ==="
        timeout --foreground 30s qemu-system-x86_64 "${QEMU_ARGS[@]}" \
            -serial "file:$LOG_FILE" -no-reboot || true
   		rc=$?
		if [[ $rc -eq 124 ]]; then
			echo ""
			echo "=== QEMU timed out after ${TIMEOUT}s ==="
			exit 1
		fi

    fi
}

test() {
    build
    sign
    run

    echo ""
    echo "=== Analyzing Results ==="
    cat "$LOG_FILE"

    if grep -q "Command line:.*console=ttyS0.*" "$LOG_FILE"; then
        echo "✅ SUCCESS: Config file read correctly!"
    else
        echo "❌ FAILURE: Config file was not read correctly or command line mismatch."
        exit 1
    fi

    if grep -q "✅ RSA Signature VERIFIED for config" "$LOG_FILE"; then
        echo "✅ SUCCESS: Config RSA Signature verified!"
    else
        echo "❌ FAILURE: Config RSA Signature verification failed or did not run."
        exit 1
    fi

    if grep -q "✅ RSA Signature VERIFIED for initrd" "$LOG_FILE"; then
        echo "✅ SUCCESS: Initrd RSA Signature verified!"
    else
        echo "❌ FAILURE: Initrd RSA Signature verification failed or did not run."
        exit 1
    fi

    if grep -q "✅ CONFIG VERIFIED OK" "$LOG_FILE" && grep -q "✅ INITRD VERIFIED OK" "$LOG_FILE"; then
        echo "✅ SUCCESS: Full verification passed!"
    else
        echo "❌ FAILURE: Full verification failed."
        exit 1
    fi

    echo "=== Checking Kernel Activity ==="
    if grep -i -q "Linux version" "$LOG_FILE"; then
        echo "✅ SUCCESS: Kernel started!"
    elif grep -q "Jumping to handover" "$LOG_FILE"; then
        echo "⚠️  Handover executed but no kernel output. (Check serial console settings)"
    else
        echo "❌ FAILURE: Kernel did not start or no output captured."
    fi

    if grep -q "INITOS:" "$LOG_FILE"; then
        echo "✅ SUCCESS: initos-initrd script is running!"
    elif grep -i -q "Unable to mount root fs" "$LOG_FILE"; then
        echo "⚠️  Kernel started but panicked due to missing initrd/init. (Progress!)"
    else
        # In case of panic, it might not reach here, but let's check for "initrd" presence in kernel log
        if grep -i -q "Unpacking initramfs" "$LOG_FILE" || grep -i -q "Freeing initrd memory" "$LOG_FILE"; then
            echo "⚠️  Kernel found initrd, but script didn't run (likely panic)."
        else
            echo "❌ FAILURE: initrd not found or script didn't run."
        fi
    fi
}

if [[ $# -gt 0 ]]; then
    for cmd in "$@"; do
        $cmd
    done
    exit 0
fi

test    