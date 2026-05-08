{
  description = "FastFlowLM Packaging Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    # The AMD XDNA driver flake
    amd-xdna.url = "git+https://codeberg.org/tmichnicki/amd-xdna-nix";
    
    # The FastFlowLM source code
    fastflowlm-src = {
      url = "git+https://github.com/FastFlowLM/FastFlowLM";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, amd-xdna, fastflowlm-src }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          
          # Use the driver from our local repository
          xrt = amd-xdna.packages.${system}.default;
          
          rustPlatform = pkgs.rustPlatform;

          # Fetch tokenizers-cpp with submodules
          tokenizers-cpp-src = pkgs.fetchFromGitHub {
            owner = "mlc-ai";
            repo = "tokenizers-cpp";
            rev = "acbdc5a27ae01ba74cda756f94da698d40f11dfe";
            hash = "sha256-/Y9FphwL0zs9hXyfvEbDbaDKAzy/hJ9qlSpUzViuDo8=";
            fetchSubmodules = true;
          };

          # Build tokenizers-cpp Rust library
          tokenizers-c-rust = rustPlatform.buildRustPackage {
            name = "tokenizers-c";
            version = "0.1.0";
            src = "${tokenizers-cpp-src}/rust";
            cargoHash = "sha256-AYsFZSWmWRLXLKNeFsHpc5pE09GazTvENr3yXvHCt2s=";
            postUnpack = ''
              cp ${./Cargo.lock} "$sourceRoot/Cargo.lock"
            '';
          };

          # Build tokenizers-cpp C++ library
          tokenizers-cpp = pkgs.stdenv.mkDerivation {
            name = "tokenizers-cpp";
            version = "0.1.0";
            src = tokenizers-cpp-src;
            nativeBuildInputs = [ pkgs.cmake pkgs.ninja ];
            buildInputs = [ tokenizers-c-rust ];
            postUnpack = ''
              mkdir -p "$sourceRoot/build/release"
              cp ${tokenizers-c-rust}/lib/libtokenizers_c.a "$sourceRoot/build/release/"
              cat > "$sourceRoot/build/cargo" << 'EOF'
#!/bin/sh
exit 0
EOF
              chmod +x "$sourceRoot/build/cargo"
            '';
            configurePhase = ''
              cmake -S . -B build -G Ninja \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=$out \
                -DCARGO_EXECUTABLE=$PWD/build/cargo
            '';
            buildPhase = "ninja -C build";
            installPhase = "ninja -C build install";
          };

          # NPU kernel libraries from FastFlowLM source
          npu-kernel-libs = pkgs.stdenv.mkDerivation {
            name = "flm-npu-libs";
            src = "${fastflowlm-src}/src/lib";
            dontConfigure = true;
            dontBuild = true;
            installPhase = ''
              mkdir -p $out/lib
              for lib in lib*.so; do
                [ -f "$lib" ] && cp -v "$lib" $out/lib/
              done
            '';
          };

          flm = pkgs.stdenv.mkDerivation {
            pname = "flm";
            version = "0.9.41";
            src = fastflowlm-src;

            nativeBuildInputs = [
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
              pkgs.python3
              pkgs.makeWrapper
            ];

            buildInputs = [
              pkgs.boost
              pkgs.curl
              pkgs.fftw
              pkgs.fftwFloat
              pkgs.fftwLongDouble
              pkgs.ffmpeg
              pkgs.readline
              pkgs.libxcrypt
              pkgs.zlib
              pkgs.util-linux.dev
              pkgs.util-linux.lib
              pkgs.libdrm
              tokenizers-cpp
              xrt
            ];

            propagatedBuildInputs = [ npu-kernel-libs ];

            postUnpack = ''
              # Replace empty submodule with the fetched tokenizers-cpp source
              rm -rf "$sourceRoot/third_party/tokenizers-cpp"
              mkdir -p "$sourceRoot/third_party"
              cp -r ${tokenizers-cpp-src} "$sourceRoot/third_party/tokenizers-cpp"
              chmod -R u+w "$sourceRoot/third_party/tokenizers-cpp"

              # Create a fake cargo stub so the CMake custom command won't invoke real cargo
              cat > "$sourceRoot/third_party/tokenizers-cpp/fake-cargo" << 'FAKECARGO'
#!/bin/sh
exit 0
FAKECARGO
              chmod +x "$sourceRoot/third_party/tokenizers-cpp/fake-cargo"
            '';

            configurePhase = ''
              runHook preConfigure
              XRT_INCLUDE_PATH="${xrt}/include"
              XRT_LIB_PATH="${xrt}/lib"
              [[ ! -d "$XRT_LIB_PATH" ]] && XRT_LIB_PATH="${xrt}/lib64"

              TOKENIZERS_CPP_LIB=$(echo ${tokenizers-cpp}/lib)
              UTIL_LINUX_LIB=$(echo ${pkgs.util-linux.lib}/lib)

              # Pre-populate the tokenizers-cpp cmake binary dir so cargo is never invoked
              mkdir -p src/build/tokenizers-cpp/release
              cp ${tokenizers-c-rust}/lib/libtokenizers_c.a src/build/tokenizers-cpp/release/

              cmake -S src -G Ninja -B src/build \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=$out \
                -DCMAKE_XCLBIN_PREFIX=$out/share/flm \
                -DFLM_VERSION=0.9.41 \
                -DNPU_VERSION=32.0.203.304 \
                -DXRT_INCLUDE_DIR="$XRT_INCLUDE_PATH" \
                -DXRT_LIB_DIR="$XRT_LIB_PATH" \
                -DCMAKE_PREFIX_PATH="$TOKENIZERS_CPP_LIB" \
                -DCMAKE_EXE_LINKER_FLAGS="-L$UTIL_LINUX_LIB -luuid" \
                -DCARGO_EXECUTABLE="$PWD/third_party/tokenizers-cpp/fake-cargo"
              runHook postConfigure
            '';

            buildPhase = "ninja -C src/build";

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/lib $out/share/flm
              cp src/build/flm $out/bin/
              cp -v ${npu-kernel-libs}/lib/*.so $out/lib/
              chmod u+w $out/lib/*.so
              cp -r src/xclbins $out/share/flm/ 2>/dev/null || true
              cp src/model_list.json $out/share/flm/
              runHook postInstall
            '';

            fixupPhase = ''
              runHook preFixup
              XRT_LIB_PATH_SAVED="${xrt}/lib"
              [[ ! -d "$XRT_LIB_PATH_SAVED" ]] && XRT_LIB_PATH_SAVED="${xrt}/lib64"
              wrapProgram $out/bin/flm --set XILINX_XRT "${xrt}"
              FULL_RPATH=${pkgs.lib.makeLibraryPath [
                pkgs.util-linux.lib
                pkgs.ffmpeg.lib
                pkgs.curl.out
                pkgs.boost
                pkgs.fftw
                pkgs.fftwFloat
                pkgs.fftwLongDouble
                pkgs.readline
                pkgs.ncurses
                pkgs.gcc.libc
                pkgs.stdenv.cc.cc
              ]}
              patchelf --set-rpath "$out/lib:$XRT_LIB_PATH_SAVED:$FULL_RPATH" $out/bin/flm 2>/dev/null || true
              find $out/lib -name "*.so" -exec patchelf --set-rpath "$XRT_LIB_PATH_SAVED:$FULL_RPATH" {} \; 2>/dev/null || true
              runHook postFixup
            '';
          };
        in {
          default = flm;
          fastflowlm = flm;
        }
      );

      # NixOS Module to enable FastFlowLM with the NPU driver
      nixosModules.default = { config, lib, pkgs, ... }: {
        options.services.fastflowlm = {
          enable = lib.mkEnableOption "FastFlowLM Server";
          package = lib.mkOption {
            type = lib.types.package;
            default = self.packages.${pkgs.system}.default;
          };
          model = lib.mkOption {
            type = lib.types.str;
            default = "llama3.2:1b";
            description = "The model tag to serve by default.";
          };
          port = lib.mkOption {
            type = lib.types.port;
            default = 52625;
          };
        };

        config = lib.mkIf config.services.fastflowlm.enable {
          environment.systemPackages = [ config.services.fastflowlm.package ];
          
          systemd.services.fastflowlm = {
            description = "FastFlowLM NPU Server";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${config.services.fastflowlm.package}/bin/flm serve ${config.services.fastflowlm.model} --port ${toString config.services.fastflowlm.port}";
              Restart = "always";
              User = "root"; # Needs access to /dev/amdxdna
            };
          };
        };
      };
    };
}
