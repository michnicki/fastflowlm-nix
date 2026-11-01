{
  description = "FastFlowLM Packaging Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    # The AMD XDNA driver flake
    amd-xdna.url = "git+https://github.com/michnicki/amd-xdna-nix";
    
    # The FastFlowLM source code
    fastflowlm-src = {
      url = "git+https://github.com/ROCm/FastFlowLM";
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

          # Fetch xgrammar (grammar engine for constrained decoding) with its
          # 3rdparty submodules. Pinned to the gitlink FastFlowLM references;
          # only needs updating when FastFlowLM bumps that submodule.
          xgrammar-src = pkgs.fetchFromGitHub {
            owner = "mlc-ai";
            repo = "xgrammar";
            rev = "97787376faee5ed8466cfad57c99855e4ce2f6aa";
            hash = "sha256-Ff/CLdSjq8ammfci+Eu9hY4433e7csf8EeGu2X9B2rI=";
            fetchSubmodules = true;
          };

          # v1.0.11 builds these codec libraries from pinned release tarballs
          # through ExternalProject (src/cmake/FlmAudioCodecs.cmake and
          # FlmImageCodecs.cmake), which downloads at build time — impossible
          # in the Nix sandbox. Pre-fetch them and rewrite the URLs to file://
          # in postPatch; ExternalProject still verifies the same URL_HASH.
          # Versions and hashes track upstream's pins; only need updating when
          # FastFlowLM bumps these dependencies.
          libjpeg-turbo-tarball = pkgs.fetchurl {
            url = "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz";
            hash = "sha256-bzAJLO+fuDl3lkZgj07hSuPLrJicR/oF6EGwhB8Jh44=";
          };
          libwebp-tarball = pkgs.fetchurl {
            url = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz";
            hash = "sha256-5KtwCb8GKf0RmC1MKqg5ZM8kTP+6c0fs05AZqeOMRWQ=";
          };
          opus-tarball = pkgs.fetchurl {
            urls = [
              "https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz"
              "https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz"
            ];
            hash = "sha256-b/y1kyB76SWE3xWzJGbtZLvsmRCfAHyCIF8BlFckEaE=";
          };
          ogg-tarball = pkgs.fetchurl {
            urls = [
              "https://github.com/xiph/ogg/releases/download/v1.3.6/libogg-1.3.6.tar.gz"
              "https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz"
              "https://ftp.osuosl.org/pub/xiph/releases/ogg/libogg-1.3.6.tar.gz"
            ];
            hash = "sha256-g+ZwRzBoPQBNIOIbj39V3LM4PN+EwNrt8wveF193Rjg=";
          };
          vorbis-tarball = pkgs.fetchurl {
            urls = [
              "https://github.com/xiph/vorbis/releases/download/v1.3.7/libvorbis-1.3.7.tar.gz"
              "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz"
              "https://ftp.osuosl.org/pub/xiph/releases/vorbis/libvorbis-1.3.7.tar.gz"
            ];
            hash = "sha256-DpgkCanD/ILuBuCCBbE1XlxqpMNrylgUbvOZYhsM5as=";
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

          # NPU kernel libraries from FastFlowLM source.
          #
          # Upstream keeps the prebuilt engine libs in a per-backend subdirectory
          # so the XRT and HRX builds never collide (src/lib/xrt vs src/lib/hrx).
          # This must track FLM_ENGINE_LIB_DIR in src/CMakeLists.txt, which follows
          # FLM_USE_HRX; we leave that at its default of OFF, so xrt it is. The top
          # of src/lib holds only Windows .dll files plus two stale .so leftovers.
          npu-kernel-libs = pkgs.stdenv.mkDerivation {
            name = "flm-npu-libs";
            src = "${fastflowlm-src}/src/lib/xrt";
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
            version = "1.0.11";
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
              # v1.0.11 switched line editing from GPL readline to BSD
              # libedit (readline-compatible API, linked via pkg-config).
              pkgs.libedit
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

              # Same for the xgrammar submodule (v1.0.11+ builds flm_xgrammar
              # from third_party/xgrammar sources).
              rm -rf "$sourceRoot/third_party/xgrammar"
              cp -r ${xgrammar-src} "$sourceRoot/third_party/xgrammar"
              chmod -R u+w "$sourceRoot/third_party/xgrammar"

              # Create a fake cargo stub so the CMake custom command won't invoke real cargo
              cat > "$sourceRoot/third_party/tokenizers-cpp/fake-cargo" << 'FAKECARGO'
#!/bin/sh
exit 0
FAKECARGO
              chmod +x "$sourceRoot/third_party/tokenizers-cpp/fake-cargo"
            '';

            postPatch = ''
              # Point the codec ExternalProjects at the pre-fetched tarballs
              # instead of downloading at build time. file:// URLs keep the
              # URL_HASH verification intact.
              sed -i 's|URL https://github.com/libjpeg-turbo/.*|URL file://${libjpeg-turbo-tarball}|' \
                src/cmake/FlmImageCodecs.cmake
              sed -i 's|URL https://storage.googleapis.com/.*|URL file://${libwebp-tarball}|' \
                src/cmake/FlmImageCodecs.cmake
              sed -i 's|"[^"]*opus-1\.6\.1\.tar\.gz[^"]*"|"file://${opus-tarball}"|' \
                src/cmake/FlmAudioCodecs.cmake
              sed -i 's|"[^"]*libogg-1\.3\.6\.tar\.gz[^"]*"|"file://${ogg-tarball}"|' \
                src/cmake/FlmAudioCodecs.cmake
              sed -i 's|"[^"]*libvorbis-1\.3\.7\.tar\.gz[^"]*"|"file://${vorbis-tarball}"|' \
                src/cmake/FlmAudioCodecs.cmake
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
                -DFLM_VERSION=1.0.11 \
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
                pkgs.libedit
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
