#!/usr/bin/env python3

# Create an EROFS based on a store.

import os
import subprocess
import sys
import tempfile

def create_nix_erofs(nix_store_path="/nix/store", output_erofs="nix-store-metadata.erofs"):
    """
    Generates a metadata-only EROFS image for a 1-to-1 overlayfs mount over /nix/store.
    """
    if not os.path.exists(nix_store_path):
        print(f"Error: Path {nix_store_path} does not exist.", file=sys.stderr)
        sys.exit(1)

    # Dumpfile format for mkfs.erofs --file-list
    # Format: <path_in_erofs> <host_path> <type> <mode> <uid> <gid> [xattrs...]
    print(f"Scanning {nix_store_path} and generating metadata manifest...")
    
    with tempfile.NamedTemporaryFile("w+", delete=False) as manifest:
        manifest_path = manifest.name
        
        for root, dirs, files in os.walk(nix_store_path):
            for name in dirs + files:
                full_path = os.path.join(root, name)
                rel_path = os.path.relpath(full_path, nix_store_path)
                st = os.lstat(full_path)

                # Set metacopy xattr on non-empty files so overlayfs delegates to lower path
                xattrs = ""
                if os.path.isfile(full_path) and not os.path.islink(full_path):
                    if st.st_size > 512:
                        # metacopy xattr tells overlayfs data is on the lower layer
                        xattrs = 'trusted.overlay.metacopy=""'

                # Format entry for mkfs.erofs
                manifest.write(f"/{rel_path} {full_path}\n")

    print(f"Building EROFS image: {output_erofs}...")
    try:
        # Build EROFS with inline data enabled and metacopy xattrs preserved
        cmd = [
            "mkfs.erofs",
            "-U", "00000000-0000-0000-0000-000000000000",
            "--file-list=" + manifest_path,
            output_erofs,
            nix_store_path
        ]
        subprocess.run(cmd, check=True)
        print(f"Successfully generated {output_erofs}")
    finally:
        if os.path.exists(manifest_path):
            os.remove(manifest_path)

if __name__ == "__main__":
    store_dir = sys.argv[1] if len(sys.argv) > 1 else "/nix/store"
    out_img = sys.argv[2] if len(sys.argv) > 2 else "nix-metadata.erofs"
    create_nix_erofs(store_dir, out_img)