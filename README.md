# fastflowlm-nix

Nix flake for [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM), a fast LLM inference engine optimized for AMD NPUs, plus a NixOS module for running the `flm` server.

## Package Summary

| Field | Value |
|---|---|
| Upstream | [FastFlowLM/FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) |
| Packaged version | `0.9.43` |
| Main program | `flm` |
| Supported systems | `x86_64-linux` |
| Flake outputs | `packages.x86_64-linux.default`, `packages.x86_64-linux.fastflowlm`, `nixosModules.default` |

## Requirements

- Nix with flakes enabled.
- An AMD system with a supported XDNA NPU.
- Access to `/dev/amdxdna`.
- The AMD XDNA driver enabled, for example through [amd-xdna-nix](https://github.com/michnicki/amd-xdna-nix).

## Usage

### Run without installing

```bash
nix run github:michnicki/fastflowlm-nix -- --help
```

### Build

```bash
nix build github:michnicki/fastflowlm-nix
```

### Enable the NixOS module

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    amd-xdna-nix.url = "github:michnicki/amd-xdna-nix";

    fastflowlm-nix = {
      url = "github:michnicki/fastflowlm-nix";
      inputs.amd-xdna.follows = "amd-xdna-nix";
    };
  };

  outputs = { nixpkgs, amd-xdna-nix, fastflowlm-nix, ... }: {
    nixosConfigurations.my-machine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        amd-xdna-nix.nixosModules.default
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

The `services.fastflowlm` module options are:

| Option | Default | Description |
|---|---|---|
| `enable` | `false` | Enables the FastFlowLM server service. |
| `package` | This flake's default package | Package used by the service. |
| `model` | `"llama3.2:1b"` | Model tag served by default. |
| `port` | `52625` | TCP port used by the server. |

The service runs as `root` because it needs direct access to `/dev/amdxdna`.

## Development

This flake does not define a dedicated development shell. Use `nix build` for local verification.

## Updating

Use the update helper from the repository root:

```bash
./scripts/update-fastflowlm.sh [--dry-run]
```

The script fetches the latest upstream release or tag, updates the FastFlowLM version and source lock, verifies the build, and commits the bump. The pinned `tokenizers-cpp` dependency only needs manual attention if upstream changes that dependency.

## License

See the [upstream FastFlowLM repository](https://github.com/FastFlowLM/FastFlowLM) for source and NPU binary licensing details.
