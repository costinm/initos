{
  description = "llama.cpp CUDA profile with matching NVIDIA userspace libraries";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          cudaSupport = true;
          allowUnfreePredicate = pkg: true;
        };
      };

      llama-cuda = pkgs.llama-cpp.override { cudaSupport = true; };
      cuda-toolkit = pkgs.cudaPackages.cudatoolkit;
      nvidia = pkgs.linuxPackages.nvidia_x11;

      runtimePath = pkgs.lib.makeBinPath [
        cuda-toolkit
        nvidia.bin
      ];

      runtimeLibPath = pkgs.lib.makeLibraryPath [
        cuda-toolkit
        nvidia
        pkgs.stdenv.cc.cc.lib
      ];

      setenv = pkgs.writeShellScriptBin "setenv" ''
        # Source this file to update the current shell:
        #   source target/nix/profile/bin/setenv
        #
        # Running it directly starts an interactive shell with the same env.
        if (return 0 2>/dev/null); then
          sourced=1
        else
          sourced=0
        fi

        script="''${BASH_SOURCE[0]:-$0}"
        profile_bin="$(cd "$(dirname "$script")" && pwd)"

        export CUDA_HOME="${cuda-toolkit}"
        export CUDA_PATH="${cuda-toolkit}"
        export PATH="$profile_bin:${runtimePath}:$PATH"
        export LD_LIBRARY_PATH="${runtimeLibPath}:''${LD_LIBRARY_PATH:-}"

        if [ "$sourced" -eq 0 ]; then
          exec "''${SHELL:-/bin/sh}" -i
        fi
      '';

      wrapped-llama = pkgs.runCommand "llama-cpp-cuda-wrapped"
        {
          nativeBuildInputs = [ pkgs.makeWrapper ];
        }
        ''
          mkdir -p $out/bin

          for bin in ${llama-cuda}/bin/*; do
            name="$(basename "$bin")"
            makeWrapper "$bin" "$out/bin/$name" \
              --set CUDA_HOME "${cuda-toolkit}" \
              --set CUDA_PATH "${cuda-toolkit}" \
              --prefix PATH : "${runtimePath}" \
              --prefix LD_LIBRARY_PATH : "${runtimeLibPath}"
          done
        '';
    in
    {
      packages.${system} = {
        default = pkgs.buildEnv {
          name = "llama-cuda-profile";
          paths = [
            setenv
            wrapped-llama
            cuda-toolkit
            nvidia
            nvidia.bin
          ];
        };
      };
    };
}
