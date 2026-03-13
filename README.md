# FastFlowLM Nix Flake

This repository contains a Nix flake for packaging [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM), a fast Large Language Model (LLM) inference engine optimized for AMD NPUs, along with the required AMD XDNA driver.

## Overview

The flake provides:
1. A reproducible build of the `flm` executable, including its dependencies like `tokenizers-cpp` and the AMD XCLBIN NPU kernels.
2. A NixOS module to easily configure and run the FastFlowLM server as a systemd service with proper access to the AMD NPU device (`/dev/amdxdna`).

## Prerequisites

- A system running Nix with flake support enabled.
- An AMD system with a supported NPU (XDNA architecture).
- Access to the `amd-xdna` driver repository (`https://codeberg.org/tmichnicki/amd-xdna-nix` as configured in `flake.nix`).

## Usage

### Running the CLI directly

You can run the `flm` CLI directly from this flake using `nix run`:

```bash
# Assuming you are in the project directory
nix run . -- --help

# Or remotely
nix run git+https://codeberg.org/tmichnicki/fastflowlm-nix -- --help
```

### NixOS Module

This flake provides a NixOS module that sets up the `flm` server as a systemd service. The AMD NPU driver is **not** included automatically — see the note below for how to enable it.

To use it, add this flake to your system's `flake.nix` inputs and import the module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    fastflowlm-nix.url = "git+https://codeberg.org/tmichnicki/fastflowlm-nix";
  };

  outputs = { self, nixpkgs, fastflowlm-nix, ... }: {
    nixosConfigurations.myMachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        fastflowlm-nix.nixosModules.default
        {
          services.fastflowlm = {
            enable = true;
            model = "llama3.2:1b"; # Default model
            port = 52625;          # Default port
          };
        }
      ];
    };
  };
}
```

#### Module Options

*   `services.fastflowlm.enable`: (Boolean) Enable the FastFlowLM Server.
*   `services.fastflowlm.package`: (Package) The FastFlowLM package to use. Defaults to the one provided by this flake.
*   `services.fastflowlm.model`: (String) The model tag to serve by default. Default: `"llama3.2:1b"`.
*   `services.fastflowlm.port`: (Integer) The port on which the server will listen. Default: `52625`.

**Note:** The systemd service runs as `root` because it requires direct access to `/dev/amdxdna`.

**AMD NPU driver:** This module does **not** automatically enable the AMD NPU driver. You must enable it yourself — either by importing the `amd-xdna` NixOS module directly, or by using the one re-exported from this flake's input:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    fastflowlm-nix.url = "git+https://codeberg.org/tmichnicki/fastflowlm-nix";
    # Reuse the exact amd-xdna version this flake was tested with:
    amd-xdna.follows = "fastflowlm-nix/amd-xdna";
  };

  outputs = { self, nixpkgs, fastflowlm-nix, amd-xdna, ... }: {
    nixosConfigurations.myMachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        amd-xdna.nixosModules.default          # enables hardware.amdnpu
        fastflowlm-nix.nixosModules.default
        {
          hardware.amdnpu.enable = true;
          services.fastflowlm = {
            enable = true;
            model = "llama3.2:1b";
            port = 52625;
          };
        }
      ];
    };
  };
}
```

## Build Details

The build process packaged in this flake handles several complex components:
- **tokenizers-cpp**: Fetches and builds both the Rust (`tokenizers-c`) and C++ parts of the MLX tokenizers library, correctly linking them.
- **XRT (Xilinx Runtime)**: Injects the XRT headers and libraries from the local `amd-xdna` flake input.
- **NPU Kernels**: Extracts and installs the pre-compiled `.so` kernel libraries provided in the FastFlowLM source.
- **RPATH Patching**: Uses `patchelf` to ensure the final `flm` binary and its libraries can dynamically find all dependencies (including XRT, ffmpeg, and util-linux libraries) at runtime within the Nix store.

## License

Please refer to the original [FastFlowLM repository](https://github.com/FastFlowLM/FastFlowLM) for licensing information regarding the source code and NPU binaries.
