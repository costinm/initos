{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  name = "initos-dev";

  buildInputs = with pkgs; [
    # Build tools
    cpio
    erofs-utils
    cryptsetup
    sbsigntool
    e2fsprogs
    gzip

    # Test tools
    age
    qemu
    swtpm
    genimage
    OVMF

    # General
    curl
    cacert
    openssl
    xz
  ];

  # Keep host Rust in PATH (not duplicated from nixpkgs)
  shellHook = ''
    # Prepend host cargo/rust to PATH
    export PATH="$HOME/.cargo/bin:$HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin:$PATH"

    echo "=== initos dev shell (nix) ==="
    echo "Rust: $(rustc --version)"
    echo "QEMU: $(qemu-system-x86_64 --version 2>/dev/null | head -1)"
    echo ""
    echo "Run:  bash scripts/build.sh"
    echo "      cargo test --target x86_64-unknown-linux-musl -- --include-ignored"
    echo "      bash tests/run_qemu.sh"
  '';
}
